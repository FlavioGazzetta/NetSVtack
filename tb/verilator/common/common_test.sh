#!/usr/bin/env bash

source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"
tb_init common "$@"
C=rtl/common
T=tb/verilator/common

for b in 8 14 20 28
do
    tb_build hdr_link_$b hdr_link hdr_link.cpp $T/hdr_link.sv $C/hdr_insert.sv $C/hdr_strip.sv -GBYTES=$b
done

for b in 8 14 20 28
do
    tb_run hdr_link_$b
done

for b in 8 14 20 28
do
    tb_sweep hdr_link_$b FRAMES=100000
done

tb_summary
