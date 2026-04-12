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
| 03 | POST | `/methods/post` | POST with JSON body |
| 04 | PUT | `/methods/put/42` | PUT + path parameter |
| 05 | DELETE | `/methods/delete/99` | DELETE + path parameter |
| 06 | PATCH | `/methods/patch/7` | PATCH + path parameter |
| 07 | HEAD | `/methods/head` | HEAD — no body, custom response header |
| 08 | GET | `/params/path/hello` | path parameter extraction |
| 09 | GET | `/params/query?name=...` | query string parsing |
| 10 | GET | `/cookies/set` | `Set-Cookie` response headers |
| 11 | GET | `/cookies/echo` | `Cookie` request header parsing |
| 12 | POST | `/upload` | multipart/form-data file upload |
| 13 | GET | `/download` | file download with `Content-Disposition` |
| 14 | GET | `/headers/echo` | custom request header echo |
