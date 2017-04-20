#!/usr/bin/python

# trailing_stop.py

# Install python package:
# > pip install https://github.com/swgr424/Robinhood/archive/master.zip
# swgr424 includes a PR for gathering quotes for multiple symbols at once
# Wait...

from Robinhood import Robinhood
import time
import argparse
from six.moves.urllib.parse import unquote

# Debug
#from pprint import pprint

''' Python example of trailing stop loss simulation for Robinhood

Example:

    ./trailing_stop.py -u=cardinalnumber -p=Ujp43wJi0fsajk54ew

'''

# Assign description to the help doc
parser = argparse.ArgumentParser(
    description='Demo stop loss orders for Robinhood')
# Add arguments
parser.add_argument(
    '-u', '--username', type=str, help='User name', required=True)
parser.add_argument(
    '-p', '--password', type=str, help='Password', required=True)
parser.add_argument(
    '--percent', type=float, help='Trailing percent', required=False, default=3)
#parser.add_argument(
#    '--tight', type=float, help='Trailing percent when below average price', required=False, default=2)
# Array for all arguments passed to script
args = parser.parse_args()
# Assign args to variables
#    server = args.server

#pprint(args)
#
rh = Robinhood()
logged_in = rh.login(username=args.username, password=args.password)
account = rh.get_account()

def load_positions():
    _pos = {}
    _ord = {}
    next = rh.endpoints['positions'] + '?nonzero=true'
    while True:
        positions = rh.session.get(next).json()
        for position in positions.get('results'):
            instrument = rh.session.get(position['instrument']).json()
            _pos[instrument['symbol']] = position
            _ord[instrument['symbol']] = list(filter(lambda x: x['side'] == 'sell' and x['cancel'] != None, rh.session.get(rh.endpoints['orders'] + '?instrument=' + position['instrument']).json().get('results')))
        if positions['next'] == None:
            break
        next = positions['next']
    return _pos, _ord

def to_price(price):
    return( float(('%.4f' if float(price) < 1 else '%.2f') % float(price)))

while True:
    positions, orders = load_positions()
    quotes = rh.session.get(rh.endpoints['quotes'] + '?symbols=' + ',' .join(list(positions.keys()))).json().get('results')
    for idx,symbol in enumerate(positions):
        #print("Average price of ${0}: ${1} | bid ${2}" . format(symbol, positions[symbol]['average_buy_price'], quotes[idx]['bid_price']))
        trailing_price = to_price((to_price(quotes[idx]['bid_price']) - (to_price(quotes[idx]['bid_price']) * float(args.percent / 100))))
        #if to_price(positions[symbol]['average_buy_price']) > trailing_price:
        #    trailing_price = to_price(
        #               (to_price(positions[symbol]['average_buy_price'])
        #                    - (to_price(positions[symbol]['average_buy_price']) * float(args.tight / 100))
        #               )
        #    )
        #print (" trailing price: %f" % trailing_price)
        quantity = float(positions[symbol]['quantity']) - float(positions[symbol]['shares_held_for_sells'])
        for order in list(filter(lambda order: float(order.get('stop_price')) < trailing_price, orders[symbol] )):
            #pprint(order)
            quantity += float(order['quantity'])
            rh.session.post(order['cancel']).json() # TODO: verify
        if quantity:
            print('Setting stop loss at ${0} for {1} shares of ${2}' . format(trailing_price, quantity, symbol))
            res = rh.session.post(
                rh.endpoints['orders'],
                data = {
                'account': unquote(account['url']),
                'instrument': unquote(positions[symbol]['instrument']),
                'price': float(quotes[idx]['bid_price']),
                'stop_price' : float(trailing_price),
                'quantity': quantity,
                'side': 'sell',
                'symbol': symbol,
                'time_in_force': 'gtc',
                'trigger': 'stop',
                'type': 'market'
            }
            )
            res.raise_for_status()
            # TODO: verify
    time.sleep(15)
