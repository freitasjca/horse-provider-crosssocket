#!/usr/bin/env bash
# =============================================================================
#  repro-cs-shutdown.sh
#  Bisects the CrossSocket segfault-on-SIGTERM seen in bench-h2.sh's S4 run.
#
#  What is established so far (2026-11-02):
#    * bench-h2.sh S4 -> CrossSocket server dumps core on shutdown, 2 of 2 runs.
#    * An isolated single-SIGTERM repro of that cell is CLEAN — both immediately
#      after load (settle=0) and after a 1 s settle, 8/8. So the trigger is NOT
#      c=1000, and NOT kill-timing alone. Two earlier guesses (c=1000; settle),
#      both refuted by measurement.
#
#  The remaining difference between the clean repro and the crashing harness is
#  the KILL SEQUENCE. In bench-h2.sh each cell ENDS with `pkill -f <exe>` and the
#  NEXT cell STARTS with `pkill -f HorseBench`, and the server is never `wait`ed
#  on — so the dying CrossSocket server receives a SECOND SIGTERM (from the next
#  cell) while THorse.StopListen from the first may still be running. This script
#  isolates that: kill COUNT (1 vs 2) and METHOD (kill $pid vs pkill -f).
#
#  Hypothesis: a second SIGTERM re-enters HandleStopSignal -> THorse.StopListen
#  while the first teardown is mid-flight (FServer being freed / FStopEvent being
#  freed by the woken main thread) -> double-free / use-after-free -> SIGSEGV.
#
#  Run from this directory (…/samples/bench) against a FRESH build:
#    ./run-p1.sh --build          # needs FPC trunk
#    bash repro-cs-shutdown.sh
#
#  Exit-code legend (the fresh .lpr installs the handler):
#     0   = StopListen completed            -> clean shutdown
#    139  = SIGSEGV during shutdown         -> THE BUG
#    143  = default-terminated, no handler  -> you built an OLD .lpr
#
#  Expected if the double-signal hypothesis holds:
#    single-* -> 0 (clean) ,  double-* -> 139 (crash), reproducibly.
# =============================================================================
set -u
BIN="${BIN:-./bin/HorseBenchCrossSocket}"      # run-p1.sh outputs to ./bin
B="$(basename "$BIN")"
PORT=9002
URL="http://127.0.0.1:${PORT}/ping"
N="${N:-200000}"
LOG="$(mktemp -d)"
ulimit -n 100000 2>/dev/null || true
[ -x "$BIN" ] || { echo "ERROR: $BIN not built. Run ./run-p1.sh --build first."; exit 1; }

wait_for_port(){ local t=0; while [ "$t" -lt 15 ]; do sleep 1; ss -ltn 2>/dev/null|grep -q ":${PORT} " && return 0; t=$((t+1)); done; return 1; }

# $1=label  $2=method(kill|pkill)  $3=nkills  $4=gap-between-kills(secs)
run_killtest(){
  pkill -f "$B" >/dev/null 2>&1 || true; sleep 1
  "$BIN" > "$LOG/srv-$1.log" 2>&1 & local pid=$!
  wait_for_port || { echo "[$1] never bound :$PORT"; kill -9 "$pid" 2>/dev/null; return; }
  h2load --h1 -c 1000 -n "$N" "$URL" >/dev/null 2>&1
  local k=0 n="${3:-1}"
  while [ "$k" -lt "$n" ]; do
    if [ "$2" = pkill ]; then pkill -f "$B" >/dev/null 2>&1; else kill -TERM "$pid" 2>/dev/null; fi
    k=$((k+1)); [ "$k" -lt "$n" ] && sleep "${4:-0}"
  done
  wait "$pid" 2>/dev/null; local rc=$?
  local v="exit $rc"; case $rc in 139)v="SIGSEGV(139) — CRASH";;0)v="clean(0)";;143)v="no-handler(143 — OLD build)";;esac
  printf '== %-18s %-5s ×%s gap=%ss  -> %s\n' "$1" "$2" "$n" "${4:-0}" "$v"
  grep -iE "runtime error|access violation|external SIG|sigsegv" "$LOG/srv-$1.log" | head -3 | sed 's/^/     srv: /'
}

echo "### CrossSocket shutdown kill-sequence bisection   bin=$BIN  N=$N   $(date)"
run_killtest single-kill     kill  1 0      # control — known clean
run_killtest single-pkill    pkill 1 0      # method control: pkill, one signal
run_killtest double-kill-0   kill  2 0      # two signals via kill $pid, back-to-back
run_killtest double-pkill-0  pkill 2 0      # bench-h2.sh shape: two pkills back-to-back
run_killtest double-pkill-05 pkill 2 0.05   # small gap, mimics cell-return + next cell
run_killtest double-pkill-2  pkill 2 0.2    # larger gap (teardown likely still running)

# gdb backtrace on a crash, if gdb is installed (attach before the load so it is
# already watching when the double kill fires). run-p1.sh builds -O2 no -g, so
# names are mangled, but the failing thread/frame still localises it.
if command -v gdb >/dev/null 2>&1; then
  echo; echo "### gdb backtrace (double-pkill crash)"
  pkill -f "$B" >/dev/null 2>&1 || true; sleep 1
  "$BIN" > "$LOG/srv-gdb.log" 2>&1 & gpid=$!
  wait_for_port || { echo "never bound"; kill -9 "$gpid" 2>/dev/null; }
  ( gdb -p "$gpid" -batch -ex 'handle SIGTERM nostop noprint pass' -ex 'continue' \
        -ex 'thread apply all bt' > "$LOG/gdb-bt.txt" 2>/dev/null ) & gdbpid=$!
  sleep 2
  h2load --h1 -c 1000 -n "$N" "$URL" >/dev/null 2>&1
  pkill -f "$B" >/dev/null 2>&1; pkill -f "$B" >/dev/null 2>&1   # double
  wait "$gdbpid" 2>/dev/null
  head -40 "$LOG/gdb-bt.txt" 2>/dev/null | sed 's/^/   /'
else
  echo; echo "### (gdb not installed — exit codes above are the evidence)"
fi
pkill -f "$B" >/dev/null 2>&1 || true
echo "### logs in $LOG"
