import math
import machine
from machine import Pin
import time
import asyncio
# stepts per rev = 200
# write high -> wait -> write low -> wait
# wait controls the speed

usleep = lambda x: asyncio.sleep(x/1000000.0)
class Stepper(object):
    steps_per_revolution:int
    speed:int
    
    def __init__(self, step_pin: int, dir_pin: int, steps_per_revolution = 2000, speed = 1000):
        self.step_pin = Pin(step_pin, Pin.OUT)
        self.dir_pin = Pin(dir_pin, Pin.OUT)
        self.steps_per_revolution = steps_per_revolution
        self.speed = speed
    
    
    async def rotate(self, revs:float, dir = False):
        self.dir_pin.off()
        self.step_pin.off()
        print(f'Rotating {revs} Revolutions')
        if dir:
            self.dir_pin.on()
        else:
            self.dir_pin.off()
        for i in range(math.floor(revs*self.steps_per_revolution)):
            # print(f'Stepping step {i} of {revs*self.steps_per_revolution} steps, Speed: {self.speed}')
            self.step_pin.on()
            await usleep(self.speed) # sleep wants s but we want μs
            self.step_pin.off()
            await usleep(self.speed) # sleep wants s but we want μs
            # print(f'Step took {(time.time_ns()-start)/1000}us')
        self.dir_pin.off()
        self.step_pin.off()