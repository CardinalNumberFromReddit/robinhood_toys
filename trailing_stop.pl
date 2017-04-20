#!/usr/bin/env perl
use strict;
use warnings;

# Install Perl dist first:
# > cpanm -n Finance::Robinhood

use lib '..\lib', 'lib';
use Getopt::Long qw(GetOptions);
use Pod::Usage qw(pod2usage);
use Finance::Robinhood;
use Try::Tiny;
$|++;
#
my ($help, $man,    # Pod::Usage
    $verbose,       # Debugging
    $username, $password,    # New login
    $token,                  # Stored access token
    $percent, $tight         # How much rope to give us
);
## Parse options and print usage if there is a syntax error,
## or if usage was explicitly requested.
GetOptions('help|?'       => \$help,
           man            => \$man,
           'verbose+'     => \$verbose,
           'username|u:s' => \$username,
           'password|p:s' => \$password,
           'token:s'      => \$token,
           'percent|%t=f' => \$percent,
           'tight=f'      => \$tight
) or pod2usage(2);
$percent //= 3;    # Defaults
$tight   //= 2;    # Defaults

#$verbose++;
#
pod2usage(1) if $help;
pod2usage(-verbose => 2) if $man;
pod2usage("$0: Not sure how far away to keep orders.") if !$percent;
pod2usage(
    -message =>
        "$0: Missing or incomplete username/password combo given and no authorization token either.",
    -verbose => 1,
    -exitval => 1
) if !(($username && $password) || ($token));
$Finance::Robinhood::DEBUG = $verbose;    # Debugging!
#
my $rh = new Finance::Robinhood($token ? (token => $token) : ());
if ($username && $password && !$token) {
    $rh->login($username, $password) || exit;
}
my $account = $rh->accounts()->{results}[0];   # Accounts are a paginated list
#
sub load_positions {
    my (%positions, %orders);
    my $next = {nonzero => 1};
    try {
        while ($next) {
            my $positions = $account->positions($next);
            for my $position (@{$positions->{results}}) {
                $positions{$position->instrument->symbol} = $position;
                my $orders = $rh->list_orders(
                                  {instrument => $position->instrument->url});
                @{$orders{$position->instrument->symbol}} = grep {
                    my $state = $_->state;
                    $_->side eq 'sell'
                        && (   $state eq 'queued'
                            || $state eq 'confirmed'
                            || $state eq 'partially_filled')
                        && $_->instrument->symbol eq
                        $position->instrument->symbol
                } @{$orders->{results}};
            }
            last if !$positions->{next};
            $next = $positions->{next};
        }
    };
    return (\%positions, \%orders);
}
sub to_price { sprintf(($_[0] < 1 ? '%.4f' : '%.2f'), $_[0]) }
#
while (1) {
    my ($positions, $orders) = load_positions();
    for my $symbol (keys %$positions) {
        my $quote = $positions->{$symbol}->instrument->quote;
        my $bid   = $quote->bid_price;

        #  TODO: Change this to $bid or $ask for delay
        my $trailing_price = to_price(($bid - ($bid * ($percent / 100))));

#$trailing_price = price(
#               ($positions->{$symbol}->average_buy_price
#                    - ($positions->{$symbol}->average_buy_price * ($tight / 100))
#               )
#) if $positions->{$symbol}->average_buy_price > $trailing_price;
        my @orders = grep { $_->stop_price < $trailing_price }
            grep { $_->_can_cancel && $_->state ne 'canceled' }
            @{$orders->{$symbol}};
        my $quantity = $positions->{$symbol}->quantity
            - $positions->{$symbol}->shares_held_for_sells;
        for my $order (@orders) {
            $order->cancel;
            for (1 .. 10) {
                sleep 1;    # XXX - Somehow this isn't instant
                $order->refresh;
                if ($order->state eq 'cancelled') {
                    $quantity += $order->quantity;
                    last;
                }
            }
        }
        next if !$quantity;
        CORE::say sprintf "\rsetting stop price to %s for %d shares of %s",
            $trailing_price, $quantity, $symbol;
        try {
            my $order =
                Finance::Robinhood::Order->new(
                              instrument => $positions->{$symbol}->instrument,
                              account    => $account,
                              type       => 'market',
                              trigger    => 'stop',
                              stop_price => $trailing_price,
                              side       => 'sell',
                              time_in_force => 'gtc',
                              quantity      => $quantity
                );

 # TODO: What if the order is rejected? (stop price below current price, etc.)
        }
        catch {
            warn "Caught error placing order: $_";
        }
    }
    sleep 15;
}
