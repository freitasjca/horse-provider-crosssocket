#!/usr/bin/env bash
# ============================================================================
#  bench-perf-ladder.sh   —   Linux/WSL bench ladder: Delphi and/or Lazarus
#  Produces the same table: raw transport → Horse → Horse + header middleware,
#  across all providers, with auto-scaled caps, a warm-up, and RUNS averaged.
#
#  Usage:  ./bench-perf-ladder.sh [c] [n] [runs] [maxconn] [listenqueue] [compiler]
#    c           concurrent connections    (default 100)
#    n           total requests per cell   (default 200000)
#    runs        runs averaged per cell    (default 3)
#    maxconn     THorse.MaxConnections     (default = max(256, 2*c))
#    listenqueue THorse.ListenQueue (Indy) (default = max(200, 2*c))
#    compiler    delphi | lazarus | both   (default delphi)
#
#  The 'compiler' keyword can appear in any argument position; numeric
#  positionals are parsed from whatever remains.
#
#  Environment variables:
#    BOMB                 Path to bombardier binary         (default: bombardier)
#    SERVERS_DIR          Directory of Delphi server ELFs   (default: script dir)
#    LAZARUS_SERVERS_DIR  Directory of Lazarus server ELFs  (default: SERVERS_DIR)
#
#  When compiler=both, Delphi and Lazarus CrossSocket rows are paired
#  side-by-side so the Delphi-vs-FPC throughput difference is obvious.
#  LAZARUS_SERVERS_DIR must be separate from SERVERS_DIR when both compilers
#  produce the same binary name (HorseBenchCrossSocket, etc.).
#
#  Examples:
#    ./bench-perf-ladder.sh                              # Delphi, c=100 n=200000
#    ./bench-perf-ladder.sh 500                          # Delphi, c=500, caps auto
#    ./bench-perf-ladder.sh 100 200000 3 lazarus         # Lazarus-only run
#    ./bench-perf-ladder.sh 100 200000 3 both            # cross-compiler comparison
#    LAZARUS_SERVERS_DIR=/opt/fpc-bins \
#      ./bench-perf-ladder.sh 100 200000 3 both          # explicit Lazarus dir
#    for c in 10 28 56 100 200 500; do
#      ./bench-perf-ladder.sh "$c"; done                 # Delphi sweep
#
#  PREREQS (see bench-perf-ladder-linux.md):
#    * bombardier Linux build (set BOMB=/path/to/bombardier or on PATH)
#    * Delphi Linux64 ELF binaries (no .exe) in SERVERS_DIR  — compiler=delphi/both
#      Names: HorseBenchIndy  HorseBenchCrossSocket  HorseBenchMormot
#             HorseBenchRawIndy  HorseBenchRawCrossSocket  HorseBenchRawMormot
#    * Lazarus FPC ELF binaries in LAZARUS_SERVERS_DIR       — compiler=lazarus/both
#      Names: HorseBenchCrossSocket  HorseBenchFPCHttp  HorseBenchMormot
#             HorseBenchRawCrossSocket  HorseBenchRawMormot  HorseBenchRawFPCHttp
#    * ulimit -n 100000  before high-c runs
# ============================================================================
set -uo pipefail

# ---- pre-parse: extract 'compiler' keyword; leave numerics as positionals ---
COMPILER="delphi"
POSITIONALS=()
for _arg in "$@"; do
  case "$_arg" in
    delphi|lazarus|both) COMPILER="$_arg" ;;
    *) POSITIONALS+=("$_arg") ;;
  esac
done
set -- "${POSITIONALS[@]+"${POSITIONALS[@]}"}"

# ---- config (override via env) ---------------------------------------------
BOMB="${BOMB:-bombardier}"
BASE_URL="http://127.0.0.1"
ROUTE="/ping"
SERVERS_DIR="${SERVERS_DIR:-$(cd "$(dirname "$0")" && pwd)}"
LAZARUS_SERVERS_DIR="${LAZARUS_SERVERS_DIR:-${SERVERS_DIR}}"

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

RESULTS="${SERVERS_DIR}/bench-perf-ladder-c${CONCURRENCY}-n${REQUESTS}-${COMPILER}.txt"
TMP_OUT="$(mktemp)"
trap 'rm -f "$TMP_OUT"; kill_all' EXIT

# All known server binary names across both compilers.
# pkill silently ignores names that don't match any running process.
# Delphi and Lazarus builds share the same names; kill_all covers both.
SERVER_NAMES=(
  HorseBenchIndy HorseBenchCrossSocket HorseBenchMormot
  HorseBenchRawIndy HorseBenchRawCrossSocket HorseBenchRawMormot
  HorseBenchFPCHttp HorseBenchRawFPCHttp
  HorseBenchFPCHttp_diag HorseBenchCrossSocket_diag HorseBenchMormot_diag
)

# Current binary directory — set before each group of cell() calls.
CELL_BIN_DIR="${SERVERS_DIR}"

# ---- prereq checks ---------------------------------------------------------
command -v "$BOMB" >/dev/null 2>&1 || \
  { echo "ERROR: bombardier not found (set BOMB=/path/to/bombardier)"; exit 1; }

case "$COMPILER" in
  delphi|both)
    [[ -x "${SERVERS_DIR}/HorseBenchIndy" ]] || \
      { echo "ERROR: Delphi server binaries not found in ${SERVERS_DIR}"; \
        echo "       Need Linux ELF builds without .exe (run build.bat on Windows first)"; exit 1; } ;;
esac
case "$COMPILER" in
  lazarus|both)
    [[ -x "${LAZARUS_SERVERS_DIR}/HorseBenchCrossSocket" ]] || \
      { echo "ERROR: Lazarus server binaries not found in ${LAZARUS_SERVERS_DIR}"; \
        echo "       Build samples/bench/Servers/Lazarus with Lazarus/lazbuild, then set"; \
        echo "       LAZARUS_SERVERS_DIR=/path/to/output if different from SERVERS_DIR"; exit 1; } ;;
esac

# ---- helpers ---------------------------------------------------------------
kill_all() {
  # Delphi Linux servers respond to SIGTERM but have no signal handler in the
  # Delphi code ({$IFDEF MSWINDOWS} guards it). Lazarus servers install
  # fpSignal(SIGTERM) and drain cleanly. Both are SIGKILLed as a backstop.
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
pct() {   # $1=percentile label -> latency string from --latencies block
  local v; v="$(awk -v p="$1" '$1==p {print $2; exit}' "$TMP_OUT")"
  echo "${v:-n/a}"
}

printrow() {  # label rps 2xx 5xx others p50 p75 p90 p95 p99 -> console + file
  printf ' %-34s %-8s %-10s %-8s %-8s %-9s %-9s %-9s %-9s %-9s\n' "$@" | tee -a "$RESULTS"
}

# cell: $1=exe_name $2=port $3="server-args" $4=label
# Launches from CELL_BIN_DIR. Set CELL_BIN_DIR before calling.
cell() {
  local exe="$1" port="$2" args="$3" label="$4"
  kill_all; sleep 1
  # shellcheck disable=SC2086
  "${CELL_BIN_DIR}/${exe}" $args >/dev/null 2>&1 &
  local pid=$!
  if ! wait_for_port "$port"; then
    printrow "$label" "ERR" "noListen" "-" "-" "-" "-" "-" "-" "-"
    kill "$pid" 2>/dev/null || true; return
  fi
  # warm-up (discarded): prime accept loop / thread pool / context pool
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

# Convenience wrappers that set CELL_BIN_DIR and delegate to cell().
delphi_cell()  { CELL_BIN_DIR="${SERVERS_DIR}";         cell "$@"; }
lazarus_cell() { CELL_BIN_DIR="${LAZARUS_SERVERS_DIR}"; cell "$@"; }

# ---- header ----------------------------------------------------------------
: > "$RESULTS"
{
  echo "Horse performance ladder   compiler=${COMPILER}  c=${CONCURRENCY}  n=${REQUESTS}  runs=${RUNS}  maxconn=${MAXCONN}  listenqueue=${LISTENQ}"
  echo "Generated $(date '+%Y-%m-%d %H:%M:%S')  on $(uname -srm)   CPUs=$(nproc)"
  [[ "$COMPILER" != "delphi" ]] && \
    echo "LAZARUS_SERVERS_DIR=${LAZARUS_SERVERS_DIR}"
} | tee -a "$RESULTS"

echo
echo "=================================================================================================="
echo " Performance ladder (Linux)  compiler=${COMPILER}  c=${CONCURRENCY}  n=${REQUESTS}  runs=${RUNS}"
echo " maxconn=${MAXCONN}  listenqueue=${LISTENQ}.  One server at a time."
echo " Each cell: 1 discarded warm-up (-n ${WARMUP_N}) then ${RUNS} measured runs averaged."
echo " Use RELEASE builds, an idle box, and 'ulimit -n 100000' for high c."
[[ "$COMPILER" == "both" ]] && \
  echo " Paired rows: Delphi first, then (FPC) immediately after for direct comparison."
echo "=================================================================================================="
echo
printrow LABEL RPSavg 2xx 5xx others P50 P75 P90 P95 P99
printf -- ' ---------------------------------- -------- ---------- -------- -------- --------- --------- --------- --------- ---------\n' | tee -a "$RESULTS"

# ---- the ladder ------------------------------------------------------------
#
# compiler=delphi : original behaviour — Delphi builds only, same row order as before.
# compiler=lazarus: Lazarus builds only — CrossSocket + FPC-HTTP + Raw-CrossSocket.
# compiler=both   : CrossSocket rows are paired (Delphi then FPC) for direct comparison;
#                   Delphi-only providers (Indy, mORMot) and Lazarus-only (FPC-HTTP)
#                   appear in their natural positions.

case "$COMPILER" in

# --------------------------------------------------------------------------
delphi)
  # Identical to the original script's ladder — backward compatible.
  delphi_cell HorseBenchRawMormot      9005 ""                                                        "raw-mormot bare"
  delphi_cell HorseBenchRawMormot      9005 "--headers"                                               "raw-mormot +headers"
  # raw-mormot async backend (THttpAsyncServer) — transport baseline for the async A/B
  delphi_cell HorseBenchRawMormot      9005 "--async"                                                 "raw-mormot bare (async)"
  delphi_cell HorseBenchRawMormot      9005 "--async --headers"                                       "raw-mormot +headers (async)"
  delphi_cell HorseBenchRawCrossSocket 9004 ""                                                        "raw-crosssock bare"
  delphi_cell HorseBenchRawCrossSocket 9004 "--headers"                                               "raw-crosssock +headers"
  delphi_cell HorseBenchRawIndy        9006 "--listenqueue ${LISTENQ}"                                "raw-indy bare"
  delphi_cell HorseBenchRawIndy        9006 "--headers --listenqueue ${LISTENQ}"                      "raw-indy +headers"
  delphi_cell HorseBenchIndy           9001 "--maxconn ${MAXCONN} --listenqueue ${LISTENQ}"           "Horse+Indy bare"
  delphi_cell HorseBenchIndy           9011 "--headers-only --maxconn ${MAXCONN} --listenqueue ${LISTENQ}" "Horse+Indy +headers"
  delphi_cell HorseBenchIndy           9011 "--cors --maxconn ${MAXCONN} --listenqueue ${LISTENQ}"    "Horse+Indy +cors"
  delphi_cell HorseBenchCrossSocket    9002 "--maxconn ${MAXCONN} --listenqueue ${LISTENQ}"           "Horse+CrossSock bare"
  delphi_cell HorseBenchCrossSocket    9012 "--headers-only --maxconn ${MAXCONN} --listenqueue ${LISTENQ}" "Horse+CrossSock +headers"
  delphi_cell HorseBenchCrossSocket    9012 "--cors --maxconn ${MAXCONN} --listenqueue ${LISTENQ}"    "Horse+CrossSock +cors"
  delphi_cell HorseBenchMormot         9003 "--maxconn ${MAXCONN} --listenqueue ${LISTENQ}"           "Horse+mORMot bare"
  delphi_cell HorseBenchMormot         9013 "--headers-only --maxconn ${MAXCONN} --listenqueue ${LISTENQ}" "Horse+mORMot +headers"
  delphi_cell HorseBenchMormot         9013 "--cors --maxconn ${MAXCONN} --listenqueue ${LISTENQ}"    "Horse+mORMot +cors"
  # mORMot async backend (THttpAsyncServer) — A/B vs the thread-pool rows above
  delphi_cell HorseBenchMormot         9003 "--async --maxconn ${MAXCONN}"                            "Horse+mORMot bare (async)"
  delphi_cell HorseBenchMormot         9013 "--async --headers-only --maxconn ${MAXCONN}"            "Horse+mORMot +headers (async)"
  # NOTE: the mORMot --httpapi (http.sys) backend is Windows-only — it has no rows here.
  #       Use bench-perf-ladder.bat on Windows for the http.sys A/B (raw + Horse).
  ;;

# --------------------------------------------------------------------------
lazarus)
  # Lazarus-only: CrossSocket + mORMot + FPC default HTTPApplication + Raw servers.
  # FPC-HTTP = Horse default provider on FPC (fphttpserver/THTTPApplication,
  # threaded=true). Analogous role to Indy on Delphi — one thread per connection.
  lazarus_cell HorseBenchRawMormot      9005 ""                                                       "raw-mormot bare (FPC)"
  lazarus_cell HorseBenchRawMormot      9005 "--headers"                                              "raw-mormot +headers (FPC)"
  # raw-mormot async backend (THttpAsyncServer) on FPC — transport baseline
  lazarus_cell HorseBenchRawMormot      9005 "--async"                                                "raw-mormot bare (FPC async)"
  lazarus_cell HorseBenchRawMormot      9005 "--async --headers"                                      "raw-mormot +headers (FPC async)"
  lazarus_cell HorseBenchRawCrossSocket 9004 ""                                                       "raw-crosssock bare (FPC)"
  lazarus_cell HorseBenchRawCrossSocket 9004 "--headers"                                              "raw-crosssock +headers (FPC)"
  # raw fphttpserver (no Horse) — FPC default-transport baseline (analog of raw-indy)
  lazarus_cell HorseBenchRawFPCHttp     9008 ""                                                       "raw-fpchttp bare (FPC)"
  lazarus_cell HorseBenchRawFPCHttp     9008 "--headers"                                              "raw-fpchttp +headers (FPC)"
  lazarus_cell HorseBenchCrossSocket    9002 "--maxconn ${MAXCONN}"                                   "Horse+CrossSock bare (FPC)"
  lazarus_cell HorseBenchCrossSocket    9012 "--headers-only --maxconn ${MAXCONN}"                    "Horse+CrossSock +headers (FPC)"
  lazarus_cell HorseBenchMormot         9003 "--maxconn ${MAXCONN}"                                   "Horse+mORMot bare (FPC)"
  lazarus_cell HorseBenchMormot         9013 "--headers-only --maxconn ${MAXCONN}"                    "Horse+mORMot +headers (FPC)"
  # mORMot async backend (THttpAsyncServer) on FPC — A/B vs thread-pool rows above
  lazarus_cell HorseBenchMormot         9003 "--async --maxconn ${MAXCONN}"                           "Horse+mORMot bare (FPC async)"
  lazarus_cell HorseBenchMormot         9013 "--async --headers-only --maxconn ${MAXCONN}"           "Horse+mORMot +headers (FPC async)"
  # FPC-HTTP: --listenqueue sets THTTPApplication.QueueSize (TCP accept backlog).
  # No --maxconn: fphttpserver has no module-pool cap analogous to WebBroker.
  lazarus_cell HorseBenchFPCHttp        9007 "--listenqueue ${LISTENQ}"                               "Horse+FPC-HTTP bare"
  lazarus_cell HorseBenchFPCHttp        9017 "--headers-only --listenqueue ${LISTENQ}"                "Horse+FPC-HTTP +headers"
  ;;

# --------------------------------------------------------------------------
both)
  # Cross-compiler comparison. CrossSocket rows are paired so the Delphi vs
  # FPC throughput difference is immediately visible. Delphi-only rows
  # (Indy, mORMot, RawIndy, RawMormot) and Lazarus-only rows (FPC-HTTP) follow.

  # Raw transport baselines — mORMot paired, CrossSocket paired, Indy Delphi-only.
  delphi_cell  HorseBenchRawMormot      9005 ""                                                       "raw-mormot bare"
  lazarus_cell HorseBenchRawMormot      9005 ""                                                       "raw-mormot bare (FPC)"
  delphi_cell  HorseBenchRawMormot      9005 "--async"                                                "raw-mormot bare (async)"
  lazarus_cell HorseBenchRawMormot      9005 "--async"                                                "raw-mormot bare (FPC async)"
  delphi_cell  HorseBenchRawMormot      9005 "--headers"                                              "raw-mormot +headers"
  lazarus_cell HorseBenchRawMormot      9005 "--headers"                                              "raw-mormot +headers (FPC)"
  delphi_cell  HorseBenchRawMormot      9005 "--async --headers"                                      "raw-mormot +headers (async)"
  lazarus_cell HorseBenchRawMormot      9005 "--async --headers"                                      "raw-mormot +headers (FPC async)"
  delphi_cell  HorseBenchRawCrossSocket 9004 ""                                                       "raw-crosssock bare"
  lazarus_cell HorseBenchRawCrossSocket 9004 ""                                                       "raw-crosssock bare (FPC)"
  delphi_cell  HorseBenchRawCrossSocket 9004 "--headers"                                              "raw-crosssock +headers"
  lazarus_cell HorseBenchRawCrossSocket 9004 "--headers"                                              "raw-crosssock +headers (FPC)"
  delphi_cell  HorseBenchRawIndy        9006 "--listenqueue ${LISTENQ}"                               "raw-indy bare"
  delphi_cell  HorseBenchRawIndy        9006 "--headers --listenqueue ${LISTENQ}"                     "raw-indy +headers"
  # raw fphttpserver — the FPC analog of raw-indy (raw default self-hosted transport)
  lazarus_cell HorseBenchRawFPCHttp     9008 ""                                                       "raw-fpchttp bare (FPC)"
  lazarus_cell HorseBenchRawFPCHttp     9008 "--headers"                                              "raw-fpchttp +headers (FPC)"

  # Delphi-only: Indy.
  delphi_cell HorseBenchIndy            9001 "--maxconn ${MAXCONN} --listenqueue ${LISTENQ}"          "Horse+Indy bare"
  delphi_cell HorseBenchIndy            9011 "--headers-only --maxconn ${MAXCONN} --listenqueue ${LISTENQ}" "Horse+Indy +headers"
  delphi_cell HorseBenchIndy            9011 "--cors --maxconn ${MAXCONN} --listenqueue ${LISTENQ}"   "Horse+Indy +cors"

  # CrossSocket — paired Delphi + FPC.
  delphi_cell  HorseBenchCrossSocket    9002 "--maxconn ${MAXCONN} --listenqueue ${LISTENQ}"          "Horse+CrossSock bare"
  lazarus_cell HorseBenchCrossSocket    9002 "--maxconn ${MAXCONN}"                                   "Horse+CrossSock bare (FPC)"
  delphi_cell  HorseBenchCrossSocket    9012 "--headers-only --maxconn ${MAXCONN} --listenqueue ${LISTENQ}" "Horse+CrossSock +headers"
  lazarus_cell HorseBenchCrossSocket    9012 "--headers-only --maxconn ${MAXCONN}"                    "Horse+CrossSock +headers (FPC)"
  # --cors is Delphi-only (Horse.CORS uses WebBroker, not available on FPC).
  delphi_cell  HorseBenchCrossSocket    9012 "--cors --maxconn ${MAXCONN} --listenqueue ${LISTENQ}"   "Horse+CrossSock +cors (Delphi)"

  # mORMot — paired Delphi + FPC.
  delphi_cell  HorseBenchMormot         9003 "--maxconn ${MAXCONN} --listenqueue ${LISTENQ}"          "Horse+mORMot bare"
  lazarus_cell HorseBenchMormot         9003 "--maxconn ${MAXCONN}"                                   "Horse+mORMot bare (FPC)"
  delphi_cell  HorseBenchMormot         9003 "--async --maxconn ${MAXCONN}"                           "Horse+mORMot bare (async)"
  lazarus_cell HorseBenchMormot         9003 "--async --maxconn ${MAXCONN}"                           "Horse+mORMot bare (FPC async)"
  delphi_cell  HorseBenchMormot         9013 "--headers-only --maxconn ${MAXCONN} --listenqueue ${LISTENQ}" "Horse+mORMot +headers"
  lazarus_cell HorseBenchMormot         9013 "--headers-only --maxconn ${MAXCONN}"                    "Horse+mORMot +headers (FPC)"
  delphi_cell  HorseBenchMormot         9013 "--cors --maxconn ${MAXCONN} --listenqueue ${LISTENQ}"   "Horse+mORMot +cors (Delphi)"

  # Lazarus-only: FPC default provider (fphttpserver, thread-per-connection).
  lazarus_cell HorseBenchFPCHttp        9007 "--listenqueue ${LISTENQ}"                               "Horse+FPC-HTTP bare"
  lazarus_cell HorseBenchFPCHttp        9017 "--headers-only --listenqueue ${LISTENQ}"                "Horse+FPC-HTTP +headers"
  ;;

esac

echo
echo "=================================================================================================="
echo " Done. Table saved to: ${RESULTS}"
echo " Read: 'raw-mormot bare' (Delphi) = ceiling for Delphi builds."
echo "       'raw-mormot bare (FPC)' or 'raw-crosssock bare (FPC)' = Lazarus ceiling."
echo "       fraction = row_RPS / ceiling shows Horse framework overhead."
echo " Non-zero 5xx on Indy/FPC-HTTP = MaxConnections/QueueSize < c (auto-scaled here)."
echo " Non-zero 'others' on Indy = listenqueue < c burst (auto-scaled here)."
echo " Paired (FPC) rows lower than Delphi = compiler or GC/allocator difference."
echo "=================================================================================================="
