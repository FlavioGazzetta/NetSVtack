#pragma once

#include "../mac/mac_model.h"

#include <cstring>

static const uint8_t XG_SEQ = 0x9C;

// One 66 bit block: the 2 bit sync header and the 64 bits after it, not scrambled
struct Block {
    uint8_t header;
    uint64_t data;
};

struct Xgmii {
    uint64_t d;
    uint8_t c;
};

// What each lane holds for a block type: C control code, D data, S start,
// T terminate, O ordered set. With a T the data bytes sit one byte up, after
// the type.
struct BlockType {
    uint8_t type;
    const char *lanes;
};

static const BlockType BLOCK_TYPES[] = {
    {0x1E, "CCCCCCCC"}, {0x2D, "CCCCODDD"}, {0x33, "CCCCSDDD"}, {0x66, "ODDDSDDD"},
    {0x55, "ODDDODDD"}, {0x78, "SDDDDDDD"}, {0x4B, "ODDDCCCC"}, {0x87, "TCCCCCCC"},
    {0x99, "DTCCCCCC"}, {0xAA, "DDTCCCCC"}, {0xB4, "DDDTCCCC"}, {0xCC, "DDDDTCCC"},
    {0xD2, "DDDDDTCC"}, {0xE1, "DDDDDDTC"}, {0xFF, "DDDDDDDT"},
};

static const Block ERROR_BLOCK = {1, 0x1E | (0x1Eull << 8) | (0x1Eull << 15) | (0x1Eull << 22) | (0x1Eull << 29) | (0x1Eull << 36) | (0x1Eull << 43) | (0x1Eull << 50) | (0x1Eull << 57)};
static const Xgmii ERROR_WORD = {0xFEFEFEFEFEFEFEFEull, 0xFF};
static const Xgmii IDLE_WORD = {0x0707070707070707ull, 0xFF};

static inline int data_shift(const BlockType &t, int lane){
    return std::strchr(t.lanes, 'T') ? 8 * (lane + 1) : 8 * lane;
}

// what the transmit side makes of an XGMII word, ordered sets are not sent
static inline Block pcs_encode(Xgmii w){
    char lanes[9] = {0};
    for (int i = 0; i < 8; i++){
        uint8_t d = (uint8_t)(w.d >> (8 * i));
        bool c = (w.c >> i) & 1;
        lanes[i] = !c ? 'D' : d == XG_START ? 'S' : d == XG_TERM ? 'T' : 'C';
    }
    if (w.c == 0){
        return {2, w.d};
    }
    for (const BlockType &t : BLOCK_TYPES){
        if (std::strcmp(t.lanes, lanes) != 0){
            continue;
        }
        uint64_t b = t.type;
        for (int i = 0; i < 8; i++){
            uint8_t d = (uint8_t)(w.d >> (8 * i));
            if (lanes[i] == 'C'){
                b |= (uint64_t)(d == XG_IDLE ? 0x00 : 0x1E) << (8 + 7 * i);
            }
            else if (lanes[i] == 'D'){
                b |= (uint64_t)d << data_shift(t, i);
            }
        }
        return {1, b};
    }
    return ERROR_BLOCK;
}

static inline Xgmii pcs_decode(Block b){
    if (b.header == 2){
        return {b.data, 0};
    }
    if (b.header != 1){
        return ERROR_WORD;
    }
    for (const BlockType &t : BLOCK_TYPES){
        if (t.type != (b.data & 0xFF)){
            continue;
        }
        Xgmii w = {0, 0};
        for (int i = 0; i < 8; i++){
            uint8_t d;
            switch (t.lanes[i]){
                case 'D': d = (uint8_t)(b.data >> data_shift(t, i)); break;
                case 'S': d = XG_START; break;
                case 'T': d = XG_TERM; break;
                case 'O': d = XG_SEQ; break;
                default: d = ((b.data >> (8 + 7 * i)) & 0x7F) == 0 ? XG_IDLE : XG_ERROR; break;
            }
            w.d |= (uint64_t)d << (8 * i);
            w.c |= (t.lanes[i] != 'D' ? 1 : 0) << i;
        }
        return w;
    }
    return ERROR_WORD;
}

// x^58 + x^39 + 1 over the 64 bits, bit 0 first. hist holds the bits that
// went on the wire before, the newest in bit 0.
static inline uint64_t pcs_scramble(uint64_t data, uint64_t &hist){
    uint64_t out = 0;
    for (int i = 0; i < 64; i++){
        uint64_t bit = ((data >> i) ^ (hist >> 38) ^ (hist >> 57)) & 1;
        out |= bit << i;
        hist = (hist << 1) | bit;
    }
    return out;
}

static inline uint64_t pcs_descramble(uint64_t data, uint64_t &hist){
    uint64_t out = 0;
    for (int i = 0; i < 64; i++){
        uint64_t bit = (data >> i) & 1;
        out |= ((bit ^ (hist >> 38) ^ (hist >> 57)) & 1) << i;
        hist = (hist << 1) | bit;
    }
    return out;
}
