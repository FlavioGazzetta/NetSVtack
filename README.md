# NetSVtack

A TCP/IP network stack in hand-written SystemVerilog for an FPGA: Ethernet,
ARP, IPv4, UDP and TCP, on a 64 bit datapath at 156.25 MHz for 10 Gigabit
Ethernet. The board is a ZCU106, using one of its SFP+ cages.

The targets are to sustain 10 Gbps and to answer in under 800 ns round trip
(125 clocks, wire to wire), which is the number to compare against the Linux
kernel stack on the same link. Neither is measured yet.

## Where it is at

Done and verified in simulation:

- the MAC: `mac_rx` and `mac_tx` between 64 bit XGMII and AXI-Stream, with
  the CRC32 they share. Receive takes a start in lane 0 or 4, strips the
  preamble and FCS and flags bad frames. Transmit adds the preamble, pads to
  the minimum, appends the FCS and keeps the gap between frames.
- `hdr_strip` and `hdr_insert`: take a header of any length off the front of
  a stream, or put one on. Every layer above the MAC is one of these plus its
  own checks.
- Ethernet: `eth_rx` keeps frames for this MAC or broadcast and says whether
  they are ARP or IPv4. `eth_tx` builds the header.
- ARP: `arp` answers requests for this IP, sends requests, and feeds what it
  hears to `arp_cache` (8 entries).
- IPv4: `ipv4_rx` checks the header checksum and the destination and cuts the
  Ethernet padding off. `ipv4_tx` builds the header with its checksum and
  looks the next hop up in the ARP cache.
- UDP: `udp_rx` and `udp_tx`.
- ICMP: `icmp` answers echo requests, so the stack can be pinged.
- TCP, one connection opened by the peer: `tcp_rx` parses the header and
  checks the checksum, `tcp_ctrl` keeps the state and the sequence numbers,
  `tcp_tx` builds segments, and `tcp_rx_buf` and `tcp_tx_buf` hold 16 KB each
  way. Data that is not acknowledged in time is sent again from the oldest
  byte, and a peer that stops answering is dropped after 8 tries.
- `netsvtack`, the top level, with all of it wired from XGMII to the UDP and
  TCP streams.

In simulation a datagram's first word reaches the application 14 to 18 clocks
after the start of its frame goes into the XGMII pins and its last word 7 to 9
clocks after the end of the frame. Going out, the frame starts on XGMII 5
clocks after the application offers the first word.

Still to do: the ZCU106 build (10GBASE-R PCS/PMA on a GTH, and a clock
crossing from the recovered receive clock), then the measurements on the
board.

Known gaps:

- `mac_tx` always starts a frame in lane 0, so the gap is 12 to 19 bytes
  instead of an average of 12. Full line rate for every frame length needs the
  deficit idle count and lane 4 starts.
- UDP checksums are not checked and are sent as 0 (allowed over IPv4).
- A datagram for an address that is not in the ARP cache is dropped and an ARP
  request goes out instead. Cache entries never age.
- IPv4 packets with options or in fragments are dropped. No VLAN tags.
- TCP: no congestion control, no fast retransmit and no zero window probe.
  Segments that arrive out of order are dropped and asked for again. TCP
  options are ignored apart from sending the MSS, and data in a segment that
  has options is not taken. Nothing is sent back to a port that is closed.
  The stack cannot open or close a connection itself, the peer does both.
- `tcp_tx` copies a segment into a FIFO before it goes out, to have the
  checksum for the header. That costs one clock per 8 bytes of data.

## Layout

```
rtl/common/        hdr_strip, hdr_insert, frame_mux, frame_fifo
rtl/mac/           crc32, mac_rx, mac_tx
rtl/eth/           eth_rx, eth_tx
rtl/arp/           arp, arp_cache
rtl/ipv4/          ipv4_rx, ipv4_tx
rtl/udp/           udp_rx, udp_tx
rtl/icmp/          icmp
rtl/tcp/           tcp_rx, tcp_ctrl, tcp_tx, tcp_rx_buf, tcp_tx_buf
rtl/top/           netsvtack

tb/verilator/      C++ testbenches: mac, common, tcp, top
tb/verilator/lib.sh    build, run and summary shared by every <block>_test.sh
tb/regressions/    regression YAMLs and the runner
spec/              diagrams
```

Streams between blocks are AXI-Stream, 64 bits with tkeep, and tuser on tlast
marks a frame to drop. Byte 0 of a word is the first byte on the wire. The
receive side has no tready. Header fields travel next to a stream as plain
signals: held through the frame on receive, and on transmit held until the
first word is taken.

The `top` testbench drives the whole stack through XGMII: ARP requests and
replies, datagrams in both directions, and frames that have to be dropped
(bad FCS, another MAC or IP, bad checksum, wrong length, fragments), and
pings. The `tcp` testbench has a peer that opens connections to the stack,
sends and receives random data, loses segments both ways, ignores the window
now and then, and closes. With `:pcap` either one writes every frame to a
capture that opens in Wireshark.

## Getting started

You need Verilator (I use 5.046), Python 3 and PyYAML.

## Running the tests

The testbenches are written in C++ and run by the regression script
`tb/regressions/regress.py`.

```
make sanity      quick run of every suite
make nightly     sanity, then each suite with more seeds and extra variants
make top         a single suite (mac, common, tcp, top)
make list        shows each suite and the command it runs
make lint        lints all the RTL
```

Each suite is a YAML file in `tb/regressions/` with one command for sanity and
one for nightly:

```yaml
name: mac
sanity: ./tb/verilator/mac/mac_test.sh
nightly: ./tb/verilator/mac/mac_test.sh :sweep :random_seeds=10
```

`sanity.yml` lists the suites that make up sanity. `nightly.yml` runs sanity
and then the nightly command of every suite listed after it.

To run a single test, call the layer's script directly. You can filter by test
name and pass options after it:

```
tb/verilator/mac/mac_test.sh mac_rx
tb/verilator/mac/mac_test.sh mac_rx :seeds=7
tb/verilator/mac/mac_test.sh mac_rx :FRAMES=20000
tb/verilator/mac/mac_test.sh :sweep :random_seeds=5
tb/verilator/top/top_test.sh :OPS=200 :trace :pcap
tb/verilator/mac/mac_test.sh :help
```

Options in capitals like `:FRAMES=20000` are test settings, which the C++ reads
as `TB_FRAMES`. `:trace` writes a waveform for each run and `:pcap` writes the
frames the test saw as a capture that opens in Wireshark.

Logs and summaries end up in `.build/regressions/<suite>/<sanity or nightly>/`
and the builds, waveforms and captures in `.build/verilator/`.
