#!/usr/bin/env bash

source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"
tb_init tcp "$@"

RTL=$(cd "$REPO_ROOT" && find rtl -name '*.sv' | sort)

tb_build tcp_rx tcp_rx tcp_rx.cpp rtl/tcp/tcp_rx.sv rtl/common/hdr_strip.sv
tb_build tcp_conn netsvtack tcp_conn.cpp $RTL -GTCP_RTO=3000

tb_run tcp_rx
tb_run tcp_conn
tb_run tcp_conn LOSS=0
tb_run tcp_conn PPM=-1000
tb_run tcp_conn PUSH=30 BYTES=60000

tb_sweep tcp_rx SEGMENTS=200000
tb_sweep tcp_conn CONNS=40
tb_sweep tcp_conn CONNS=20 LOSS=20

tb_summary
