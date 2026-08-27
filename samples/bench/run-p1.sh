#!/usr/bin/env bash
# ============================================================================
#  run-p1.sh — Phase P1 of plans/bench-plan-all-providers.md
#
#  S8 (framework floor: raw transport vs Horse-wrapped) + S1 (per-request
#  floor at low concurrency), on Linux, across the four providers that exist
#  on this platform.
#
#  P1 is deliberately the cheapest phase, and it can redirect the whole
#  project: if THorse.Execute turns out to be most of the per-request cost,
#  then every transport ranking that follows is a fight over what is left,
#  and the effort belongs in the framework rather than in providers.
#
#  ── Reading the output ──
#
#  nghttp2 is HTTP/2; everything else is HTTP/1.1. On THIS scenario — one
#  request in flight per connection on a trivial route — HTTP/2 is EXPECTED
#  to lose, because it pays for framing, HPACK and per-stream state that
#  HTTP/1.1 keep-alive does not. That is protocol cost, not an implementation
#  defect. The scenario where HTTP/2 is meant to win is S4 (phase P2), which
#  puts many requests in flight per connection.
#
#  So: do not rank S1 across protocols. Read it as two separate columns, and
#  read the raw-vs-wrapped delta WITHIN each provider.
#
#  Usage:
#    ./run-p1.sh --build          build the servers first (needs fpc)
#    ./run-p1.sh                  run, assuming binaries are present
#    ./run-p1.sh --runs 5         more repeats per cell (default 3)
# ============================================================================
set -uo pipefail

cd "$(dirname "$0")" || exit 1

RUNS=3
DO_BUILD=0
REQS=200000
CONNS=10
WORKERS=4          # pinned everywhere; auto-sizing makes runs incomparable
OUT="bench-results-linux-$(date +%Y%m%d-%H%M%S).md"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build) DO_BUILD=1; shift ;;
    --runs)  RUNS="$2"; shift 2 ;;
    --reqs)  REQS="$2"; shift 2 ;;
    --conns) CONNS="$2"; shift 2 ;;
    --workers) WORKERS="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

# ── Preconditions ───────────────────────────────────────────────────────────
if ! command -v h2load > /dev/null 2>&1; then
  echo "ERROR: h2load not found (apt install nghttp2-client)." >&2
  echo "       h2load is used for BOTH protocols — --h1 for the HTTP/1.1" >&2
  echo "       servers — so that client cost is constant and only the" >&2
  echo "       protocol varies. Mixing bombardier and h2load would make the" >&2
  echo "       client a variable in a comparison that is already close." >&2
  exit 1
fi

ROOT=../../../..
BIN=./bin
mkdir -p "$BIN"

# name | dir | lpr | define | port | protocol | framework
SERVERS=(
  "CrossSocket|Servers/Lazarus/CrossSocket|HorseBenchCrossSocket|HORSE_PROVIDER_CROSSSOCKET|9002|h1|Horse"
  "Raw-CrossSocket|Servers/Lazarus/RawCrossSocket|HorseBenchRawCrossSocket||9004|h1|none"
  "mORMot|Servers/Lazarus/Mormot|HorseBenchMormot|HORSE_PROVIDER_MORMOT|9003|h1|Horse"
  "Raw-mORMot|Servers/Lazarus/RawMormot|HorseBenchRawMormot||9005|h1|none"
  "FPCHttp|Servers/Lazarus/FPCHttp|HorseBenchFPCHttp||9007|h1|Horse"
  "Raw-FPCHttp|Servers/Lazarus/RawFPCHttp|HorseBenchRawFPCHttp||9008|h1|none"
  "Epoll|Servers/Lazarus/Epoll|HorseBenchEpoll|HORSE_PROVIDER_EPOLL|9043|h1|Horse"
  "nghttp2|Servers/Lazarus/Nghttp2|HorseBenchNghttp2|HORSE_PROVIDER_NGHTTP2|9041|h2|Horse"
  "Raw-nghttp2|Servers/Lazarus/RawNghttp2|HorseBenchRawNghttp2||9042|h2|none"
)

FPCFLAGS=(-MDelphi -O2 -Sh
  "-Fu$ROOT/horse/src"
  "-Fu$ROOT/horse-provider-crosssocket/src"
  "-Fu$ROOT/horse-provider-mormot/src"
  "-Fu$ROOT/horse-provider-nghttp2/src"
  "-Fu$ROOT/Delphi-nghttp2/src"
  "-Fu$ROOT/Delphi-Cross-Socket/Net"
  "-Fu$ROOT/Delphi-Cross-Socket/Utils"
  "-Fu$ROOT/horse-request-guard/src"
  "-Fu$ROOT/horse-security-headers/src"
  "-FuCommon"
)

if [[ $DO_BUILD -eq 1 ]]; then
  command -v fpc > /dev/null 2>&1 || { echo "ERROR: fpc not found." >&2; exit 1; }
  for row in "${SERVERS[@]}"; do
    IFS='|' read -r NAME DIR LPR DEF PORT PROTO FW <<< "$row"
    echo "building $NAME ..."
    UNITDIR="$BIN/units-$NAME"; mkdir -p "$UNITDIR"
    DEFARG=(); [[ -n "$DEF" ]] && DEFARG=("-d$DEF")
    # Separate unit dir per server: FPC's .ppu cache does NOT account for -d
    # changes, so a shared dir silently reuses units built with the wrong
    # provider define and the binary serves from a transport you did not pick.
    if ! fpc "${FPCFLAGS[@]}" "${DEFARG[@]}" -FU"$UNITDIR" -o"$BIN/$LPR" \
             "$DIR/$LPR.lpr" > "$BIN/$NAME.build.log" 2>&1; then
      echo "  FAILED — see $BIN/$NAME.build.log"
      tail -5 "$BIN/$NAME.build.log" | sed 's/^/    | /'
    else
      echo "  ok"
    fi
  done
  echo
fi

# ── Harness ─────────────────────────────────────────────────────────────────
SRV_PID=""
cleanup() { [[ -n "$SRV_PID" ]] && kill -TERM "$SRV_PID" 2>/dev/null; }
trap cleanup EXIT INT TERM

port_free() { ! ss -ltn 2>/dev/null | grep -q ":$1 "; }

# median of stdin (one number per line)
median() { sort -n | awk '{a[NR]=$1} END{ if(NR==0){print 0} else if(NR%2){print a[(NR+1)/2]} else {printf "%.0f", (a[NR/2]+a[NR/2+1])/2} }'; }

{
  echo "# Bench P1 — framework floor + per-request floor (Linux)"
  echo
  echo "Plan: \`plans/bench-plan-all-providers.md\` phases S8 + S1."
  echo
  echo "- host: \`$(uname -srm)\`, $(nproc) cores"
  echo "- load: h2load, \`-n $REQS -c $CONNS\`, one request in flight per connection"
  echo "- runs per cell: $RUNS (median reported)"
  echo "- worker pool pinned to $WORKERS everywhere it applies"
  echo
  echo "**nghttp2 rows are HTTP/2; all others are HTTP/1.1.** On this scenario"
  echo "HTTP/2 is expected to lose — it pays for framing, HPACK and per-stream"
  echo "state that HTTP/1.1 keep-alive does not. Do not rank across protocols"
  echo "here; see S4 in phase P2 for the scenario HTTP/2 exists for."
  echo
  echo "| Provider | Proto | Framework | req/s (median) | P50 ms | P99 ms | CPU% | req/s/core |"
  echo "|---|---|---|---|---|---|---|---|"
} | tee "$OUT"

for row in "${SERVERS[@]}"; do
  IFS='|' read -r NAME DIR LPR DEF PORT PROTO FW <<< "$row"
  BINPATH="$BIN/$LPR"

  if [[ ! -x "$BINPATH" ]]; then
    echo "| $NAME | $PROTO | $FW | _not built_ | | | | |" | tee -a "$OUT"
    continue
  fi
  if ! port_free "$PORT"; then
    echo "| $NAME | $PROTO | $FW | _port $PORT busy_ | | | | |" | tee -a "$OUT"
    continue
  fi

  # One server process at a time. At low concurrency co-resident servers are
  # harmless, but keeping the harness uniform across phases matters more —
  # P3 runs at c=10000 where idle processes do perturb the one under test.
  ARGS=()
  [[ "$FW" == "Horse" && "$NAME" == "nghttp2" ]] && ARGS=("--workers=$WORKERS")
  [[ "$NAME" == "Raw-nghttp2" ]] && ARGS=("--workers=$WORKERS")

  "$BINPATH" "${ARGS[@]}" > "$BIN/$NAME.run.log" 2>&1 &
  SRV_PID=$!
  sleep 1

  if ! kill -0 "$SRV_PID" 2>/dev/null; then
    echo "| $NAME | $PROTO | $FW | _server exited_ | | | | |" | tee -a "$OUT"
    tail -3 "$BIN/$NAME.run.log" | sed 's/^/    | /'
    SRV_PID=""
    continue
  fi

  H2ARGS=(-n "$REQS" -c "$CONNS")
  [[ "$PROTO" == "h1" ]] && H2ARGS+=(--h1) || H2ARGS+=(-m 1)

  # Warm-up, discarded: context pools and thread pools have startup costs that
  # inflate the first few hundred requests.
  h2load "${H2ARGS[@]/-n $REQS/}" -n 2000 -c 20 "http://127.0.0.1:$PORT/ping" \
    > /dev/null 2>&1

  RPS_F=$(mktemp); P50_F=$(mktemp); P99_F=$(mktemp)
  CPU_TOTAL=0
  for ((r = 1; r <= RUNS; r++)); do
    CPU_BEFORE=$(ps -o cputimes= -p "$SRV_PID" 2>/dev/null | tr -d ' ')
    LOGF=$(mktemp)
    T0=$(date +%s)
    OUTPUT=$(h2load "${H2ARGS[@]}" --log-file="$LOGF" \
             "http://127.0.0.1:$PORT/ping" 2>&1)
    T1=$(date +%s)
    CPU_AFTER=$(ps -o cputimes= -p "$SRV_PID" 2>/dev/null | tr -d ' ')

    echo "$OUTPUT" | grep -oE '[0-9.]+ req/s' | grep -oE '^[0-9.]+' | head -1 \
      >> "$RPS_F"

    { # Percentiles come from the per-request log, NOT from h2load's summary
      # line — that line reports min/max/mean/sd and has no percentiles in it
      # at all. Reading its columns as P50/P99 would put two differently
      # named numbers in the table, which is the same class of error as an
      # unlabelled configuration: quietly wrong, and invisible in the output.
      #
      # --log-file columns are tab-separated:
      #   1 start time (us since epoch)   2 HTTP status   3 duration (us)
      awk -F'\t' 'NF>=3 && $3 ~ /^[0-9]+$/ {print $3}' "$LOGF" | sort -n \
        > "$LOGF.sorted"
      N=$(wc -l < "$LOGF.sorted")
      if [[ "$N" -gt 0 ]]; then
        awk -v n="$N" 'NR==int(n*0.50)+0 || (int(n*0.50)==0 && NR==1){printf "%.3f", $1/1000; exit}' \
          "$LOGF.sorted" >> "$P50_F"; echo >> "$P50_F"
        awk -v n="$N" 'NR==int(n*0.99)+0 || (int(n*0.99)==0 && NR==1){printf "%.3f", $1/1000; exit}' \
          "$LOGF.sorted" >> "$P99_F"; echo >> "$P99_F"
      fi
      rm -f "$LOGF.sorted"
    }
    rm -f "$LOGF"

    ELAPSED=$(( T1 - T0 )); [[ $ELAPSED -eq 0 ]] && ELAPSED=1
    if [[ -n "${CPU_BEFORE:-}" && -n "${CPU_AFTER:-}" ]]; then
      CPU_TOTAL=$(( CPU_TOTAL + (CPU_AFTER - CPU_BEFORE) * 100 / ELAPSED ))
    fi
  done

  RPS=$(median < "$RPS_F"); P50=$(median < "$P50_F"); P99=$(median < "$P99_F")
  CPU=$(( CPU_TOTAL / RUNS ))
  CORES=$(nproc)
  # req/s per core: a provider that wins throughput by burning 4x the CPU has
  # not won, and without this column the table cannot tell those two apart.
  if [[ "$CPU" -gt 0 ]]; then
    RPSC=$(awk -v r="$RPS" -v c="$CPU" 'BEGIN{printf "%.0f", r/(c/100)}')
  else
    RPSC="n/a"
  fi

  echo "| $NAME | $PROTO | $FW | $RPS | $P50 | $P99 | $CPU | $RPSC |" | tee -a "$OUT"
  rm -f "$RPS_F" "$P50_F" "$P99_F"

  kill -TERM "$SRV_PID" 2>/dev/null
  wait "$SRV_PID" 2>/dev/null
  SRV_PID=""
  sleep 0.5
done

{
  echo
  echo "## Framework floor (S8)"
  echo
  echo "Compare each Horse row against its Raw counterpart. The delta is what"
  echo "\`THorse.Execute\` + context pool + bridges cost per request on that"
  echo "transport."
  echo
  echo "| Pair | Raw req/s | Horse req/s | Horse cost |"
  echo "|---|---|---|---|"
  echo "| CrossSocket | | | |"
  echo "| mORMot | | | |"
  echo "| FPCHttp | | | |"
  echo "| nghttp2 | | | |"
  echo
  echo "**If the floor dominates**, the provider comparison is a fight over"
  echo "what is left, and further transport work has poor return — optimise"
  echo "\`THorse.Execute\` instead. That verdict is the point of P1; record it"
  echo "before running P2."
} | tee -a "$OUT"

echo
echo "Results: $OUT"
