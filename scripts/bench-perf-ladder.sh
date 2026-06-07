#!/usr/bin/env bash
# ============================================================================
#  bench-perf-ladder.sh   —   Linux/WSL port of bench-perf-ladder.bat
#  Produces the SAME table: raw transport -> Horse -> Horse + header middleware,
#  across all providers, with auto-scaled caps, a warm-up, and RUNS averaged.
#
#  Usage:  ./bench-perf-ladder.sh [c] [n] [runs] [maxconn] [listenqueue]
#    c           concurrent connections    (default 100)
#    n           total requests per cell   (default 200000)
#    runs        runs averaged per cell    (default 3)
#    maxconn     THorse.MaxConnections     (default = max(256, 2*c))
#    listenqueue THorse.ListenQueue (Indy) (default = max(200, 2*c))
#  maxconn/listenqueue AUTO-SCALE from c so high-c runs stay clean on Indy.
#  Each run writes its own file: bench-perf-ladder-c<c>-n<n>.txt
#
#  Examples:
#    ./bench-perf-ladder.sh                 # c=100 n=200000
#    ./bench-perf-ladder.sh 500             # c=500, caps auto 1000/1000
#    for c in 10 28 56 100 200 500; do ./bench-perf-ladder.sh "$c"; done   # sweep
#
#  PREREQS (see bench-perf-ladder-linux.md):
#    * bombardier Linux build (set BOMB=/path/to/bombardier or have it on PATH)
#    * the bench server ELF binaries (Delphi Linux64 build) in SERVERS_DIR,
#      named WITHOUT .exe: HorseBenchIndy, HorseBenchCrossSocket, HorseBenchMormot,
#      HorseBenchRawIndy, HorseBenchRawCrossSocket, HorseBenchRawMormot
#    * raise the fd limit before high-c runs:  ulimit -n 100000
# ============================================================================
set -uo pipefail

# ---- config (override via env) ---------------------------------------------
BOMB="${BOMB:-bombardier}"
BASE_URL="http://127.0.0.1"
ROUTE="/ping"
SERVERS_DIR="${SERVERS_DIR:-$(cd "$(dirname "$0")" && pwd)}"

CONCURRENCY="${1:-100}"
REQUESTS="${2:-200000}"
RUNS="${3:-3}"

# numeric guard
[[ "$CONCURRENCY" =~ ^[0-9]+$ ]] || { echo "ERROR: c must be a positive integer"; exit 1; }
[[ "$REQUESTS"    =~ ^[0-9]+$ ]] || { echo "ERROR: n must be a positive integer"; exit 1; }

# caps auto-scale from c (>= c) unless overridden
def_maxconn=$(( CONCURRENCY * 2 )); (( def_maxconn < 256 )) && def_maxconn=256
def_listenq=$(( CONCURRENCY * 2 )); (( def_listenq < 200 )) && def_listenq=200
MAXCONN="${4:-$def_maxconn}"
LISTENQ="${5:-$def_listenq}"
WARMUP_N=$(( CONCURRENCY * 10 )); (( WARMUP_N < 2000 )) && WARMUP_N=2000

RESULTS="${SERVERS_DIR}/bench-perf-ladder-c${CONCURRENCY}-n${REQUESTS}.txt"
TMP_OUT="$(mktemp)"
trap 'rm -f "$TMP_OUT"; kill_all' EXIT

SERVER_NAMES=(HorseBenchIndy HorseBenchCrossSocket HorseBenchMormot \
              HorseBenchRawIndy HorseBenchRawCrossSocket HorseBenchRawMormot)

# ---- prereq checks ---------------------------------------------------------
command -v "$BOMB" >/dev/null 2>&1 || { echo "ERROR: bombardier not found (set BOMB=/path/to/bombardier)"; exit 1; }
[[ -x "${SERVERS_DIR}/HorseBenchIndy" ]] || { echo "ERROR: server binaries not found in ${SERVERS_DIR} (need Linux ELF builds, no .exe)"; exit 1; }

# ---- helpers ---------------------------------------------------------------
kill_all() {
  # The Linux bench servers have NO graceful signal handler (the Ctrl handler is
  # {$IFDEF MSWINDOWS}), and a transport lib could conceivably trap SIGTERM — so
  # escalate: SIGTERM, give a moment to exit, then SIGKILL any survivors.
  local s i alive
  for s in "${SERVER_NAMES[@]}"; do pkill -x    "$s" 2>/dev/null || true; done   # SIGTERM
  for i in 1 2 3 4 5 6; do          # up to ~1.5s grace
    alive=0
    for s in "${SERVER_NAMES[@]}"; do pgrep -x "$s" >/dev/null 2>&1 && { alive=1; break; }; done
    [ "$alive" -eq 0 ] && return 0
    sleep 0.25
  done
  for s in "${SERVER_NAMES[@]}"; do pkill -9 -x "$s" 2>/dev/null || true; done   # SIGKILL stragglers
  sleep 0.3
}

wait_for_port() {   # $1=port  -> 0 if listening within ~15s
  local port="$1" i=0
  while (( i < 15 )); do
    sleep 1
    if (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null; then exec 3>&- 3<&-; return 0; fi
    (( i++ ))
  done
  return 1
}

code() {  # $1=code label (2xx/5xx/others) -> count from TMP_OUT (0 if absent)
  local v; v="$(grep -oE "$1 - [0-9]+" "$TMP_OUT" | awk '{print $3}' | head -1)"
  echo "${v:-0}"
}
pct() {   # $1=percentile label (e.g. 50%) -> latency string from --latencies block
  local v; v="$(awk -v p="$1" '$1==p {print $2; exit}' "$TMP_OUT")"
  echo "${v:-n/a}"
}

printrow() {  # label rps 2xx 5xx others p50 p75 p90 p95 p99  -> console + file
  printf ' %-27s %-8s %-10s %-8s %-8s %-9s %-9s %-9s %-9s %-9s\n' "$@" | tee -a "$RESULTS"
}

cell() {  # $1=exe $2=port $3="args" $4=label
  local exe="$1" port="$2" args="$3" label="$4"
  kill_all; sleep 1
  # shellcheck disable=SC2086
  "${SERVERS_DIR}/${exe}" $args >/dev/null 2>&1 &
  local pid=$!
  if ! wait_for_port "$port"; then
    printrow "$label" "ERR" "noListen" "-" "-" "-" "-" "-" "-" "-"
    kill "$pid" 2>/dev/null || true; return
  fi
  # warm-up (discarded): prime accept loop / thread pool for the c-burst
  "$BOMB" -c "$CONCURRENCY" -n "$WARMUP_N" --http1 "${BASE_URL}:${port}${ROUTE}" >/dev/null 2>&1 || true

  local sum=0 rps twoxx=0 fivexx=0 others=0 p50=n/a p75=n/a p90=n/a p95=n/a p99=n/a r
  for (( r=1; r<=RUNS; r++ )); do
    "$BOMB" -c "$CONCURRENCY" -n "$REQUESTS" --latencies --http1 "${BASE_URL}:${port}${ROUTE}" > "$TMP_OUT" 2>&1 || true
    rps="$(awk '/Reqs\/sec/{print int($2); exit}' "$TMP_OUT")"
    sum=$(( sum + ${rps:-0} ))
    twoxx="$(code 2xx)"; fivexx="$(code 5xx)"; others="$(code others)"
    p50="$(pct 50%)"; p75="$(pct 75%)"; p90="$(pct 90%)"; p95="$(pct 95%)"; p99="$(pct 99%)"
  done
  local avg=$(( sum / RUNS ))
  kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
  printrow "$label" "$avg" "$twoxx" "$fivexx" "$others" "$p50" "$p75" "$p90" "$p95" "$p99"
}

# ---- header ----------------------------------------------------------------
: > "$RESULTS"
{
  echo "Horse performance ladder   c=${CONCURRENCY}  n=${REQUESTS}  runs=${RUNS}  maxconn=${MAXCONN}  listenqueue=${LISTENQ}"
  echo "Generated $(date '+%Y-%m-%d %H:%M:%S')  on $(uname -srm)   CPUs=$(nproc)"
} | tee -a "$RESULTS"

echo
echo "================================================================================"
echo " Performance ladder (Linux)  c=${CONCURRENCY}  n=${REQUESTS}  runs=${RUNS}  maxconn=${MAXCONN}  listenqueue=${LISTENQ}"
echo " One server at a time. Horse servers get --maxconn ${MAXCONN} --listenqueue ${LISTENQ}."
echo " Each cell: 1 discarded warm-up (-n ${WARMUP_N}) then ${RUNS} measured runs averaged."
echo " Use RELEASE builds, an idle box, and 'ulimit -n 100000' for high c."
echo "================================================================================"
echo
printrow LABEL RPSavg 2xx 5xx others P50 P75 P90 P95 P99
printf -- ' --------------------------- -------- ---------- -------- -------- --------- --------- --------- --------- ---------\n' | tee -a "$RESULTS"

# ---- the ladder ------------------------------------------------------------
cell HorseBenchRawMormot       9005 ""                                                 "raw-mormot bare"
cell HorseBenchRawMormot       9005 "--headers"                                        "raw-mormot +headers"
cell HorseBenchRawCrossSocket  9004 ""                                                 "raw-crosssock bare"
cell HorseBenchRawCrossSocket  9004 "--headers"                                        "raw-crosssock +headers"
cell HorseBenchRawIndy         9006 "--listenqueue ${LISTENQ}"                         "raw-indy bare"
cell HorseBenchRawIndy         9006 "--headers --listenqueue ${LISTENQ}"               "raw-indy +headers"
cell HorseBenchIndy            9001 "--maxconn ${MAXCONN} --listenqueue ${LISTENQ}"                "Horse+Indy bare"
cell HorseBenchIndy            9011 "--headers-only --maxconn ${MAXCONN} --listenqueue ${LISTENQ}" "Horse+Indy +headers"
cell HorseBenchIndy            9011 "--cors --maxconn ${MAXCONN} --listenqueue ${LISTENQ}"         "Horse+Indy +cors"
cell HorseBenchCrossSocket     9002 "--maxconn ${MAXCONN} --listenqueue ${LISTENQ}"                "Horse+CrossSock bare"
cell HorseBenchCrossSocket     9012 "--headers-only --maxconn ${MAXCONN} --listenqueue ${LISTENQ}" "Horse+CrossSock +headers"
cell HorseBenchCrossSocket     9012 "--cors --maxconn ${MAXCONN} --listenqueue ${LISTENQ}"         "Horse+CrossSock +cors"
cell HorseBenchMormot          9003 "--maxconn ${MAXCONN} --listenqueue ${LISTENQ}"                "Horse+mORMot bare"
cell HorseBenchMormot          9013 "--headers-only --maxconn ${MAXCONN} --listenqueue ${LISTENQ}" "Horse+mORMot +headers"
cell HorseBenchMormot          9013 "--cors --maxconn ${MAXCONN} --listenqueue ${LISTENQ}"         "Horse+mORMot +cors"

echo
echo "================================================================================"
echo " Done. Table saved to: ${RESULTS}"
echo " Read: take 'raw-mormot bare' RPS as the ceiling. fraction = row_RPS / ceiling."
echo " Non-zero 5xx = mis-built server or maxconn < c. Non-zero 'others' on Indy ="
echo " listenqueue < c burst (or fd/somaxconn limit). Both auto-scale from c here."
echo "================================================================================"
