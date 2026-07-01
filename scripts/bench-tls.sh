#!/usr/bin/env bash
#
# bench-tls.sh  -  TLS / mutual-TLS throughput bench across all providers (Linux)
#
# Linux counterpart of bench-tls.bat. Benchmarks HTTPS for the three TLS-capable
# self-hosted providers built for Delphi Linux64 — CrossSocket, mORMot, ICS —
# driving them with HorseBenchTLSClient.
#
# Usage:
#   ./bench-tls.sh            one-way TLS
#   ./bench-tls.sh --mtls     mutual TLS (servers + client present certs)
#
# Prerequisites: the bench binaries + a certs/ folder next to them. Set BIN_DIR
# to override autodetection.
#
# TLS ports (bare + 30): CrossSocket 9032   mORMot 9033   ICS 9039
set -uo pipefail

MODE="${1:-}"
SRVFLAG="--tls"; CLIFLAG=""
if [[ "$MODE" == "--mtls" ]]; then SRVFLAG="--mtls"; CLIFLAG="--mtls"; fi

HERE="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="${BIN_DIR:-}"
if [[ -z "$BIN_DIR" ]]; then
  for d in "$HERE" "$HERE/../samples/bench/Linux64/Release" "$HERE/../Linux64/Release"; do
    [[ -x "$d/HorseBenchCrossSocket" ]] && BIN_DIR="$d" && break
  done
fi
if [[ -z "$BIN_DIR" || ! -x "$BIN_DIR/HorseBenchCrossSocket" ]]; then
  echo "ERROR: HorseBench binaries not found. Build them or set BIN_DIR." >&2
  exit 1
fi
echo "[bench-tls] Binaries: $BIN_DIR"
echo "[bench-tls] Mode    : $SRVFLAG"

# Ensure cert fixtures sit next to the binaries.
if [[ ! -f "$BIN_DIR/certs/server.crt" ]]; then
  if [[ -f "$HERE/../samples/bench/certs/server.crt" ]]; then
    mkdir -p "$BIN_DIR/certs"
    cp "$HERE"/../samples/bench/certs/* "$BIN_DIR/certs/"
  else
    echo "ERROR: certs/server.crt not found (run samples/bench/certs/gen-certs.sh)." >&2
    exit 1
  fi
fi

pids=()
cleanup() { for p in "${pids[@]:-}"; do kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT

echo "[bench-tls] Starting CrossSocket (9032), mORMot (9033), ICS (9039) with $SRVFLAG ..."
( cd "$BIN_DIR" && ./HorseBenchCrossSocket "$SRVFLAG" ) & pids+=($!)
( cd "$BIN_DIR" && ./HorseBenchMormot      "$SRVFLAG" ) & pids+=($!)
( cd "$BIN_DIR" && ./HorseBenchICS         "$SRVFLAG" ) & pids+=($!)

# Wait for the TLS ports.
ready=0
for _ in $(seq 1 10); do
  if (exec 3<>/dev/tcp/127.0.0.1/9032) 2>/dev/null && \
     (exec 3<>/dev/tcp/127.0.0.1/9033) 2>/dev/null && \
     (exec 3<>/dev/tcp/127.0.0.1/9039) 2>/dev/null; then
    ready=1; break
  fi
  sleep 1
done
[[ "$ready" == "0" ]] && echo "[bench-tls] WARNING: not all TLS ports came up; running anyway."

echo
"$BIN_DIR/HorseBenchTLSClient" $CLIFLAG
rc=$?

echo
echo "[bench-tls] Done (client exit=$rc)."
exit "$rc"
