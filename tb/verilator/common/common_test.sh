#!/usr/bin/env bash

source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"
tb_init common "$@"
C=rtl/common
T=tb/verilator/common

for b in 8 14 20 28
do
    tb_build hdr_link_$b hdr_link hdr_link.cpp $T/hdr_link.sv $C/hdr_insert.sv $C/hdr_strip.sv -GBYTES=$b
done
tb_build cdc_link cdc_link cdc_link.cpp $T/cdc_link.sv $C/frame_cdc.sv

for b in 8 14 20 28
do
    tb_run hdr_link_$b
done

tb_run cdc_link
tb_run cdc_link PPM=1000
tb_run cdc_link PPM=-1000
tb_run cdc_link PPM=-1000 GAPS=1

for b in 8 14 20 28
do
    tb_sweep hdr_link_$b FRAMES=100000
done

tb_sweep cdc_link FRAMES=200000 PPM=200
tb_sweep cdc_link FRAMES=200000 PPM=-200

tb_summary
