#!/usr/bin/env bash

source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"
tb_init top "$@"

RTL=$(cd "$REPO_ROOT" && find rtl -name '*.sv' | sort)

tb_build netsvtack netsvtack netsvtack.cpp $RTL

tb_run netsvtack

tb_sweep netsvtack OPS=100000

tb_summary
