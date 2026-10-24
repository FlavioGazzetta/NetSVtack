#include "Vtop.h"
#include "verilated.h"
#include "../top/net_model.h"

#include <deque>
#include <random>

static const Mac STACK_MAC = {0x02, 0x00, 0x00, 0x00, 0x00, 0x01};
static const Mac HOST_MAC = {0x02, 0x00, 0x00, 0x00, 0x00, 0x10};
static const uint32_t STACK_IP = 0xC0A80180;
static const uint32_t HOST_IP = 0xC0A8010A;
static const uint16_t STACK_PORT = 5001;
static const uint16_t HOST_PORT = 40000;

struct Datagram {
    uint16_t src_port;
    uint16_t dst_port;
    Bytes data;
    uint64_t start; // the clock the start of its frame goes into the stack
    uint64_t end;
    bool alone; // nothing else was on its way through the stack
};

static Sim<Vtop> *sim;
static Vtop *top;
static Pcap *pcap;
static std::mt19937 rng;
static std::deque<Lane> wire; // XGMII into the stack
static RxClock<Vtop> rx_clock;
static int failures = 0;

static std::deque<Datagram> expected;
static int n_udp = 0;
static bool arp_done = false;
static uint64_t start_min = ~0ull, start_max = 0; // start of frame in to start of frame out
static uint64_t end_min = ~0ull, end_max = 0; // end of frame in to start of frame out
static uint64_t small_min = ~0ull, small_max = 0; // start to start for a 64 byte frame

static uint32_t p_seq; // the test's side of the connection
static uint32_t p_ack;
static uint32_t stack_ack; // what the stack has acknowledged
static bool synack = false;
static Bytes tcp_sent;
static Bytes tcp_back;

static bool tx_in_frame = false;
static Bytes tx_got;
static uint64_t tx_start;

static void fail(const char *what){
    VL_PRINTF("FAIL: clock %lu %s\n", (unsigned long)sim->cycle, what);
    failures++;
}

static void range(uint64_t v, uint64_t &lo, uint64_t &hi){
    lo = v < lo ? v : lo;
    hi = v > hi ? v : hi;
}

static uint32_t get32(const Bytes &b, size_t at){
    return ((uint32_t)b[at] << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3];
}

static uint16_t get16(const Bytes &b, size_t at){
    return (b[at] << 8) | b[at + 1];
}

static void send_frame(const Bytes &frame, int idles){
    for (int i = 0; i < idles; i++){
        wire.push_back({XG_IDLE, true});
    }
    while (wire.size() % 4 != 0){
        wire.push_back({XG_IDLE, true});
    }
    pcap->write(sim->cycle + wire.size() / 8, padded(frame));
    std::vector<Lane> lanes;
    xg_frame(lanes, with_fcs(padded(frame)));
    wire.insert(wire.end(), lanes.begin(), lanes.end());
}

static void send_udp(size_t len, int idles){
    Datagram d = {(uint16_t)(1024 + rng() % 60000), (uint16_t)(1 + rng() % 65535), Bytes(len), 0, 0, expected.empty() && wire.empty()};
    for (auto &b : d.data){
        b = (uint8_t)rng();
    }
    send_frame(eth_frame(STACK_MAC, HOST_MAC, 0x0800, ipv4_packet(HOST_IP, STACK_IP, 17, rng(), 64, 0, udp_packet(d.src_port, d.dst_port, d.data))), idles);
    d.end = sim->cycle + (wire.size() - 1) / 8;
    d.start = d.end - (wire.size() - 1) / 8 + (wire.size() - (8 + padded(Bytes(42 + len)).size() + 4 + 1)) / 8;
    expected.push_back(d);
}

static void send_tcp(uint8_t flags, const Bytes &data){
    Bytes seg = tcp_segment(HOST_IP, STACK_IP, HOST_PORT, STACK_PORT, p_seq, p_ack, flags, 65535, {}, data);
    send_frame(eth_frame(STACK_MAC, HOST_MAC, 0x0800, ipv4_packet(HOST_IP, STACK_IP, 6, rng(), 64, 0, seg)), 12);
    p_seq += data.size() + ((flags & 0x02) ? 1 : 0);
}

static void got_udp(const Bytes &ip){
    if (expected.empty()){
        fail("a datagram came back with none expected");
        return;
    }
    Datagram &d = expected.front();
    Bytes data(ip.begin() + 28, ip.end());
    if (get16(ip, 20) != d.dst_port || get16(ip, 22) != d.src_port || get16(ip, 24) != 8 + d.data.size() || data != d.data){
        VL_PRINTF("FAIL: clock %lu datagram %d came back as %zu bytes from port %u to %u, sent %zu from %u to %u, or differs\n",
                  (unsigned long)sim->cycle, n_udp, data.size(), get16(ip, 20), get16(ip, 22), d.data.size(), d.src_port, d.dst_port);
        failures++;
    }
    if (d.alone){
        range(tx_start - d.start, start_min, start_max);
        range(tx_start - d.end, end_min, end_max);
        if (d.data.size() <= 18){
            range(tx_start - d.start, small_min, small_max);
        }
    }
    expected.pop_front();
    n_udp++;
}

static void got_tcp(const Bytes &ip){
    Bytes seg(ip.begin() + 20, ip.end());
    if (tcp_checksum(STACK_IP, HOST_IP, seg) != 0){
        fail("bad TCP checksum from the stack");
    }
    if (get16(seg, 0) != STACK_PORT || get16(seg, 2) != HOST_PORT){
        fail("TCP segment with the wrong ports");
    }
    uint32_t seq = get32(seg, 4);
    uint8_t flags = seg[13];
    size_t off = (seg[12] >> 4) * 4;
    if (flags & 0x10){
        stack_ack = get32(seg, 8);
    }
    if (flags & 0x02){
        if (!synack){
            synack = true;
            p_ack = seq + 1;
            send_tcp(0x10, {});
        }
        return;
    }
    if (seg.size() > off && seq == p_ack){
        tcp_back.insert(tcp_back.end(), seg.begin() + off, seg.end());
        p_ack += seg.size() - off;
        send_tcp(0x10, {});
    }
}

static void got_frame(){
    if (tx_got.size() < 64 || crc32_eth(tx_got.data(), tx_got.size() - 4) != get32(Bytes(tx_got.rbegin(), tx_got.rbegin() + 4), 0)){
        fail("frame out is short or has a bad FCS");
        return;
    }
    Bytes f(tx_got.begin(), tx_got.end() - 4);
    pcap->write(tx_start, f);
    if (!std::equal(HOST_MAC.begin(), HOST_MAC.end(), f.begin()) || !std::equal(STACK_MAC.begin(), STACK_MAC.end(), f.begin() + 6)){
        fail("frame out has the wrong MAC addresses");
        return;
    }
    if (get16(f, 12) == 0x0806){
        arp_done = get16(f, 20) == 2 && get32(f, 28) == STACK_IP;
        return;
    }
    Bytes ip(f.begin() + 14, f.begin() + 14 + get16(f, 16));
    if (get16(f, 12) != 0x0800 || ip_checksum(ip.data(), 20) != 0 || get32(ip, 12) != STACK_IP || get32(ip, 16) != HOST_IP){
        fail("frame out is not a good IPv4 packet from the stack to the host");
        return;
    }
    if (ip[9] == 17){
        got_udp(ip);
    }
    else if (ip[9] == 6){
        got_tcp(ip);
    }
    else {
        fail("frame out is neither UDP nor TCP");
    }
}

static void step(){
    sim->low();
    rx_clock.run(top, wire);
    sim->high();
    for (int i = 0; i < 8; i++){
        uint8_t d = (top->xgmii_txd >> (8 * i)) & 0xFF;
        bool c = (top->xgmii_txc >> i) & 1;
        if (!tx_in_frame){
            if (c && d == XG_START){
                tx_in_frame = true;
                tx_got.clear();
                tx_start = sim->cycle;
                break;
            }
        }
        else if (c){
            tx_in_frame = false;
            got_frame();
        }
        else {
            tx_got.push_back(d);
        }
    }
}

// clocks until cond holds, false if it never does
template <class F> static bool wait_for(F cond, int limit){
    for (int i = 0; i < limit && failures < 10; i++){
        if (cond()){
            return true;
        }
        step();
    }
    return cond();
}

int main(int argc, char **argv, char **env){
    Verilated::commandArgs(argc, argv);
    Sim<Vtop> s;
    Pcap p;
    sim = &s;
    top = s.top;
    pcap = &p;
    rng.seed(tb_env("TB_SEED", 1));
    int datagrams = tb_env("TB_DATAGRAMS", 600);
    size_t bytes = tb_env("TB_BYTES", 40000);

    top->rst_n = 0;
    top->rx_rst_n = 0;
    top->xgmii_rxd = 0x0707070707070707ull;
    top->xgmii_rxc = 0xFF;
    for (int i = 0; i < 3; i++){
        step();
    }
    top->rst_n = 1;
    top->rx_rst_n = 1;

    // the stack learns the host's MAC from its ARP request
    send_frame(eth_frame(MAC_BROADCAST, HOST_MAC, 0x0806, arp_packet(1, HOST_MAC, HOST_IP, {}, STACK_IP)), 12);
    if (!wait_for([]{ return arp_done; }, 400)){
        fail("no ARP reply");
    }

    while (n_udp < datagrams && failures < 10){
        int burst = rng() % 3 == 0 ? 2 + rng() % 6 : 1;
        for (int i = 0; i < burst; i++){
            size_t len = rng() % 3 == 0 ? rng() % 19 : rng() % 1473;
            send_udp(len, i == 0 ? 12 : 5 + rng() % 12);
        }
        if (!wait_for([]{ return expected.empty() && !tx_in_frame; }, 4000)){
            fail("a datagram never came back");
            expected.clear();
        }
        for (int i = rng() % 20; i > 0; i--){
            step();
        }
    }

    p_seq = rng();
    send_tcp(0x02, {});
    if (!wait_for([]{ return synack; }, 400)){
        fail("no SYN-ACK");
    }
    if (!wait_for([]{ return (bool)top->tcp_connected; }, 400)){
        fail("tcp_connected stays low");
    }
    while (tcp_sent.size() < bytes && failures < 10){
        Bytes data(1 + rng() % 1460);
        for (auto &b : data){
            b = (uint8_t)rng();
        }
        tcp_sent.insert(tcp_sent.end(), data.begin(), data.end());
        send_tcp(0x18, data);
        if (!wait_for([]{ return tcp_back.size() == tcp_sent.size() && stack_ack == p_seq; }, 6000)){
            fail("TCP data was not acknowledged and echoed");
        }
    }
    if (tcp_back != tcp_sent){
        fail("what came back over TCP is not what went in");
    }

    if (failures == 0){
        VL_PRINTF("PASS: all echo tests passed (%d datagrams and %zu TCP bytes came back)\n", n_udp, tcp_back.size());
        VL_PRINTF("  UDP echo in clocks, XGMII in to XGMII out: start to start %lu..%lu, end to start %lu..%lu, a 64 byte frame start to start %lu..%lu\n",
                  (unsigned long)start_min, (unsigned long)start_max, (unsigned long)end_min, (unsigned long)end_max, (unsigned long)small_min, (unsigned long)small_max);
    }
    else {
        VL_PRINTF("FAIL: %d echo test(s) failed\n", failures);
    }
    return failures == 0 ? 0 : 1;
}
