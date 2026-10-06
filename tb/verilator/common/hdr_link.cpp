#include "Vtop.h"
#include "verilated.h"
#include "../mac/mac_model.h"

#include <deque>
#include <random>

struct Frame {
    std::vector<uint8_t> hdr;
    std::vector<uint8_t> payload;
    bool user;
};

static int failures = 0;
static int bytes;
static std::deque<Frame> exp_wire;
static std::deque<Frame> exp_hdr;
static std::deque<Frame> exp_out;
static std::vector<uint8_t> wire_got;
static std::vector<uint8_t> out_got;
static int frames_out = 0;

// byte k on the wire is byte BYTES-1-k of the header port
static void set_hdr(Vtop *top, const std::vector<uint8_t> &h){
    for (int i = 0; i < 8; i++){
        top->hdr_in[i] = 0;
    }
    for (int k = 0; k < bytes; k++){
        int idx = bytes - 1 - k;
        top->hdr_in[idx / 4] |= (uint32_t)h[k] << (8 * (idx % 4));
    }
}

static std::vector<uint8_t> get_hdr(Vtop *top){
    std::vector<uint8_t> h(bytes);
    for (int k = 0; k < bytes; k++){
        int idx = bytes - 1 - k;
        h[k] = (top->hdr_out[idx / 4] >> (8 * (idx % 4))) & 0xFF;
    }
    return h;
}

static bool collect(std::vector<uint8_t> &got, uint64_t data, uint8_t keep, bool last, const char *what){
    if ((keep & (keep + 1)) != 0 || (!last && keep != 0xFF)){
        VL_PRINTF("FAIL: %s tkeep=0x%02x tlast=%d\n", what, keep, last);
        failures++;
    }
    for (int i = 0; i < 8; i++){
        uint8_t b = (data >> (8 * i)) & 0xFF;
        if ((keep >> i) & 1){
            got.push_back(b);
        }
        else if (b != 0){
            VL_PRINTF("FAIL: %s byte %d past tkeep is 0x%02x\n", what, i, b);
            failures++;
        }
    }
    return last;
}

// the insert output, sampled before the clock edge
static void sample_wire(Vtop *top){
    if (top->bypass || !top->w_tvalid || !top->w_tready){
        return;
    }
    if (!collect(wire_got, top->w_tdata, top->w_tkeep, top->w_tlast, "wire")){
        return;
    }
    Frame f = exp_wire.front();
    exp_wire.pop_front();
    std::vector<uint8_t> want = f.hdr;
    want.insert(want.end(), f.payload.begin(), f.payload.end());
    if (wire_got != want || (bool)top->w_tuser != f.user){
        VL_PRINTF("FAIL: wire frame is %zu bytes tuser=%d, expected %zu tuser=%d, or differs\n", wire_got.size(), top->w_tuser, want.size(), f.user);
        failures++;
    }
    wire_got.clear();
}

// the strip outputs, sampled after the clock edge
static void sample_out(Vtop *top){
    if (top->hdr_valid){
        if (exp_hdr.empty()){
            VL_PRINTF("FAIL: hdr_valid with no frame expected\n");
            failures++;
        }
        else {
            if (get_hdr(top) != exp_hdr.front().hdr){
                VL_PRINTF("FAIL: header of frame %d differs\n", frames_out);
                failures++;
            }
            exp_hdr.pop_front();
        }
    }
    if (!top->m_tvalid){
        return;
    }
    if (!collect(out_got, top->m_tdata, top->m_tkeep, top->m_tlast, "out")){
        return;
    }
    if (exp_out.empty()){
        VL_PRINTF("FAIL: a payload of %zu bytes came out with none expected\n", out_got.size());
        failures++;
    }
    else {
        Frame f = exp_out.front();
        exp_out.pop_front();
        if (out_got != f.payload || (bool)top->m_tuser != f.user){
            VL_PRINTF("FAIL: payload %d is %zu bytes tuser=%d, expected %zu tuser=%d, or differs\n", frames_out, out_got.size(), top->m_tuser, f.payload.size(), f.user);
            failures++;
        }
        frames_out++;
    }
    out_got.clear();
}

int main(int argc, char **argv, char **env){
    Verilated::commandArgs(argc, argv);
    Sim<Vtop> sim;
    Vtop *top = sim.top;
    std::mt19937 rng(tb_env("TB_SEED", 1));
    int frames = tb_env("TB_FRAMES", 3000);

    top->rst_n = 0;
    top->w_tready = 1;
    for (int i = 0; i < 3; i++){
        sim.tick();
    }
    top->rst_n = 1;
    sim.tick();
    bytes = top->bytes;
    uint64_t limit = 200ull * frames + 1000;

    // through the insert and then the strip, with the output stalling at random
    for (int f = 0; f < frames && failures < 10; f++){
        Frame fr;
        fr.hdr.resize(bytes);
        fr.payload.resize(rng() % 4 == 0 ? rng() % 20 : rng() % 200);
        fr.user = rng() % 8 == 0;
        for (auto &b : fr.hdr){
            b = (uint8_t)rng();
        }
        for (auto &b : fr.payload){
            b = (uint8_t)rng();
        }
        exp_wire.push_back(fr);
        exp_hdr.push_back(fr);
        exp_out.push_back(fr);
        int stall = rng() % 3 == 0 ? 0 : 1 + rng() % 4;
        int pause = rng() % 3 == 0 ? 1 + rng() % 4 : 0;

        set_hdr(top, fr.hdr);
        size_t pos = 0;
        bool done = false;
        while (!done && sim.cycle < limit){
            size_t n = fr.payload.size() - pos;
            // an empty last word now and then, and always when there is no payload
            bool last = n <= 8 && !(n == 8 && rng() % 4 == 0);
            if (n > 8){
                n = 8;
            }
            top->s_tdata = 0;
            for (size_t i = 0; i < n; i++){
                top->s_tdata |= (uint64_t)fr.payload[pos + i] << (8 * i);
            }
            top->s_tkeep = (uint8_t)((1u << n) - 1);
            top->s_tvalid = pause == 0 || rng() % (pause + 1) != 0;
            top->s_tlast = last;
            top->s_tuser = last && fr.user;
            top->w_tready = stall == 0 || rng() % (stall + 1) != 0;
            sim.low();
            bool taken = top->s_tvalid && top->s_tready;
            sample_wire(top);
            sim.high();
            sample_out(top);
            if (taken){
                pos += n;
                done = last;
            }
        }
        top->s_tvalid = 0;
    }
    top->w_tready = 1;
    for (int i = 0; i < 8; i++){
        sim.low();
        sample_wire(top);
        sim.high();
        sample_out(top);
    }

    // straight into the strip, frames back to back and shorter than the header
    top->bypass = 1;
    int shorts = 0;
    for (int f = 0; f < frames && failures < 10; f++){
        size_t len = rng() % 3 == 0 ? rng() % (bytes + 2) : rng() % 200;
        std::vector<uint8_t> raw(len);
        for (auto &b : raw){
            b = (uint8_t)rng();
        }
        bool user = rng() % 8 == 0;
        if (len >= (size_t)bytes){
            Frame fr;
            fr.hdr.assign(raw.begin(), raw.begin() + bytes);
            fr.payload.assign(raw.begin() + bytes, raw.end());
            fr.user = user;
            exp_hdr.push_back(fr);
            exp_out.push_back(fr);
        }
        else {
            shorts++;
        }
        int pause = rng() % 3 == 0 ? 1 + rng() % 4 : 0;
        size_t pos = 0;
        bool done = false;
        while (!done && sim.cycle < limit){
            size_t n = len - pos;
            bool last = n <= 8 && !(n == 8 && rng() % 4 == 0);
            if (n > 8){
                n = 8;
            }
            top->r_tdata = 0;
            for (size_t i = 0; i < n; i++){
                top->r_tdata |= (uint64_t)raw[pos + i] << (8 * i);
            }
            top->r_tkeep = (uint8_t)((1u << n) - 1);
            top->r_tvalid = pause == 0 || rng() % (pause + 1) != 0;
            top->r_tlast = last;
            top->r_tuser = last && user;
            sim.low();
            sim.high();
            sample_out(top);
            if (top->r_tvalid){
                pos += n;
                done = last;
            }
        }
        top->r_tvalid = 0;
    }
    for (int i = 0; i < 8; i++){
        sim.tick();
        sample_out(top);
    }

    if (sim.cycle >= limit){
        VL_PRINTF("FAIL: stuck, the input was not taken\n");
        failures++;
    }
    if (!exp_wire.empty() || !exp_hdr.empty() || !exp_out.empty()){
        VL_PRINTF("FAIL: still waiting for %zu wire frames, %zu headers, %zu payloads\n", exp_wire.size(), exp_hdr.size(), exp_out.size());
        failures++;
    }
    if (failures == 0){
        VL_PRINTF("PASS: all hdr_link tests passed (%d byte header, %d frames, %d shorter than the header)\n", bytes, frames_out, shorts);
    }
    else {
        VL_PRINTF("FAIL: %d hdr_link test(s) failed\n", failures);
    }
    return failures == 0 ? 0 : 1;
}
