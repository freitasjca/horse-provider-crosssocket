# Lazarus / FPC param-test projects — horse-provider-crosssocket

FPC ports of the Delphi `tests/HorseCSParamTest{Server,Client}.dpr` programs.
Same routes, same port (**9100**), same test sections **A–I** — so the FPC
client (or the Delphi client) exercises an identical surface.

| File | Role |
|---|---|
| `HorseCSParamTestServer.lpr` | Console server on port 9100 — run first |
| `HorseCSParamTestClient.lpr` | Sequential test runner; exit code = number of failures |

## Why these are `.lpr` (and there are no `.lpi` here)

`.lpr` is the FPC program source — the substance of the port. The `.lpi`
(Lazarus project file) is IDE-managed XML carrying *your* machine's unit search
paths, so it is intentionally **not** committed here. Create it once per machine:

> **Project → New Project → Program**, then **Project → Add existing unit** →
> select the `.lpr`. Set the items below, then **Save**.

## Server vs client — the key FPC difference

- **Server** route handlers are plain **unit-scope procedures** registered with
  no `@` (e.g. `THorse.Get('/ping', RoutePing)`). This is the
  `Horse.BenchRoutes.pas` pattern and compiles on stock FPC **without**
  `HORSE_FPC_FUNCTIONREFERENCES`.
- **Client** uses `TCrossHttpClient`, whose callbacks are `reference to
  procedure`, and the helpers (`DoSync`, `DoMultipart`, `FireConc`) capture
  local state. That **requires an FPC with function-reference support** (the
  same toolchain the shipped `samples/bench/Client/Lazarus/HorseBenchClient.lpr`
  targets). If your FPC rejects the anonymous callbacks, use the **Delphi**
  client against this FPC server — the wire surface is identical.

## Required project settings

**Server** — Project Options → Compiler Options → Custom Options:
```
-dHORSE_PROVIDER_CROSSSOCKET
```
(legacy `-dHORSE_CROSSSOCKET` also works).

**Client** — no provider define needed (it is a pure HTTP client).

**Both** — add unit search paths (Project Options → Compiler Options → Paths →
*Other unit files*) to:
- `horse/src`
- `Delphi-Cross-Socket/Source` (+ `Net`, `Utils`, … per that repo's layout)
- `horse-provider-crosssocket/src`

**Leak detection** — FPC has no `ReportMemoryLeaksOnShutdown`; build the server
with `-gh` (heaptrc) to get a leak report on exit. Stop the server with
Ctrl-C / SIGTERM so `THorse.StopListen` drains in-flight work first, otherwise
heaptrc reports false positives.

## Run sequence (Linux)

```sh
lazbuild HorseCSParamTestServer.lpi      # after you create the .lpi
lazbuild HorseCSParamTestClient.lpi
./HorseCSParamTestServer &               # listens on 9100
./HorseCSParamTestClient                 # exit code = failures
kill -INT %1                             # clean shutdown
```
