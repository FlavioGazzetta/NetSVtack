#include "Vtop.h"
#include "verilated.h"
#include "mac_model.h"

#include <random>

int main(int argc, char **argv, char **env){
    int failures = 0;
    long checks = 0;

    Verilated::commandArgs(argc, argv);
    Sim<Vtop> sim;
    Vtop *top = sim.top;
    std::mt19937_64 rng(tb_env("TB_SEED", 1));
    int rounds = tb_env("TB_ROUNDS", 20000);

    // one step from a random state, the model does the same bytes bit by bit
    for (int r = 0; r < rounds && failures < 10; r++){
        uint32_t crc = (uint32_t)rng();
        uint64_t data = rng();
        top->crc_in = crc;
        top->data = data;
        sim.tick();
        uint32_t model = crc;
        for (int b = 1; b <= 8; b++){
            model ^= (data >> (8 * (b - 1))) & 0xFF;
            for (int i = 0; i < 8; i++){
                model = (model >> 1) ^ (0xEDB88320u & (0u - (model & 1)));
            }
            checks++;
            if (top->crc_out[b - 1] != model){
                VL_PRINTF("FAIL: %d bytes of 0x%016lx from 0x%08x gave 0x%08x, expected 0x%08x\n", b, (unsigned long)data, crc, top->crc_out[b - 1], model);
                failures++;
            }
        }
    }

    // whole frames in pieces, then the FCS must leave the residue
    for (int r = 0; r < rounds / 20 && failures < 10; r++){
        std::vector<uint8_t> frame(1 + rng() % 200);
        for (auto &b : frame){
            b = (uint8_t)rng();
        }
        std::vector<uint8_t> wire = with_fcs(frame);
        uint32_t crc = 0xFFFFFFFFu;
        size_t at = 0;
        while (at < wire.size()){
            size_t n = 1 + rng() % 8;
            if (n > wire.size() - at){
                n = wire.size() - at;
            }
            uint64_t data = rng(); // bytes past n must not matter
            for (size_t i = 0; i < n; i++){
                data &= ~(0xFFull << (8 * i));
                data |= (uint64_t)wire[at + i] << (8 * i);
            }
            top->crc_in = crc;
            top->data = data;
            sim.tick();
            crc = top->crc_out[n - 1];
            at += n;
        }
        checks++;
        if (crc != 0xDEBB20E3u){
            VL_PRINTF("FAIL: frame of %zu bytes left 0x%08x, expected the residue 0xDEBB20E3\n", frame.size(), crc);
            failures++;
        }
    }

    if (failures == 0){
        VL_PRINTF("PASS: all crc32 tests passed (%ld checks)\n", checks);
    }
    else {
        VL_PRINTF("FAIL: %d crc32 test(s) failed\n", failures);
    }
    return failures == 0 ? 0 : 1;
}
