import asyncio
from VL53L0X import VL53L0X
from machine import I2C
from stepper import Stepper
import time

class CurtainBot(object):
    
    
    def __init__(self, 
                 distance_per_rev = 20, 
                 target_open = 300, 
                 target_close = 1000, 
                 close_time = '23:00',
                 open_time = '04:00',
                 tolerance = 20,
                 step_pin = 12, 
                 dir_pin = 14, 
                 speed= 50, 
                 i2c_mode = 0,
                 tof_i2c_addr = 0x29) -> None:
        self.distance_per_rev = distance_per_rev
        self.target_open = target_open
        self.target_close = target_close
        self.current_target = target_open
        self.tolerance = tolerance
        self.open_time = open_time
        self.close_time = close_time
        
        
        i2c = I2C(i2c_mode)
        addrs = i2c.scan()
        print("Scanning devices:", [hex(x) for x in addrs])
        if tof_i2c_addr not in addrs:
            print("ToF is not detected")
        self.tof = VL53L0X(i2c)
        self.motor = Stepper(step_pin, dir_pin,steps_per_revolution=2000, speed=speed)
        self.running = False
        
    def close(self):
        self.current_target = self.target_close
        
    def open(self):
        print('PRAISE THE SUN!')
        self.current_target = self.target_open
    
    def stop(self):
        self.running = False
        
    def get_distance(self):
        return self.tof.read()
    
    def set_target(self, target_d):
        self.current_target = target_d
    
    def set_distance_per_rev(self, distance_per_rev):
        self.distance_per_rev = distance_per_rev

    def get_info_json(self):
        return self.__dict__
    
    def explode(self):
        print('BOOM!')


    async def run(self):
        self.running = True
        print('running')
        while True:
            distance = 0
            current_time = time.strftime('%H:%M')
            if current_time == self.close_time:
                self.current_target = self.target_close
            elif current_time == self.open_time:
                self.current_target = self.target_open
            try:
                distance = self.get_distance()
                if distance >= 8100:
                    print('Error ranging')
                    await asyncio.sleep(0.1)
                    return
            
            except Exception as e:
                print(f'Error: {e}')
                await asyncio.sleep(0.1)
                return
            print(distance)
            delta = self.current_target - distance
            
            if abs(delta) < self.tolerance:
                return
            if delta > 0:
                print(f'rotating {delta/self.distance_per_rev} left')
                await self.motor.rotate(delta/self.distance_per_rev, False)
            else:
                print(f'rotating {delta/self.distance_per_rev} right')
                
                await self.motor.rotate(abs(delta/self.distance_per_rev), True)