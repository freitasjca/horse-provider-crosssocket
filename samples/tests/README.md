# Integration Test Projects

Two console programs that together form the integration test suite.

| Program | Role |
|---|---|
| `HorseCSTestServer.dpr` | HTTP server on `127.0.0.1:9100` — start first |
| `HorseCSTestClient.dpr` | Test runner — exits with `0` (all pass) or `N` (N failures) |

---

## Creating the .dproj files

The `.dpr` sources are committed. The `.dproj` project files must be created in the Delphi IDE and then committed. Create two separate console application projects with the settings below.

### HorseCSTestServer.dproj

**Project Options → Delphi Compiler → Conditional defines:**
```
HORSE_CROSSSOCKET
```

**Project Options → Delphi Compiler → Search path** (relative to this file's directory):
```
..\..\modules\horse\src
..\..\modules\Delphi-Cross-Socket\Net
..\..\modules\Delphi-Cross-Socket\Utils
..\..\modules\Delphi-Cross-Socket\OpenSSL
..\..\src
```

**Project Options → Delphi Compiler → Output directory:**
```
$(Platform)\$(Config)
```

**App type:** Console application (`{$APPTYPE CONSOLE}` is already in the .dpr)

---

### HorseCSTestClient.dproj

**Project Options → Delphi Compiler → Conditional defines:** *(none required)*

**Project Options → Delphi Compiler → Search path:**
```
..\..\modules\Delphi-Cross-Socket\Net
..\..\modules\Delphi-Cross-Socket\Utils
..\..\modules\Delphi-Cross-Socket\OpenSSL
```

**Project Options → Delphi Compiler → Output directory:**
```
$(Platform)\$(Config)
```

**App type:** Console application

---

## Running manually

```bat
cd horse-provider-crosssocket

REM 1. Install dependencies (once)
boss install

REM 2. Build both projects in the Delphi IDE (Win64 Release)

REM 3. Start the server (leave this window open)
samples\tests\Win64\Release\HorseCSTestServer.exe

REM 4. In a second window: run the client
samples\tests\Win64\Release\HorseCSTestClient.exe
REM Exit code 0 = all tests passed; N = N tests failed
echo Exit code: %ERRORLEVEL%
```

Or use the provided scripts from the repo root:

```bat
scripts\build.bat Release Win64
scripts\run-tests.bat Win64 Release
```

---

## Test coverage

| # | Method | Route | What is tested |
|---|---|---|---|
| 01 | GET | `/ping` | basic connectivity |
| 02 | GET | `/methods/get` | GET method routing |
| 03 | POST | `/methods/post` | POST with JSON body echo |
| 04 | PUT | `/methods/put/42` | PUT + path parameter |
| 05 | DELETE | `/methods/delete/99` | DELETE + path parameter |
| 06 | PATCH | `/methods/patch/7` | PATCH + path parameter |
| 07 | HEAD | `/methods/head` | HEAD — no body, custom response header |
| 08 | GET | `/params/path/hello` | single path parameter extraction |
| 09 | GET | `/params/query?name=...` | query string parsing |
| 10 | GET | `/cookies/set` | `Set-Cookie` response headers |
| 11 | GET | `/cookies/echo` | `Cookie` request header parsing |
| 12 | POST | `/upload` | multipart/form-data file upload |
| 13 | GET | `/download` | file download with `Content-Disposition` |
| 14 | GET | `/headers/echo` | custom request header echo |
| 15 | POST | `/methods/post` (empty body) | pool nil-body path — no crash after Reset |
| 16 | POST | `/echo/body` (64 KB body) | large body stream read without truncation |
| 17 | POST | `/echo/body` (A → ping → B) | sequential pool Reset — no body leakage |
| 18 | POST | `/echo/body` (×4 concurrent) | parallel pool context isolation — no cross-contamination |
| 19 | GET | `/params/multi/alpha/beta` | two path params in one route pattern |
| 20 | GET | `/does/not/exist` | 404 on unregistered route |
| 21 | GET | `/status/400` | explicit 4xx status code propagation + JSON body |
| 22 | GET | `/status/500` | explicit 5xx status code propagation + JSON body |
| 23 | GET | `/methods/get` | `Content-Type` response header verification |
| 24 | GET | `/response/large` | 65 536-byte response body transmitted without truncation |

Tests 15–18 are the primary regression suite for the CrossSocket context pool (`FIX-POOL-1`).  Test 18 fires four requests simultaneously — a broken pool will either crash the server or mix body content across responses.

**Test 18 implementation note — closure factory pattern:**  
The four `DoRequest` callbacks are dispatched via the nested `FireOne(AIdx, AHeaders)` helper rather than via `var LIdx := I` inline variables inside the loop body.  Delphi 10.3/10.4 may hoist an inline loop variable to a single shared heap location, causing all four closures to see the last-written value after the loop exits.  The nested procedure creates a fresh stack frame per call, guaranteeing each closure captures an independent `AIdx`.
