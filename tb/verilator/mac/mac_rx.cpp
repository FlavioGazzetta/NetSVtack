#include "Vtop.h"
#include "verilated.h"
#include "mac_model.h"

#include <deque>
#include <random>

enum Kind { GOOD, BAD_FCS, ERROR_CHAR, RUNT, BAD_PREAMBLE, NKIND };
static const char *kind_name[NKIND] = {"good", "bad FCS", "error", "runt", "bad preamble"};

int main(int argc, char **argv, char **env){
    int failures = 0;
    int kinds[NKIND] = {};
    int start_lane[2] = {};
    int end_lane[8] = {};
    int min_gaps = 0;

    Verilated::commandArgs(argc, argv);
    Sim<Vtop> sim;
    Vtop *top = sim.top;
    Pcap pcap;
    std::mt19937 rng(tb_env("TB_SEED", 1));
    int frames = tb_env("TB_FRAMES", 4000);

    std::vector<Lane> wire(16, Lane{XG_IDLE, true});
    std::deque<std::vector<uint8_t>> expected;
    int expected_bad = 0;
    int idles = 16;

    for (int f = 0; f < frames; f++){
        int r = rng() % 100;
        Kind kind = r < 70 ? GOOD : r < 80 ? BAD_FCS : r < 87 ? ERROR_CHAR : r < 94 ? RUNT : BAD_PREAMBLE;
        size_t len;
        if (kind == RUNT){
            len = 1 + rng() % 59;
        }
        else {
            // a third sit just above the minimum so every end alignment comes up often
            len = rng() % 3 == 0 ? 60 + rng() % 24 : 60 + rng() % 1455;
        }
        std::vector<uint8_t> frame(len);
        for (auto &b : frame){
            b = (uint8_t)rng();
        }
        std::vector<uint8_t> bytes = with_fcs(frame);
        if (kind == BAD_FCS){
            bytes[rng() % bytes.size()] ^= 1 << (rng() % 8);
        }

        // the gap so far is the minimum, a start has to wait for lane 0 or 4
        if (idles == 4 && wire.size() % 4 == 0){
            min_gaps++;
        }
        while (wire.size() % 4 != 0){
            wire.push_back({XG_IDLE, true});
        }
        size_t start = wire.size();
        start_lane[(start % 8) / 4]++;
        xg_frame(wire, bytes);
        end_lane[wire.size() % 8]++;
        if (kind == ERROR_CHAR){
            wire[start + 8 + rng() % bytes.size()] = {XG_ERROR, true};
        }
        if (kind == BAD_PREAMBLE){
            wire[start + 1 + rng() % 7].d ^= 1 << (rng() % 8);
        }
        // terminate plus at least 4 idles, sometimes a long pause
        idles = rng() % 4 == 0 ? 4 + rng() % 40 : 4 + rng() % 8;
        for (int i = 0; i < idles; i++){
            wire.push_back({XG_IDLE, true});
        }

        kinds[kind]++;
        if (kind == GOOD){
            expected.push_back(frame);
        }
        else if (kind != BAD_PREAMBLE){
            expected_bad++;
        }
    }

    top->rst_n = 0;
    xg_word(wire, 0, top->xgmii_rxd, top->xgmii_rxc);
    for (int i = 0; i < 3; i++){
        sim.tick();
    }
    top->rst_n = 1;

    std::vector<uint8_t> got;
    int good_out = 0;
    int bad_out = 0;
    int stat_good = 0;
    int stat_bad = 0;
    size_t words = wire.size() / 8 + 8;
    for (size_t w = 0; w < words && failures < 10; w++){
        xg_word(wire, w, top->xgmii_rxd, top->xgmii_rxc);
        sim.tick();
        stat_good += top->stat_good;
        stat_bad += top->stat_bad;
        if (!top->m_tvalid){
            continue;
        }
        uint8_t keep = top->m_tkeep;
        if ((keep & (keep + 1)) != 0 || keep == 0 || (!top->m_tlast && keep != 0xFF)){
            VL_PRINTF("FAIL: word %zu tkeep=0x%02x tlast=%d\n", w, keep, top->m_tlast);
            failures++;
        }
        for (int i = 0; i < 8; i++){
            uint8_t b = (top->m_tdata >> (8 * i)) & 0xFF;
            if ((keep >> i) & 1){
                got.push_back(b);
            }
            else if (b != 0){
                VL_PRINTF("FAIL: word %zu byte %d past tkeep is 0x%02x, expected 0\n", w, i, b);
                failures++;
            }
        }
        if (!top->m_tlast){
            continue;
        }
        if (top->m_tuser){
            bad_out++;
        }
        else if (expected.empty()){
            VL_PRINTF("FAIL: word %zu a good frame of %zu bytes came out with none expected\n", w, got.size());
            failures++;
        }
        else {
            if (got != expected.front()){
                VL_PRINTF("FAIL: word %zu good frame %d is %zu bytes, expected %zu, or differs\n", w, good_out, got.size(), expected.front().size());
                failures++;
            }
            pcap.write(sim.cycle, got);
            expected.pop_front();
            good_out++;
        }
        got.clear();
    }

    if (!expected.empty()){
        VL_PRINTF("FAIL: %zu good frame(s) never came out\n", expected.size());
        failures++;
    }
    if (stat_good != kinds[GOOD] || stat_bad != expected_bad){
        VL_PRINTF("FAIL: stat_good=%d stat_bad=%d, expected %d and %d\n", stat_good, stat_bad, kinds[GOOD], expected_bad);
        failures++;
    }
    if (bad_out > expected_bad){
        VL_PRINTF("FAIL: %d frames came out with tuser, only %d were bad\n", bad_out, expected_bad);
        failures++;
    }

    // make sure the random run actually reached the corners
    bool covered = start_lane[0] > 0 && start_lane[1] > 0 && min_gaps > 0;
    for (int i = 0; i < NKIND; i++){
        covered = covered && kinds[i] > 0;
    }
    for (int i = 0; i < 8; i++){
        covered = covered && end_lane[i] > 0;
    }
    if (!covered && frames >= 1000){
        VL_PRINTF("FAIL: coverage, starts lane0=%d lane4=%d, minimum gaps=%d\n", start_lane[0], start_lane[1], min_gaps);
        for (int i = 0; i < NKIND; i++){
            VL_PRINTF("  %s: %d\n", kind_name[i], kinds[i]);
        }
        failures++;
    }

    if (failures == 0){
        VL_PRINTF("PASS: all mac_rx tests passed (%d good, %d bad FCS, %d error, %d runt, %d bad preamble, %d lane 4 starts)\n",
                  kinds[GOOD], kinds[BAD_FCS], kinds[ERROR_CHAR], kinds[RUNT], kinds[BAD_PREAMBLE], start_lane[1]);
    }
    else {
        VL_PRINTF("FAIL: %d mac_rx test(s) failed\n", failures);
    }
    return failures == 0 ? 0 : 1;
}
