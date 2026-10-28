#!/usr/bin/env python3
# Reads the meter's UART lines (min max avg lost, hex, in 6.4 ns clocks) and prints nanoseconds.
# usage:
#   python3 fpga/zcu106/meter.py /dev/ttyUSB1              what the meter reads
#   python3 fpga/zcu106/meter.py /dev/ttyUSB1 --loop 21    with the loopback reading (avg, in clocks) taken off
# set the port to 115200 baud first: stty -F /dev/ttyUSB1 115200 raw

import argparse

CLOCK_NS = 6.4

def parse(line):
    fields = line.split()
    if len(fields) != 4:
        return None
    try:
        return [int(f, 16) for f in fields]
    except ValueError:
        return None

def show(report, loop):
    lo, hi, avg, lost = report
    if lo > hi:
        return f"no echo, {lost} probes lost"
    ns = [(v - loop) * CLOCK_NS for v in (lo, hi, avg)]
    text = f"min {ns[0]:7.1f} ns  max {ns[1]:7.1f} ns  avg {ns[2]:7.1f} ns  ({lo} {hi} {avg} clocks)"
    if lost:
        text += f"  {lost} lost, avg is low"
    return text

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("port")
    ap.add_argument("--loop", type=float, default=0.0)
    args = ap.parse_args()
    with open(args.port, "r", errors="replace") as f:
        for line in f:
            report = parse(line)
            if report:
                print(show(report, args.loop), flush=True)
