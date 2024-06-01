import network
import socket
from time import sleep
import machine
import requests

ap_ssid = 'Pico'
ap_password = 'RaspPi4B07'
ap = network.WLAN(network.AP_IF)
ap.config(essid=ap_ssid, password=ap_password)
ap.active(True)

def open_socket(ip):
    address = (ip, 80)
    connection = socket.socket()
    connection.bind(address)
    connection.listen(1)
    return connection
    
def serve(connection):
    # Start web server
    while True:
        try:
            client = connection.accept()[0]
            request = client.recv(1024)
            request = str(request)
            
            try:
                method = request.split()[0]
                print(method)
                path = request.split()[1]
            except IndexError:
                pass
            
            if method == "b'POST" and path == '/POST':
                print('POST', connection)
                conn, addr = connection.accept()
                data = conn.recv(1024).decode("ascii")
                print(data)
                
            elif method == 'GET':
                try:
                    path = path.split('?')[0]
                    print(path)
                except IndexError:
                    pass
            
            client.send(200)
            client.close()
        
        except Exception as e:
            # Log the error and continue
            print(f"Error: {e}")
            continue

try:
    ip = connect()
    connection = open_socket(ip)
    serve(connection)
except KeyboardInterrupt:
    machine.reset()