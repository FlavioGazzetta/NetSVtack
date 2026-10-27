#!/usr/bin/env bash

source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"
tb_init echo "$@"
RTL=$(cd "$REPO_ROOT" && find rtl -name '*.sv' | sort)

tb_build echo netsvtack_echo echo.cpp $RTL
tb_build meter meter_link meter.cpp tb/verilator/echo/meter_link.sv $RTL

tb_run echo
tb_run echo PPM=-1000
tb_run meter
tb_run meter LOOP=1

tb_sweep echo DATAGRAMS=50000 BYTES=2000000
tb_sweep meter REPORTS=2000

tb_summary
