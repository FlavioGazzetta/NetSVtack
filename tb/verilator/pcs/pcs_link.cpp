#include "Vtop.h"
#include "verilated.h"
#include "pcs_model.h"

#include <deque>
#include <random>

static const int SLIP_WAIT = 32;

// what is known about one block on the wire
struct Meta {
    Xgmii word; // what should come out of pcs_rx
    bool special; // put there by the test, scrambled against the wire itself
    bool hit; // has a bit error
};

static int failures = 0;

static void fail(uint64_t cycle, const char *what){
    VL_PRINTF("FAIL: clock %lu %s\n", (unsigned long)cycle, what);
    failures++;
}

// a control block the transmit side never sends: ordered sets, odd control codes, unknown types
static Block special_block(std::mt19937 &rng){
    static const uint8_t ordered[4] = {0x4B, 0x2D, 0x55, 0x66};
    uint64_t r = ((uint64_t)rng() << 32) | rng();
    switch (rng() % 4){
        case 0: {
            uint64_t b = (r & ~0xFFull) | ordered[rng() % 4];
            b &= ~(0xFFull << 32); // both O codes 0
            return {1, b};
        }
        case 1: return {1, (r & ~0xFFull) | BLOCK_TYPES[rng() % 15].type};
        case 2: return {1, r};
        default: return {(uint8_t)(rng() % 8 == 0 ? 3 * (rng() % 2) : 1), (r & ~0xFFull) | 0x1E};
    }
}

int main(int argc, char **argv, char **env){
    Verilated::commandArgs(argc, argv);
    Sim<Vtop> sim;
    Vtop *top = sim.top;
    std::mt19937 rng(tb_env("TB_SEED", 1));
    int count = tb_env("TB_FRAMES", 3000);
    int err_every = tb_env("TB_ERR", 3000); // one bit error in about this many blocks, 0 for none
    int drop_every = tb_env("TB_DROP", 6000); // the wire loses a bit about this often, 0 for never
    int special_pct = tb_env("TB_SPECIAL", 20); // idle words replaced on the wire, in percent

    std::vector<Lane> stream;
    for (int fi = 0; fi < count; fi++){
        size_t gap = 4 + rng() % (rng() % 4 == 0 ? 40 : 9);
        for (size_t i = 0; i < gap || stream.size() % 4 != 0; i++){
            stream.push_back({XG_IDLE, true});
        }
        if (rng() % 8 == 0){
            stream[stream.size() - 1 - rng() % 4] = {(uint8_t)(rng() % 2 ? XG_ERROR : rng()), true};
        }
        if (rng() % 50 == 0){
            for (int i = 0; i < 8; i++){
                stream.push_back({(uint8_t)(rng() % 4 == 0 ? rng() : rng() % 2 ? XG_TERM : XG_START), rng() % 2 == 0});
            }
            continue;
        }
        if (rng() % 20 == 0 && stream.size() % 8 == 0){ // the end of a frame with one control lane too many
            static const uint8_t odd[4] = {XG_TERM, XG_START, XG_ERROR, XG_SEQ};
            size_t term = rng() % 8;
            size_t at = stream.size();
            for (size_t i = 0; i < 8; i++){
                stream.push_back(i < term ? Lane{(uint8_t)rng(), false} : i == term ? Lane{XG_TERM, true} : Lane{XG_IDLE, true});
            }
            if (term < 7){
                stream[at + term + 1 + rng() % (7 - term)] = {odd[rng() % 4], true};
            }
            continue;
        }
        std::vector<uint8_t> wire(rng() % 5 == 0 ? 1 + rng() % 1518 : 1 + rng() % 120);
        for (auto &b : wire){
            b = (uint8_t)rng();
        }
        size_t at = stream.size();
        xg_frame(stream, wire);
        if (rng() % 40 == 0){
            stream[at + 8 + rng() % wire.size()] = {XG_ERROR, true};
        }
    }
    size_t words = stream.size() / 8 + 300;

    std::deque<uint8_t> bits; // the wire
    std::deque<Meta> meta; // one for each block that has gone on it
    uint64_t meta_base = 0;
    uint64_t rd_pos = 0; // bits taken off the wire or skipped
    uint64_t tx_hist = 0; // for the descrambler on what pcs_tx sends
    uint64_t wire_hist = 0; // the last 64 bits on the wire, the newest in bit 0
    bool tx_synced = false;
    bool reading = false;
    int skip = rng() % 66; // bits the receiver still has to drop
    std::deque<int> slip_due; // clocks until a slip acts
    uint64_t prev_block = ~0ull; // the block taken the clock before, if it was whole and clean
    int aligned_run = 0;
    int misaligned_run = 0;
    uint64_t checked = 0;
    uint64_t locks = 0;
    uint64_t stalls = 0;
    bool was_locked = false;

    top->rst_n = 0;
    top->xgmii_txd = IDLE_WORD.d;
    top->xgmii_txc = IDLE_WORD.c;
    top->rx_valid = 0;
    for (int i = 0; i < 3; i++){
        sim.tick();
    }
    top->rst_n = 1;

    for (size_t w = 0; w < words && failures < 10; w++){
        Xgmii in;
        xg_word(stream, w, in.d, in.c);
        top->xgmii_txd = in.d;
        top->xgmii_txc = in.c;

        for (auto &d : slip_due){
            d--;
        }
        while (!slip_due.empty() && slip_due.front() <= 0){
            slip_due.pop_front();
            skip++;
        }
        if (drop_every && reading && rng() % drop_every == 0){
            skip++;
        }
        if (!reading && bits.size() >= 66 * 3){
            reading = true;
        }

        bool valid = reading && bits.size() >= (size_t)(66 + skip);
        bool check = false;
        Xgmii expect = IDLE_WORD;
        if (valid){
            for (; skip > 0; skip--){
                bits.pop_front();
                rd_pos++;
            }
            uint8_t header = 0;
            uint64_t data = 0;
            for (int i = 0; i < 66; i++){
                uint64_t bit = bits.front();
                bits.pop_front();
                if (i < 2){
                    header |= bit << i;
                }
                else {
                    data |= bit << (i - 2);
                }
            }
            bool aligned = rd_pos % 66 == 0;
            uint64_t k = rd_pos / 66;
            rd_pos += 66;
            while (meta_base + 1 < k){
                meta.pop_front();
                meta_base++;
            }
            aligned_run = aligned && (header == 1 || header == 2) ? aligned_run + 1 : 0; // a bad header while searching is a slip
            misaligned_run = aligned ? 0 : misaligned_run + 1;
            if (aligned){
                const Meta &m = meta[k - meta_base];
                bool prev_ok = prev_block == k - 1 && !meta[k - 1 - meta_base].special;
                check = !m.hit && (m.special || prev_ok);
                expect = m.word;
                prev_block = m.hit ? ~0ull : k;
            }
            else {
                prev_block = ~0ull;
            }
            top->rx_header = header;
            top->rx_data = data;
        }
        else if (reading){
            stalls++;
        }
        top->rx_valid = valid;

        sim.tick();

        Block ref = pcs_encode(in);
        uint64_t sent = top->tx_data;
        uint64_t plain = pcs_descramble(sent, tx_hist);
        if (tx_synced && (top->tx_header != ref.header || plain != ref.data)){
            VL_PRINTF("FAIL: clock %lu pcs_tx sent %d %016lx for %02x %016lx, expected %d %016lx\n", (unsigned long)sim.cycle, top->tx_header, (unsigned long)plain, in.c, (unsigned long)in.d, ref.header, (unsigned long)ref.data);
            failures++;
        }
        if (tx_synced && sent == ref.data && ref.header == 1){
            fail(sim.cycle, "pcs_tx sent a control block without scrambling it");
        }
        tx_synced = true;

        Meta m = {pcs_decode(ref), false, false};
        uint8_t header = top->tx_header;
        if (in.c == 0xFF && in.d == IDLE_WORD.d && (int)(rng() % 100) < special_pct){
            Block s = special_block(rng);
            uint64_t hist = wire_hist;
            m = {pcs_decode(s), true, false};
            header = s.header;
            sent = pcs_scramble(s.data, hist);
        }
        else if (err_every && rng() % err_every == 0){
            int at = rng() % 66;
            m.hit = true;
            if (at < 2){
                header ^= 1 << at;
            }
            else {
                sent ^= 1ull << (at - 2);
            }
        }
        meta.push_back(m);
        for (int i = 0; i < 66; i++){
            bits.push_back(i < 2 ? (header >> i) & 1 : (sent >> (i - 2)) & 1);
            if (i >= 2){
                wire_hist = (wire_hist << 1) | ((sent >> (i - 2)) & 1);
            }
        }

        if (top->rx_slip){
            slip_due.push_back(1 + rng() % (SLIP_WAIT - 4));
        }
        bool lock = was_locked; // the output was made with the lock of the clock before
        if (top->block_lock && !was_locked){
            locks++;
        }
        was_locked = top->block_lock;
        if (lock && misaligned_run > 300){
            fail(sim.cycle, "block_lock is high on a boundary that is wrong");
            misaligned_run = 0;
        }
        if (!lock && aligned_run > 64 + SLIP_WAIT + 8){
            fail(sim.cycle, "no block_lock on the right boundary");
            aligned_run = 0;
        }
        if (!lock || !valid){
            if (top->xgmii_rxc != IDLE_WORD.c || top->xgmii_rxd != IDLE_WORD.d){
                fail(sim.cycle, "pcs_rx is not idle without lock or a valid block");
            }
        }
        else if (check){
            checked++;
            if (top->xgmii_rxc != expect.c || top->xgmii_rxd != expect.d){
                VL_PRINTF("FAIL: clock %lu pcs_rx gave %02x %016lx, expected %02x %016lx\n", (unsigned long)sim.cycle, top->xgmii_rxc, (unsigned long)top->xgmii_rxd, expect.c, (unsigned long)expect.d);
                failures++;
            }
        }
    }

    if (checked < words / 5){
        VL_PRINTF("FAIL: only %lu of %zu words were checked\n", (unsigned long)checked, words);
        failures++;
    }

    if (failures == 0){
        VL_PRINTF("PASS: all pcs_link tests passed (%zu words, %lu checked, %lu locks, %lu stalls)\n", words, (unsigned long)checked, (unsigned long)locks, (unsigned long)stalls);
    }
    else {
        VL_PRINTF("FAIL: %d pcs_link test(s) failed\n", failures);
    }
    return failures == 0 ? 0 : 1;
}
