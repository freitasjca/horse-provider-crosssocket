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
#  ── Before believing any delta ──
#
#  This rig cannot resolve below roughly 20% by timing. Run the same server
#  twice and compare those two numbers first — that is the noise floor, and
#  nothing smaller than it means anything. See .claude/skills/perf-measurement.
#
#  Usage:
#    ./run-p1.sh --build          build the servers first (needs FPC trunk)
#    ./run-p1.sh                  run, assuming binaries are present
#    ./run-p1.sh --runs 5         more repeats per cell (default 3)
#    ./run-p1.sh --conns 10       the S1 concurrency pass (default 1 = floor)
#
#  Environment:
#    TRUNK_FPC    path to the trunk fpc binary (default /usr/local/fpc-trunk/bin/fpc)
#    TRUNK_UNITS  path to its unit tree        (default .../units/x86_64-linux)
# ============================================================================
set -uo pipefail

cd "$(dirname "$0")" || exit 1

RUNS=3
DO_BUILD=0
REQS=50000
CONNS=1            # see note
# One connection, to match the nghttp2 floor figure already measured that way
# (18 360 req/s). Mixing concurrencies is how the earlier Epoll number (-c 10)
# and the nghttp2 number (-c 1) ended up incomparable. S1 at -c 10 is a
# separate run — pass --conns 10; this pass is about the FLOOR, which is a
# per-request cost.
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

BIN=./bin
mkdir -p "$BIN"

# ── Where the sibling repos are ─────────────────────────────────────────────
# FOUND by walking up, not counted with `..`.
#
# The first committed version hard-coded ROOT=../../../.. — correct only for
# the copy living under patches/, which is four levels down. Applied into the
# repo it is three, so every -Fu pointed one directory above the repo set and
# all nine servers failed with "Can't find unit Horse". Nine identical logs,
# none of which named a search path.
#
# Note the symlinked-workspace trap that made this hard to see: bash resolves
# `cd ..` LOGICALLY (tracking $PWD through symlinks) while fpc opens paths via
# the kernel, which resolves them PHYSICALLY. From a symlinked checkout the two
# land in different directories. Probing with [[ -d ]] uses the same physical
# resolution fpc will, so what this loop finds is what fpc will find.
ROOT=""
_probe="."
for _ in 1 2 3 4 5 6; do
  if [[ -d "$_probe/horse/src" ]]; then ROOT="$_probe"; break; fi
  _probe="$_probe/.."
done
if [[ -z "$ROOT" ]]; then
  echo "ERROR: cannot locate the repo set — no ancestor of $PWD contains horse/src." >&2
  echo "       This script expects the sibling layout: horse/, mORMot2/," >&2
  echo "       Delphi-Cross-Socket/, Delphi-nghttp2/ etc. all beside each other." >&2
  exit 1
fi

# ── Compiler ────────────────────────────────────────────────────────────────
# Trunk, not whatever `fpc` resolves to on PATH.
#
# A run that used /usr/bin/fpc = 3.2.2 left every nghttp2 target unbuildable:
# 3.2.2 is a HARD BLOCKER for that provider, and it also rejects the anonymous
# methods the FPCHttp bench server uses. build-fpc.sh has always used trunk;
# this matches it, and prints the version into the results so a 3.2.2 run can
# never be mistaken for a trunk one.
FPCBIN=${TRUNK_FPC:-/usr/local/fpc-trunk/bin/fpc}
TU=${TRUNK_UNITS:-/usr/local/fpc-trunk/lib/fpc/3.3.1/units/x86_64-linux}

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

# ── Search paths ────────────────────────────────────────────────────────────
# Every path is resolved and CHECKED before anything is compiled. A missing
# search path is not a code failure and does not read like one: fpc reports it
# as "Can't find unit X", which sends you looking at source. Reporting it here,
# once, by name, is the whole reason this section exists.
#
# Each entry is tried at $ROOT/<p> first and $ROOT/patches/<p> second, because
# during development patches/ was the source of record for the nghttp2 units
# and some checkouts still have no repo-root copy.
MISSING=()
FPCFLAGS=(
  # -n is NOT optional: without it fpc still reads /etc/fpc.cfg, which points
  # at the DISTRO 3.2.2 unit tree. Trunk then loads 3.2.2 .ppu files for
  # anything not in the explicit list below and dies with "PPU Invalid Version
  # 207 expecting 208" — an error that names a unit, not the config file that
  # actually caused it.
  # NO -Sh. It makes ansistring the default `string`, which changes generic
  # instantiations and therefore FPC's mangled symbol names — units end up
  # compiled in incompatible string contexts and the link fails with
  # "undefined reference to HORSE.CORE.PARAM$_$TOPENADDRESSING$..." style
  # errors that look like missing source, not a switch.
  # -Sc enables C-style assignment operators (+=, -=, *=, /=). Needed only by
  # LazUtils, pulled in below for `Masks`: its lazutf8.pas uses them and the
  # unit's own mode directive does not turn them on, so building that
  # dependency from source fails with "C styled assignment operators are
  # turned off". Lazarus supplies the switch via LazUtils' .lpk; a bare fpc
  # build must supply it here. Additive — it enables a syntax, so Horse, DCS
  # and mORMot sources are unaffected.
  -n -MDelphi -O2 -Sc
)

# Appends -Fu / -Fi for a path under ROOT, recording it if absent. Deliberately
# NOT a command substitution: $(...) runs in a subshell, so appends to MISSING
# from inside one would be silently discarded and the preflight would pass.
_resolve() {
  if   [[ -d "$ROOT/$1" ]];         then RESOLVED="$ROOT/$1"; return 0
  elif [[ -d "$ROOT/patches/$1" ]]; then RESOLVED="$ROOT/patches/$1"; return 0
  fi
  RESOLVED=""; MISSING+=("$1"); return 1
}
U() { _resolve "$1" && FPCFLAGS+=("-Fu$RESOLVED"); }
I() { _resolve "$1" && FPCFLAGS+=("-Fi$RESOLVED"); }

U horse/src
U horse-provider-crosssocket/src
U horse-provider-mormot/src
U horse-provider-nghttp2/src
U Delphi-nghttp2/src
U Delphi-Cross-Socket/Net
U Delphi-Cross-Socket/Utils
# DTF.* — the Delphi-to-FPC compatibility shims DCS's own units pull in
# (DTF.RTL, DTF.StaticZLib). FPC-only, so a Delphi build never reveals that
# this path is missing.
U Delphi-Cross-Socket/DelphiToFPC
# mORMot2 splits its units across four directories. src/lib holds mormot.lib.z,
# which mormot.core.zip pulls in; src/crypt holds mormot.crypt.core, which
# mormot.net.client pulls in. Omit either and the build dies deep inside mORMot
# with no hint that a search path is what is missing — the crypt one cost both
# mORMot rows of the 2026-08-17 run.
U mORMot2/src/core
U mORMot2/src/net
U mORMot2/src/crypt
U mORMot2/src/lib
U horse-request-guard/src
U horse-security-headers/src
# INCLUDE path (-Fi), not a unit path: Delphi-Cross-Socket's units start with
# {$I zLib.inc} and that file sits at the DCS repo root, not beside them.
# Missing it fails as "Cannot open include file", which reads like a broken
# checkout rather than a missing flag.
I Delphi-Cross-Socket

# Relative to this directory, not to ROOT.
FPCFLAGS+=("-FuCommon")

# ── LazUtils, for the CrossSocket rows only ─────────────────────────────────
# Delphi-Cross-Socket's Utils.IOUtils has `Masks` in its uses clause (one call,
# MatchesMask). On Delphi that is System.Masks, in the RTL. On FPC it is NOT an
# RTL unit at all — it lives in Lazarus's LazUtils. DCS's FPC users normally
# build through the Lazarus IDE, so a bare-fpc build like this one is the only
# place it shows up, and it shows up as "Can't find unit Masks used by
# Utils.IOUtils": a unit name with no clue that it belongs to a different
# product. Both CrossSocket rows failed on it on 2026-08-17.
#
# SOURCE directory, not the prebuilt lib/: LazUtils' .ppu are compiled by
# whatever fpc Lazarus was installed with — typically distro 3.2.2 — and mixing
# those into a trunk build gives "PPU Invalid Version 207 expecting 208".
MASKS_DIR=""
MASKS_HOW=""

# 1. The trunk unit tree itself. Cheapest to check, and if some FPC package
#    does ship masks.ppu the whole Lazarus question disappears — the build
#    already had fcl-base on its search path and still failed, which is
#    evidence it is not there, but evidence is not the same as a look.
if [[ -z "$MASKS_DIR" && -d "$TU" ]]; then
  _m=$(find "$TU" -maxdepth 2 -name 'masks.ppu' -print -quit 2>/dev/null)
  [[ -n "$_m" ]] && { MASKS_DIR=$(dirname "$_m"); MASKS_HOW="fpc trunk package"; }
fi

# 2. LazUtils source, from LAZARUS_DIR or the usual prefixes.
if [[ -z "$MASKS_DIR" ]]; then
  for _c in ${LAZARUS_DIR:+"$LAZARUS_DIR/components/lazutils"} \
            ${LAZARUS_DIR:+"$LAZARUS_DIR"} \
            /usr/share/lazarus/*/components/lazutils \
            /usr/lib/lazarus/*/components/lazutils \
            /usr/local/share/lazarus/*/components/lazutils \
            /usr/share/lazarus/components/lazutils \
            /usr/lib/lazarus/components/lazutils \
            /usr/local/lib/lazarus/components/lazutils \
            /opt/lazarus/components/lazutils \
            "$HOME"/lazarus/components/lazutils; do
    if [[ -f "$_c/masks.pas" || -f "$_c/masks.pp" ]]; then
      MASKS_DIR="$_c"; MASKS_HOW="lazutils source"; break
    fi
  done
fi

# 3. Last resort: a bounded search of the usual roots. Bounded because an
#    unbounded find over $HOME on this filesystem is measured in minutes.
if [[ -z "$MASKS_DIR" ]]; then
  _m=$(find /usr /opt /usr/local "$HOME" -maxdepth 6 \
            \( -name 'masks.pas' -o -name 'masks.pp' \) -print -quit 2>/dev/null)
  [[ -n "$_m" ]] && { MASKS_DIR=$(dirname "$_m"); MASKS_HOW="found by search"; }
fi

if [[ -n "$MASKS_DIR" ]]; then
  FPCFLAGS+=("-Fu$MASKS_DIR" "-Fi$MASKS_DIR")
fi

# ── CnPack, for the CrossSocket rows ────────────────────────────────────────
# Utils.Hash.pas uses CnMD5/CnSHA1/CnSHA2 from the subset the DCS fork vendors
# to be boss-installable. -Fi as well as -Fu: every CnPack unit opens
# {$I CnPack.inc}, which lives in CnPack/Common, and a unit path does not
# satisfy an include.
if [[ -d "$ROOT/Delphi-Cross-Socket/CnPack/Common" ]]; then
  FPCFLAGS+=("-Fu$ROOT/Delphi-Cross-Socket/CnPack/Common"
             "-Fu$ROOT/Delphi-Cross-Socket/CnPack/Crypto"
             "-Fi$ROOT/Delphi-Cross-Socket/CnPack/Common")
fi

# Trunk RTL units, mirroring build-fpc.sh, plus the extra packages the bench
# servers reach that the nghttp2 test programs do not: fcl-xml (htmlelements,
# via CustWeb), users (pwd, via mormot.core.os), libffi (ffi.manager, via the
# gRPC registry).
for _u in rtl rtl-console rtl-objpas rtl-extra rtl-generics fcl-base fcl-web \
          fcl-json regexpr pthreads openssl fcl-net hash fcl-xml users libffi \
          fcl-process fcl-db paszlib; do
  FPCFLAGS+=("-Fu$TU/$_u")
done

# ── Units whose package directory is not guessable ──────────────────────────
# Located by searching for the .ppu rather than by adding every $TU/*/ dir.
# build-dcs-tests.sh does add them all, and can afford to: it only has to link.
# Here a duplicate unit name resolving to the wrong package would silently
# change WHAT IS BEING MEASURED, so this stays a named list — the list just no
# longer has to encode which package ships each unit.
#
# `zlib`: Utils.Hash.pas has an UNGUARDED `ZLib` in its uses clause, where
# every other DCS unit branches to DTF.StaticZLib under {$IFDEF DELPHI}. It is
# not in paszlib, which is why listing paszlib above was not enough — this
# blocked both CrossSocket rows.
for _need in zlib; do
  _hit=$(find "$TU" -maxdepth 2 -name "$_need.ppu" -print -quit 2>/dev/null)
  if [[ -n "$_hit" ]]; then
    _d=$(dirname "$_hit")
    [[ " ${FPCFLAGS[*]} " == *" -Fu$_d "* ]] || FPCFLAGS+=("-Fu$_d")
  else
    echo "WARNING: unit '$_need' not found under $TU — the CrossSocket rows" >&2
    echo "         will fail with \"Can't find unit ZLib used by Utils.Hash\"." >&2
  fi
done

if [[ $DO_BUILD -eq 1 ]]; then
  # ── Preflight ─────────────────────────────────────────────────────────────
  FATAL=0
  if [[ ! -x "$FPCBIN" ]]; then
    echo "ERROR: trunk fpc not found at $FPCBIN" >&2
    echo "       Set TRUNK_FPC (and TRUNK_UNITS), as build-fpc.sh documents." >&2
    echo "       Do NOT fall back to a PATH fpc: 3.2.2 cannot build the" >&2
    echo "       nghttp2 targets and would silently drop them from the run." >&2
    FATAL=1
  elif [[ ! -d "$TU/rtl" ]]; then
    echo "ERROR: TRUNK_UNITS does not look like a unit tree: $TU" >&2
    echo "       Expected $TU/rtl to exist. Find rtl/system.ppu under your" >&2
    echo "       trunk install; TRUNK_UNITS is that file's directory with" >&2
    echo "       /rtl removed." >&2
    FATAL=1
  fi
  if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo "ERROR: ${#MISSING[@]} search path(s) not found under $ROOT" >&2
    printf '         %s\n' "${MISSING[@]}" >&2
    echo "       (each was also tried under $ROOT/patches/)" >&2
    FATAL=1
  fi
  [[ $FATAL -eq 0 ]] || exit 1

  FPCVER=$("$FPCBIN" -iV 2>/dev/null)
  case "$FPCVER" in
    3.3.*) ;;
    *) echo "WARNING: $FPCBIN reports $FPCVER, not 3.3.x trunk." >&2
       echo "         The nghttp2 rows will not build. Continuing." >&2 ;;
  esac
  if [[ -z "$MASKS_DIR" ]]; then
    echo "WARNING: no 'masks' unit found — the two CrossSocket rows will fail" >&2
    echo "         with \"Can't find unit Masks used by Utils.IOUtils\"." >&2
    echo "         It is a Lazarus LazUtils unit, not FPC RTL. Either install" >&2
    echo "         Lazarus, or point LAZARUS_DIR at a checkout, or clone just" >&2
    echo "         the sources:" >&2
    echo "           git clone --depth 1 https://gitlab.com/freepascal.org/lazarus/lazarus.git ~/lazarus" >&2
    echo "           LAZARUS_DIR=~/lazarus ./run-p1.sh --build" >&2
  fi
  echo "fpc:   $FPCBIN ($FPCVER)"
  echo "root:  $ROOT"
  echo "masks: ${MASKS_DIR:-<none>}${MASKS_HOW:+  ($MASKS_HOW)}"
  echo

  for row in "${SERVERS[@]}"; do
    IFS='|' read -r NAME DIR LPR DEF PORT PROTO FW <<< "$row"
    echo "building $NAME ..."
    # WIPE, not mkdir -p. FPC's .ppu cache does not account for changed
    # compiler switches any more than it does for changed -d defines, and this
    # directory accumulates units built with -Sh, without -Sh, under distro
    # 3.2.2 and under trunk. fpc happily reuses whichever it finds "current",
    # producing objects from incompatible string and generic contexts — which
    # links as
    #   undefined reference to HORSE.CORE.PARAM$_$TOPENADDRESSING$...
    # i.e. a missing symbol that is in fact present, just mangled from a
    # different compilation context.
    UNITDIR="$BIN/units-$NAME"; rm -rf "$UNITDIR"; mkdir -p "$UNITDIR"
    DEFARG=(); [[ -n "$DEF" ]] && DEFARG=("-d$DEF")
    # Separate unit dir per server: FPC's .ppu cache does NOT account for -d
    # changes, so a shared dir silently reuses units built with the wrong
    # provider define and the binary serves from a transport you did not pick.
    if ! "$FPCBIN" "${FPCFLAGS[@]}" "${DEFARG[@]}" -FU"$UNITDIR" -o"$BIN/$LPR" \
             "$DIR/$LPR.lpr" > "$BIN/$NAME.build.log" 2>&1; then
      echo "  FAILED — see $BIN/$NAME.build.log"
      grep -E 'Fatal|Error' "$BIN/$NAME.build.log" | head -5 | sed 's/^/    | /'
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

port_free()  { ! ss -ltn 2>/dev/null | grep -q ":$1 "; }
port_bound() {   ss -ltn 2>/dev/null | grep -q ":$1 "; }

# `kill -0` succeeds on a ZOMBIE — a child that exited but has not been reaped
# — so a server that died at startup passes it, and the harness then walks into
# an h2load that can never connect. /proc's state field tells them apart.
alive() {
  local pid=$1 st
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  st=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null)
  [[ "$st" != "Z" ]]
}

# Every h2load call is wrapped. Without this one unresponsive server hangs the
# whole matrix with no output — which is exactly what happened, twice.
row_fail() {   # <name> <proto> <fw> <reason>
  echo "| $1 | $2 | $3 | _$4_ | | | | |" | tee -a "$OUT"
}

# median of stdin (one number per line)
median() { sort -n | awk '{a[NR]=$1} END{ if(NR==0){print 0} else if(NR%2){print a[(NR+1)/2]} else {printf "%.0f", (a[NR/2]+a[NR/2+1])/2} }'; }

{
  echo "# Bench P1 — framework floor + per-request floor (Linux)"
  echo
  echo "Plan: \`plans/bench-plan-all-providers.md\` phases S8 + S1."
  echo
  echo "- host: \`$(uname -srm)\`, $(nproc) cores"
  echo "- compiler: \`$("$FPCBIN" -iV 2>/dev/null || echo unknown)\` at \`$FPCBIN\`"
  echo "- load: h2load, \`-n $REQS -c $CONNS\`, one request in flight per connection"
  echo "- runs per cell: $RUNS (median reported)"
  echo "- worker pool pinned to $WORKERS everywhere it applies"
  echo
  echo "**nghttp2 rows are HTTP/2; all others are HTTP/1.1.** On this scenario"
  echo "HTTP/2 is expected to lose — it pays for framing, HPACK and per-stream"
  echo "state that HTTP/1.1 keep-alive does not. Do not rank across protocols"
  echo "here; see S4 in phase P2 for the scenario HTTP/2 exists for."
  echo
  echo "This rig's timing noise floor is roughly 20%. Establish it with a"
  echo "same-binary A/B before treating any delta below that as real."
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

  if ! alive "$SRV_PID"; then
    row_fail "$NAME" "$PROTO" "$FW" "server exited at startup"
    tail -3 "$BIN/$NAME.run.log" | sed 's/^/    | /'
    wait "$SRV_PID" 2>/dev/null; SRV_PID=""
    continue
  fi
  if ! port_bound "$PORT"; then
    row_fail "$NAME" "$PROTO" "$FW" "up but not listening on $PORT"
    tail -3 "$BIN/$NAME.run.log" | sed 's/^/    | /'
    kill -TERM "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null; SRV_PID=""
    continue
  fi

  H2ARGS=(-n "$REQS" -c "$CONNS")
  [[ "$PROTO" == "h1" ]] && H2ARGS+=(--h1) || H2ARGS+=(-m 1)

  # One request, with a hard cap, before committing to the run. A server that
  # accepts and never answers is turned into one skipped row instead of a
  # hung matrix.
  PROBE=$(timeout 15 h2load "${H2ARGS[@]/-n $REQS/}" -n 1 -c 1 \
            "http://127.0.0.1:$PORT/ping" 2>&1); PRC=$?
  if [[ $PRC -ne 0 ]] || ! grep -qE '1 succeeded' <<< "$PROBE"; then
    if [[ $PRC -eq 124 ]]; then
      row_fail "$NAME" "$PROTO" "$FW" "no reply — h2load hung on 1 request"
    else
      row_fail "$NAME" "$PROTO" "$FW" "probe failed (h2load rc=$PRC)"
    fi
    echo "$PROBE" | tail -4 | sed 's/^/    h2load | /'
    tail -4 "$BIN/$NAME.run.log" | sed 's/^/    server | /'
    kill -TERM "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null; SRV_PID=""
    continue
  fi

  # Warm-up, discarded: context pools and thread pools have startup costs that
  # inflate the first few hundred requests.
  timeout 120 h2load "${H2ARGS[@]/-n $REQS/}" -n 2000 -c 20 \
    "http://127.0.0.1:$PORT/ping" > /dev/null 2>&1

  RPS_F=$(mktemp); P50_F=$(mktemp); P99_F=$(mktemp)
  CPU_TOTAL=0
  for ((r = 1; r <= RUNS; r++)); do
    CPU_BEFORE=$(ps -o cputimes= -p "$SRV_PID" 2>/dev/null | tr -d ' ')
    LOGF=$(mktemp)
    T0=$(date +%s)
    OUTPUT=$(timeout 180 h2load "${H2ARGS[@]}" --log-file="$LOGF" \
             "http://127.0.0.1:$PORT/ping" 2>&1)
    T1=$(date +%s)
    CPU_AFTER=$(ps -o cputimes= -p "$SRV_PID" 2>/dev/null | tr -d ' ')

    echo "$OUTPUT" | grep -oE '[0-9.]+ req/s' | grep -oE '^[0-9.]+' | head -1 \
      >> "$RPS_F"

    # Percentiles come from the per-request log, NOT from h2load's summary
    # line — that line reports min/max/mean/sd and has no percentiles in it at
    # all. Reading its columns as P50/P99 would put two differently named
    # numbers in the table, which is the same class of error as an unlabelled
    # configuration: quietly wrong, and invisible in the output.
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
    rm -f "$LOGF.sorted" "$LOGF"

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
