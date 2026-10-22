#include "Vtop.h"
#include "verilated.h"
#include "net_model.h"

#include <deque>
#include <map>
#include <random>

static const Mac STACK_MAC = {0x02, 0x00, 0x00, 0x00, 0x00, 0x01};
static const uint32_t STACK_IP = 0x0A000002;
static const uint32_t GATEWAY_IP = 0x0A000001;
static const uint32_t NETMASK = 0xFFFFFF00;
static const int HOSTS = 6;

struct Datagram {
    uint32_t ip;
    uint16_t src_port;
    uint16_t dst_port;
    Bytes data;
    bool known; // the stack has a MAC for it
};

static int failures = 0;
static Sim<Vtop> *sim;
static Vtop *top;
static Pcap *pcap;
static std::mt19937 rng;

static std::deque<Lane> wire; // XGMII into the stack, what has not gone in yet
static RxClock<Vtop> rx_clock;
static std::deque<uint64_t> rx_start; // clock the first word of a good datagram went in
static std::deque<uint64_t> rx_end;

static std::deque<Datagram> app_tx; // waiting to go into udp_tx
static size_t app_pos = 0;
static int app_gap = 0;
static std::deque<uint64_t> tx_start; // clock the first word of a datagram was offered
static bool app_offered = false;
static uint64_t tx_frame_start = 0;

static std::deque<Datagram> exp_udp_rx;
static std::deque<Bytes> exp_arp_tx;
static std::deque<Bytes> exp_ip_tx;
static std::map<uint32_t, Mac> cache; // what the stack should know
static uint16_t ip_id = 0;

static Bytes app_got;
static bool app_first = true;
static Bytes tx_got;
static bool tx_in_frame = false;
static int tx_idle = 100;

static int n_udp_rx = 0;
static int n_udp_rx_bad = 0;
static int n_udp_tx = 0;
static int n_arp_tx = 0;
static int n_dropped = 0;
static int n_ping = 0;
static uint64_t rx_first_min = ~0ull, rx_first_max = 0;
static uint64_t rx_last_min = ~0ull, rx_last_max = 0;
static uint64_t tx_min = ~0ull, tx_max = 0;

static Mac host_mac(int h){
    return Mac{0x02, 0xAA, 0x00, 0x00, 0x00, (uint8_t)(0x10 + h)};
}

static uint32_t host_ip(int h){
    return h == HOSTS ? GATEWAY_IP : 0x0A000010 + h;
}

static void fail(const char *what){
    VL_PRINTF("FAIL: clock %lu %s\n", (unsigned long)sim->cycle, what);
    failures++;
}

static void range(uint64_t v, uint64_t &lo, uint64_t &hi){
    lo = v < lo ? v : lo;
    hi = v > hi ? v : hi;
}

// a frame onto the wire into the stack, returns the clock its start goes in
static uint64_t send_frame(const Bytes &frame, bool good_fcs, int idles){
    for (int i = 0; i < idles; i++){
        wire.push_back({XG_IDLE, true});
    }
    while (wire.size() % 4 != 0){
        wire.push_back({XG_IDLE, true});
    }
    uint64_t start = sim->cycle + wire.size() / 8;
    Bytes bytes = with_fcs(padded(frame));
    if (!good_fcs){
        bytes[rng() % bytes.size()] ^= 1 << (rng() % 8);
    }
    std::vector<Lane> lanes;
    xg_frame(lanes, bytes);
    wire.insert(wire.end(), lanes.begin(), lanes.end());
    return start;
}

static void check_app(){
    if (!top->udp_rx_tvalid){
        return;
    }
    Datagram *e = exp_udp_rx.empty() ? nullptr : &exp_udp_rx.front();
    if (app_first){
        app_first = false;
        // the header fields are there with the first word
        if (e && !rx_start.empty() && sim->cycle >= rx_start.front()
            && top->udp_rx_src_ip == e->ip && top->udp_rx_src_port == e->src_port && top->udp_rx_dst_port == e->dst_port){
            range(sim->cycle - rx_start.front(), rx_first_min, rx_first_max);
        }
    }
    for (int i = 0; i < 8; i++){
        if ((top->udp_rx_tkeep >> i) & 1){
            app_got.push_back((top->udp_rx_tdata >> (8 * i)) & 0xFF);
        }
    }
    if (!top->udp_rx_tlast){
        return;
    }
    app_first = true;
    if (top->udp_rx_tuser){
        n_udp_rx_bad++;
    }
    else if (!e){
        fail("a datagram came out of udp_rx with none expected");
    }
    else {
        if (app_got != e->data || top->udp_rx_src_ip != e->ip || top->udp_rx_src_port != e->src_port
            || top->udp_rx_dst_port != e->dst_port || top->udp_rx_len != e->data.size()){
            VL_PRINTF("FAIL: clock %lu datagram %d out of udp_rx is %zu bytes len=%u, expected %zu, or differs\n",
                      (unsigned long)sim->cycle, n_udp_rx, app_got.size(), top->udp_rx_len, e->data.size());
            failures++;
        }
        range(sim->cycle - rx_end.front(), rx_last_min, rx_last_max);
        rx_start.pop_front();
        rx_end.pop_front();
        exp_udp_rx.pop_front();
        n_udp_rx++;
    }
    app_got.clear();
}

static void check_tx_frame(){
    if (tx_got.size() < 64){
        fail("a frame under 64 bytes went out");
        return;
    }
    if (crc32_eth(tx_got.data(), tx_got.size() - 4) != (uint32_t)(tx_got[tx_got.size() - 4] | tx_got[tx_got.size() - 3] << 8 | tx_got[tx_got.size() - 2] << 16 | tx_got[tx_got.size() - 1] << 24)){
        fail("a frame went out with a bad FCS");
        return;
    }
    Bytes frame(tx_got.begin(), tx_got.end() - 4);
    pcap->write(sim->cycle, frame);
    bool is_arp = frame[12] == 0x08 && frame[13] == 0x06;
    std::deque<Bytes> &q = is_arp ? exp_arp_tx : exp_ip_tx;
    if (q.empty()){
        fail(is_arp ? "an ARP frame went out with none expected" : "a frame went out with none expected");
        return;
    }
    if (frame != padded(q.front())){
        VL_PRINTF("FAIL: clock %lu %s frame out is %zu bytes, expected %zu, or differs\n",
                  (unsigned long)sim->cycle, is_arp ? "ARP" : "IPv4", frame.size(), padded(q.front()).size());
        for (size_t i = 0; i < frame.size() && i < 64; i++){
            VL_PRINTF("%02x%s", frame[i], i % 16 == 15 ? "\n" : " ");
        }
        VL_PRINTF("\n");
        failures++;
    }
    q.pop_front();
    if (is_arp){
        n_arp_tx++;
    }
    else {
        n_udp_tx++;
        if (!tx_start.empty()){
            range(tx_frame_start - tx_start.front(), tx_min, tx_max);
            tx_start.pop_front();
        }
    }
}

static void check_tx(){
    for (int i = 0; i < 8; i++){
        uint8_t d = (top->xgmii_txd >> (8 * i)) & 0xFF;
        bool c = (top->xgmii_txc >> i) & 1;
        if (!tx_in_frame){
            if (c && d == XG_START){
                if (i != 0 || top->xgmii_txd != 0xD5555555555555FBull || top->xgmii_txc != 0x01){
                    fail("bad preamble out");
                }
                if (tx_idle < 12){
                    fail("less than 12 bytes of gap out");
                }
                tx_in_frame = true;
                tx_got.clear();
                tx_frame_start = sim->cycle;
                break;
            }
            if (!c || d != XG_IDLE){
                fail("not idle between frames out");
            }
            tx_idle++;
        }
        else if (c){
            if (d != XG_TERM){
                fail("control character inside a frame out");
            }
            tx_in_frame = false;
            tx_idle = 1;
            check_tx_frame();
        }
        else {
            tx_got.push_back(d);
        }
    }
}

static bool busy(){
    return !wire.empty() || !app_tx.empty() || tx_in_frame;
}

static void step(){
    top->udp_tx_tvalid = 0;
    size_t n = 0;
    bool last = false;
    if (!app_tx.empty() && app_gap == 0){
        Datagram &d = app_tx.front();
        n = d.data.size() - app_pos;
        last = n <= 8;
        n = n > 8 ? 8 : n;
        top->udp_tx_dst_ip = d.ip;
        top->udp_tx_src_port = d.src_port;
        top->udp_tx_dst_port = d.dst_port;
        top->udp_tx_len = d.data.size();
        top->udp_tx_tdata = 0;
        for (size_t i = 0; i < n; i++){
            top->udp_tx_tdata |= (uint64_t)d.data[app_pos + i] << (8 * i);
        }
        top->udp_tx_tkeep = (uint8_t)((1u << n) - 1);
        top->udp_tx_tvalid = 1;
        top->udp_tx_tlast = last;
        top->udp_tx_tuser = 0;
        if (!app_offered && d.known){
            tx_start.push_back(sim->cycle);
        }
        app_offered = true;
    }
    else if (app_gap > 0){
        app_gap--;
    }
    sim->low();
    rx_clock.run(top, wire);
    if (top->udp_tx_tvalid && top->udp_tx_tready){
        app_pos += n;
        if (last){
            app_tx.pop_front();
            app_pos = 0;
            app_offered = false;
            app_gap = rng() % 3 == 0 ? rng() % 6 : 0;
        }
    }
    sim->high();
    check_app();
    check_tx();
}

static void settle(){
    int quiet = 0;
    while (quiet < 60 && sim->cycle < 50000000 && failures < 10){
        quiet = busy() ? 0 : quiet + 1;
        step();
    }
}

static Bytes random_bytes(size_t n){
    Bytes b(n);
    for (auto &x : b){
        x = (uint8_t)rng();
    }
    return b;
}

static size_t random_len(){
    return rng() % 3 == 0 ? rng() % 40 : rng() % 1473;
}

// a host asks for the stack's MAC, the stack answers and learns the host
static void op_arp_request(int h, bool for_us){
    settle();
    uint32_t tpa = for_us ? STACK_IP : 0x0A0000F0;
    Bytes f = eth_frame(MAC_BROADCAST, host_mac(h), 0x0806, arp_packet(1, host_mac(h), host_ip(h), Mac{}, tpa));
    pcap->write(sim->cycle, padded(f));
    send_frame(f, true, 8);
    if (for_us){
        exp_arp_tx.push_back(eth_frame(host_mac(h), STACK_MAC, 0x0806, arp_packet(2, STACK_MAC, STACK_IP, host_mac(h), host_ip(h))));
        cache[host_ip(h)] = host_mac(h);
    }
    settle();
}

static void op_arp_reply(int h){
    settle();
    Bytes f = eth_frame(STACK_MAC, host_mac(h), 0x0806, arp_packet(2, host_mac(h), host_ip(h), STACK_MAC, STACK_IP));
    pcap->write(sim->cycle, padded(f));
    send_frame(f, true, 8);
    cache[host_ip(h)] = host_mac(h);
    settle();
}

enum RxKind { RX_GOOD, RX_BAD_FCS, RX_OTHER_MAC, RX_OTHER_IP, RX_BAD_CSUM, RX_BAD_LEN, RX_NOT_UDP, RX_FRAGMENT, RX_NKIND };
static int rx_kinds[RX_NKIND] = {};

static void op_udp_rx(){
    int r = rng() % 100;
    RxKind kind = r < 72 ? RX_GOOD : (RxKind)(1 + (r - 72) / 4);
    rx_kinds[kind]++;
    int h = rng() % HOSTS;
    Datagram d = {host_ip(h), (uint16_t)rng(), (uint16_t)rng(), random_bytes(random_len()), true};
    Bytes udp = udp_packet(d.src_port, d.dst_port, d.data);
    if (kind == RX_BAD_LEN){
        udp[5] ^= 1 << (rng() % 8);
    }
    uint32_t dst_ip = kind == RX_OTHER_IP ? STACK_IP ^ (1u << (rng() % 32)) : STACK_IP;
    uint16_t flags = kind == RX_FRAGMENT ? (rng() % 2 ? 0x2000 : 1 + rng() % 0x1FFF) : (rng() % 2 ? 0x4000 : 0);
    Bytes ip = ipv4_packet(d.ip, dst_ip, kind == RX_NOT_UDP ? 1 : 17, (uint16_t)rng(), 64, flags, udp);
    if (kind == RX_BAD_CSUM){
        ip[rng() % 20] ^= 1 << (rng() % 8);
    }
    Mac dst = STACK_MAC;
    if (kind == RX_OTHER_MAC){
        dst[rng() % 6] ^= 2 << (rng() % 7);
    }
    else if (rng() % 8 == 0){
        dst = MAC_BROADCAST;
    }
    Bytes f = eth_frame(dst, host_mac(h), 0x0800, ip);
    if (kind != RX_BAD_FCS){
        pcap->write(sim->cycle, padded(f));
    }
    uint64_t start = send_frame(f, kind != RX_BAD_FCS, rng() % 4 == 0 ? 4 + rng() % 60 : 4 + rng() % 8);
    if (kind == RX_GOOD){
        exp_udp_rx.push_back(d);
        rx_start.push_back(start);
        rx_end.push_back(sim->cycle + (wire.size() - 1) / 8);
    }
}

static void op_udp_tx(uint32_t ip){
    uint32_t hop = ((ip ^ STACK_IP) & NETMASK) == 0 ? ip : GATEWAY_IP;
    bool known = cache.count(hop) != 0;
    Datagram d = {ip, (uint16_t)rng(), (uint16_t)rng(), random_bytes(random_len()), known};
    if (!known){
        settle();
    }
    app_tx.push_back(d);
    if (known){
        Bytes ipp = ipv4_packet(STACK_IP, ip, 17, ip_id++, 64, 0x4000, udp_packet(d.src_port, d.dst_port, d.data));
        exp_ip_tx.push_back(eth_frame(cache[hop], STACK_MAC, 0x0800, ipp));
    }
    else {
        exp_arp_tx.push_back(eth_frame(MAC_BROADCAST, STACK_MAC, 0x0806, arp_packet(1, STACK_MAC, STACK_IP, Mac{}, hop)));
        n_dropped++;
        settle();
    }
}

// a host pings the stack. The reply is the request with the type changed and
// the checksum moved by the same amount
static void op_ping(int h){
    settle();
    int r = rng() % 10;
    uint8_t type = r == 0 ? 13 : 8;
    Bytes req = icmp_echo(type, (uint16_t)rng(), (uint16_t)rng(), random_bytes(random_len()));
    Bytes f = eth_frame(STACK_MAC, host_mac(h), 0x0800, ipv4_packet(host_ip(h), STACK_IP, 1, (uint16_t)rng(), 64, 0, req));
    if (r != 1){
        pcap->write(sim->cycle, padded(f));
    }
    send_frame(f, r != 1, 8);
    if (r > 1 && cache.count(host_ip(h)) != 0){
        Bytes rep = req;
        uint32_t c = ((rep[2] << 8) | rep[3]) + 0x0800;
        c = (c & 0xFFFF) + (c >> 16);
        rep[0] = 0;
        rep[2] = c >> 8;
        rep[3] = c & 0xFF;
        if (ip_checksum(rep.data(), rep.size()) != 0){
            fail("the model's echo reply has a bad checksum");
        }
        exp_ip_tx.push_back(eth_frame(host_mac(h), STACK_MAC, 0x0800, ipv4_packet(STACK_IP, host_ip(h), 1, ip_id++, 64, 0x4000, rep)));
        n_ping++;
    }
    else if (r > 1){
        exp_arp_tx.push_back(eth_frame(MAC_BROADCAST, STACK_MAC, 0x0806, arp_packet(1, STACK_MAC, STACK_IP, Mac{}, host_ip(h))));
        n_dropped++;
    }
    settle();
}

int main(int argc, char **argv, char **env){
    Verilated::commandArgs(argc, argv);
    Sim<Vtop> s;
    Pcap p;
    sim = &s;
    top = s.top;
    pcap = &p;
    rng.seed(tb_env("TB_SEED", 1));
    int ops = tb_env("TB_OPS", 3000);

    top->cfg_mac = mac_value(STACK_MAC);
    top->cfg_ip = STACK_IP;
    top->cfg_gateway = GATEWAY_IP;
    top->cfg_netmask = NETMASK;
    top->cfg_tcp_port = 5001;
    top->rst_n = 0;
    top->rx_rst_n = 0;
    top->xgmii_rxd = 0x0707070707070707ull;
    top->xgmii_rxc = 0xFF;
    for (int i = 0; i < 3; i++){
        sim->low();
        rx_clock.run(top, wire);
        sim->high();
    }
    top->rst_n = 1;
    top->rx_rst_n = 1;

    for (int o = 0; o < ops && failures < 10; o++){
        int r = rng() % 100;
        if (r < 3){
            op_arp_request(rng() % (HOSTS + 1), rng() % 4 != 0);
        }
        else if (r < 5){
            op_arp_reply(rng() % (HOSTS + 1));
        }
        else if (r < 10){
            op_ping(rng() % (HOSTS + 1));
        }
        else if (r < 55){
            op_udp_rx();
        }
        else {
            op_udp_tx(rng() % 5 == 0 ? rng() : host_ip(rng() % HOSTS));
        }
        // let some of it through before the next one is queued
        int run = rng() % 4 == 0 ? rng() % 200 : rng() % 4;
        for (int i = 0; i < run; i++){
            step();
        }
    }
    settle();

    if (!exp_udp_rx.empty() || !exp_arp_tx.empty() || !exp_ip_tx.empty()){
        VL_PRINTF("FAIL: still waiting for %zu datagrams in, %zu ARP frames out, %zu IPv4 frames out\n", exp_udp_rx.size(), exp_arp_tx.size(), exp_ip_tx.size());
        failures++;
    }
    bool covered = n_udp_tx > 0 && n_arp_tx > 0 && n_dropped > 0 && n_ping > 0;
    for (int i = 0; i < RX_NKIND; i++){
        covered = covered && rx_kinds[i] > 0;
    }
    if (!covered && ops >= 1000){
        VL_PRINTF("FAIL: coverage, %d datagrams out, %d ARP frames out, %d dropped for no MAC\n", n_udp_tx, n_arp_tx, n_dropped);
        failures++;
    }

    if (failures == 0){
        VL_PRINTF("PASS: all netsvtack tests passed (%d datagrams in, %d out, %d pings answered, %d ARP frames out, %d dropped for no MAC, %d dropped with tuser)\n",
                  n_udp_rx, n_udp_tx - n_ping, n_ping, n_arp_tx, n_dropped, n_udp_rx_bad);
        VL_PRINTF("  clocks in: start of frame to first word %lu..%lu, end of frame to tlast %lu..%lu. out: first word to start of frame %lu..%lu\n",
                  (unsigned long)rx_first_min, (unsigned long)rx_first_max, (unsigned long)rx_last_min, (unsigned long)rx_last_max,
                  (unsigned long)tx_min, (unsigned long)tx_max);
    }
    else {
        VL_PRINTF("FAIL: %d netsvtack test(s) failed\n", failures);
    }
    return failures == 0 ? 0 : 1;
}
