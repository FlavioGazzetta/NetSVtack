#include "Vtop.h"
#include "verilated.h"
#include "../mac/mac_model.h"

#include <random>
#include <string>

int main(int argc, char **argv, char **env){
    Verilated::commandArgs(argc, argv);
    Sim<Vtop> sim;
    Vtop *top = sim.top;
    std::mt19937 rng(tb_env("TB_SEED", 1));
    int reports = tb_env("TB_REPORTS", 40);
    bool loop = tb_env("TB_LOOP", 0); // the meter's own frames come back to it, nothing echoes
    int failures = 0;

    uint64_t m_at = 0; // clock the last frame left the meter
    uint64_t e_at = 0; // clock a frame got back to the meter, 0 when its ethertype has been seen
    int e_word = 0;
    int late = 0; // probes left whose echo is late
    int back = 0; // echoes since the last probe
    int late_probes = 0;
    uint64_t lo = ~0ull, hi = 0, sum = 0, echoes = 0; // the test's own count for this window
    long offset = -1; // what the meter adds, the same for every report
    int seen = 0;
    int with_loss = 0;
    uint64_t round_min = ~0ull, round_max = 0;

    std::string uart; // the line coming out of the UART
    std::string expected_line;
    int lines = 0;
    int u_wait = 0; // clocks to the middle of the next bit, 0 when idle
    int u_bit = 0;
    int u_char = 0;

    top->rst_n = 0;
    top->cut = 0;
    top->dly = 0;
    top->loop = loop;
    for (int i = 0; i < 3; i++){
        sim.tick();
    }
    top->rst_n = 1;

    for (uint64_t c = 0; seen < reports && failures < 10 && c < (uint64_t)reports * 20000; c++){
        top->cut = !loop && seen >= 10 && seen < 13; // three windows with the way back down
        sim.tick();

        if (top->m_start){
            m_at = sim.cycle;
            back = 0;
            if (late > 0){
                late--;
            }
            if (late == 0){
                // now and then the echo takes longer than the gap between probes, so it comes in after the next one left
                late = !loop && rng() % 40 == 0 ? 2 + rng() % 3 : 0;
                late_probes += late;
                top->dly = late ? 600 + rng() % 100 : rng() % 8;
            }
        }
        if (e_at && ++e_word == 2){
            bool ipv4 = ((top->back_d >> 32) & 0xFFFF) == 0x0008; // the echo and not ARP
            if ((ipv4 || loop) && !top->cut && late == 0 && back++ == 0){
                uint64_t d = e_at - m_at;
                lo = d < lo ? d : lo;
                hi = d > hi ? d : hi;
                sum += d;
                echoes++;
            }
            e_at = 0;
        }
        if (top->b_start){
            e_at = sim.cycle;
            e_word = 0;
        }

        if (u_wait == 0){
            if (!top->uart_txd){
                u_wait = 6; // start bit, DIV is 4
                u_bit = 0;
                u_char = 0;
            }
        }
        else if (--u_wait == 0){
            if (u_bit < 8){
                u_char |= top->uart_txd << u_bit++;
                u_wait = 4;
            }
            else {
                if (!top->uart_txd){
                    VL_PRINTF("FAIL: clock %lu no stop bit on the UART\n", (unsigned long)sim.cycle);
                    failures++;
                }
                uart += (char)u_char;
                if (u_char == '\n'){
                    if (uart != expected_line){
                        VL_PRINTF("FAIL: UART line is '%s', expected '%s'\n", uart.c_str(), expected_line.c_str());
                        failures++;
                    }
                    uart.clear();
                    lines++;
                }
            }
        }

        if (!top->rep_valid){
            continue;
        }
        seen++;
        char buf[32];
        std::snprintf(buf, sizeof buf, "%04X %04X %04X %04X\r\n", top->rep_min, top->rep_max, top->rep_avg, top->rep_lost);
        expected_line = buf;
        if (echoes + top->rep_lost != 16){
            VL_PRINTF("FAIL: report %d has %u lost, the test saw %lu echoes of 16\n", seen, top->rep_lost, (unsigned long)echoes);
            failures++;
        }
        else if (echoes){
            if (offset < 0){
                offset = (long)top->rep_min - (long)lo;
            }
            if (top->rep_min != lo + offset || top->rep_max != hi + offset || (top->rep_lost == 0 && top->rep_avg != (sum + 16 * offset) / 16)){
                VL_PRINTF("FAIL: report %d is min %u max %u avg %u, the test measured min %lu max %lu sum %lu and the meter adds %ld\n",
                          seen, top->rep_min, top->rep_max, top->rep_avg, (unsigned long)lo, (unsigned long)hi, (unsigned long)sum, offset);
                failures++;
            }
            round_min = lo < round_min ? lo : round_min;
            round_max = hi > round_max ? hi : round_max;
        }
        with_loss += top->rep_lost != 0;
        lo = ~0ull;
        hi = 0;
        sum = 0;
        echoes = 0;
    }

    if (seen < reports){
        VL_PRINTF("FAIL: only %d of %d reports came\n", seen, reports);
        failures++;
    }
    if (offset < 0 || offset > 4){
        VL_PRINTF("FAIL: the meter is %ld clocks off the round trip at XGMII\n", offset);
        failures++;
    }
    if (loop ? with_loss != 0 : with_loss < 3 || late_probes == 0){
        VL_PRINTF("FAIL: %d reports had loss, the link was cut for 3 windows, and %d echoes were late\n", with_loss, late_probes);
        failures++;
    }
    if (lines < seen - 1){
        VL_PRINTF("FAIL: %d lines on the UART for %d reports\n", lines, seen);
        failures++;
    }

    if (failures == 0){
        VL_PRINTF("PASS: all meter tests passed (%d reports, %d with loss, %d late echoes, %d UART lines, round trip %lu..%lu clocks, the meter reads %ld more)\n",
                  seen, with_loss, late_probes, lines, (unsigned long)round_min, (unsigned long)round_max, offset);
    }
    else {
        VL_PRINTF("FAIL: %d meter test(s) failed\n", failures);
    }
    return failures == 0 ? 0 : 1;
}
