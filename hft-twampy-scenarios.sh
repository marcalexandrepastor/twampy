#!/usr/bin/env bash
# =============================================================================
# hft-twampy-scenarios.sh
# TWAMP-based network characterization for High-Frequency Trading environments
#
# Tool  : twampy (Nokia) — https://github.com/nokia/twampy
#         pip install twampy
#
# Usage : Edit RESPONDER_IP (and optionals) in CONFIG, then:
#           chmod +x hft-twampy-scenarios.sh
#           ./hft-twampy-scenarios.sh [scenario]   # run one scenario
#           ./hft-twampy-scenarios.sh all           # run full suite
#           ./hft-twampy-scenarios.sh baseline      # baseline only
#
# Start the responder on the remote host first:
#   twampy responder --port 862
#   # Or pin it to a specific core for accuracy:
#   taskset -c 3 twampy responder --port 862
#
# DSCP markings used (match your exchange/co-lo QoS policy):
#   EF   = 46  (0xB8) — expedited forwarding: order entry, risk checks
#   AF41 = 34  (0x88) — assured forwarding:   primary market data
#   AF31 = 26  (0x68) — assured forwarding:   secondary/backup feeds
#   CS6  = 48  (0xC0) — network control:      heartbeats, session mgmt
#   CS0  = 0   (0x00) — best effort:          historical, bulk reference
#
# Output: results saved to $RESULTS_DIR with timestamps
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIG — edit these before running
# =============================================================================
RESPONDER_IP="${RESPONDER_IP:-10.0.0.2}"      # IP of the twampy responder
RESPONDER_PORT="${RESPONDER_PORT:-862}"        # TWAMP-Light port
LOCAL_IFACE="${LOCAL_IFACE:-wlan0}"             # Outbound interface
RESULTS_DIR="${RESULTS_DIR:-./twampy-results}" # Where to write output files
CPU_PIN="${CPU_PIN:-}"                         # If set, pin sender: taskset -c $CPU_PIN
LOG_FORMAT="${LOG_FORMAT:-text}"               # text | json | csv

# =============================================================================
# INFRASTRUCTURE
# =============================================================================
mkdir -p "$RESULTS_DIR"
TS=$(date +%Y%m%d_%H%M%S)

log() { printf '\n\e[1;36m[%s] %s\e[0m\n' "$(date +%T)" "$*"; }
warn() { printf '\e[1;33m[WARN] %s\e[0m\n' "$*"; }
sep() { printf '\e[90m%s\e[0m\n' "$(printf '─%.0s' {1..72})"; }

# Optionally pin the twampy process to a dedicated core to remove
# scheduler jitter from the measurement itself.
TASKSET=""
if [[ -n "$CPU_PIN" ]]; then
    TASKSET="taskset -c $CPU_PIN"
    log "Pinning twampy sender to CPU core $CPU_PIN"
fi

# Wrapper: run twampy and tee output to a named results file.
run() {
    local name="$1"; shift
    local outfile="$RESULTS_DIR/${TS}_${name}.${LOG_FORMAT}"
    log "Scenario: $name → $outfile"
    sep
    $TASKSET twampy sender \
        "$@" \
        "$RESPONDER_IP:$RESPONDER_PORT" \
        | tee "$outfile"
    sep
}

# =============================================================================
# ── SCENARIO 1 ───────────────────────────────────────────────────────────────
# BASELINE LATENCY FINGERPRINT
# Purpose : Establish clean RTT baseline with no artificial load.
#           Run this first and last — before/after tuning — to measure delta.
#           64-byte packets (IP+UDP+TWAMP header only, zero padding) at a
#           gentle 10 pps over 60 seconds. This is what a quiet FIX heartbeat
#           looks like on the wire. Use this result as your reference floor.
# Expect  : sub-100µs p99 in co-lo, 500µs–2ms for cross-DC, >5ms = problem
# =============================================================================
scenario_baseline() {
    run "01_baseline_latency_fingerprint" \
        --count     600         \
        --interval  100         \
        --padding   0           \
        --tos       0           \
        --ttl       64          \
        --do-not-fragment
}

# =============================================================================
# ── SCENARIO 2 ───────────────────────────────────────────────────────────────
# ORDER ENTRY SIMULATION  (FIX over TCP proxy / ITCH UDP order ack)
# Purpose : Model the latency of the order entry path — the most
#           latency-critical flow in any HFT system. Small packets
#           (FIX NewOrderSingle ~150 bytes), EF DSCP marking, high rate
#           to stress the NIC interrupt / socket processing pipeline.
#           2000 pps = 2 orders/ms — typical for a fast algo on one gateway.
# Packet  : 150 bytes total (14B FIX header + 136B body → ~86B UDP payload
#           after TWAMP header; we pad to 100 to approximate real size)
# DSCP    : EF (46/0xB8) — highest QoS queue, lowest jitter path
# =============================================================================
scenario_order_entry() {
    run "02_order_entry_EF_2000pps" \
        --count     6000        \
        --interval  1           \
        --padding   100         \
        --tos       184         \
        --ttl       64          \
        --do-not-fragment
}

# =============================================================================
# ── SCENARIO 3 ───────────────────────────────────────────────────────────────
# PRIMARY MARKET DATA FEED  (CME Globex / ICE / NASDAQ TotalView-ITCH)
# Purpose : Simulate a consolidated market data feed. UDP multicast feeds
#           from major venues run at 500–50,000 pps depending on instrument.
#           E-mini futures (ES, NQ) routinely burst to 50K+ pps at the open.
#           This tests whether your network path can sustain the feed rate
#           without introducing tail latency under load.
# Packet  : 220 bytes (typical CME MDP3 incremental refresh message size)
# Rate    : 10,000 pps — representative of a busy equity/futures feed
# DSCP    : AF41 (34/0x88) — primary market data, admitted with guarantees
# =============================================================================
scenario_market_data_primary() {
    run "03_market_data_primary_AF41_10Kpps" \
        --count     60000       \
        --interval  0.1         \
        --padding   164         \
        --tos       136         \
        --ttl       64          \
        --do-not-fragment
}

# =============================================================================
# ── SCENARIO 4 ───────────────────────────────────────────────────────────────
# SECONDARY / BACKUP MARKET DATA FEED
# Purpose : Many venues (CME, ICE) send feeds A and B simultaneously over
#           separate network paths. Characterize the secondary path and
#           compare its latency/jitter profile against the primary.
#           A persistent latency gap between A and B feed indicates
#           asymmetric routing and must be corrected before going live.
# Packet  : 220 bytes (same as primary for apples-to-apples comparison)
# Rate    : 10,000 pps on a different port / path
# DSCP    : AF31 (26/0x68) — secondary data, lower admission priority
# =============================================================================
scenario_market_data_secondary() {
    run "04_market_data_secondary_AF31_10Kpps" \
        --count     60000       \
        --interval  0.1         \
        --padding   164         \
        --tos       104         \
        --ttl       64          \
        --do-not-fragment
}

# =============================================================================
# ── SCENARIO 5 ───────────────────────────────────────────────────────────────
# MARKET OPEN BURST — "the 9:30 AM hammer"
# Purpose : The equity open (09:30 ET) and futures roll windows produce the
#           highest instantaneous packet rates of any trading session. Market
#           makers, arbitrageurs, and opening auction algorithms all fire
#           simultaneously. This creates a packet burst that can saturate NIC
#           ring buffers and expose kernel interrupt-coalescing misconfiguration.
#           We simulate this as a 100K pps burst lasting 5 seconds (500K packets)
#           followed by measurement of recovery time.
# Packet  : 100 bytes (compressed ITCH/MDP3 top-of-book update)
# Rate    : 100,000 pps — aggressive burst, not sustained
# DSCP    : AF41 (0x88)
# =============================================================================
scenario_market_open_burst() {
    run "05_market_open_burst_100Kpps" \
        --count     500000      \
        --interval  0.01        \
        --padding   44          \
        --tos       136         \
        --ttl       64          \
        --do-not-fragment
}

# =============================================================================
# ── SCENARIO 6 ───────────────────────────────────────────────────────────────
# FIX SESSION HEARTBEAT / KEEPALIVE
# Purpose : FIX 4.2/4.4/5.0 sessions exchange Heartbeat(0) messages every
#           30–60 seconds (configurable). Session managers and risk engines
#           also send application-layer pings. This test characterizes
#           the network's behavior for infrequent, latency-critical small
#           control messages — most likely to be delayed by interrupt coalescing
#           or by being behind a queue of larger packets.
# Packet  : 56 bytes (FIX Heartbeat "8=FIX.4.2|9=0073|35=0|..." stripped to
#           the UDP core; 12B TWAMP header + ~44B body)
# Rate    : 1 pps (exactly one heartbeat per second, 300 seconds = 5 min)
# DSCP    : CS6 (48/0xC0) — network control class, smallest queue wait
# =============================================================================
scenario_fix_heartbeat() {
    run "06_fix_heartbeat_CS6_1pps_5min" \
        --count     300         \
        --interval  1000        \
        --padding   0           \
        --tos       192         \
        --ttl       64          \
        --do-not-fragment
}

# =============================================================================
# ── SCENARIO 7 ───────────────────────────────────────────────────────────────
# OPTIONS CHAIN SNAPSHOT REFRESH
# Purpose : Options market data is far bulkier than futures. A single SPX
#           chain refresh can be hundreds of thousands of strikes; a full
#           top-of-book snapshot burst for all expirations can hit 500KB–2MB
#           in a single burst. This test uses large packets (jumbo frame
#           territory) to characterize path MTU behavior and whether your
#           NIC/switch is configured for jumbo frames end-to-end.
#           If RTT spikes on large packets, MTU mismatch or IP fragmentation
#           is occurring somewhere in the path.
# Packet  : 1400 bytes (just under standard 1500B MTU to avoid fragmentation
#           on paths not configured for jumbo frames)
# Rate    : 5,000 pps = ~56 Mbps — sustained options chain refresh
# DSCP    : AF41 (0x88)
# =============================================================================
scenario_options_chain_refresh() {
    run "07_options_chain_1400B_5Kpps" \
        --count     30000       \
        --interval  0.2         \
        --padding   1344        \
        --tos       136         \
        --ttl       64          \
        --do-not-fragment
}

# =============================================================================
# ── SCENARIO 8 ───────────────────────────────────────────────────────────────
# JUMBO FRAME / LARGE MTU PATH VALIDATION
# Purpose : Co-location environments commonly support 9000-byte jumbo frames
#           for internal traffic. If your NIC, ToR switch, and the responder's
#           NIC are all configured for jumbo frames (MTU ≥ 9000), this test
#           validates the path. If any hop is not jumbo-capable, packets will
#           be fragmented or dropped (with DF set) and you'll see loss/RTT spikes.
#           Compare RTT-per-byte between this and scenario 7 — if they match,
#           jumbo frames are working. If this scenario shows loss, check MTU
#           on each hop: ip link show; ethtool -k eth0 | grep jumbo
# Packet  : 8972 bytes (9000 MTU − 20 IP − 8 UDP = 8972B max payload)
# Rate    : 1000 pps = ~72 Mbps — moderate jumbo load
# DSCP    : AF41
# =============================================================================
scenario_jumbo_frame_validation() {
    run "08_jumbo_frame_9000B_1Kpps" \
        --count     5000        \
        --interval  1           \
        --padding   8900        \
        --tos       136         \
        --ttl       64          \
        --do-not-fragment
}

# =============================================================================
# ── SCENARIO 9 ───────────────────────────────────────────────────────────────
# CROSS-VENUE ARBITRAGE LATENCY WINDOW
# Purpose : Stat-arb and cross-venue strategies depend on the time delta
#           between receiving a price update from venue A and getting the
#           corresponding update from venue B. This test characterizes
#           the absolute path latency between your server and a remote
#           endpoint (e.g., a cross-connect to a second co-lo).
#           Run simultaneously in two terminal windows — one to each venue's
#           responder — and compare the two result files. The difference in
#           median RTT is your venue latency advantage/disadvantage.
# Packet  : 64 bytes (minimal — measures pure network latency, not copy cost)
# Rate    : 100 pps over 10 minutes — long enough to catch diurnal variation
# DSCP    : EF (0xB8) — measure the fast path
# =============================================================================
scenario_cross_venue_latency() {
    run "09_cross_venue_arbitrage_window" \
        --count     6000        \
        --interval  10          \
        --padding   0           \
        --tos       184         \
        --ttl       64          \
        --do-not-fragment
}

# =============================================================================
# ── SCENARIO 10 ──────────────────────────────────────────────────────────────
# SUSTAINED THROUGHPUT STRESS — BUFFER BLOAT DETECTION
# Purpose : Send at wire rate for an extended period to detect buffer bloat,
#           BDP mismatches, and queueing latency under saturation. If median
#           RTT during this test is >> baseline, your network path has
#           excessive queuing somewhere (NIC ring buffer, switch port buffer,
#           or kernel socket buffer). For HFT, any sustained RTT increase
#           under load indicates the network is not deterministic and must
#           be redesigned (lower coalescing intervals, smaller queues, WRED).
# Rate    : 50,000 pps, ~300 bytes/packet = ~120 Mbps — typical peak intraday
#           load for a mid-size HFT operation on a single 1G link.
#           Scale up to 500K pps on 10GbE by halving interval.
# DSCP    : AF41 (0x88)
# Duration: 5 minutes
# =============================================================================
scenario_buffer_bloat_stress() {
    run "10_buffer_bloat_50Kpps_5min" \
        --count     15000000    \
        --interval  0.02        \
        --padding   244         \
        --tos       136         \
        --ttl       64          \
        --do-not-fragment
}

# =============================================================================
# ── SCENARIO 11 ──────────────────────────────────────────────────────────────
# JITTER ISOLATION — MICROSECOND-RESOLUTION PROBE
# Purpose : Detect periodic jitter sources: OS tick (HZ=250 → 4ms spikes on
#           6.2, HZ=1000 → 1ms on 6.17), NIC interrupt coalescing windows,
#           TCP retransmit timers, NUMA balancing, THP khugepaged, RCU
#           callbacks, and kswapd. Set the interval to a prime number of
#           milliseconds to avoid aliasing with any periodic kernel timer.
#           Collect 10,000 samples at 7ms intervals (~70 seconds) and examine
#           the RTT distribution histogram. Periodic spikes at fixed multiples
#           (e.g., every 4ms, every 200ms) indicate specific timer sources.
#           Stochastic spikes indicate lock contention or NIC buffer overflow.
# Packet  : minimal (64B) — any size variation would obscure latency signal
# Rate    : 143 pps (interval = 7ms, prime to avoid aliasing)
# DSCP    : EF
# =============================================================================
scenario_jitter_isolation() {
    run "11_jitter_isolation_7ms_prime_interval" \
        --count     10000       \
        --interval  7           \
        --padding   0           \
        --tos       184         \
        --ttl       64          \
        --do-not-fragment
}

# =============================================================================
# ── SCENARIO 12 ──────────────────────────────────────────────────────────────
# MIXED TRAFFIC QOS VALIDATION — PRIORITY QUEUE BEHAVIOR
# Purpose : Run two twampy sessions simultaneously (in background + foreground)
#           to validate that your QoS policy actually differentiates between
#           traffic classes. The EF stream simulates order entry; the CS0
#           stream simulates bulk historical data. The EF stream's RTT should
#           be unaffected by the CS0 stream's presence. If EF latency rises
#           when CS0 load is added, your switch's priority queueing (PQ, WFQ,
#           or WRED) is misconfigured or the link is saturated.
#
# Start the low-priority (CS0) background flood in one terminal:
#   twampy sender --count 999999 --interval 0.05 --padding 1200 --tos 0   \
#                 --port 862 10.0.0.2 &
# Then immediately run this EF probe in another:
# =============================================================================
scenario_qos_priority_validation_ef() {
    log "QoS test: EF probe running alongside CS0 background flood"
    log "Start the background flood first:"
    log "  twampy sender --count 999999 --interval 0.05 --padding 1200 \\"
    log "                --tos 0   --port $RESPONDER_PORT $RESPONDER_IP &"
    log ""
    log "Press ENTER when background flood is running..."
    read -r

    run "12a_qos_ef_probe_under_cs0_load" \
        --count     3000        \
        --interval  10          \
        --padding   0           \
        --tos       184         \
        --ttl       64          \
        --do-not-fragment
}

# Run just the background flood side if you want to generate it locally
scenario_qos_background_flood() {
    log "Starting CS0 background flood — run EF probe in another window"
    log "  ./hft-twampy-scenarios.sh qos_ef"
    run "12b_qos_background_cs0_flood" \
        --count     999999      \
        --interval  0.05        \
        --padding   1200        \
        --tos       0           \
        --ttl       64          \
        --do-not-fragment
}

# =============================================================================
# ── SCENARIO 13 ──────────────────────────────────────────────────────────────
# PACKET LOSS DETECTION — BURST LOSS ANALYSIS
# Purpose : Identify whether packet loss occurs in isolated bursts (NIC ring
#           overflow, switch buffer overflow, single bad cable event) or
#           uniformly (bad link, bit-error rate, NIC firmware bug).
#           Burst loss during a volatile trading session can mean lost
#           market data packets — unrecoverable with UDP multicast unless
#           you have gap-fill from the exchange (CME MBO recovery feed, etc).
#           Uniform low loss suggests a systematic hardware problem.
#           Send 1M packets at 50K pps; analyze the sequence gap pattern
#           in the JSON output to distinguish burst vs uniform loss.
# =============================================================================
scenario_packet_loss_analysis() {
    run "13_packet_loss_analysis_1M_50Kpps" \
        --count     1000000     \
        --interval  0.02        \
        --padding   0           \
        --tos       136         \
        --ttl       64          \
        --do-not-fragment
}

# =============================================================================
# ── SCENARIO 14 ──────────────────────────────────────────────────────────────
# ASYMMETRIC PATH DETECTION — ONE-WAY DELAY PROXY
# Purpose : TWAMP measures round-trip time. A symmetric RTT (forward == return)
#           is assumed. If your path is asymmetric (e.g., different ECMP routes
#           for forward vs return, or an asymmetric WAN path to an exchange
#           co-lo), the RTT may be stable but the one-way components unequal.
#           Detect this by comparing RTT from site A → B with RTT from B → A
#           (run this on both hosts). If RTT_AB ≠ RTT_BA significantly
#           (>10%), suspect asymmetric routing.
#           Also run with TTL=1, 2, 3, ... to fingerprint each hop's latency
#           contribution (poor-man's traceroute with latency).
#
# TTL sweep: exposes per-hop latency — uncomment if you have ICMP TTL exceeded
# responses enabled on intermediate hops.
# =============================================================================
scenario_asymmetric_path_ttl_sweep() {
    log "TTL sweep for per-hop latency fingerprinting"
    for ttl in 1 2 3 4 5 6 7 8 9 10 15 20 30 64; do
        log "  TTL = $ttl"
        outfile="$RESULTS_DIR/${TS}_14_ttl_sweep_ttl${ttl}.${LOG_FORMAT}"
        $TASKSET twampy sender \
            --interface  "$LOCAL_IFACE" \
            --output     "$LOG_FORMAT"  \
            --count      100            \
            --interval   10             \
            --padding    0              \
            --tos        184           \
            --ttl        "$ttl"         \
            "$RESPONDER_IP" \
            | tee "$outfile" || true    # TTL-expired packets will cause errors; continue
    done
    log "TTL sweep complete. Check $RESULTS_DIR/${TS}_14_ttl_sweep_*.json"
}

# =============================================================================
# ── SCENARIO 15 ──────────────────────────────────────────────────────────────
# END-OF-DAY SESSION SHUTDOWN SIMULATION
# Purpose : At 16:00 ET, exchanges close equity sessions and send a storm of
#           trade and order status messages. FIX engines send Logout and
#           administrative messages. This creates a brief but intense burst
#           followed by near-zero traffic — a sharp traffic transition.
#           This test validates that the network path handles a traffic
#           step-down cleanly, without the NIC's adaptive interrupt coalescing
#           shifting to a "quiet mode" that then causes the first post-EOD
#           packet to be delayed (common on poorly tuned NICs).
# Pattern : 30s high rate → 30s silence → 30s high rate again
#           Watch for latency increase in the third phase vs the first.
# =============================================================================
scenario_eod_session_shutdown() {
    log "Phase 1: EOD burst (30s at 10K pps)"
    run "15a_eod_phase1_burst" \
        --count     300000      \
        --interval  0.1         \
        --padding   100         \
        --tos       192         \
        --ttl       64          \
        --do-not-fragment

    log "Phase 2: 30-second silence (simulating post-close quiet)"
    sleep 30

    log "Phase 3: Post-silence recovery (watch for first-packet spike)"
    run "15b_eod_phase3_recovery_after_silence" \
        --count     300000      \
        --interval  0.1         \
        --padding   100         \
        --tos       192         \
        --ttl       64          \
        --do-not-fragment

    log "Compare phase1 vs phase3 latency — any increase = adaptive coalescing problem."
    log "Fix: ethtool -C $LOCAL_IFACE adaptive-rx off adaptive-tx off rx-usecs 50"
}

# =============================================================================
# ── SCENARIO 16 ──────────────────────────────────────────────────────────────
# IPV6 LATENCY COMPARISON
# Purpose : Some co-lo providers and exchange gateways are transitioning to
#           IPv6 for internal addressing. Compare IPv4 vs IPv6 RTT on the same
#           physical path — any difference exposes protocol-processing overhead
#           in your network stack, NIC firmware, or switch ASIC.
#           Requires the responder to be reachable via IPv6.
# =============================================================================
scenario_ipv6_comparison() {
    local v6_target="${IPV6_RESPONDER:-${RESPONDER_IP}}"  # override with IPV6_RESPONDER env var

    log "IPv4 baseline (for comparison)"
    run "16a_ipv4_baseline" \
        --count     1000        \
        --interval  10          \
        --padding   0           \
        --tos       184         \
        --ttl       64          \
        --do-not-fragment

    log "IPv6 probe (set IPV6_RESPONDER env var if different from RESPONDER_IP)"
    outfile="$RESULTS_DIR/${TS}_16b_ipv6_probe.${LOG_FORMAT}"
    $TASKSET twampy sender \
        --ipv6 \
        --interface  "$LOCAL_IFACE" \
        --output     "$LOG_FORMAT"  \
        --count      1000           \
        --interval   10             \
        --padding    0              \
        --tos        184           \
        --ttl        64             \
        --do-not-fragment           \
        "$v6_target" \
        | tee "$outfile"
}

# =============================================================================
# ── SCENARIO 17 ──────────────────────────────────────────────────────────────
# CONTINUOUS OVERNIGHT MONITORING (latency SLA watchdog)
# Purpose : Run overnight to collect baseline latency statistics for SLA
#           reporting and to catch infrastructure events (maintenance windows,
#           BGP reconvergence, power fluctuations) that cause latency spikes
#           during off-hours. Useful for validating that a carrier's committed
#           latency SLA (<X µs p99) is actually being met over 8 hours.
#           Results are written incrementally; pipe through a monitoring tool
#           or parse the JSON to feed into your time-series DB (Prometheus,
#           InfluxDB, Grafana).
# Duration: 8 hours (28,800 packets at 1 per second)
# =============================================================================
scenario_overnight_monitoring() {
    log "Starting 8-hour overnight latency monitor. Results → $RESULTS_DIR"
    log "Stop with Ctrl+C; partial results are saved incrementally."
    run "17_overnight_latency_sla_monitor" \
        --count     28800       \
        --interval  1000        \
        --padding   0           \
        --tos       184         \
        --ttl       64          \
        --do-not-fragment
}

# =============================================================================
# ── FULL SUITE ────────────────────────────────────────────────────────────────
# Run all characterization scenarios in sequence (skip overnight and QoS
# interactive tests which require manual steps).
# =============================================================================
run_all() {
    log "=== HFT TWAMP Full Characterization Suite ==="
    log "Responder: $RESPONDER_IP:$RESPONDER_PORT"
    log "Interface: $LOCAL_IFACE"
    log "Output:    $RESULTS_DIR"

    scenario_baseline
    scenario_fix_heartbeat
    scenario_order_entry
    scenario_market_data_primary
    scenario_market_data_secondary
    scenario_market_open_burst
    scenario_options_chain_refresh
    scenario_jitter_isolation
    scenario_buffer_bloat_stress
    scenario_packet_loss_analysis
    scenario_asymmetric_path_ttl_sweep
    scenario_eod_session_shutdown

    log "=== Suite complete. Results in $RESULTS_DIR ==="
    log "Tip: diff the two feed JSONs to spot asymmetric paths:"
    log "     jq '.rtt.p99' $RESULTS_DIR/${TS}_03_*.json"
    log "     jq '.rtt.p99' $RESULTS_DIR/${TS}_04_*.json"
}

# =============================================================================
# ── QUICK REFERENCE COMMANDS ──────────────────────────────────────────────────
# These are standalone one-liners for copy-paste into a terminal.
# They mirror the scenarios above but with no wrapper infrastructure.
# =============================================================================
print_quick_reference() {
cat << 'QUICKREF'
# =============================================================================
# TWAMPY QUICK REFERENCE — HFT ONE-LINERS
# Replace 10.0.0.2 with your responder IP
# =============================================================================

# Start responder (run on remote host, pin to a dedicated core):
taskset -c 3 twampy responder

# ── Baseline ──────────────────────────────────────────────────────────────────
twampy sender --count 600   --interval 100   --padding 0    --tos 0   --ttl 64 --do-not-fragment 10.0.0.2

# ── Order Entry  EF 2K pps ────────────────────────────────────────────────────
twampy sender --count 6000   --interval 1     --padding 100  --tos 184 --ttl 64 --do-not-fragment 10.0.0.2

# ── Market Data  AF41 10K pps ─────────────────────────────────────────────────
twampy sender --count 60000  --interval 0.1   --padding 164  --tos 136 --ttl 64 --do-not-fragment 10.0.0.2

# ── Market Open Burst  100K pps ───────────────────────────────────────────────
twampy sender --count 500000 --interval 0.01  --padding 44   --tos 136 --ttl 64 --do-not-fragment 10.0.0.2

# ── FIX Heartbeat  CS6 1pps 5min ──────────────────────────────────────────────
twampy sender --count 300    --interval 1000  --padding 0    --tos 192 --ttl 64 --do-not-fragment 10.0.0.2

# ── Options Chain Large Packets  5K pps ───────────────────────────────────────
twampy sender --count 30000  --interval 0.2   --padding 1344 --tos 136 --ttl 64 --do-not-fragment 10.0.0.2

# ── Jumbo Frame Validation  9KB  1K pps ───────────────────────────────────────
twampy sender --count 5000   --interval 1     --padding 8900 --tos 136 --ttl 64 --do-not-fragment 10.0.0.2

# ── Jitter Probe  7ms prime interval ─────────────────────────────────────────
twampy sender --count 10000  --interval 7     --padding 0    --tos 184 --ttl 64 --do-not-fragment 10.0.0.2

# ── Buffer Bloat Stress  50K pps 5min ─────────────────────────────────────────
twampy sender --count 15000000 --interval 0.02 --padding 244 --tos 136 --ttl 64 --do-not-fragment 10.0.0.2

# ── Packet Loss Analysis  1M packets ─────────────────────────────────────────
twampy sender --count 1000000 --interval 0.02 --padding 0   --tos 136 --ttl 64 --do-not-fragment 10.0.0.2

# ── QoS test: run BOTH simultaneously ─────────────────────────────────────────
# Terminal 1 (background CS0 flood):
twampy sender --count 999999 --interval 0.05 --padding 1200 --tos 0 10.0.0.2 &
# Terminal 2 (EF probe — RTT should not increase from baseline):
twampy sender --count 3000   --interval 10   --padding 0    --tos 184 10.0.0.2

# ── IPv6 comparison ───────────────────────────────────────────────────────────
twampy sender --ipv6 --count 1000 --interval 10 --padding 0 --tos 184 ::1

# ── Overnight SLA monitor ─────────────────────────────────────────────────────
twampy sender --count 28800 --interval 1000 --padding 0 --tos 184 --output json 10.0.0.2 | tee overnight.json

# ── JSON output + parse p99 with jq ───────────────────────────────────────────
twampy sender --count 1000 --interval 1 --output json 10.0.0.2
  | jq '{min: .rtt.min, avg: .rtt.avg, p99: .rtt.p99, max: .rtt.max, loss: .loss_pct}'

QUICKREF
}

# =============================================================================
# ── ENTRYPOINT ────────────────────────────────────────────────────────────────
# =============================================================================
case "${1:-help}" in
    all)                          run_all ;;
    baseline)                     scenario_baseline ;;
    order_entry)                  scenario_order_entry ;;
    market_data_primary)          scenario_market_data_primary ;;
    market_data_secondary)        scenario_market_data_secondary ;;
    market_open_burst)            scenario_market_open_burst ;;
    fix_heartbeat)                scenario_fix_heartbeat ;;
    options_chain)                scenario_options_chain_refresh ;;
    jumbo)                        scenario_jumbo_frame_validation ;;
    cross_venue)                  scenario_cross_venue_latency ;;
    buffer_bloat)                 scenario_buffer_bloat_stress ;;
    jitter)                       scenario_jitter_isolation ;;
    qos_ef)                       scenario_qos_priority_validation_ef ;;
    qos_flood)                    scenario_qos_background_flood ;;
    loss)                         scenario_packet_loss_analysis ;;
    ttl_sweep)                    scenario_asymmetric_path_ttl_sweep ;;
    eod)                          scenario_eod_session_shutdown ;;
    ipv6)                         scenario_ipv6_comparison ;;
    overnight)                    scenario_overnight_monitoring ;;
    quickref)                     print_quick_reference ;;
    help|*)
        echo ""
        echo "Usage: RESPONDER_IP=10.0.0.2 $0 <scenario>"
        echo ""
        echo "Scenarios:"
        echo "  all                   Run full characterization suite"
        echo "  baseline              Clean RTT baseline (reference floor)"
        echo "  order_entry           Order entry: EF, 100B, 2K pps"
        echo "  market_data_primary   Primary feed: AF41, 220B, 10K pps"
        echo "  market_data_secondary Secondary feed: AF31, 220B, 10K pps"
        echo "  market_open_burst     Opening bell: AF41, 100B, 100K pps burst"
        echo "  fix_heartbeat         FIX keepalive: CS6, 64B, 1 pps, 5 min"
        echo "  options_chain         Options snapshot: 1400B, 5K pps"
        echo "  jumbo                 Jumbo frame validation: 9KB, 1K pps"
        echo "  cross_venue           Cross-venue latency window: EF, 100 pps, 10 min"
        echo "  buffer_bloat          Bloat stress: 300B, 50K pps, 5 min"
        echo "  jitter                Jitter isolation: 64B, 7ms prime, 10K samples"
        echo "  qos_ef                QoS EF probe (run alongside qos_flood)"
        echo "  qos_flood             QoS CS0 background flood"
        echo "  loss                  Packet loss analysis: 1M packets at 50K pps"
        echo "  ttl_sweep             TTL hop-by-hop latency fingerprint"
        echo "  eod                   EOD burst→silence→recovery (adaptive coalescing test)"
        echo "  ipv6                  IPv4 vs IPv6 RTT comparison"
        echo "  overnight             8-hour SLA watchdog (28.8K probes)"
        echo "  quickref              Print standalone one-liner commands"
        echo ""
        echo "Environment variables:"
        echo "  RESPONDER_IP    Responder host IP    (default: 10.0.0.2)"
        echo "  RESPONDER_PORT  TWAMP-Light port     (default: 862)"
        echo "  LOCAL_IFACE     Outbound interface   (default: eth0)"
        echo "  RESULTS_DIR     Output directory     (default: ./twampy-results)"
        echo "  CPU_PIN         Pin sender to core N (default: unset)"
        echo "  LOG_FORMAT      text | json | csv    (default: json)"
        echo ""
        ;;
esac
