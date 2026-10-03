#include "Vtop.h"
#include "verilated.h"
#include "mac_model.h"

#include <deque>
#include <random>

static int failures = 0;
static std::deque<std::vector<uint8_t>> expected;
static std::deque<uint64_t> sent_at;
static std::vector<uint8_t> got;
static int received = 0;
static uint64_t min_latency = ~0ull;
static uint64_t max_latency = 0;

static void sample(Sim<Vtop> &sim, Pcap &pcap){
    Vtop *top = sim.top;
    if (top->stat_bad){
        VL_PRINTF("FAIL: clock %lu stat_bad\n", (unsigned long)sim.cycle);
        failures++;
    }
    if (!top->m_tvalid){
        return;
    }
    if (got.empty() && !sent_at.empty()){
        uint64_t latency = sim.cycle - sent_at.front();
        sent_at.pop_front();
        min_latency = latency < min_latency ? latency : min_latency;
        max_latency = latency > max_latency ? latency : max_latency;
    }
    for (int i = 0; i < 8; i++){
        if ((top->m_tkeep >> i) & 1){
            got.push_back((top->m_tdata >> (8 * i)) & 0xFF);
        }
    }
    if (!top->m_tlast){
        return;
    }
    if (expected.empty()){
        VL_PRINTF("FAIL: a frame of %zu bytes came out with none expected\n", got.size());
        failures++;
    }
    else {
        if (top->m_tuser || got != expected.front()){
            VL_PRINTF("FAIL: frame %d is %zu bytes tuser=%d, expected %zu, or differs\n", received, got.size(), top->m_tuser, expected.front().size());
            failures++;
        }
        pcap.write(sim.cycle, got);
        expected.pop_front();
        received++;
    }
    got.clear();
}

int main(int argc, char **argv, char **env){
    Verilated::commandArgs(argc, argv);
    Sim<Vtop> sim;
    Vtop *top = sim.top;
    Pcap pcap;
    std::mt19937 rng(tb_env("TB_SEED", 1));
    int count = tb_env("TB_FRAMES", 4000);

    top->rst_n = 0;
    top->s_tvalid = 0;
    top->s_tuser = 0;
    for (int i = 0; i < 3; i++){
        sim.tick();
    }
    top->rst_n = 1;

    for (int fi = 0; fi < count && failures < 10; fi++){
        size_t len = rng() % 3 == 0 ? 1 + rng() % 80 : 1 + rng() % 1514;
        std::vector<uint8_t> frame(len);
        for (auto &b : frame){
            b = (uint8_t)rng();
        }
        int gap = rng() % 4 == 0 ? rng() % 6 : 0;
        for (int i = 0; i < gap; i++){
            top->s_tvalid = 0;
            sim.tick();
            sample(sim, pcap);
        }
        size_t words = (len + 7) / 8;
        size_t w = 0;
        while (w < words){
            uint64_t d = 0;
            uint8_t keep = 0;
            for (size_t i = 0; i < 8 && w * 8 + i < len; i++){
                d |= (uint64_t)frame[w * 8 + i] << (8 * i);
                keep |= 1 << i;
            }
            top->s_tvalid = 1;
            top->s_tdata = d;
            top->s_tkeep = keep;
            top->s_tlast = w == words - 1;
            sim.low();
            bool ready = top->s_tready;
            if (ready && w == 0){
                sent_at.push_back(sim.cycle);
            }
            sim.high();
            sample(sim, pcap);
            if (ready){
                w++;
            }
        }
        if (frame.size() < 60){
            frame.resize(60, 0);
        }
        expected.push_back(frame);
    }
    top->s_tvalid = 0;
    for (int i = 0; i < 40; i++){
        sim.tick();
        sample(sim, pcap);
    }

    if (!expected.empty()){
        VL_PRINTF("FAIL: %zu frame(s) never came out\n", expected.size());
        failures++;
    }

    if (failures == 0){
        VL_PRINTF("PASS: all mac_link tests passed (%d frames, latency %lu to %lu clocks)\n", received, (unsigned long)min_latency, (unsigned long)max_latency);
    }
    else {
        VL_PRINTF("FAIL: %d mac_link test(s) failed\n", failures);
    }
    return failures == 0 ? 0 : 1;
}
