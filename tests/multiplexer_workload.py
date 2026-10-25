"""Finite-rate log producer for isolated multiplexer stress sessions."""
import os
import time

step = 0
try:
    while True:
        os.write(1, f"\x1b[36mbuild step {step:08d}\x1b[0m: []{{}}() => log output\r\n".encode())
        step += 1
        time.sleep(0.005)
except (BrokenPipeError, KeyboardInterrupt):
    pass
