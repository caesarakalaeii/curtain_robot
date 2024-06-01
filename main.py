import asyncio
from micropyserver import MicroPyServer
import time
from utils import *
from curtain_bot import CurtainBot
import _thread

# setting up network
import network
from my_secrets import ssid, passw

import ntptime


def do_connect():
    wlan = network.WLAN(network.STA_IF)
    wlan.active(True)
    if not wlan.isconnected():
        print('connecting to network...')
        wlan.connect(ssid, passw)
        while not wlan.isconnected():
            pass
    print('network config:', wlan.ifconfig())
    ntptime.host = "1.europe.pool.ntp.org"
    print('setting correct time')
    ntptime.settime()   

server = MicroPyServer()
running = True
bot = CurtainBot(speed=10)




# main loop to check distance and drive motor

def route_api_get_distance(request):
    send_response(server, bot.get_distance())

def route_api_set_pos(request):
    if get_request_method(request) != 'POST':
        send_response(server, 'Disallowed Request', 404)
        return
    params = get_request_post_params(request)
    if params['pos']:
        bot.set_target(params['pos'])
        
def rout_api_info(request):
    send_response(server, bot.get_info_json())        

def route_api_close(request):
    bot.close()
    
def route_api_open(request):
    bot.open()
    
def route_index(request):
    send_response(server, f'Hello World! {bot.get_distance()} {time.localtime()}')
        
server.add_route('/api/getDistance', route_api_get_distance)
server.add_route('/api/setPos', route_api_set_pos)
server.add_route('/api/close', route_api_close)
server.add_route('/api/open', route_api_open)
server.add_route('/api/getInfo', rout_api_info)
server.add_route('/', route_index)

do_connect()
_thread.start_new_thread(server.start, ())
asyncio.run(bot.run())
bot.explode()