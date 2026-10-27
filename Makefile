# ============================================================
# FPGA TCP/IP stack -- build and simulation
#
# Verification is C++ Verilator testbenches in tb/verilator/<block>/, run by
# tb/regressions/regress.py:
#
#   make sanity                      every suite in tb/regressions/sanity.yml
#   make nightly                     sanity, then the suites in nightly.yml at nightly level
#   make list                        suites and their commands
#   make mac | pcs | common | tcp | top | echo    one suite (sanity level)
#   make lint                        Verilator lint of all RTL
#   make clean
#
# A suite's own script takes options directly, e.g.
#   tb/verilator/mac/mac_test.sh mac_rx :FRAMES=20000 :seeds=7 :trace :pcap
# ============================================================

VERILATOR ?= verilator
RUN       := python3 tb/regressions/regress.py
SUITES    := $(basename $(notdir $(filter-out %/sanity.yml %/nightly.yml,$(wildcard tb/regressions/*.yml))))

RTL       := $(shell find rtl -name '*.sv' | sort)
TOPS      := netsvtack_echo echo_meter pcs_tx pcs_rx

VFLAGS    := -sv --timing --timescale 1ns/1ps --assert \
             -Wno-fatal -Wno-MULTITOP

.PHONY: all lint test sanity nightly list clean $(SUITES)

all: lint sanity

lint:
	@for t in $(TOPS); do \
		echo "lint $$t"; \
		$(VERILATOR) --lint-only $(VFLAGS) --top-module $$t $(RTL) || exit 1; \
	done
	@echo "lint clean"

test sanity:
	@$(RUN) sanity

nightly:
	@$(RUN) nightly

list:
	@$(RUN) list

$(SUITES):
	@$(RUN) run $@

clean:
	rm -rf .build
