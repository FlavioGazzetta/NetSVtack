#pragma once

#include "../mac/mac_model.h"

#include <array>

typedef std::vector<uint8_t> Bytes;
typedef std::array<uint8_t, 6> Mac;

static const Mac MAC_BROADCAST = {0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF};

static inline void put16(Bytes &b, uint16_t v){
    b.push_back(v >> 8);
    b.push_back(v & 0xFF);
}

static inline void put32(Bytes &b, uint32_t v){
    put16(b, v >> 16);
    put16(b, v & 0xFFFF);
}

static inline void put_mac(Bytes &b, const Mac &m){
    b.insert(b.end(), m.begin(), m.end());
}

static inline uint64_t mac_value(const Mac &m){
    uint64_t v = 0;
    for (uint8_t x : m){
        v = (v << 8) | x;
    }
    return v;
}

static inline uint16_t ip_checksum(const uint8_t *p, size_t n){
    uint32_t sum = 0;
    for (size_t i = 0; i < n; i += 2){
        sum += (p[i] << 8) | (i + 1 < n ? p[i + 1] : 0);
    }
    while (sum >> 16){
        sum = (sum & 0xFFFF) + (sum >> 16);
    }
    return ~sum & 0xFFFF;
}

static inline Bytes eth_frame(const Mac &dst, const Mac &src, uint16_t type, const Bytes &payload){
    Bytes f;
    put_mac(f, dst);
    put_mac(f, src);
    put16(f, type);
    f.insert(f.end(), payload.begin(), payload.end());
    return f;
}

static inline Bytes arp_packet(uint16_t oper, const Mac &sha, uint32_t spa, const Mac &tha, uint32_t tpa){
    Bytes p;
    put16(p, 1);
    put16(p, 0x0800);
    p.push_back(6);
    p.push_back(4);
    put16(p, oper);
    put_mac(p, sha);
    put32(p, spa);
    put_mac(p, tha);
    put32(p, tpa);
    return p;
}

static inline Bytes ipv4_packet(uint32_t src, uint32_t dst, uint8_t protocol, uint16_t id, uint8_t ttl, uint16_t flags, const Bytes &payload){
    Bytes p;
    put16(p, 0x4500);
    put16(p, 20 + payload.size());
    put16(p, id);
    put16(p, flags);
    p.push_back(ttl);
    p.push_back(protocol);
    put16(p, 0);
    put32(p, src);
    put32(p, dst);
    uint16_t c = ip_checksum(p.data(), 20);
    p[10] = c >> 8;
    p[11] = c & 0xFF;
    p.insert(p.end(), payload.begin(), payload.end());
    return p;
}

static inline Bytes udp_packet(uint16_t src_port, uint16_t dst_port, const Bytes &data){
    Bytes p;
    put16(p, src_port);
    put16(p, dst_port);
    put16(p, 8 + data.size());
    put16(p, 0);
    p.insert(p.end(), data.begin(), data.end());
    return p;
}

static inline Bytes icmp_echo(uint8_t type, uint16_t id, uint16_t seq, const Bytes &data){
    Bytes p;
    p.push_back(type);
    p.push_back(0);
    put16(p, 0);
    put16(p, id);
    put16(p, seq);
    p.insert(p.end(), data.begin(), data.end());
    uint16_t c = ip_checksum(p.data(), p.size());
    p[2] = c >> 8;
    p[3] = c & 0xFF;
    return p;
}

static inline uint16_t tcp_checksum(uint32_t src, uint32_t dst, const Bytes &seg){
    Bytes all;
    put32(all, src);
    put32(all, dst);
    put16(all, 6);
    put16(all, seg.size());
    all.insert(all.end(), seg.begin(), seg.end());
    return ip_checksum(all.data(), all.size());
}

static inline Bytes tcp_segment(uint32_t src, uint32_t dst, uint16_t src_port, uint16_t dst_port, uint32_t seq, uint32_t ack,
                                uint8_t flags, uint16_t window, const Bytes &options, const Bytes &data){
    Bytes p;
    put16(p, src_port);
    put16(p, dst_port);
    put32(p, seq);
    put32(p, ack);
    p.push_back((5 + options.size() / 4) << 4);
    p.push_back(flags);
    put16(p, window);
    put16(p, 0);
    put16(p, 0);
    p.insert(p.end(), options.begin(), options.end());
    p.insert(p.end(), data.begin(), data.end());
    uint16_t c = tcp_checksum(src, dst, p);
    p[16] = c >> 8;
    p[17] = c & 0xFF;
    return p;
}

// padded up to the 60 bytes a frame has before its FCS
static inline Bytes padded(Bytes f){
    if (f.size() < 60){
        f.resize(60, 0);
    }
    return f;
}
