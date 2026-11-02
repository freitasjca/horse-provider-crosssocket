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
#  Two scenarios (both from the plan):
#    S1  Floor        -c 10 -m 1     one request in flight per connection.
#                                    HTTP/2 is EXPECTED to lose here; that is
#                                    protocol cost, not a defect.
#    S4  Multiplexing h2: -c 10 -m 100 (1000 in flight over 10 sockets)
#                     h1: -c 1000      (1000 in flight over 1000 sockets)
#                                    Same 1000 in flight, different transport
#                                    shapes. The scenario HTTP/2 exists for.
#
#  Never collapse to a single winner -- report a winner PER workload class.
#
#  Usage:  bench-h2.sh [n] [scenario]
#            n         requests per cell   (default 200000)
#            scenario  s1 | s4 | all       (default all)
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
  # shellcheck disable=SC2086
  "$H2LOAD" $h1 $loadargs -n "$REQUESTS" "${BASE_URL}:${port}${ROUTE}" > "$TMP_OUT" 2>&1
  grep -E "finished in|^requests:|status codes:|time for request" "$TMP_OUT" | sed 's/^/      /'
  cat "$TMP_OUT" >> "$RESULTS"
  pkill -f "$exe" >/dev/null 2>&1 || true
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

echo ""
echo "================================================================================"
echo " bench-h2   n=$REQUESTS   scenario=$SCENARIO"
echo " h2load drives everything; nghttp2=h2c, others=--h1. One server at a time."
echo "================================================================================"

case "$SCENARIO" in
  s1|S1) run_s1 ;;
  s4|S4) run_s4 ;;
  all|ALL) run_s1; run_s4 ;;
  *) echo "ERROR: scenario must be s1, s4, or all." >&2; exit 1 ;;
esac

echo ""
echo "Done. Full h2load output per cell saved to: $RESULTS"
echo "Read it PER SCENARIO: nghttp2 is HTTP/2, the rest HTTP/1.1. S1 favours HTTP/1.1"
echo "by construction; S4 is where multiplexing is allowed to pay."
