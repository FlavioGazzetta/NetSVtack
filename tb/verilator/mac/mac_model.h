#pragma once

#include "verilated.h"
#include "verilated_vcd_c.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

static inline long tb_env(const char *name, long def){
    const char *v = std::getenv(name);
    return v && *v ? std::strtol(v, nullptr, 0) : def;
}

// One clock is low() then high(). Set inputs before low(), read combinational
// outputs after it and registered outputs after high().
template <class T> struct Sim {
    T *top;
    VerilatedVcdC *vcd = nullptr;
    uint64_t cycle = 0;

    Sim(){
        top = new T;
        if (std::getenv("TB_TRACE") && std::getenv("TB_VCD")){
            Verilated::traceEverOn(true);
            vcd = new VerilatedVcdC;
            top->trace(vcd, 99);
            vcd->open(std::getenv("TB_VCD"));
        }
    }
    ~Sim(){
        if (vcd){
            vcd->close();
        }
        delete top;
    }
    void low(){
        top->clk = 0;
        top->eval();
        if (vcd){
            vcd->dump(cycle * 10);
        }
    }
    void high(){
        top->clk = 1;
        top->eval();
        if (vcd){
            vcd->dump(cycle * 10 + 5);
        }
        cycle++;
    }
    void tick(){
        low();
        high();
    }
};

static inline uint32_t crc32_eth(const uint8_t *p, size_t n){
    uint32_t c = 0xFFFFFFFFu;
    for (size_t i = 0; i < n; i++){
        c ^= p[i];
        for (int b = 0; b < 8; b++){
            c = (c >> 1) ^ (0xEDB88320u & (0u - (c & 1)));
        }
    }
    return ~c;
}

// the frame with its FCS on the end, as it goes on the wire
static inline std::vector<uint8_t> with_fcs(const std::vector<uint8_t> &frame){
    std::vector<uint8_t> out = frame;
    uint32_t c = crc32_eth(frame.data(), frame.size());
    for (int i = 0; i < 4; i++){
        out.push_back((c >> (8 * i)) & 0xFF);
    }
    return out;
}

// XGMII as a flat list of byte lanes, 8 to a word, lane 0 first
struct Lane {
    uint8_t d;
    bool c;
};

static const uint8_t XG_IDLE = 0x07;
static const uint8_t XG_START = 0xFB;
static const uint8_t XG_TERM = 0xFD;
static const uint8_t XG_ERROR = 0xFE;
static const uint8_t XG_PREAMBLE[8] = {XG_START, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0xD5};

// start, preamble, the bytes given (FCS included) and the terminate
static inline void xg_frame(std::vector<Lane> &s, const std::vector<uint8_t> &wire){
    s.push_back({XG_START, true});
    for (int i = 1; i < 8; i++){
        s.push_back({XG_PREAMBLE[i], false});
    }
    for (uint8_t b : wire){
        s.push_back({b, false});
    }
    s.push_back({XG_TERM, true});
}

// word w of the stream, idle past the end
static inline void xg_word(const std::vector<Lane> &s, size_t w, uint64_t &d, uint8_t &c){
    d = 0;
    c = 0;
    for (int i = 0; i < 8; i++){
        size_t k = w * 8 + i;
        Lane l = k < s.size() ? s[k] : Lane{XG_IDLE, true};
        d |= (uint64_t)l.d << (8 * i);
        c |= (l.c ? 1 : 0) << i;
    }
}

static inline void xg_push(std::vector<Lane> &s, uint64_t d, uint8_t c){
    for (int i = 0; i < 8; i++){
        s.push_back({(uint8_t)(d >> (8 * i)), ((c >> i) & 1) != 0});
    }
}

// Ethernet pcap with nanosecond timestamps. Frames go in without the FCS.
// Does nothing unless TB_PCAP is set (lib.sh :pcap).
struct Pcap {
    FILE *f = nullptr;

    Pcap(){
        const char *path = std::getenv("TB_PCAP");
        if (path && *path){
            f = std::fopen(path, "wb");
        }
        if (f){
            uint32_t hdr[6] = {0xA1B23C4Du, 0x00040002u, 0, 0, 65535, 1};
            std::fwrite(hdr, 4, 6, f);
        }
    }
    ~Pcap(){
        if (f){
            std::fclose(f);
        }
    }
    // cycle is the 156.25 MHz clock count, 6.4 ns each
    void write(uint64_t cycle, const std::vector<uint8_t> &frame){
        if (!f){
            return;
        }
        uint64_t ns = cycle * 32 / 5;
        uint32_t rec[4] = {(uint32_t)(ns / 1000000000u), (uint32_t)(ns % 1000000000u), (uint32_t)frame.size(), (uint32_t)frame.size()};
        std::fwrite(rec, 4, 4, f);
        std::fwrite(frame.data(), 1, frame.size(), f);
    }
};
