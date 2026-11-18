#!/usr/bin/env bash
# =============================================================================
#  bench-tail.sh   (Linux / FPC builds)   -- bench scenario S7, phase P4.
#
#  TRUE TAIL LATENCY under OPEN-LOOP load. The other scenarios (bench-h2.sh)
#  use h2load, which is CLOSED-LOOP: it waits for each response before sending
#  the next request, so a stall lowers the offered rate instead of showing in
#  the histogram -- it UNDERSTATES the tail (coordinated omission). S7 offers
#  load at a FIXED request rate regardless of how the server responds, so a
#  stall lands in the latency distribution where it belongs.
#
#  h2load CANNOT do this: its --rate paces CONNECTION creation, not request
#  submission, and -r/-D are mutually exclusive. So S7 uses **vegeta**, which
#  is a constant-rate, keep-alive, coordinated-omission-correcting generator:
#      https://github.com/tsenart/vegeta   (single static Go binary)
#  Install on the bench box (no Go needed):
#      V=12.12.0; curl -sSL \
#        https://github.com/tsenart/vegeta/releases/download/v$V/vegeta_${V}_linux_amd64.tar.gz \
#        | tar xz vegeta && sudo mv vegeta /usr/local/bin/ && vegeta -version
#
#  vegeta speaks HTTP/1.1 only (no h2c), so:
#    - CrossSocket / mORMot / FPC-HTTP / Epoll  -> vegeta, OPEN-LOOP (the real S7)
#    - nghttp2 (h2c)                            -> h2load, CLOSED-LOOP best effort,
#                                                  LABELLED coordinated-omission-prone,
#                                                  NOT comparable to the vegeta rows.
#
#  Rate per cell -- CALIBRATION LESSON (2026-11-05): the first run used 80% of each
#  provider's *closed-loop* S2, but closed-loop S2 is coordinated-omission-INFLATED, so
#  for the event-driven / thread-per-conn providers that rate was far past their real
#  OPEN-LOOP capacity and they collapsed (achieved << offered, multi-second tails). A
#  tail test is only meaningful BELOW sustainable capacity. Rates are now set from the
#  first run's *demonstrated* open-loop behaviour, not closed-loop S2:
#    CrossSocket 45000 (held 100%) · mORMot-threadpool 70000 (held) · mORMot-async 40000
#    (collapsed at 170k) · FPC-HTTP 20000 (collapsed at 60k) · Epoll 30000 (collapsed at 75k)
#    · nghttp2 40000.
#  If a cell still shows achieved << offered or success < ~99%, LOWER its rate -- that is
#  over capacity, not a tail. Override all cells with RATE=<n> for a common head-to-head,
#  and MAX_CONNS=<n> to change the connection cap (default 512).
#
#  Usage:  bench-tail.sh
#  Env:    RATE=<reqs/s>   force one rate for every cell (default: per-provider 80%)
#          DURATION=<Ns>   attack duration per cell (default 10s)
#          WORKERS=<n>     pin the nghttp2 server pool (as in bench-h2.sh)
#          VEGETA=<path>   vegeta binary (default: vegeta on PATH)
#          H2LOAD=<path>   h2load binary (default: h2load on PATH)
#
#  Prereqs: Release/FPC builds of the bench servers beside this script or under
#           ../samples/bench/bin; vegeta + h2load on PATH; libnghttp2.so.14.
#  Read the result PER GENERATOR: the vegeta P99/Max are coordinated-omission-
#  corrected; the nghttp2 h2load P99 is not.
# =============================================================================
set -u

# High request rates on loopback churn ephemeral ports; raise the fd limit.
ulimit -n 100000 2>/dev/null || true

VEGETA="${VEGETA:-vegeta}"
H2LOAD="${H2LOAD:-h2load}"
BASE_URL="http://127.0.0.1"
ROUTE="/ping"
DURATION="${DURATION:-10s}"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORKERS="${WORKERS:-0}"

NGHTTP2_ARGS=""
[ "$WORKERS" -gt 0 ] 2>/dev/null && NGHTTP2_ARGS="--workers=${WORKERS}"

# Locate the servers directory (same probe order as bench-h2.sh).
SERVERS_DIR=""
for d in "$HERE" "$HERE/../samples/bench/bin" "$HERE/../samples/bench/Linux64/Release" "$HERE/../Linux64/Release"; do
  if [ -x "$d/HorseBenchCrossSocket" ]; then SERVERS_DIR="$d"; break; fi
done
if [ -z "$SERVERS_DIR" ]; then
  echo "ERROR: HorseBench servers not found near this script. Build the Linux bench servers first." >&2
  exit 1
fi
if ! command -v "$VEGETA" >/dev/null 2>&1 && [ ! -x "$VEGETA" ]; then
  echo "ERROR: vegeta not found ($VEGETA). Install it -- see the header of this script." >&2
  exit 1
fi
if ! command -v "$H2LOAD" >/dev/null 2>&1 && [ ! -x "$H2LOAD" ]; then
  echo "ERROR: h2load not found ($H2LOAD) -- needed for the nghttp2 cell." >&2
  exit 1
fi

RESULTS="$HERE/bench-tail-result.txt"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; pkill -f "HorseBench" >/dev/null 2>&1 || true' EXIT
{
  echo "Horse S7 tail latency   duration=$DURATION   $(date)"
  echo "OPEN-LOOP via vegeta (coordinated-omission-corrected) for HTTP/1.1;"
  echo "nghttp2 is h2c CLOSED-LOOP via h2load (vegeta has no h2c) -- its tail is NOT comparable."
} > "$RESULTS"

wait_for_port() {  # $1 = port
  local port="$1" tries=0
  while [ "$tries" -lt 10 ]; do
    sleep 1
    if ss -ltn 2>/dev/null | grep -q ":${port} "; then return 0; fi
    tries=$((tries + 1))
  done
  return 1
}
wait_for_port_gone() {  # $1 = port ; bounded
  local port="$1" tries=0
  while [ "$tries" -lt 15 ]; do
    ss -ltn 2>/dev/null | grep -q ":${port} " || return 0
    sleep 1
    tries=$((tries + 1))
  done
  return 1
}

tail_cell() {  # $1 exe  $2 port  $3 h1|h2  $4 server-args  $5 rate  $6 label
  local exe="$1" port="$2" proto="$3" srvargs="$4" rate="$5" label="$6"
  pkill -f "HorseBench" >/dev/null 2>&1 || true
  sleep 1
  if [ ! -x "$SERVERS_DIR/$exe" ]; then
    echo "  [ERR] $label binary not found: $SERVERS_DIR/$exe"
    echo "[ERR] $label binary not found" >> "$RESULTS"
    return
  fi
  # shellcheck disable=SC2086
  "$SERVERS_DIR/$exe" $srvargs >/dev/null 2>&1 &
  if ! wait_for_port "$port"; then
    echo "  [ERR] $label port $port never came up"
    echo "[ERR] $label port $port never came up" >> "$RESULTS"
    return
  fi
  echo ""
  echo "  -- $label  proto=$proto  port $port  rate=${rate}/s  dur=$DURATION --"
  { echo ""; echo "-- $label  proto=$proto  port $port  rate=${rate}/s  dur=$DURATION --"; } >> "$RESULTS"
  if [ "$proto" = "h1" ]; then
    # OPEN-LOOP: vegeta offers exactly $rate req/s on the clock, keep-alive on,
    # and records the full wait of a stalled request (coordinated-omission-corrected).
    # -max-connections caps the connection pool so a server that falls behind makes
    # vegeta MISS the rate (achieved < offered, visible and honest) instead of opening
    # unbounded connections and turning the tail test into an S3 connection-scale collapse.
    # (vegeta >= 12.8.4; the v12.12.0 in the header has it.) MAX_CONNS overrides.
    echo "GET ${BASE_URL}:${port}${ROUTE}" \
      | "$VEGETA" attack -rate="$rate" -duration="$DURATION" -keepalive \
          -max-connections="${MAX_CONNS:-512}" > "$TMP/r.bin" 2>>"$RESULTS"
    "$VEGETA" report "$TMP/r.bin" > "$TMP/r.txt" 2>&1
    grep -E "Requests|Latencies|Success|Status|Error" "$TMP/r.txt" | sed 's/^/      /'
    cat "$TMP/r.txt" >> "$RESULTS"
    # Keep the raw results so P99.9 can be pulled later:
    #   vegeta report -type=json  (or -type=hdrplot for all percentiles)
    cp "$TMP/r.bin" "$HERE/bench-tail-${label//[^A-Za-z0-9._-]/_}.bin" 2>/dev/null || true
  else
    # nghttp2 h2c: vegeta cannot drive it. h2load CLOSED-LOOP at c=100, sized to a
    # comparable sample count. Its P99/Max UNDERSTATE the tail (coordinated omission)
    # -- reported for completeness, NOT as a peer of the vegeta rows.
    local secs="${DURATION%s}" n
    n=$(( rate * secs ))
    [ "$n" -lt 50000 ] && n=50000
    # NOTE: $NGHTTP2_ARGS (--workers=N) is a SERVER arg (passed via srvargs above); it must
    # NOT go to h2load, whose own thread flag is -t (h2load rejects --workers -> empty result).
    "$H2LOAD" -c 100 -n "$n" "${BASE_URL}:${port}${ROUTE}" > "$TMP/h.txt" 2>&1
    if grep -qE "finished in" "$TMP/h.txt"; then
      grep -E "finished in|^requests:|status codes:|time for request" "$TMP/h.txt" | sed 's/^/      /'
    else
      echo "      [ERR] h2load produced no result for nghttp2 (n=$n) -- last lines:"
      tail -6 "$TMP/h.txt" | sed 's/^/        /'
    fi
    echo "      [NOTE] nghttp2 = CLOSED-LOOP (vegeta has no h2c); tail is coordinated-omission-prone, NOT comparable to the vegeta rows."
    { echo "[NOTE] nghttp2 closed-loop (h2load); tail coordinated-omission-prone, not comparable."; cat "$TMP/h.txt"; } >> "$RESULTS"
  fi
  pkill -f "$exe" >/dev/null 2>&1 || true
  wait_for_port_gone "$port" || echo "      [warn] $label port $port still open after teardown wait"
}

echo ""
echo "================================================================================"
echo " bench-tail (S7)   open-loop tail latency   dur=$DURATION"
echo " vegeta drives HTTP/1.1 (coordinated-omission-corrected); nghttp2 h2c via h2load."
echo "================================================================================"
echo "" >> "$RESULTS"; echo "== S7 Tail latency  dur=$DURATION ==" >> "$RESULTS"

# Rate defaults = ~80% of each provider's S2 (c=100 /ping), 2026-11-05 Linux ladder.
# RATE=<n> overrides every cell with one common rate.
tail_cell HorseBenchCrossSocket 9002 h1 ""              "${RATE:-45000}" "CrossSocket"
tail_cell HorseBenchMormot      9003 h1 ""              "${RATE:-70000}" "mORMot-threadpool"
tail_cell HorseBenchMormot      9003 h1 "--async"       "${RATE:-40000}" "mORMot-async"
tail_cell HorseBenchFPCHttp     9007 h1 ""              "${RATE:-20000}" "FPC-HTTP"
tail_cell HorseBenchEpoll       9043 h1 ""              "${RATE:-30000}" "Epoll"
tail_cell HorseBenchNghttp2     9041 h2 "$NGHTTP2_ARGS" "${RATE:-40000}" "nghttp2"

echo ""
echo "Done. Full output per cell saved to: $RESULTS"
echo "Read PER GENERATOR: vegeta P99/Max are coordinated-omission-corrected; the nghttp2"
echo "h2load row is closed-loop and understates its tail. Raw vegeta results saved as"
echo "bench-tail-<provider>.bin -- 'vegeta report -type=hdrplot <bin>' gives P99.9 and beyond."
