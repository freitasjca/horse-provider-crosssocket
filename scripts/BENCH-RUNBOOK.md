# Bench & test runbook

How to run **every** benchmark and integration test in this repo. Run all scripts
from the **repository root** (`horse-provider-crosssocket\`), not from inside
`scripts\`.

There are three families:

1. **Integration tests** — correctness (functional + TLS). Pass/fail, exit code = failures.
2. **Comparison benches** — in-repo drivers (`HorseBenchClient`, `HorseBenchTLSClient`) that sweep all providers and print RPS / percentile tables.
3. **Load / analysis benches** — `bombardier`-driven scripts that stress one or more providers to characterise throughput, latency, and the keep-alive header defect.

---

## 0. Prerequisites

| Need | For | Notes |
|---|---|---|
| Delphi 10.4+ (Win) / Delphi Linux64 | everything | `scripts\check-env.bat` verifies the toolchain |
| Built binaries | everything | `scripts\build.bat` builds the *tests*. The **bench servers** are built in the IDE — open `samples\bench\HorseBenchGroup.groupproj`, Build All, **Release / Win64**. |
| [`bombardier`](https://github.com/codesenberg/bombardier) | load/analysis scripts only | default path `c:\tools\bombardier\bombardier.exe` (edit `BOMB=` to change) |
| [`h2load`](https://github.com/nghttp2/nghttp2) | HTTP/2 bench (`bench-h2`) only | drives **both** protocols (`--h1` for HTTP/1.1); default `c:\tools\h2load\h2load.exe` or on `PATH`. Ships with nghttp2 |
| OpenSSL libs | TLS benches/tests | DLLs next to the exe (Win) / `libssl`+`libcrypto` (Linux); ICS bundles its own |
| `certs\` fixtures | TLS only | committed under `samples\bench\certs` and `tests\certs`; scripts copy them next to the binaries |

```bat
set DELPHI_ROOT=C:\Program Files (x86)\Embarcadero\Studio\22.0
scripts\check-env.bat
scripts\build.bat Release Win64
```

> **Where the bench exes land.** The bench `.dproj` files emit to
> `..\..\bin\Win64\Release` relative to the repo — i.e. a shared `bin\` one level
> *above* `horse-provider-crosssocket\` (here `C:\lang\Repo\bin\Win64\Release`).
> Every bench script searches that dir (plus `scripts\`, `..\samples\bench\Win64\Release\`
> and `..\Win64\Release\`), so once the group is built, run the scripts as-is. If
> you build somewhere else, drop the exes into `scripts\` or set `SERVERS_DIR`.
>
> **ICS, nghttp2 and HTTP.sys have no `.dproj` yet** — their `.dpr` sources exist
> (`Servers\ICS\`, `Servers\RawICS\`, `Servers\Nghttp2\`, `Servers\HttpSys\`) but you
> must create a Console project for each in the IDE, add it to `HorseBenchGroup.groupproj`,
> set the define (`HORSE_PROVIDER_ICS` / `HORSE_PROVIDER_NGHTTP2` / `HORSE_PROVIDER_HTTPSYS`)
> and the unit search paths (copy an existing bench `.dproj` and swap the provider). The
> Epoll server already ships as a Lazarus `.lpr` (`Servers\Lazarus\Epoll\`, built with FPC
> for the `.sh` ladder). Until a project exists the scripts print `[ERR] binary not found`
> for those rows and run everything else.

### Provider / port reference

| Provider | Bare | +middleware | TLS (`--tls`/`--mtls`) | Raw baseline |
|---|---|---|---|---|
| Indy | 9001 | 9011 | — | Raw-Indy 9006 |
| CrossSocket | 9002 | 9012 | **9032** | Raw-CrossSocket 9004 |
| mORMot | 9003 | 9013 | **9033** | Raw-mORMot 9005 |
| ICS | 9009 | 9019 | **9039** | **Raw-ICS 9010** |
| Epoll *(Linux)* | 9043 | 9053 | — | — |
| nghttp2 *(HTTP/2)* | 9041 | 9051 | — | Raw-nghttp2 9042 |
| HTTP.sys *(Windows)* | 9045 | 9055 | — | — |

> **Platform / protocol split — absence is not defeat:**
> - **nghttp2** speaks HTTP/2 (h2c); everyone else HTTP/1.1. It is *not* in the
>   bombardier ladder/scenarios (HTTP/1.1 drivers) — it has its own `h2load`
>   comparison, **§4**.
> - **ICS** and **HTTP.sys** are **Windows-only** — swept by the `.bat` ladder,
>   scenarios and (ICS also) the in-repo client/TLS bench; never by the Linux `.sh`.
>   HTTP.sys is kernel-mode and needs a **URL ACL** per port (it binds `127.0.0.1`;
>   grant `netsh http add urlacl url=http://127.0.0.1:9045/ user=Everyone`, and `:9055`,
>   or run elevated).
> - **Epoll** is **Linux-only** (Horse built-in, `SO_REUSEPORT`) — swept by
>   `bench-perf-ladder.sh` (FPC build), never by the `.bat` suite. 9053 (its mw port)
>   is shared with the nghttp2 middleware block, which is fine: one server runs at a time.

Integration-test ports are separate: functional **9100**, CrossSocket TLS **9101**,
ICS TLS **9111**, mORMot TLS **9201**.

---

## 1. Integration tests (correctness)

### Functional suite — `run-tests.bat [Platform] [Config]`
```bat
scripts\run-tests.bat            REM Win64 Release, 14 tests on :9100
```
Starts `HorseCSTestServer`, health-checks `GET /ping`, runs `HorseCSTestClient`,
kills the server. **Exit code = failed tests (0 = all pass).**

### TLS / mutual-TLS suite — `run-tls-tests.bat [Platform] [Config]`
```bat
scripts\run-tls-tests.bat        REM two passes on :9101 — one-way then mutual TLS
```
Runs `HorseCSTLSTestServer`/`Client` with no arg (T1/T2 one-way) then `mtls`
(T3/T4 mutual). Copies `tests\certs` next to the binaries. **Exit code = failed
assertions.** mTLS pass needs the `Net.CrossSslSocket.*` patches (or the fork).

> mORMot and ICS ship the parallel `Horse{Mormot,ICS}TLSTest*` pairs in their **own
> repos** (ports 9201 / 9111). Build and run those from the respective repo; the
> client is identical (`mtls` argument, exit code = failures).

---

## 2. Comparison benches (RPS + percentiles, in-repo driver)

These need the **bench server projects built** (`samples\bench\Servers\*`). No
bombardier required.

### Plain HTTP — `HorseBenchClient`
Start the servers you want to compare, then run the client (it sweeps all providers ×
5 scenarios and writes a Markdown table):
```bat
REM in separate windows / background:
HorseBenchIndy.exe          &  HorseBenchIndy.exe --middleware
HorseBenchCrossSocket.exe   &  HorseBenchCrossSocket.exe --middleware
HorseBenchMormot.exe        &  HorseBenchMormot.exe --middleware
HorseBenchICS.exe           &  HorseBenchICS.exe --middleware
HorseBenchClient.exe
```
Scenarios: 1 `GET /ping` c=10, 2 `GET /ping` c=100, 3 `GET /ping` c=500,
4 `POST /echo` c=100, 5 `GET /alloc` c=100.

### HTTPS / mutual TLS — `bench-tls.bat` / `bench-tls.sh`
```bat
scripts\bench-tls.bat            REM one-way HTTPS  (CrossSocket :9032, mORMot :9033, ICS :9039)
scripts\bench-tls.bat --mtls     REM mutual TLS
```
```bash
scripts/bench-tls.sh             # Delphi-Linux64 builds
scripts/bench-tls.sh --mtls
```
Starts the three TLS bench servers with `--tls`/`--mtls`, runs `HorseBenchTLSClient`
(RPS + p50/p99 per provider for `GET /ping` and `POST /echo`), then stops them.
**Exit code = total errors.** Copies `samples\bench\certs` next to the binaries.

---

## 3. Load / analysis benches (bombardier)

All auto-detect the server binaries (same folder as the script, or
`..\samples\bench\Win64\Release`, or `..\Win64\Release`) and manage server
lifecycle themselves. Use **Release** builds.

### Full ladder — `bench-perf-ladder.bat [c] [n] [runs] [maxconn] [listenqueue]`
```bat
scripts\bench-perf-ladder.bat 100 200000 3
```
The headline comparison: every HTTP/1.1 provider × mode (bare / +headers / +cors,
plus mORMot `--async` and `--httpapi`), driven by bombardier. Writes a results table.
- **Windows (`.bat`):** Indy, CrossSocket, mORMot, **ICS**, **HTTP.sys** (+ raw baselines).
  HTTP.sys rows need the URL ACL above; a cell with no ACL reports `noListen` and the
  script prints the exact `netsh` fix.
- **Linux (`scripts\bench-perf-ladder.sh`):** CrossSocket, mORMot, FPC-HTTP and the
  built-in **Epoll** provider (FPC build) — no Indy/ICS/HTTP.sys (Windows-only).

nghttp2 is HTTP/2 and is benched separately in **§4**. Background reading:
`bench-perf-ladder-windows.md`, `bench-perf-ladder-linux.md`.

### Fixed scenarios — `bench-scenario1.bat` … `bench-scenario5.bat`
```bat
scripts\bench-scenario3.bat      REM GET /ping  c=500  n=500000 across all providers
```
| # | Request | c | n |
|---|---|---|---|
| 1 | `GET /ping` | 10 | 50 000 |
| 2 | `GET /ping` | 100 | 200 000 |
| 3 | `GET /ping` | 500 | 500 000 |
| 4 | `POST /echo` (256 B) | 100 | 100 000 |
| 5 | `GET /alloc` | 100 | 100 000 |

The scenarios now sweep 13 HTTP/1.1 endpoints (Indy / CrossSocket / mORMot / **ICS** /
**HTTP.sys** bare + middleware, plus the raw baselines). `run_bench_test.bat` launches
all 13 servers (bare + middleware) and runs the in-repo client (which now has an
HTTP.sys column too). HTTP.sys rows need its URL ACL, else they report connection errors.

### Defect characterisation (keep-alive + header middleware 5xx)
| Script | What it isolates | Usage |
|---|---|---|
| `bench-middleware-ab.bat` | which middleware drives the pre-pipeline 5xx (bare / guard-only / headers-only / cors / both), c=100 n=200000 | `scripts\bench-middleware-ab.bat [indy\|crosssocket\|mormot]` |
| `bench-isolation-check.bat` | bare vs middleware, same provider fully isolated — is it the box or the middleware? | `scripts\bench-isolation-check.bat [provider]` |
| `bench-concurrency-sweep.bat` | the **onset** concurrency of the 5xx race (`--headers-only`) | `scripts\bench-concurrency-sweep.bat [provider]` |
| `bench-latency-delta.bat` | per-request latency cost of middleware at c=1 (P50 delta) | `scripts\bench-latency-delta.bat [provider]` |

See `PROVE-HORSE-KEEPALIVE-DEFECT.md` for the analysis these support.

### Resource monitors (run alongside a bench)
```powershell
powershell -File scripts\bench-monitor.ps1     # CPU / RAM / handle sampling
powershell -File scripts\bench-resources.ps1   # per-process resource table
```

---

## 4. HTTP/2 vs HTTP/1.1 (h2load) — `bench-h2.bat` / `bench-h2.sh`

The nghttp2 provider speaks **HTTP/2**; everyone else speaks **HTTP/1.1**. That is
not a detail to normalise away — it decides what "efficient" means. So nghttp2 is
kept out of the bombardier ladder (an HTTP/1.1 driver) and gets its own harness
built on **`h2load`**, which speaks *both* protocols. Using one load generator for
both holds client-side cost constant, so only the server protocol varies — the whole
point (see `plans/bench-plan-all-providers.md`).

```bat
scripts\bench-h2.bat                REM S1 + S4, n=200000, all providers
scripts\bench-h2.bat 200000 s1      REM S1 only
scripts\bench-h2.bat 200000 s4      REM S4 only
```
```bash
scripts/bench-h2.sh                 # Linux: CrossSocket, mORMot, nghttp2 (no Indy/ICS)
WORKERS=8 scripts/bench-h2.sh       # pin the nghttp2 dispatch pool for a published run
```

Needs the new **`HorseBenchNghttp2`** server (`samples\bench\Servers\Nghttp2\`,
h2c on 9041 / 9051; Delphi port of the Lazarus `.lpr`) and the libnghttp2 runtime
(`nghttp2.dll` on PATH / `libnghttp2-14`). Drives nghttp2 natively and the HTTP/1.1
servers with `--h1`.

| Scenario | Load | Decides |
|---|---|---|
| **S1** Floor | `-c 10 -m 1` (h2 and h1 alike) | Per-request cost at one request in flight. **HTTP/2 is *expected* to lose** — framing / HPACK / per-stream state. Protocol cost, not a defect |
| **S4** Multiplexing | h2 `-c 10 -m 100`; h1 `-c 1000` | **Same 1 000 requests in flight**, different transport shapes. The scenario HTTP/2 exists for |

> **Never collapse the output to one winner.** Read it per scenario — the report is
> a winner *per workload class*. A trivial-route req/s ranking measures the wrong
> thing. Full `h2load` output per cell lands in `bench-h2-result.txt`.

---

## Quick recipes

```bat
REM Smoke test: functional + TLS correctness
scripts\build.bat Release Win64
scripts\run-tests.bat
scripts\run-tls-tests.bat

REM Compare providers over HTTP, then over HTTPS and mTLS
scripts\bench-perf-ladder.bat 100 200000 3
scripts\bench-tls.bat
scripts\bench-tls.bat --mtls
```

## Notes

- **TLS certs** are self-signed throwaway fixtures (`certs\gen-certs.sh` regenerates
  them). CrossSocket server-side mTLS needs the `Net.CrossSslSocket.*` patches or the
  fork; one-way TLS and mORMot/ICS mTLS work as-is.
- **Linux:** `bench-perf-ladder.sh` and `bench-tls.sh` cover the Delphi-Linux64 builds.
  The `.bat` defect scripts are Windows-only (they rely on `netstat`/`taskkill`).
- All scripts kill the servers they start on exit, even on interrupt — but a crash
  mid-run can leave a `HorseBench*` process; `taskkill /F /IM HorseBench*.exe` clears it.
