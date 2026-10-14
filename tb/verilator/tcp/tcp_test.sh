#!/usr/bin/env bash

source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"
tb_init tcp "$@"

tb_build tcp_rx tcp_rx tcp_rx.cpp rtl/tcp/tcp_rx.sv rtl/common/hdr_strip.sv

tb_run tcp_rx

tb_sweep tcp_rx SEGMENTS=200000

tb_summary
