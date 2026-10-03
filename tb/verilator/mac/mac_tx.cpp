#include "Vtop.h"
#include "verilated.h"
#include "mac_model.h"

#include <random>

enum Kind { NORMAL, ABORT, UNDERRUN };

struct Frame {
    std::vector<uint8_t> bytes;
    Kind kind;
    int gap; // idle clocks before it is offered
    size_t stall; // UNDERRUN: tvalid drops before this word
};

int main(int argc, char **argv, char **env){
    int failures = 0;

    Verilated::commandArgs(argc, argv);
    Sim<Vtop> sim;
    Vtop *top = sim.top;
    Pcap pcap;
    std::mt19937 rng(tb_env("TB_SEED", 1));
    int count = tb_env("TB_FRAMES", 4000);

    std::vector<Frame> frames(count);
    for (auto &f : frames){
        size_t len = rng() % 3 == 0 ? 1 + rng() % 80 : 1 + rng() % 1514;
        f.bytes.resize(len);
        for (auto &b : f.bytes){
            b = (uint8_t)rng();
        }
        int r = rng() % 100;
        f.kind = r < 90 ? NORMAL : r < 95 ? ABORT : UNDERRUN;
        f.gap = rng() % 4 == 0 ? rng() % 6 : 0;
        size_t words = (len + 7) / 8;
        f.stall = 0;
        if (f.kind == UNDERRUN){
            if (words < 2){
                f.kind = NORMAL;
            }
            else {
                f.stall = 1 + rng() % (words - 1);
            }
        }
    }

    top->rst_n = 0;
    top->s_tvalid = 0;
    for (int i = 0; i < 3; i++){
        sim.tick();
    }
    top->rst_n = 1;

    std::vector<Lane> wire;
    for (int fi = 0; fi < count; fi++){
        Frame &f = frames[fi];
        size_t words = (f.bytes.size() + 7) / 8;
        size_t w = 0;
        int gap = f.gap;
        bool stalled = false;
        while (w < words){
            bool valid = gap == 0;
            if (f.kind == UNDERRUN && w == f.stall && !stalled){
                valid = false; // one clock with nothing to send, in the middle of the frame
            }
            top->s_tvalid = valid;
            uint64_t d = ((uint64_t)rng() << 32) | rng(); // bytes past tkeep are junk
            uint8_t keep = 0;
            for (size_t i = 0; i < 8 && w * 8 + i < f.bytes.size(); i++){
                d &= ~(0xFFull << (8 * i));
                d |= (uint64_t)f.bytes[w * 8 + i] << (8 * i);
                keep |= 1 << i;
            }
            top->s_tdata = d;
            top->s_tkeep = keep;
            top->s_tlast = w == words - 1;
            top->s_tuser = w == words - 1 && f.kind == ABORT;
            sim.low();
            bool ready = top->s_tready;
            sim.high();
            xg_push(wire, top->xgmii_txd, top->xgmii_txc);
            if (gap > 0){
                gap--;
            }
            else if (!valid){
                stalled = true;
            }
            else if (ready){
                w++;
            }
        }
    }
    top->s_tvalid = 0;
    for (int i = 0; i < 20; i++){
        sim.tick();
        xg_push(wire, top->xgmii_txd, top->xgmii_txc);
    }

    // decode what went out
    size_t at = 0;
    long term_at = -1; // lane of the last terminate
    bool back_to_back = false;
    int fi = 0;
    int sent = 0;
    int errored = 0;
    int padded = 0;
    int min_gap = 1000;
    int max_gap = 0;
    int end_lane[8] = {};
    while (at < wire.size() && failures < 10){
        if (wire[at].c && wire[at].d == XG_IDLE){
            at++;
            continue;
        }
        if (!(wire[at].c && wire[at].d == XG_START)){
            VL_PRINTF("FAIL: lane %zu is 0x%02x (ctrl %d) outside a frame\n", at, wire[at].d, wire[at].c);
            failures++;
            break;
        }
        if (fi == count){
            VL_PRINTF("FAIL: a frame went out after the last one sent\n");
            failures++;
            break;
        }
        Frame &f = frames[fi];
        if (at % 8 != 0){
            VL_PRINTF("FAIL: frame %d starts in lane %zu\n", fi, at % 8);
            failures++;
        }
        for (int i = 1; i < 8; i++){
            if (wire[at + i].c || wire[at + i].d != XG_PREAMBLE[i]){
                VL_PRINTF("FAIL: frame %d preamble byte %d is 0x%02x (ctrl %d)\n", fi, i, wire[at + i].d, wire[at + i].c);
                failures++;
            }
        }
        if (term_at >= 0){
            int gap = (int)(at - term_at);
            if (gap < 12 || (back_to_back && gap > 19)){
                VL_PRINTF("FAIL: gap of %d bytes before frame %d (%s)\n", gap, fi, back_to_back ? "back to back" : "after a pause");
                failures++;
            }
            if (back_to_back){
                min_gap = gap < min_gap ? gap : min_gap;
                max_gap = gap > max_gap ? gap : max_gap;
            }
        }
        at += 8;
        std::vector<uint8_t> got;
        while (at < wire.size() && !wire[at].c){
            got.push_back(wire[at].d);
            at++;
        }
        if (wire[at].d == XG_TERM){
            std::vector<uint8_t> want = f.bytes;
            if (want.size() < 60){
                want.resize(60, 0);
                padded++;
            }
            want = with_fcs(want);
            if (f.kind != NORMAL){
                VL_PRINTF("FAIL: frame %d should have been cut short but went out whole\n", fi);
                failures++;
            }
            else if (got != want){
                VL_PRINTF("FAIL: frame %d (%zu bytes) went out as %zu bytes, expected %zu, or differs\n", fi, f.bytes.size(), got.size(), want.size());
                failures++;
            }
            got.resize(got.size() - 4);
            pcap.write(at / 8, got);
            end_lane[at % 8]++;
            term_at = at;
            // the next frame was already waiting unless it has a pause in front
            back_to_back = fi + 1 < count && frames[fi + 1].gap == 0;
            at++;
            sent++;
        }
        else if (wire[at].d == XG_ERROR){
            if (f.kind == NORMAL){
                VL_PRINTF("FAIL: frame %d (%zu bytes) ended in error characters\n", fi, f.bytes.size());
                failures++;
            }
            term_at = at;
            back_to_back = false;
            while (at < wire.size() && wire[at].c && wire[at].d == XG_ERROR){
                at++;
            }
            errored++;
        }
        else {
            VL_PRINTF("FAIL: frame %d ended with control 0x%02x\n", fi, wire[at].d);
            failures++;
            break;
        }
        fi++;
    }
    if (fi != count && failures == 0){
        VL_PRINTF("FAIL: %d frames went out, %d were sent\n", fi, count);
        failures++;
    }

    // make sure the random run actually reached the corners
    bool covered = errored > 0 && padded > 0 && min_gap == 12;
    for (int i = 0; i < 8; i++){
        covered = covered && end_lane[i] > 0;
    }
    if (!covered && count >= 1000){
        VL_PRINTF("FAIL: coverage, %d errored, %d padded, back to back gap %d to %d\n", errored, padded, min_gap, max_gap);
        failures++;
    }

    if (failures == 0){
        VL_PRINTF("PASS: all mac_tx tests passed (%d sent, %d padded, %d cut short, back to back gap %d to %d bytes)\n", sent, padded, errored, min_gap, max_gap);
    }
    else {
        VL_PRINTF("FAIL: %d mac_tx test(s) failed\n", failures);
    }
    return failures == 0 ? 0 : 1;
}
