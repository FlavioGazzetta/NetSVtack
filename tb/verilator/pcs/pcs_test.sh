#!/usr/bin/env bash

source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"
tb_init pcs "$@"
P=rtl/pcs
T=tb/verilator/pcs

tb_build pcs_link pcs_link pcs_link.cpp $T/pcs_link.sv $P/pcs_tx.sv $P/pcs_rx.sv

tb_run pcs_link
tb_run pcs_link ERR=0 DROP=0 SPECIAL=0
tb_run pcs_link DROP=4000 ERR=200

tb_sweep pcs_link FRAMES=100000
tb_sweep pcs_link FRAMES=100000 DROP=4000 ERR=200

tb_summary
