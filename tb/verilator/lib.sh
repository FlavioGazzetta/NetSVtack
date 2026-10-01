#!/usr/bin/env bash
# Shared build/run/summary for tb/verilator/<block>/<block>_test.sh. A block script does:
#
#   source "$(dirname "$0")/../lib.sh"
#   tb_init <block> "$@"
#   tb_build mac_rx mac_rx mac_rx.cpp rtl/mac/mac_rx.sv rtl/mac/crc32.sv
#   tb_run mac_rx                        every seed
#   tb_run mac_rx FRAMES=500             knobs reach the C++ as TB_FRAMES
#   tb_sweep mac_rx FRAMES=200000        only with :sweep
#   tb_summary
#
# Tests run from the repo root.

set -uo pipefail

TB_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$TB_ROOT/../.." && pwd)"
TOTAL_TESTS=0
PASSED_TESTS=0
TEST_RESULTS=()
FAILED_TESTS=()
FILTERS=()
declare -A BUILT

tb_usage()
{
    printf 'Usage: %s [test ...] [:option ...]\n\n' "$0"
    printf '  test               run only tests whose name starts with this\n'
    printf '  :sweep             also run the nightly-only variants\n'
    printf '  :seeds=1,2,3       run every test once per listed seed (default 1)\n'
    printf '  :random_seeds=N    run every test with N new random seeds\n'
    printf '  :KEY=VAL           test knob, e.g. :FRAMES=2000 (read as TB_KEY in C++)\n'
    printf '  :trace             write a .vcd waveform for every run\n'
    printf '  :pcap              write a .pcap of the frames for every run (opens in Wireshark)\n'
    printf '  :nocolor           plain output without green/red\n'
    printf '  :help              show this message\n'
}

tb_init()
{
    BLOCK="$1"
    shift
    BUILD_ROOT="$REPO_ROOT/.build/verilator/$BLOCK"
    for arg in "$@"
    do
        case "$arg" in
            :sweep) SWEEP=1 ;;
            :trace) export TB_TRACE=1 ;;
            :pcap) PCAP=1 ;;
            :nocolor) export NO_COLOR=1 ;;
            :help) tb_usage; exit 0 ;;
            :seeds=*) SEEDS="${arg#:seeds=}"; SEEDS="${SEEDS//,/ }" ;;
            :random_seeds=*)
                RANDOM_SEEDS="${arg#:random_seeds=}"
                if ! [[ "$RANDOM_SEEDS" =~ ^[0-9]+$ ]]
                then
                    printf 'Bad value in %s, expected a number\n' "$arg"
                    exit 2
                fi
                ;;
            :[A-Z]*=*) export "TB_${arg#:}" ;;
            :*) printf 'Unknown option: %s\n\n' "$arg"; tb_usage; exit 2 ;;
            *) FILTERS+=("$arg") ;;
        esac
    done

    if [[ ( -t 1 || -n "${FORCE_COLOR:-}" ) && -z "${NO_COLOR:-}" ]]
    then
        GREEN=$'\033[32m'
        RED=$'\033[31m'
        RESET=$'\033[0m'
    else
        GREEN=''
        RED=''
        RESET=''
    fi

    SEEDS="${SEEDS:-1}"
    if [[ -n "${RANDOM_SEEDS:-}" ]]
    then
        SEEDS=""
        for ((i = 0; i < RANDOM_SEEDS; i++))
        do
            SEEDS+="$(od -An -N4 -tu4 /dev/urandom | tr -d ' ') "
        done
        SEEDS="${SEEDS% }"
        printf 'Random seeds for this run: %s\n' "$SEEDS"
    fi
}

tb_selected()
{
    local name="$1"
    local f
    if ((${#FILTERS[@]} == 0))
    then
        return 0
    fi
    for f in "${FILTERS[@]}"
    do
        if [[ "$name" == "$f"* ]]
        then
            return 0
        fi
    done
    return 1
}

tb_record()
{
    local label="$1"
    local ok="$2"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    if [[ "$ok" == 1 ]]
    then
        PASSED_TESTS=$((PASSED_TESTS + 1))
        TEST_RESULTS+=("${GREEN}PASS${RESET}: $label")
    else
        TEST_RESULTS+=("${RED}FAIL${RESET}: $label")
        FAILED_TESTS+=("$label")
    fi
}

# tb_build <build> <top module> <cpp file> <rtl...> [verilator args...]
tb_build()
{
    local build="$1"
    local top="$2"
    local cpp="$3"
    shift 3
    local dir="$BUILD_ROOT/$build"
    local srcs=()
    local args=()
    local a

    tb_selected "$build" || return 0
    for a in "$@"
    do
        if [[ "$a" == *.sv ]]
        then
            srcs+=("$REPO_ROOT/$a")
        else
            args+=("$a")
        fi
    done
    printf 'Building %s...\n' "$build"
    mkdir -p "$dir"
    if verilator --cc "${srcs[@]}" \
            --top-module "$top" \
            --prefix Vtop \
            --trace \
            --assert \
            -Wno-fatal \
            --exe "$(dirname "$0")/$cpp" \
            -CFLAGS "-O1" \
            --Mdir "$dir" \
            "${args[@]}" \
            --build \
            --build-jobs 0 \
            --verilate-jobs 1 > "$dir/build.log" 2>&1
    then
        BUILT[$build]=1
    else
        BUILT[$build]=0
        grep -E '%Error|%Warning|error:' "$dir/build.log" | head -20
        printf '%sBuild failed for %s (log: %s).%s\n' "$RED" "$build" "$dir/build.log" "$RESET"
        tb_record "$build (build)" 0
    fi
}

# tb_run <build> [KEY=VAL ...]
tb_run()
{
    local build="$1"
    shift
    local label="$build"
    local kv seed ok env_args=() pcap_args

    tb_selected "$build" || return 0
    [[ "${BUILT[$build]:-0}" == 1 ]] || return 0
    for kv in "$@"
    do
        label+=".$kv"
        env_args+=("TB_$kv")
    done
    ok=1
    for seed in $SEEDS
    do
        printf 'Running %s (seed %s)...\n' "$label" "$seed"
        pcap_args=()
        if [[ -n "${PCAP:-}" ]]
        then
            pcap_args=("TB_PCAP=$BUILD_ROOT/$build/$label.seed$seed.pcap")
        fi
        if ! (
                cd "$REPO_ROOT"
                env "${env_args[@]}" "${pcap_args[@]}" TB_SEED="$seed" TB_VCD="$BUILD_ROOT/$build/$label.seed$seed.vcd" \
                    timeout 1800 "$BUILD_ROOT/$build/Vtop"
            )
        then
            printf '%sTest failed for %s (seed %s).%s\n' "$RED" "$label" "$seed" "$RESET"
            ok=0
        fi
    done
    tb_record "$label" "$ok"
}

tb_sweep()
{
    if [[ -n "${SWEEP:-}" ]]
    then
        tb_run "$@"
    fi
}

tb_summary()
{
    local r
    printf '\n%s test summary\n' "$BLOCK"
    for r in "${TEST_RESULTS[@]}"
    do
        printf '  %s\n' "$r"
    done
    if ((TOTAL_TESTS > 0 && PASSED_TESTS == TOTAL_TESTS))
    then
        printf '\n%s%d/%d tests passed%s\n' "$GREEN" "$PASSED_TESTS" "$TOTAL_TESTS" "$RESET"
    else
        printf '\n%s%d/%d tests passed%s\n' "$RED" "$PASSED_TESTS" "$TOTAL_TESTS" "$RESET"
    fi
    printf 'Seeds: %s\n' "$SEEDS"
    if ((TOTAL_TESTS == 0))
    then
        printf '%sNo tests matched.%s\n' "$RED" "$RESET"
        exit 1
    fi
    if ((${#FAILED_TESTS[@]} > 0))
    then
        printf '%sFailed tests:' "$RED"
        printf ' %s' "${FAILED_TESTS[@]}"
        printf '%s\n' "$RESET"
        exit 1
    fi
}
