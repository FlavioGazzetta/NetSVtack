#include "Vtop.h"
#include "verilated.h"
#include "../top/net_model.h"

#include <deque>
#include <random>

static const Mac STACK_MAC = {0x02, 0x00, 0x00, 0x00, 0x00, 0x01};
static const Mac PEER_MAC = {0x02, 0xAA, 0x00, 0x00, 0x00, 0x10};
static const uint32_t STACK_IP = 0x0A000002;
static const uint32_t PEER_IP = 0x0A000010;
static const uint16_t STACK_PORT = 5001;
static const int PEER_RTO = 1500; // clocks, the stack's is 3000

static const uint8_t FIN = 0x01, SYN = 0x02, RST = 0x04, PSH = 0x08, ACK = 0x10;

static int failures = 0;
static Sim<Vtop> *sim;
static Vtop *top;
static Pcap *pcap;
static std::mt19937 rng;
static int loss; // percent of segments lost, each way
static int push_pct; // percent of the peer's segments that ignore the stack's window

static std::deque<Lane> wire; // XGMII into the stack
static RxClock<Vtop> rx_clock;
static Bytes tx_got;
static bool tx_in_frame = false;

// the peer, a client that connects to the stack
enum PeerState { P_CLOSED, P_SYN_SENT, P_OPEN, P_FIN_SENT, P_DONE };
static PeerState peer = P_CLOSED;
static uint16_t peer_port;
static uint32_t c_iss, c_una, c_nxt, c_max, c_rcv; // its sequence numbers
static uint32_t s_iss; // the stack's
static uint32_t s_seen; // end of the data the stack has sent so far
static uint32_t stack_wnd;
static uint32_t c_edge; // end of the furthest window the peer has given
static bool c_edge_set;
static bool small_wnd; // this connection gives small windows
static int n_over = 0; // segments sent past the stack's window
static uint64_t c_progress; // clock of the last thing that moved
static bool c_ack_due = false;
static bool s_fin_seen = false;
static Bytes to_stack; // what the peer sends
static Bytes to_peer; // what the application sends
static size_t app_wr = 0; // bytes the application has written
static size_t app_rd = 0; // bytes the application has read
static size_t peer_rd = 0; // bytes the peer has received in order

static int n_conn = 0, n_seg_in = 0, n_seg_out = 0, n_lost_in = 0, n_lost_out = 0, n_resent = 0;

static void fail(const char *what){
    VL_PRINTF("FAIL: clock %lu %s\n", (unsigned long)sim->cycle, what);
    failures++;
}

static void send_frame(const Bytes &frame){
    for (int i = 0; i < 5; i++){
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

static void peer_send(uint32_t seq, uint8_t flags, const Bytes &options, const Bytes &data){
    n_seg_in++;
    if (peer != P_SYN_SENT && (int)(rng() % 100) < loss){
        n_lost_in++;
        return;
    }
    uint16_t window = small_wnd ? 300 + rng() % 3000 : 4000 + rng() % 60000;
    if (flags & ACK){
        uint32_t edge = c_rcv + window;
        if (!c_edge_set || (int32_t)(edge - c_edge) > 0){
            c_edge = edge;
            c_edge_set = true;
        }
    }
    Bytes seg = tcp_segment(PEER_IP, STACK_IP, peer_port, STACK_PORT, seq, (flags & ACK) ? c_rcv : 0, flags, window, options, data);
    send_frame(eth_frame(STACK_MAC, PEER_MAC, 0x0800, ipv4_packet(PEER_IP, STACK_IP, 6, (uint16_t)rng(), 64, 0x4000, seg)));
}

// a TCP segment from the stack
static void peer_receive(const Bytes &frame){
    Bytes ip(frame.begin() + 14, frame.end());
    size_t total = (ip[2] << 8) | ip[3];
    if (ip_checksum(ip.data(), 20) != 0 || total > ip.size() || total < 40){
        fail("bad IPv4 header on a segment out");
        return;
    }
    Bytes seg(ip.begin() + 20, ip.begin() + total);
    if (tcp_checksum(STACK_IP, PEER_IP, seg) != 0){
        fail("bad TCP checksum out");
        return;
    }
    n_seg_out++;
    uint16_t src_port = (seg[0] << 8) | seg[1];
    uint16_t dst_port = (seg[2] << 8) | seg[3];
    uint32_t seq = (uint32_t)seg[4] << 24 | seg[5] << 16 | seg[6] << 8 | seg[7];
    uint32_t ack = (uint32_t)seg[8] << 24 | seg[9] << 16 | seg[10] << 8 | seg[11];
    size_t doff = (seg[12] >> 4) * 4;
    uint8_t flags = seg[13];
    uint16_t window = (seg[14] << 8) | seg[15];
    Bytes data(seg.begin() + doff, seg.end());
    if (src_port != STACK_PORT || dst_port != peer_port){
        return; // from a connection that has ended
    }
    if ((int)(rng() % 100) < loss){
        n_lost_out++;
        return;
    }
    if (flags & RST){
        fail("the stack sent a reset");
        return;
    }
    if (flags & SYN){
        if (peer != P_SYN_SENT && seq != s_iss){
            fail("a second SYN with another sequence number");
        }
        if (!(flags & ACK) || ack != c_iss + 1 || doff != 24 || seg[20] != 2 || seg[21] != 4 || seg[22] != 0x05 || seg[23] != 0xB4 || !data.empty()){
            fail("bad SYN ACK");
            return;
        }
        if (peer == P_SYN_SENT){
            s_iss = seq;
            s_seen = seq + 1;
            c_rcv = seq + 1;
            c_una = c_nxt = c_max = c_iss + 1;
            stack_wnd = window;
            peer = P_OPEN;
            c_progress = sim->cycle;
        }
        c_ack_due = true;
        return;
    }
    if (peer != P_OPEN && peer != P_FIN_SENT && peer != P_DONE){
        return;
    }
    if (!(flags & ACK) || doff != 20){
        fail("a segment out without ACK or with options");
        return;
    }
    if ((int32_t)(ack - c_una) > 0 && (int32_t)(c_max - ack) >= 0){
        c_una = ack;
        c_progress = sim->cycle;
        if ((int32_t)(c_una - c_nxt) > 0){
            c_nxt = c_una;
        }
    }
    else if ((int32_t)(ack - c_max) > 0){
        fail("the stack acknowledged data that was never sent");
    }
    stack_wnd = window;
    // every byte it sends has to be the byte the application wrote there
    uint32_t off = seq - (s_iss + 1);
    if (!data.empty() && off + data.size() > app_wr){
        fail("the stack sent data the application has not written");
        return;
    }
    for (size_t i = 0; i < data.size(); i++){
        if (data[i] != to_peer[off + i]){
            VL_PRINTF("FAIL: clock %lu byte %zu out is 0x%02x, expected 0x%02x\n", (unsigned long)sim->cycle, (size_t)off + i, data[i], to_peer[off + i]);
            failures++;
            return;
        }
    }
    if (!data.empty() && c_edge_set && (int32_t)(seq + data.size() - c_edge) > 0){
        fail("the stack sent data past the window it was given");
    }
    if (!data.empty()){
        if ((int32_t)(seq - s_seen) < 0){
            n_resent++;
        }
        if ((int32_t)(seq + data.size() - s_seen) > 0){
            s_seen = (uint32_t)(seq + data.size());
        }
        if (seq == c_rcv){
            c_rcv += data.size();
            peer_rd += data.size();
        }
        c_ack_due = true;
    }
    if (flags & FIN){
        if ((uint32_t)(seq + data.size()) == c_rcv && !s_fin_seen){
            if (peer_rd != to_peer.size() || peer == P_OPEN){
                fail("the stack closed before the peer did or before all the data");
            }
            s_fin_seen = true;
            c_rcv += 1;
        }
        c_ack_due = true;
    }
}

static void check_tx(){
    for (int i = 0; i < 8; i++){
        uint8_t d = (top->xgmii_txd >> (8 * i)) & 0xFF;
        bool c = (top->xgmii_txc >> i) & 1;
        if (!tx_in_frame){
            if (c && d == XG_START){
                tx_in_frame = true;
                tx_got.clear();
                break;
            }
        }
        else if (c){
            tx_in_frame = false;
            if (d != XG_TERM || tx_got.size() < 64 || crc32_eth(tx_got.data(), tx_got.size()) != 0x2144DF1Cu){
                fail("bad frame out");
                continue;
            }
            Bytes frame(tx_got.begin(), tx_got.end() - 4);
            pcap->write(sim->cycle, frame);
            if (frame[12] == 0x08 && frame[13] == 0x00 && frame[23] == 6){
                peer_receive(frame);
            }
        }
        else {
            tx_got.push_back(d);
        }
    }
}

static void peer_tick(){
    bool waiting = (peer == P_SYN_SENT) || ((peer == P_OPEN || peer == P_FIN_SENT) && c_una != c_max);
    if (waiting && sim->cycle - c_progress > PEER_RTO){
        c_progress = sim->cycle;
        if (peer == P_SYN_SENT){
            peer_send(c_iss, SYN, Bytes{2, 4, 0x05, 0xB4}, Bytes{});
        }
        else {
            c_nxt = c_una; // go back to the oldest byte
        }
    }
    if (peer != P_OPEN && peer != P_FIN_SENT && peer != P_DONE){
        return;
    }
    if (wire.size() > 400){
        return; // one frame at a time on the wire
    }
    uint32_t sent = c_nxt - (c_iss + 1);
    uint32_t flight = c_nxt - c_una;
    // now and then it does not wait for room, the stack has to drop that and get it again later
    bool push = push_pct > 0 ? (int)(rng() % 100) < push_pct : rng() % 400 == 0;
    if (sent < to_stack.size() && (flight < stack_wnd || push) && rng() % 8 == 0){
        size_t n = to_stack.size() - sent;
        size_t room = flight < stack_wnd ? stack_wnd - flight : 1460;
        if (push){
            room += 3000;
            n_over++;
        }
        size_t most = rng() % 4 == 0 ? 1 + rng() % 16 : 1 + rng() % 1460;
        n = n > room ? room : n;
        n = n > most ? most : n;
        Bytes data(to_stack.begin() + sent, to_stack.begin() + sent + n);
        peer_send(c_nxt, ACK | (rng() % 2 ? PSH : 0), Bytes{}, data);
        c_nxt += n;
        if ((int32_t)(c_nxt - c_max) > 0){
            if (c_una == c_max){
                c_progress = sim->cycle;
            }
            c_max = c_nxt;
        }
        c_ack_due = false;
        return;
    }
    // close once everything has gone both ways
    bool all = sent == to_stack.size() && peer_rd == to_peer.size() && app_wr == to_peer.size();
    if (all && c_nxt == (uint32_t)(c_iss + 1 + to_stack.size()) && (peer == P_OPEN || peer == P_FIN_SENT) && (peer == P_OPEN ? c_una == c_nxt && app_rd == to_stack.size() : true)){
        if (peer == P_OPEN){
            c_progress = sim->cycle;
        }
        peer_send(c_nxt, FIN | ACK, Bytes{}, Bytes{});
        peer = P_FIN_SENT;
        c_nxt += 1;
        c_max = c_nxt;
        c_ack_due = false;
        return;
    }
    if (peer == P_FIN_SENT && s_fin_seen && c_una == c_max){
        peer = P_DONE;
    }
    if (c_ack_due){
        peer_send(c_nxt, ACK, Bytes{}, Bytes{});
        c_ack_due = false;
    }
}

static int app_stall;
static int app_pause;

static void step(){
    size_t n = to_peer.size() - app_wr;
    n = n > 8 ? 8 : n;
    if (n > 1 && rng() % 3 == 0){
        n = 1 + rng() % n;
    }
    top->tcp_tx_tdata = 0;
    for (size_t i = 0; i < n; i++){
        top->tcp_tx_tdata |= (uint64_t)to_peer[app_wr + i] << (8 * i);
    }
    top->tcp_tx_tkeep = (uint8_t)((1u << n) - 1);
    top->tcp_tx_tvalid = n > 0 && (app_pause == 0 || rng() % (app_pause + 1) == 0);
    top->tcp_rx_tready = app_stall == 0 || rng() % (app_stall + 1) == 0;
    sim->low();
    rx_clock.run(top, wire);
    if (top->tcp_tx_tvalid && top->tcp_tx_tready){
        app_wr += n;
    }
    if (top->tcp_rx_tvalid && top->tcp_rx_tready){
        for (int i = 0; i < 8; i++){
            if (!((top->tcp_rx_tkeep >> i) & 1)){
                continue;
            }
            uint8_t b = (top->tcp_rx_tdata >> (8 * i)) & 0xFF;
            if (app_rd >= to_stack.size() || b != to_stack[app_rd]){
                if (failures < 10){
                    VL_PRINTF("FAIL: clock %lu byte %zu into the application is 0x%02x, wrong or one too many\n", (unsigned long)sim->cycle, app_rd, b);
                }
                failures++;
            }
            app_rd++;
        }
    }
    sim->high();
    check_tx();
    peer_tick();
}

int main(int argc, char **argv, char **env){
    Verilated::commandArgs(argc, argv);
    Sim<Vtop> s;
    Pcap p;
    sim = &s;
    top = s.top;
    pcap = &p;
    rng.seed(tb_env("TB_SEED", 1));
    int conns = tb_env("TB_CONNS", 4);
    int bytes = tb_env("TB_BYTES", 20000);
    loss = tb_env("TB_LOSS", 5);
    push_pct = tb_env("TB_PUSH", 0);

    top->cfg_mac = mac_value(STACK_MAC);
    top->cfg_ip = STACK_IP;
    top->cfg_gateway = 0x0A000001;
    top->cfg_netmask = 0xFFFFFF00;
    top->cfg_tcp_port = STACK_PORT;
    top->xgmii_rxd = 0x0707070707070707ull;
    top->xgmii_rxc = 0xFF;
    top->rst_n = 0;
    top->rx_rst_n = 0;
    for (int i = 0; i < 3; i++){
        sim->low();
        rx_clock.run(top, wire);
        sim->high();
    }
    top->rst_n = 1;
    top->rx_rst_n = 1;

    // the stack learns the peer's MAC from its ARP request
    send_frame(eth_frame(MAC_BROADCAST, PEER_MAC, 0x0806, arp_packet(1, PEER_MAC, PEER_IP, Mac{}, STACK_IP)));
    for (int i = 0; i < 100; i++){
        step();
    }

    for (int c = 0; c < conns && failures == 0; c++){
        to_stack.resize(rng() % 5 == 0 ? rng() % 40 : rng() % bytes);
        to_peer.resize(rng() % 5 == 0 ? rng() % 40 : rng() % bytes);
        for (auto &b : to_stack){
            b = (uint8_t)rng();
        }
        for (auto &b : to_peer){
            b = (uint8_t)rng();
        }
        app_wr = app_rd = peer_rd = 0;
        app_stall = rng() % 3 == 0 ? 1 + rng() % 6 : rng() % 4 == 0 ? 2000 : 0;
        small_wnd = rng() % 3 == 0;
        if (push_pct > 0){
            app_stall = 300; // the receive buffer fills up
        }
        c_edge_set = false;
        app_pause = rng() % 3 == 0 ? 1 + rng() % 6 : 0;
        peer_port = 1024 + rng() % 60000;
        // the sequence numbers wrap in some connections
        c_iss = rng() % 2 ? 0xFFFFFFFFu - rng() % 20000 : (uint32_t)rng();
        c_una = c_nxt = c_max = c_iss;
        s_fin_seen = false;
        c_ack_due = false;
        peer = P_SYN_SENT;
        c_progress = sim->cycle;
        peer_send(c_iss, SYN, Bytes{2, 4, 0x05, 0xB4}, Bytes{});

        uint64_t limit = sim->cycle + 2000000 + 4000ull * (to_stack.size() + to_peer.size());
        bool was_connected = false;
        while (peer != P_DONE && failures == 0 && sim->cycle < limit){
            step();
            was_connected = was_connected || top->tcp_connected;
        }
        if (peer != P_DONE){
            VL_PRINTF("FAIL: connection %d stuck, peer state %d, %zu of %zu bytes into the application, %zu of %zu to the peer\n",
                      c, peer, app_rd, to_stack.size(), peer_rd, to_peer.size());
            VL_PRINTF("  peer: una=%u nxt=%u max=%u end=%u window=%u, application wrote %zu\n", c_una - c_iss, c_nxt - c_iss, c_max - c_iss, (uint32_t)to_stack.size() + 1, stack_wnd, app_wr);
            failures++;
        }
        if (!was_connected || app_rd != to_stack.size()){
            fail("tcp_connected never went high or data is missing");
        }
        // the last ACK can be lost, the stack then sends its FIN again
        for (int i = 0; i < 4 * 3000 && failures == 0; i++){
            step();
        }
        if (top->tcp_connected){
            fail("still connected after the close");
        }
        n_conn++;
    }

    if (failures == 0){
        VL_PRINTF("PASS: all tcp_conn tests passed (%d connections, %d segments in with %d lost and %d past the window, %d out with %d lost, %d sent again by the stack)\n",
                  n_conn, n_seg_in, n_lost_in, n_over, n_seg_out, n_lost_out, n_resent);
    }
    else {
        VL_PRINTF("FAIL: %d tcp_conn test(s) failed\n", failures);
    }
    return failures == 0 ? 0 : 1;
}
