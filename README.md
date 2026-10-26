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
  TCP streams. `mac_rx` runs on the clock recovered from the link, and
  `frame_cdc`, an asynchronous FIFO, brings its frames onto the transmit clock
  that everything else uses.
- the 10GBASE-R PCS: `pcs_tx` encodes XGMII into 66 bit blocks and scrambles
  them, `pcs_rx` finds the block boundary, descrambles and decodes. The
  serial side is Vivado's GTH transceiver IP with its 64B/66B gearbox.
- `netsvtack_echo`, the design that goes on the board: the stack with
  `udp_echo`, which sends every datagram back to where it came from, and the
  TCP stream looped back into itself.

In simulation a datagram's first word reaches the application 19 to 23 clocks
after the start of its frame goes into the XGMII pins and its last word 12 to
14 clocks after the end of the frame. Going out, the frame starts on XGMII 5
clocks after the application offers the first word. With `udp_echo` a 64 byte
frame starts coming back 29 to 30 clocks after it started going in (about 190
ns), and any frame 19 to 21 clocks after its end. That is XGMII to XGMII: the
PCS adds a clock each way and the transceiver its own delay, which only the
board can give.

The ZCU106 build (Vivado 2025.2) places and routes and writes a bitstream. All
timing is met at 6.4 ns with 0.55 ns of slack on the transmit clock and 2.6 ns
on the receive clock. The whole design is 7.9 k LUTs and 5.3 k flip-flops, 3%
and 1% of the XCZU7EV, plus 13 block RAMs and one UltraRAM.

Still to do: load it on the board, and measure the throughput and the round
trip there and against the Linux kernel stack on the same link.

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
- The PCS has no link fault signalling and no bit error rate monitor. It sends
  idle whatever the receive side sees, and ordered sets that come in are
  decoded and then ignored by the MAC.
- `frame_cdc` relies on the two clocks being within a few hundred ppm, as two
  ends of an Ethernet link are. What it does when it overflows is not tested.
- The bitstream has never been on a board. The pins come from the board files
  and from other ZCU106 designs, not from a link that came up.
- Nothing resets the receive side of the transceiver when the link goes away
  and comes back. If block lock does not return, press CPU_RESET.

## Layout

```
rtl/common/        hdr_strip, hdr_insert, frame_mux, frame_fifo, frame_cdc
rtl/pcs/           pcs_tx, pcs_rx
rtl/mac/           crc32, mac_rx, mac_tx
rtl/eth/           eth_rx, eth_tx
rtl/arp/           arp, arp_cache
rtl/ipv4/          ipv4_rx, ipv4_tx
rtl/udp/           udp_rx, udp_tx
rtl/icmp/          icmp
rtl/tcp/           tcp_rx, tcp_ctrl, tcp_tx, tcp_rx_buf, tcp_tx_buf
rtl/app/           udp_echo
rtl/top/           netsvtack, netsvtack_echo

fpga/zcu106/       board top level, transceiver wrapper, constraints, build.tcl
synth/             out of context synthesis of one block

tb/verilator/      C++ testbenches: mac, pcs, common, tcp, top, echo
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

The `pcs` testbench puts the two halves of the PCS on a wire of single bits
that starts at a random bit, loses a bit now and then so the lock has to be
found again, has bit errors, and carries blocks that `pcs_tx` never sends
(ordered sets, unknown types, bad headers). `cdc_link` in `common` runs
`frame_cdc` with its two clocks up to 1000 ppm apart and checks that a frame
comes out whole and without a gap. `echo` runs `netsvtack_echo` as the board
would see it, and `top`, `tcp` and `echo` all take `:PPM=` to run the receive
clock off the transmit clock.

## Building for the ZCU106

```
vivado -mode batch -source fpga/zcu106/build.tcl
```

makes the transceiver IP, runs synthesis and place and route, and writes the
reports and `netsvtack_zcu106.bit` to `fpga/zcu106/out/`. The board needs an
SFP+ module or cable in cage SFP0 and the SI570 at its 156.25 MHz default. The
design answers ARP and ping at 192.168.1.128 (MAC 02:00:00:00:00:01), echoes
UDP on any port and TCP on port 5001. These are parameters of
`netsvtack_echo`. LEDs 0 to 4: transceiver out of reset, block lock, TCP
connected, a good frame came in, a bad frame came in.

For timing and area of one block on its own:

```
vivado -mode batch -source synth/ooc_synth.tcl -tclargs netsvtack 6.4 $(find rtl -name '*.sv')
```

## Getting started

You need Verilator (I use 5.046), Python 3 and PyYAML.

## Running the tests

The testbenches are written in C++ and run by the regression script
`tb/regressions/regress.py`.

```
make sanity      quick run of every suite
make nightly     sanity, then each suite with more seeds and extra variants
make top         a single suite (mac, pcs, common, tcp, top, echo)
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
