#!/usr/bin/env bash

source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"
tb_init mac "$@"
M=rtl/mac
T=tb/verilator/mac

tb_build crc32 crc32_top crc32.cpp $T/crc32_top.sv $M/crc32.sv
tb_build mac_rx mac_rx mac_rx.cpp $M/mac_rx.sv $M/crc32.sv
tb_build mac_tx mac_tx mac_tx.cpp $M/mac_tx.sv $M/crc32.sv
tb_build mac_link mac_link mac_link.cpp $T/mac_link.sv $M/mac_tx.sv $M/mac_rx.sv $M/crc32.sv

tb_run crc32
tb_run mac_rx
tb_run mac_tx
tb_run mac_link

tb_sweep crc32 ROUNDS=500000
tb_sweep mac_rx FRAMES=100000
tb_sweep mac_tx FRAMES=100000
tb_sweep mac_link FRAMES=100000

tb_summary
