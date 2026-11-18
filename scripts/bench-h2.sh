#!/usr/bin/env bash
# =============================================================================
#  bench-h2.sh   (Linux / Delphi-Linux64 or FPC builds)
#  The ONE load generator for both protocols -- h2load speaks HTTP/1.1 (--h1)
#  and h2/h2c, so the client is held constant and only the server protocol
#  varies. See plans/bench-plan-all-providers.md.
#
#    nghttp2        -> HTTP/2 cleartext (h2c), driven natively   (port 9041)
#    CrossSocket/mORMot -> HTTP/1.1, driven with --h1            (9002 / 9003)
#
#  Indy and ICS are Windows-only -- use scripts/bench-h2.bat for those.
#
#  Three scenarios (all from the plan):
#    S1  Floor        -c 10 -m 1     one request in flight per connection.
#                                    HTTP/2 is EXPECTED to lose here; that is
#                                    protocol cost, not a defect.
#    S3  Conn scale   -c 10,100,1000,10000 (h1) / same -m 1 (h2)
#                                    Phase P3. Sweeps the connection count and
#                                    records req/s + PEAK server RSS per level.
#                                    The axis where each concurrency model
#                                    breaks: thread-per-conn (FPC-HTTP, Indy on
#                                    Windows) falls over first, nghttp2
#                                    thread-per-conn second. Quote the RSS
#                                    SLOPE across the sweep, not the absolute --
#                                    the baseline cancels, the per-connection
#                                    cost is the gradient. A row with failed/
#                                    errored > 0, or h2load rc=124 (timed out),
#                                    is a FAILURE MODE, not a throughput.
#    S4  Multiplexing h2: -c 10 -m 100 (1000 in flight over 10 sockets)
#                     h1: -c 1000      (1000 in flight over 1000 sockets)
#                                    Same 1000 in flight, different transport
#                                    shapes. The scenario HTTP/2 exists for.
#    S5  Blocking     /slow/<ms>, 100 in flight. Phase P4. The route sleeps
#                                    <ms> then responds, so throughput reads off
#                                    each provider's effective concurrency
#                                    (handler slots / block time): thread-per-conn
#                                    ~= c, a bounded pool ~= pool size, a single
#                                    inline event loop ~= 1 (serialises -> rc=124).
#                                    NEEDS the /slow/:ms route (BenchRoutes.pas) --
#                                    rebuild the bench servers, or cells 404.
#    S6  Mixed 90/10  /mixed, 100 in flight. Phase P4. Realistic load: ~90% fast
#                                    like /ping, ~1-in-10 blocks like /slow, the
#                                    split made server-side so h2load hits one URL.
#                                    Shows whether a slow handler stalls the fast
#                                    ones behind it. NEEDS the /mixed route --
#                                    rebuild the bench servers, or cells 404.
#
#  Never collapse to a single winner -- report a winner PER workload class.
#
#  Usage:  bench-h2.sh [n] [scenario]
#            n         requests per cell   (default 200000; for S3 prefer a
#                      large n so high-c cells aren't dominated by conn setup.
#                      S5/S6 ignore n -- they use SLOW_N / MIXED_N, see below)
#            scenario  s1 | s3 | s4 | s5 | s6 | all  (default all = s1+s4; s3,
#                      s5, s6 are opt-in: s3 is long / opens 10000 sockets,
#                      s5 blocks, s6 is the realistic mix)
#
#  S3 knobs:  S3_CONNS="10 100 1000 10000"  CELL_TIMEOUT_S3=180
#  S5 knobs:  SLOW_MS=50  SLOW_N=10000  CELL_TIMEOUT_S5=90
#  S6 knobs:  MIXED_N=50000  CELL_TIMEOUT_S6=90  (the 90/10 split + 50 ms are
#             baked into the /mixed route in BenchRoutes.pas)
#
#  Prereqs: Release builds of the servers beside this script or under
#           ../samples/bench/Linux64/Release; h2load on PATH; libnghttp2.so.14
#           (apt install libnghttp2-14). Pin nghttp2 dispatch for a published
#           run: WORKERS=N ./bench-h2.sh
# =============================================================================
set -u

# S4 opens 1000 connections to the HTTP/1.1 servers — raise the fd limit (best effort).
ulimit -n 100000 2>/dev/null || true

H2LOAD="${H2LOAD:-h2load}"
BASE_URL="http://127.0.0.1"
ROUTE="/ping"
REQUESTS="${1:-200000}"
SCENARIO="${2:-all}"
WORKERS="${WORKERS:-0}"
HERE="$(cd "$(dirname "$0")" && pwd)"

NGHTTP2_ARGS=""
[ "$WORKERS" -gt 0 ] 2>/dev/null && NGHTTP2_ARGS="--workers=${WORKERS}"

# Locate the servers directory (same probing shape as the other bench scripts).
SERVERS_DIR=""
for d in "$HERE" "$HERE/../samples/bench/bin" "$HERE/../samples/bench/Linux64/Release" "$HERE/../Linux64/Release"; do
  if [ -x "$d/HorseBenchNghttp2" ]; then SERVERS_DIR="$d"; break; fi
done
if [ -z "$SERVERS_DIR" ]; then
  echo "ERROR: HorseBenchNghttp2 not found near this script. Build the Linux bench servers first." >&2
  exit 1
fi
if ! command -v "$H2LOAD" >/dev/null 2>&1 && [ ! -x "$H2LOAD" ]; then
  echo "ERROR: h2load not found ($H2LOAD). h2load ships with nghttp2." >&2
  exit 1
fi

RESULTS="$HERE/bench-h2-result.txt"
TMP_OUT="$(mktemp)"
trap 'rm -f "$TMP_OUT"; pkill -f "HorseBench" >/dev/null 2>&1 || true' EXIT
{
  echo "Horse HTTP/2-vs-HTTP/1.1 bench (h2load)   n=$REQUESTS  scenario=$SCENARIO"
  echo "Generated $(date)"
  echo "nghttp2 speaks HTTP/2 (h2c); others HTTP/1.1 (--h1). NOT a single ranking."
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

wait_for_port_gone() {  # $1 = port ; bounded so a collapsed teardown can't hang us
  local port="$1" tries=0
  while [ "$tries" -lt 15 ]; do
    ss -ltn 2>/dev/null | grep -q ":${port} " || return 0
    sleep 1
    tries=$((tries + 1))
  done
  return 1
}

cell() {  # $1 exe  $2 port  $3 h1|h2  $4 server-args  $5 h2load-conn-args  $6 label
  local exe="$1" port="$2" proto="$3" srvargs="$4" loadargs="$5" label="$6"
  pkill -f "HorseBench" >/dev/null 2>&1 || true
  sleep 1
  if [ ! -x "$SERVERS_DIR/$exe" ]; then
    echo "  [ERR] $label ($proto) binary not found: $SERVERS_DIR/$exe"
    echo "[ERR] $label ($proto) binary not found" >> "$RESULTS"
    return
  fi
  # shellcheck disable=SC2086
  "$SERVERS_DIR/$exe" $srvargs >/dev/null 2>&1 &
  local srv_pid=$!
  if ! wait_for_port "$port"; then
    echo "  [ERR] $label ($proto) port $port never came up"
    echo "[ERR] $label ($proto) port $port never came up" >> "$RESULTS"
    return
  fi
  local h1=""
  [ "$proto" = "h1" ] && h1="--h1"
  echo ""
  echo "  -- $label  proto=$proto  port $port  ($loadargs -n $REQUESTS) --"
  {
    echo ""
    echo "-- $label  proto=$proto  port $port  $h1 $loadargs -n $REQUESTS --"
  } >> "$RESULTS"
  # CELL_TIMEOUT (seconds) bounds a cell so a provider that collapses at scale
  # (e.g. FPC-HTTP thread-per-conn at c>=1000) can't hang the whole sweep; a
  # resulting rc=124 is the failure mode, recorded like a nonzero failed count.
  local tmo=""
  [ -n "${CELL_TIMEOUT:-}" ] && tmo="timeout -k 5 ${CELL_TIMEOUT}"
  local rc=0
  if [ "${CAPTURE_RSS:-0}" = "1" ]; then
    # Background h2load and poll the server's VmRSS WHILE under load, keeping the
    # peak. One process, all its I/O threads share the address space, so the main
    # PID's VmRSS is process-wide. Quote the SLOPE across the sweep (perf-measurement
    # rule 1): absolute RSS carries a fixed baseline; per-connection cost is the gradient.
    # shellcheck disable=SC2086
    $tmo "$H2LOAD" $h1 $loadargs -n "$REQUESTS" "${BASE_URL}:${port}${ROUTE}" > "$TMP_OUT" 2>&1 &
    local lpid=$! peak=0 cur
    while kill -0 "$lpid" 2>/dev/null; do
      cur=$(awk '/^VmRSS:/{print $2}' "/proc/$srv_pid/status" 2>/dev/null)
      if [ -n "$cur" ] && [ "$cur" -gt "$peak" ] 2>/dev/null; then peak="$cur"; fi
      sleep 0.2
    done
    wait "$lpid"; rc=$?
    local peak_mb=$(( peak / 1024 ))
    echo "      RSS peak ${peak_mb} MB   h2load rc=$rc$([ "$rc" = 124 ] && echo '  [TIMED OUT]')"
    echo "RSS peak under load: ${peak_mb} MB (${peak} kB)   h2load rc=$rc" >> "$RESULTS"
  else
    # shellcheck disable=SC2086
    $tmo "$H2LOAD" $h1 $loadargs -n "$REQUESTS" "${BASE_URL}:${port}${ROUTE}" > "$TMP_OUT" 2>&1
    rc=$?
  fi
  grep -E "finished in|^requests:|status codes:|time for request" "$TMP_OUT" | sed 's/^/      /'
  [ "$rc" = 124 ] && echo "      [ERR] $label ($proto) TIMED OUT after ${CELL_TIMEOUT}s at $loadargs -- failed to drain"
  cat "$TMP_OUT" >> "$RESULTS"
  pkill -f "$exe" >/dev/null 2>&1 || true
  # Let the port close before the next cell starts: a second SIGTERM arriving
  # during teardown is what cored CrossSocket at S4 (now guarded, but still wait).
  wait_for_port_gone "$port" || echo "      [warn] $label port $port still open after teardown wait"
}

run_s1() {
  echo ""; echo "-- S1 Floor  (-c 10 -m 1) --"
  echo ""; echo "== S1 Floor  -c 10 -m 1  n=$REQUESTS ==" >> "$RESULTS"
  cell HorseBenchCrossSocket 9002 h1 ""              "-c 10"        "CrossSocket"
  cell HorseBenchMormot      9003 h1 ""              "-c 10"        "mORMot"
  cell HorseBenchFPCHttp     9007 h1 ""              "-c 10"        "FPC-HTTP"
  cell HorseBenchEpoll       9043 h1 ""              "-c 10"        "Epoll"
  cell HorseBenchNghttp2     9041 h2 "$NGHTTP2_ARGS" "-c 10 -m 1"   "nghttp2"
}
run_s4() {
  echo ""; echo "-- S4 Multiplexing  (1000 in flight: h2 10x100, h1 1000x1) --"
  echo ""; echo "== S4 Multiplexing  1000 in flight  n=$REQUESTS ==" >> "$RESULTS"
  # h1 providers: 1000 connections.  nghttp2 (h2): 10 connections x 100 streams =
  # the SAME 1000 requests in flight — the scenario HTTP/2 exists for.
  #
  # mORMot gets TWO cells on the same port 9003 (sequential — cell() runs one
  # server at a time): its DEFAULT mskThreadPool backend (one thread per concurrent
  # request) overflows the listen backlog and fails ~48% at c=1000, while --async
  # (THttpAsyncServer, epoll event loop) carries all 1000 cleanly. Keeping both
  # makes the backend difference a SAME-BATCH comparison and lets mORMot-async be
  # ranked against nghttp2 with no cross-run caveat. See the S4 section of
  # docs/provider-perf-ladder.html.
  cell HorseBenchCrossSocket 9002 h1 ""              "-c 1000"      "CrossSocket"
  cell HorseBenchMormot      9003 h1 ""              "-c 1000"      "mORMot (threadpool/default)"
  cell HorseBenchMormot      9003 h1 "--async"       "-c 1000"      "mORMot-async"
  cell HorseBenchFPCHttp     9007 h1 ""              "-c 1000"      "FPC-HTTP"
  cell HorseBenchEpoll       9043 h1 ""              "-c 1000"      "Epoll"
  cell HorseBenchNghttp2     9041 h2 "$NGHTTP2_ARGS" "-c 10 -m 100" "nghttp2"
}
run_s5() {
  # Phase P4 -- blocking-handler probe. Route /slow/<ms> sleeps <ms> then responds,
  # 100 requests in flight. This is the ONLY scenario that shows what a dispatch pool
  # buys: throughput here is (concurrent handler slots) / (block time), so it reads off
  # each provider's effective concurrency -- thread-per-conn (FPC-HTTP) ~= c slots,
  # a bounded pool ~= pool size, a single inline event loop ~= 1 slot (serialises).
  # h1 at -c 100; nghttp2 at -c 10 -m 10 (100 in flight over 10 conns) so a blocking
  # stream must not stall the other 9 on its connection -- the pool's whole job.
  # SLOW_N is small (blocking is slow) and CELL_TIMEOUT bounds a serialising provider:
  # rc=124 there is the finding (it ran the handler inline), not a throughput.
  local ms="${SLOW_MS:-50}" saved_route="$ROUTE" saved_req="$REQUESTS"
  ROUTE="/slow/${ms}"
  REQUESTS="${SLOW_N:-10000}"
  CELL_TIMEOUT="${CELL_TIMEOUT_S5:-90}"
  echo ""; echo "-- S5 Blocking handler  (/slow/${ms}, -c 100, n=$REQUESTS) --"
  echo ""; echo "== S5 Blocking handler  /slow/${ms}  -c 100  n=$REQUESTS ==" >> "$RESULTS"
  cell HorseBenchCrossSocket 9002 h1 ""              "-c 100"       "CrossSocket /slow/${ms}"
  cell HorseBenchMormot      9003 h1 ""              "-c 100"       "mORMot (threadpool/default)"
  cell HorseBenchMormot      9003 h1 "--async"       "-c 100"       "mORMot-async"
  cell HorseBenchFPCHttp     9007 h1 ""              "-c 100"       "FPC-HTTP"
  cell HorseBenchEpoll       9043 h1 ""              "-c 100"       "Epoll"
  cell HorseBenchNghttp2     9041 h2 "$NGHTTP2_ARGS" "-c 10 -m 10"  "nghttp2"
  ROUTE="$saved_route"; REQUESTS="$saved_req"; CELL_TIMEOUT=""
}
run_s6() {
  # Phase P4 -- realistic mix. Route /mixed answers ~90% of requests immediately
  # (like /ping) and blocks ~1-in-10 (like /slow); the 90/10 split is made SERVER-SIDE
  # by an atomic counter, so h2load drives one URL. 100 in flight. This is S5's question
  # on a realistic load: does one slow handler stall the fast requests queued behind it
  # (inline event loop) or not (pool / thread-per-conn)? A cell that times out (rc=124)
  # is a provider whose slow slice blocked its dispatch path, not a throughput.
  local saved_route="$ROUTE" saved_req="$REQUESTS"
  ROUTE="/mixed"
  REQUESTS="${MIXED_N:-50000}"
  CELL_TIMEOUT="${CELL_TIMEOUT_S6:-90}"
  echo ""; echo "-- S6 Mixed 90/10  (/mixed, -c 100, n=$REQUESTS) --"
  echo ""; echo "== S6 Mixed 90/10  /mixed  -c 100  n=$REQUESTS ==" >> "$RESULTS"
  cell HorseBenchCrossSocket 9002 h1 ""              "-c 100"       "CrossSocket /mixed"
  cell HorseBenchMormot      9003 h1 ""              "-c 100"       "mORMot (threadpool/default)"
  cell HorseBenchMormot      9003 h1 "--async"       "-c 100"       "mORMot-async"
  cell HorseBenchFPCHttp     9007 h1 ""              "-c 100"       "FPC-HTTP"
  cell HorseBenchEpoll       9043 h1 ""              "-c 100"       "Epoll"
  cell HorseBenchNghttp2     9041 h2 "$NGHTTP2_ARGS" "-c 10 -m 10"  "nghttp2"
  ROUTE="$saved_route"; REQUESTS="$saved_req"; CELL_TIMEOUT=""
}
run_s3() {
  # Phase P3 -- connection-scale sweep. For each connection level, every provider
  # gets one cell; CAPTURE_RSS=1 records peak server RSS under load, CELL_TIMEOUT
  # bounds a collapsed provider. h1 providers open N real sockets (-m 1 implied);
  # nghttp2 (h2) opens N connections at one stream each (-m 1) so it is COMPARABLE
  # on connection scaling -- multiplexing is S4's job, not this one.
  local conns="${S3_CONNS:-10 100 1000 10000}"
  CAPTURE_RSS=1
  CELL_TIMEOUT="${CELL_TIMEOUT_S3:-180}"
  echo ""; echo "-- S3 Connection scale  (sweep c=$conns; peak RSS per level) --"
  echo ""; echo "== S3 Connection scale  c in [$conns]  n=$REQUESTS ==" >> "$RESULTS"
  local c
  for c in $conns; do
    echo ""; echo "  === connection level c=$c ==="
    echo ""; echo "--- c=$c ---" >> "$RESULTS"
    cell HorseBenchCrossSocket 9002 h1 ""              "-c $c"        "CrossSocket c=$c"
    cell HorseBenchMormot      9003 h1 ""              "-c $c"        "mORMot c=$c (threadpool/default)"
    cell HorseBenchMormot      9003 h1 "--async"       "-c $c"        "mORMot-async c=$c"
    cell HorseBenchFPCHttp     9007 h1 ""              "-c $c"        "FPC-HTTP c=$c"
    cell HorseBenchEpoll       9043 h1 ""              "-c $c"        "Epoll c=$c"
    cell HorseBenchNghttp2     9041 h2 "$NGHTTP2_ARGS" "-c $c -m 1"   "nghttp2 c=$c"
  done
  CAPTURE_RSS=0
  CELL_TIMEOUT=""
}

echo ""
echo "================================================================================"
echo " bench-h2   n=$REQUESTS   scenario=$SCENARIO"
echo " h2load drives everything; nghttp2=h2c, others=--h1. One server at a time."
echo "================================================================================"

case "$SCENARIO" in
  s1|S1) run_s1 ;;
  s3|S3) run_s3 ;;
  s4|S4) run_s4 ;;
  s5|S5) run_s5 ;;
  s6|S6) run_s6 ;;
  all|ALL) run_s1; run_s4 ;;
  *) echo "ERROR: scenario must be s1, s3, s4, s5, s6, or all." >&2; exit 1 ;;
esac

echo ""
echo "Done. Full h2load output per cell saved to: $RESULTS"
echo "Read it PER SCENARIO: nghttp2 is HTTP/2, the rest HTTP/1.1. S1 favours HTTP/1.1"
echo "by construction; S4 is where multiplexing is allowed to pay."
