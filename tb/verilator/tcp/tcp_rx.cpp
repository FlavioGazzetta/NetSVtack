#include "Vtop.h"
#include "verilated.h"
#include "../top/net_model.h"

#include <deque>
#include <random>

static const uint32_t STACK_IP = 0x0A000002;

struct Segment {
    uint32_t src_ip;
    uint16_t src_port;
    uint16_t dst_port;
    uint32_t seq;
    uint32_t ack;
    uint8_t flags;
    uint16_t window;
    Bytes data;
};

static int failures = 0;
static std::deque<Segment> exp_seg;
static std::deque<Bytes> exp_data;
static Bytes got;
static int n_seg = 0;
static int n_data = 0;
static int n_tuser = 0;

static void sample(Vtop *top, uint64_t cycle){
    if (top->seg_valid){
        if (exp_seg.empty()){
            VL_PRINTF("FAIL: clock %lu seg_valid with no segment expected\n", (unsigned long)cycle);
            failures++;
        }
        else {
            Segment &e = exp_seg.front();
            if (top->seg_src_ip != e.src_ip || top->seg_src_port != e.src_port || top->seg_dst_port != e.dst_port
                || top->seg_seq != e.seq || top->seg_ack != e.ack || top->seg_flags != e.flags
                || top->seg_window != e.window || top->seg_len != e.data.size()){
                VL_PRINTF("FAIL: clock %lu the fields of segment %d differ\n", (unsigned long)cycle, n_seg);
                failures++;
            }
            exp_seg.pop_front();
            n_seg++;
        }
    }
    if (!top->m_tvalid){
        return;
    }
    for (int i = 0; i < 8; i++){
        if ((top->m_tkeep >> i) & 1){
            got.push_back((top->m_tdata >> (8 * i)) & 0xFF);
        }
    }
    if (!top->m_tlast){
        return;
    }
    if (top->m_tuser){
        n_tuser++;
    }
    else if (exp_data.empty()){
        VL_PRINTF("FAIL: clock %lu %zu bytes of data came out with none expected\n", (unsigned long)cycle, got.size());
        failures++;
    }
    else {
        if (got != exp_data.front()){
            VL_PRINTF("FAIL: clock %lu data %d is %zu bytes, expected %zu, or differs\n", (unsigned long)cycle, n_data, got.size(), exp_data.front().size());
            failures++;
        }
        exp_data.pop_front();
        n_data++;
    }
    got.clear();
}

int main(int argc, char **argv, char **env){
    Verilated::commandArgs(argc, argv);
    Sim<Vtop> sim;
    Vtop *top = sim.top;
    std::mt19937 rng(tb_env("TB_SEED", 1));
    int segments = tb_env("TB_SEGMENTS", 5000);
    int kinds[5] = {};

    top->cfg_ip = STACK_IP;
    top->rst_n = 0;
    for (int i = 0; i < 3; i++){
        sim.tick();
    }
    top->rst_n = 1;

    for (int s = 0; s < segments && failures < 10; s++){
        // 0 good, 1 good with options, 2 options and data, 3 bad checksum, 4 bad FCS
        int r = rng() % 100;
        int kind = r < 60 ? 0 : r < 75 ? 1 : r < 80 ? 2 : r < 90 ? 3 : 4;
        kinds[kind]++;
        Segment g = {(uint32_t)rng(), (uint16_t)rng(), (uint16_t)rng(), (uint32_t)rng(), (uint32_t)rng(), (uint8_t)rng(), (uint16_t)rng(), {}};
        size_t opt_words = (kind == 1 || kind == 2) ? 1 + rng() % 10 : (kind >= 3 && rng() % 4 == 0 ? rng() % 11 : 0);
        Bytes data(kind == 1 ? 0 : kind == 2 ? 1 + rng() % 100 : rng() % 3 == 0 ? rng() % 20 : rng() % 300);
        for (auto &b : data){
            b = (uint8_t)rng();
        }
        g.data = data;

        Bytes p;
        put16(p, g.src_port);
        put16(p, g.dst_port);
        put32(p, g.seq);
        put32(p, g.ack);
        p.push_back((5 + opt_words) << 4);
        p.push_back(g.flags);
        put16(p, g.window);
        put16(p, 0);
        put16(p, (uint16_t)rng());
        for (size_t i = 0; i < opt_words * 4; i++){
            p.push_back((uint8_t)rng());
        }
        p.insert(p.end(), data.begin(), data.end());
        Bytes pseudo;
        put32(pseudo, g.src_ip);
        put32(pseudo, STACK_IP);
        put16(pseudo, 6);
        put16(pseudo, p.size());
        Bytes all = pseudo;
        all.insert(all.end(), p.begin(), p.end());
        uint16_t c = ip_checksum(all.data(), all.size());
        p[16] = c >> 8;
        p[17] = c & 0xFF;
        if (kind == 3){
            // not in the byte with the header length
            size_t at = rng() % p.size();
            p[at == 12 ? 13 : at] ^= 1 << (rng() % 8);
        }
        if (kind == 0 || kind == 1){
            exp_seg.push_back(g);
        }
        if (kind == 0){
            exp_data.push_back(data);
        }

        top->s_src_ip = g.src_ip;
        top->s_len = p.size();
        int pause = rng() % 4 == 0 ? 1 + rng() % 3 : 0;
        for (size_t pos = 0; pos < p.size(); ){
            size_t n = p.size() - pos > 8 ? 8 : p.size() - pos;
            top->s_tdata = 0;
            for (size_t i = 0; i < n; i++){
                top->s_tdata |= (uint64_t)p[pos + i] << (8 * i);
            }
            top->s_tkeep = (uint8_t)((1u << n) - 1);
            top->s_tvalid = pause == 0 || rng() % (pause + 1) != 0;
            top->s_tlast = pos + n == p.size();
            top->s_tuser = top->s_tlast && kind == 4;
            sim.tick();
            sample(top, sim.cycle);
            if (top->s_tvalid){
                pos += n;
            }
        }
        top->s_tvalid = 0;
        // ipv4_rx leaves at least this much between packets
        int gap = 2 + (rng() % 3 == 0 ? rng() % 6 : 0);
        for (int i = 0; i < gap; i++){
            sim.tick();
            sample(top, sim.cycle);
        }
    }
    for (int i = 0; i < 8; i++){
        sim.tick();
        sample(top, sim.cycle);
    }

    if (!exp_seg.empty() || !exp_data.empty()){
        VL_PRINTF("FAIL: still waiting for %zu segments and %zu lots of data\n", exp_seg.size(), exp_data.size());
        failures++;
    }
    if (failures == 0){
        VL_PRINTF("PASS: all tcp_rx tests passed (%d good, %d with options, %d options and data, %d bad checksum, %d bad FCS, %d ended with tuser)\n",
                  kinds[0], kinds[1], kinds[2], kinds[3], kinds[4], n_tuser);
    }
    else {
        VL_PRINTF("FAIL: %d tcp_rx test(s) failed\n", failures);
    }
    return failures == 0 ? 0 : 1;
}
