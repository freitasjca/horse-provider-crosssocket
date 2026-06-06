# Test protocol — the keep-alive + response-header 500 is a Horse **Indy-provider** defect (CrossSocket/mORMot are unaffected)

> ⚠️ **CORRECTION (this supersedes earlier drafts of this file).** The defect is
> **Indy-only**. Correctly-built CrossSocket and mORMot providers serve the same
> header middleware + keep-alive + c=100 at **0%**; only Indy shows ~60%. Earlier
> "all three providers / Horse-common" claims came from **mis-built CrossSocket/mORMot
> binaries that were silently running Indy** (`HORSE_PROVIDER_*` not effective; stale
> `Horse.dcu`). The decisive comparison is no longer "Horse vs raw transport" — it is
> **Horse-Indy (fails) vs Horse-CrossSocket/mORMot (pass)**.

## Resume

**Problem & conclusion:** Any header-adding middleware (SecurityHeaders via
`Res.AddHeader`, or CORS via `Res.RawWebResponse.SetCustomHeader`) makes the Horse
**Indy provider** return **HTTP 500** for **~60%** of requests when three conditions
hold together — HTTP keep-alive reuse, concurrency ≥ ~40, and response headers being
added. The failures are generated **below `HandlerAction`**, in the
Indy/`TIdHTTPWebBrokerBridge` dispatch layer (every request that reaches `HandlerAction`
returns 200, zero exceptions). The **CrossSocket and mORMot providers are unaffected
(0%)** on the identical test, as are the raw transports — so the fault is the Horse
**Indy provider** (WebBroker bridge + single shared `THorseWebModule`), **not** the
transports and **not** Horse's shared response code. Remove any one trigger and it
drops to ~0–2% (bare ~2%, no keep-alive via ApacheBench ~1%, single/sequential
connection 0%). Ruled out by experiment: pipeline race, host saturation, Debug-build,
post-`Send` timing, header accumulation, and "all three transports" (a mis-build).
**Practical upshot:** use the **CrossSocket or mORMot provider** for header middleware
under high concurrent keep-alive.

## Objective

Show that the "~60% HTTP 500 under concurrent keep-alive when a middleware adds
response headers" defect is specific to the **Horse Indy/Console provider**, and that
the **CrossSocket and mORMot providers are unaffected**.

## The proof in one line

Same header middleware, same keep-alive, same c=100 — only the **provider** differs:

| Provider | 5xx (keep-alive, c=100) |
|---|---|
| **Horse + Indy** | **~60%**  (FAILS) |
| Horse + CrossSocket | **0%**  (FINE) |
| Horse + mORMot | **0%**  (FINE) |
| raw CrossSocket / mORMot (no Horse) | **0%**  (FINE) |

Indy fails while the other Horse providers and the raw transports are clean → the
defect is in the **Horse Indy provider** (WebBroker bridge), not the transports and
not Horse's shared code.

> **Build correctly or this test lies.** A "CrossSocket"/"mORMot" binary that does not
> have `HORSE_PROVIDER_*` effective silently runs Indy and will show ~60% — making the
> defect look provider-common when it is Indy-only. Verify each binary's real provider
> by behaviour (CrossSocket/mORMot must be 0%, Indy ~60%) before trusting the result.

## Background: keep-alive vs no-keep-alive

Keep-alive is about whether the **TCP connection is reused** across HTTP requests.

**No keep-alive (`Connection: close`)** — each request gets its own brand-new TCP
connection, used once and closed:

```
open TCP -> request -> response -> CLOSE
open TCP -> request -> response -> CLOSE      (a new connection every time)
```
One TCP handshake per request; slower; every request hits a **fresh, clean**
connection/response state on the server.

**Keep-alive (`Connection: keep-alive`, the HTTP/1.1 default)** — the same TCP
connection is reused for many sequential requests:

```
open TCP -> req -> resp -> req -> resp -> req -> resp -> ... -> CLOSE
            \____________ same connection, reused ____________/
```
One handshake amortized over many requests; faster; how browsers and real production
clients work. Critically, the server keeps **per-connection state** alive between
requests on that socket.

**Why this gates the bug:** the defect is that the *previous* request's header-laden
response leaves the *reused* connection's state corrupted, breaking the *next*
request on that same socket. With no keep-alive there is no "previous request state"
to corrupt (fresh connection each time), so the bug cannot fire. Reuse alone is not
enough either — you need **many reused connections hammered concurrently** to hit the
race (a single sequential `curl` reuse is fine).

We isolate these factors by switching load tools:

| Tool | Behaviour | Role |
|---|---|---|
| `bombardier --http1` | keep-alive ON — reuses ~100 connections aggressively | exposes the defect (~60%) |
| ApacheBench (`ab`) | keep-alive OFF — fresh connection per request | control (~1%) |
| `curl` (two URLs) | keep-alive ON but sequential (one connection, one at a time) | control (0%) |

---

## Prerequisites

1. **Build (Release, Win64)** these bench binaries (all live in one folder, e.g.
   `C:\lang\Repo\bin\Win64\Release`):
   - `HorseBenchIndy.exe`, `HorseBenchCrossSocket.exe`, `HorseBenchMormot.exe`
     (support `--headers-only`, `--cors`, `--middleware`)
   - `HorseBenchRawCrossSocket.exe`, `HorseBenchRawMormot.exe`
     (support `--headers` — adds the same 5 headers natively, no Horse)
2. **Tools**:
   - bombardier at `c:\tools\bombardier\bombardier.exe`
   - ApacheBench (`ab`) at `c:\tools\ab\ab.exe` (or on PATH)
   - `curl` (ships with Windows 10/11)
3. **Environment** (keep it consistent; the defect is power-plan independent but a
   stable box gives clean numbers):
   - Pause ESET / AV real-time scanning if present.
   - Close other load. Run from `cd C:\lang\Repo\bin\Win64\Release`.
   - Note the active power plan (`powercfg /getactivescheme`) in your results.

### Server / port reference

| Server | bare port | with-headers/middleware port |
|---|---|---|
| HorseBenchIndy | 9001 | 9011 (`--headers-only` / `--cors` / `--middleware`) |
| HorseBenchCrossSocket | 9002 | 9012 |
| HorseBenchMormot | 9003 | 9013 |
| HorseBenchRawCrossSocket (no Horse) | 9004 | 9004 (`--headers`) |
| HorseBenchRawMormot (no Horse) | 9005 | 9005 (`--headers`) |

### One-server-at-a-time rule

Every measurement below runs **exactly one** server. Before each manual start, kill
any leftovers:

```bat
taskkill /F /IM HorseBenchIndy.exe          >nul 2>&1
taskkill /F /IM HorseBenchCrossSocket.exe   >nul 2>&1
taskkill /F /IM HorseBenchMormot.exe        >nul 2>&1
taskkill /F /IM HorseBenchRawCrossSocket.exe>nul 2>&1
taskkill /F /IM HorseBenchRawMormot.exe     >nul 2>&1
```

(The helper scripts `bench-isolation-check.bat`, `bench-middleware-ab.bat`,
`bench-concurrency-sweep.bat`, and `bench-latency-delta.bat` already kill + launch
for you; the manual commands below are for the raw-transport steps those scripts do
not cover.)

---

## TEST SEQUENCE

Run in order. Record the `5xx` (and `2xx`) from each run in the results table at the
end. `n=200000`, `c=100` throughout unless noted.

### PART A — Establish the defect exists (Horse **Indy** provider)

> Use the **Indy** provider here — it is the one that exhibits the defect.
> (CrossSocket/mORMot would show 0% and prove nothing.)

**A1. Horse Indy bare, keep-alive (baseline).**
```bat
HorseBenchIndy.exe
c:\tools\bombardier\bombardier.exe -c 100 -n 200000 --http1 http://127.0.0.1:9001/ping
```
Expect: **~2% 5xx** (baseline noise). Kill the server.

**A2. Horse Indy + headers, keep-alive (defect).**
```bat
HorseBenchIndy.exe --headers-only
c:\tools\bombardier\bombardier.exe -c 100 -n 200000 --http1 http://127.0.0.1:9011/ping
```
Expect: **~60% 5xx**. Kill the server.
=> Adding response headers (through the Horse Indy provider) under keep-alive breaks it.

### PART B — Prove keep-alive is the trigger (Indy)

**B1. Horse Indy + headers, NO keep-alive (ApacheBench).**
```bat
HorseBenchIndy.exe --headers-only
c:\tools\ab\ab -c 100 -n 200000 http://127.0.0.1:9011/ping
```
(`ab` is slow — a fresh TCP connection per request. You may use `-n 50000` to save
time; the *rate* is what matters.) Read `Non-2xx responses`.
Expect: **~1%**. Kill the server.
=> Remove keep-alive and the defect vanishes. Keep-alive is required.

### PART C — THE DECISIVE TEST: Indy fails, CrossSocket/mORMot pass (correctly built)

Run the five-mode A/B for each provider (kills + launches for you, prints bare /
guard / headers / cors / both, and the `Active provider class` banner per phase):
```bat
bench-middleware-ab.bat indy
bench-middleware-ab.bat crosssocket
bench-middleware-ab.bat mormot
```
Expected:

| Mode | Indy | CrossSocket | mORMot |
|---|---|---|---|
| bare | ~2% | **0%** | **0%** |
| headers-only | **~59%** | **0%** | **0%** |
| cors | **~61%** | **0%** | **0%** |

=> **Only Indy fails.** CrossSocket and mORMot serve the identical header middleware +
keep-alive + c=100 at **0%**. The defect is the Horse **Indy provider**, not the
transports.

> ⚠️ **Verify the build per phase.** If `crosssocket`/`mormot` shows ~60%, that binary
> is silently running Indy (`HORSE_PROVIDER_*` not effective). It must be 0% to be a
> genuine CrossSocket/mORMot binary. Watch the `Active provider class` banner and the
> result: 0% = real CrossSocket/mORMot, ~60% = mis-built Indy.

### PART D — Cross-check: transports are also fine without Horse

```bat
HorseBenchRawCrossSocket.exe --headers
c:\tools\bombardier\bombardier.exe -c 100 -n 200000 --http1 http://127.0.0.1:9004/ping
REM expect 0 5xx
HorseBenchRawMormot.exe --headers
c:\tools\bombardier\bombardier.exe -c 100 -n 200000 --http1 http://127.0.0.1:9005/ping
REM expect 0 5xx
```
The raw CrossSocket/mORMot transports also handle header-laden keep-alive at **0%** —
consistent with their Horse providers. Confirms the issue is **not** the transport
and **not** Horse's shared response code; it is the **Indy/WebBroker provider path**.

### PART E — Supporting evidence (optional, strengthens the case)

**E1. Single reused connection is well-formed (rules out a deterministic bug).** (Indy)
```bat
HorseBenchIndy.exe --headers-only
curl -v http://127.0.0.1:9011/ping http://127.0.0.1:9011/ping
```
Expect: two identical, well-formed 200 responses (5 headers each, `Content-Length: 4`,
`Connection: keep-alive`, connection reused). => not framing/accumulation; needs
*concurrency*. Kill the server.

**E2. Concurrency onset curve (shows the threshold).** (Indy)
```bat
bench-concurrency-sweep.bat indy
```
Expect: 0% up to c~40, then a steep climb to ~60% at c=100.

**E3. Different header API also fails (whole response-header path).** (Indy)
```bat
HorseBenchIndy.exe --cors
c:\tools\bombardier\bombardier.exe -c 100 -n 200000 --http1 http://127.0.0.1:9011/ping
```
Expect: **~60% 5xx** (CORS uses `SetCustomHeader`, not `AddHeader`). Kill the server.

**E4. The 500s are pre-pipeline (Horse never routes them).**
Rebuild with the `_diag` server, then:
```bat
HorseBenchIndy_diag.exe --headers-only
c:\tools\bombardier\bombardier.exe -c 100 -n 200000 --http1 http://127.0.0.1:9011/ping
```
Ctrl-C and read the summary: `entered == 2xx` exactly, `exceptions = 0` => the 500s
are generated before the Horse pipeline runs.

---

## Results table (fill in)

| # | Server | Horse? | headers? | tool | keep-alive | c | 5xx % | expected |
|---|---|---|---|---|---|---|---|---|
| A1 | **Indy** bare 9001 | yes | no | bombardier | yes | 100 | ____ | ~2% |
| A2 | **Indy** 9011 `--headers-only` | yes | yes | bombardier | yes | 100 | ____ | **~60%** |
| B1 | **Indy** 9011 `--headers-only` | yes | yes | **ab** | **no** | 100 | ____ | ~1% |
| C-cs | **CrossSocket** 9012 `--headers-only` | yes | yes | bombardier | yes | 100 | ____ | **0%** |
| C-mr | **mORMot** 9013 `--headers-only` | yes | yes | bombardier | yes | 100 | ____ | **0%** |
| D-raw | RawCrossSocket 9004 / RawMormot 9005 `--headers` | no | yes | bombardier | yes | 100 | ____ | **0%** |
| C-indy | Indy `bench-middleware-ab` | yes | yes | bombardier | yes | 100 | ____ | **~60%** |
| C-cs | CrossSocket `bench-middleware-ab` | yes | yes | bombardier | yes | 100 | ____ | **0%** |
| C-mr | mORMot `bench-middleware-ab` | yes | yes | bombardier | yes | 100 | ____ | **0%** |
| D-raw | RawCrossSocket/RawMormot `--headers` | no | yes | bombardier | yes | 100 | ____ | **0%** |
| E3 | Indy 9011 `--cors` | yes | yes | bombardier | yes | 100 | ____ | ~60% |

---

## How to read the result (the conclusion)

The claim "it is the Horse **Indy provider**, not the transports or Horse's shared
code" is **proven** when ALL of these hold:

1. **A2 fails (Indy), A1 is fine** -> adding response headers through the Horse Indy
   provider triggers it.
2. **B1 is fine (~1%)** -> the trigger requires keep-alive reuse, not the headers
   alone.
3. **C: Indy ~60% but CrossSocket and mORMot 0%** -> the *same middleware, headers,
   keep-alive, and concurrency* on the other Horse providers do **not** fail. The
   cause is **specific to the Indy provider**, not Horse's shared code.
4. **D: raw CrossSocket/mORMot 0%** -> the transports themselves are also fine, so it
   is not a transport bug either.

The decisive contrast is **Horse-Indy (~60%) vs Horse-CrossSocket/mORMot (0%)** on the
identical load: only the provider differs, so the defect is isolated to the **Horse
Indy/WebBroker provider**. (Earlier this file used "Horse vs raw transport" — that is
now insufficient, because Horse-CrossSocket/mORMot are *also* 0%.)

Supporting (E1-E4, on Indy) shows it is concurrency-gated (not a deterministic framing
bug), covers any header API (`AddHeader` and `SetCustomHeader`/CORS), and is emitted
**below `HandlerAction`** in the Indy/WebBroker layer (Horse's pipeline is clean).

> Full analysis and the retracted hypotheses: `bench/results/bench-analysis-report.md` §5.
> Ready-to-file upstream report: `bench/results/upstream-issue-keepalive-header-500.md`.
> Source-audit plan to locate the exact line: `plans/horse-keepalive-header-500-audit.md`.
