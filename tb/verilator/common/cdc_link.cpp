#include "Vtop.h"
#include "verilated.h"
#include "../mac/mac_model.h"

#include <deque>
#include <random>

struct Word {
    uint64_t data;
    uint8_t keep;
    bool valid;
    bool last;
    bool user;
};

int main(int argc, char **argv, char **env){
    Verilated::commandArgs(argc, argv);
    Sim<Vtop> sim;
    Vtop *top = sim.top;
    std::mt19937 rng(tb_env("TB_SEED", 1));
    int count = tb_env("TB_FRAMES", 5000);
    int gaps = tb_env("TB_GAPS", 0); // 1 -> the frames going in have gaps in them
    double ratio = 1.0 + tb_env("TB_PPM", 0) * 1e-6; // s_clk clocks per clk
    double phase = (rng() % 1000) / 1000.0;
    int failures = 0;

    std::deque<Word> in; // what s_clk still has to send, one entry a clock
    std::deque<Word> expected;
    for (int fi = 0; fi < count; fi++){
        int idle = rng() % 4 == 0 ? rng() % 40 : 2 + rng() % 3; // mac_rx leaves at least 2 clocks
        for (int i = 0; i < idle; i++){
            in.push_back({0, 0, false, false, false});
        }
        int len = rng() % 4 == 0 ? 1 + rng() % 3 : 1 + rng() % 190;
        for (int i = 0; i < len; i++){
            while (gaps && rng() % 4 == 0){
                in.push_back({0, 0, false, false, false});
            }
            bool last = i == len - 1;
            Word w = {((uint64_t)rng() << 32) | rng(), (uint8_t)(last ? 0xFF >> (rng() % 8) : 0xFF), true, last, last && rng() % 8 == 0};
            in.push_back(w);
            expected.push_back(w);
        }
    }
    for (int i = 0; i < 40; i++){
        in.push_back({0, 0, false, false, false});
    }

    uint64_t received = 0;
    uint64_t frames = 0;
    bool in_frame = false;
    bool reset = true;
    int reset_clocks = 0;
    top->rst_n = 0;
    top->s_rst_n = 0;
    top->s_tvalid = 0;

    while ((!in.empty() || reset) && failures < 10){
        sim.low();
        for (phase += ratio; phase >= 1.0; phase -= 1.0){
            Word w = {0, 0, false, false, false};
            if (!reset){
                w = in.front();
                in.pop_front();
            }
            top->s_tdata = w.data;
            top->s_tkeep = w.keep;
            top->s_tvalid = w.valid;
            top->s_tlast = w.last;
            top->s_tuser = w.user;
            top->s_clk = 0;
            top->eval();
            top->s_clk = 1;
            top->eval();
            if (in.empty()){
                break;
            }
        }
        sim.high();
        if (reset && ++reset_clocks == 4){
            reset = false;
            top->rst_n = 1;
            top->s_rst_n = 1;
        }

        if (!top->m_tvalid){
            if (in_frame && !gaps){
                VL_PRINTF("FAIL: clock %lu a gap inside a frame\n", (unsigned long)sim.cycle);
                failures++;
            }
            if (top->m_tlast || top->m_tuser){
                VL_PRINTF("FAIL: clock %lu tlast or tuser without tvalid\n", (unsigned long)sim.cycle);
                failures++;
            }
            continue;
        }
        if (expected.empty()){
            VL_PRINTF("FAIL: clock %lu a word came out with none expected\n", (unsigned long)sim.cycle);
            failures++;
            continue;
        }
        Word e = expected.front();
        expected.pop_front();
        if (top->m_tdata != e.data || top->m_tkeep != e.keep || top->m_tlast != e.last || top->m_tuser != e.user){
            VL_PRINTF("FAIL: clock %lu word %lu is %016lx %02x last=%d user=%d, expected %016lx %02x last=%d user=%d\n", (unsigned long)sim.cycle, (unsigned long)received, (unsigned long)top->m_tdata, top->m_tkeep, top->m_tlast, top->m_tuser, (unsigned long)e.data, e.keep, e.last, e.user);
            failures++;
        }
        received++;
        in_frame = !top->m_tlast;
        frames += top->m_tlast;
    }

    if (!expected.empty() && failures < 10){
        VL_PRINTF("FAIL: %zu word(s) never came out\n", expected.size());
        failures++;
    }

    if (failures == 0){
        VL_PRINTF("PASS: all cdc_link tests passed (%lu frames, %lu words)\n", (unsigned long)frames, (unsigned long)received);
    }
    else {
        VL_PRINTF("FAIL: %d cdc_link test(s) failed\n", failures);
    }
    return failures == 0 ? 0 : 1;
}
