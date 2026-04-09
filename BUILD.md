Below is an updated `BUILD.md` tailored for the `horse-provider-crosssocket` repository. It reflects the actual folder structure, dependency handling via Boss, and includes clear build steps for both the patched Horse fork and the provider package.

---

```markdown
# Building the Packages

This document explains the directory layout, build order, and CI/CD pipeline for the Horse CrossSocket provider and its required patched Horse fork.

---

## Repository layout

```
horse-provider-crosssocket/               ← this repository
├── src/
│   ├── Horse.Provider.CrossSocket.pas
│   ├── Horse.Provider.CrossSocket.Server.pas
│   ├── Horse.Provider.CrossSocket.Pool.pas
│   ├── Horse.Provider.CrossSocket.Request.pas
│   ├── Horse.Provider.CrossSocket.Response.pas
│   └── Horse.Provider.CrossSocket.WorkerPool.pas
├── packages/
│   └── provider/
│       ├── HorseProviderCrossSocket.dpk
│       ├── HorseProviderCrossSocket.dproj
│       └── boss.json                       (package-level manifest)
├── samples/
│   └── server.dpr
├── boss.json                               (top-level manifest consumed by Boss)
└── README.md
```

When you install the provider via Boss, two additional repositories are pulled into `modules/`:

```
modules/
├── horse/                                 ← patched fork (freitasjca/horse)
│   └── src/ ...
└── Delphi-Cross-Socket/                   ← fork with Boss support (freitasjca/Delphi-Cross-Socket)
    ├── Net/
    ├── Utils/
    ├── CnPack/
    └── ...
```

---

## Prerequisites

| Tool | Minimum version | Notes |
|---|---|---|
| Delphi | 10.4 Sydney | Inline `var`, `System.Threading` |
| MSBuild | ships with RAD Studio | Used for command‑line builds |
| Boss | latest | Optional, but simplifies dependency management |
| OpenSSL | 1.1.x or 3.x | DLLs only needed at runtime for HTTPS |

---

## Getting the source and dependencies

### Option A – Using Boss (recommended)

1. Clone this repository:
   ```bash
   git clone https://github.com/your-org/horse-provider-crosssocket.git
   cd horse-provider-crosssocket
   ```

2. Install dependencies:
   ```bash
   boss install
   ```
   This will create a `modules/` folder containing the patched Horse fork and the CrossSocket fork.

### Option B – Manual setup

Clone the required repositories side by side:

```bash
git clone https://github.com/freitasjca/horse.git
git clone https://github.com/freitasjca/Delphi-Cross-Socket.git
git clone https://github.com/your-org/horse-provider-crosssocket.git
```

The resulting folder structure should be:

```
your-workspace/
├── horse/
├── Delphi-Cross-Socket/
└── horse-provider-crosssocket/
```

---

## Build order

The two packages have a strict dependency order. **Horse (patched fork) must be built before HorseProviderCrossSocket.**

### Step 1 — Build the patched Horse fork

#### Using the Delphi IDE

1. Open `horse/packages/horse-fork/HorseCS.dproj`.
2. Build the project (Shift+F9). This compiles and registers the design‑time package.

#### Using MSBuild

```cmd
cd horse\packages\horse-fork

REM Win64 Release
msbuild HorseCS.dproj /t:Clean;Build /p:Config=Release;Platform=Win64

REM Win32 Release (if you target 32‑bit)
msbuild HorseCS.dproj /t:Clean;Build /p:Config=Release;Platform=Win32

REM Linux64 Release (requires cross‑compiler)
msbuild HorseCS.dproj /t:Clean;Build /p:Config=Release;Platform=Linux64
```

Output locations after a Win64 Release build:
```
horse\packages\horse-fork\bpl\Win64\Release\HorseCS.bpl
horse\packages\horse-fork\dcp\Win64\Release\HorseCS.dcp
horse\packages\horse-fork\dcu\Win64\Release\*.dcu
```

### Step 2 — Build HorseProviderCrossSocket

#### In the Delphi IDE

1. Open `horse-provider-crosssocket/packages/provider/HorseProviderCrossSocket.dproj`.
2. Build the project. Ensure the search path includes the output from Step 1 (usually the IDE will find it if the package is installed).

#### Using MSBuild

```cmd
cd horse-provider-crosssocket\packages\provider

REM Point to the location of the CrossSocket source (adjust path as needed)
SET CROSS_SOCKET_ROOT=..\..\..\Delphi-Cross-Socket

REM Win64 Release
msbuild HorseProviderCrossSocket.dproj /t:Clean;Build /p:Config=Release;Platform=Win64
```

The `.dproj` references `HorseCS.dcp` via `DCC_DcpSearchPath`; ensure Step 1 outputs are in the path before running Step 2.

---

## Debug builds

The provider pool uses compile‑time poison values in `{$IFDEF DEBUG}` blocks (see `Horse.Provider.CrossSocket.Pool.pas [SEC-8]`). To enable these:

```cmd
msbuild HorseCS.dproj /t:Build /p:Config=Debug;Platform=Win64
msbuild HorseProviderCrossSocket.dproj /t:Build /p:Config=Debug;Platform=Win64
```

In Debug mode, any code that reads a stale field from a recycled context object will read an obvious sentinel value (`$DEAD_POISONED_...`) rather than silently getting the previous request’s data.

---

## Using the provider in your application

1. Add `{$DEFINE HORSE_CROSSSOCKET}` to your project or in the `uses` clause before `Horse`.
2. Add `Horse.Provider.CrossSocket` to your `uses`.
3. Build and run as usual.

Example `server.dpr`:

```delphi
program MyAPI;

{$APPTYPE CONSOLE}
{$DEFINE HORSE_CROSSSOCKET}

uses
  Horse,
  Horse.Provider.CrossSocket;

begin
  THorse.Get('/ping',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.Send('pong');
    end);

  THorse.Listen(9000);
end.
```

---

## CI pipeline (GitHub Actions example)

```yaml
# .github/workflows/build.yml
name: Build packages

on: [push, pull_request]

jobs:
  build:
    runs-on: windows-latest

    steps:
      - uses: actions/checkout@v4
        with:
          submodules: recursive   # fetches dependencies if added as submodules

      - name: Set up RAD Studio environment
        # Use your licensed RAD Studio MSBuild environment here.
        # Community edition does not support command‑line builds.
        run: |
          echo "BDS=${{ secrets.BDS_PATH }}" >> $GITHUB_ENV
          echo "${{ secrets.BDS_PATH }}\bin" >> $GITHUB_PATH

      - name: Fetch dependencies via Boss
        run: |
          boss install

      - name: Build HorseCS (Win64 Release)
        working-directory: modules/horse/packages/horse-fork
        run: |
          msbuild HorseCS.dproj /t:Clean;Build /p:Config=Release;Platform=Win64

      - name: Build HorseProviderCrossSocket (Win64 Release)
        working-directory: packages/provider
        env:
          CROSS_SOCKET_ROOT: ..\..\modules\Delphi-Cross-Socket
        run: |
          msbuild HorseProviderCrossSocket.dproj /t:Clean;Build /p:Config=Release;Platform=Win64

      - name: Upload BPL artifacts
        uses: actions/upload-artifact@v4
        with:
          name: bpl-win64-release
          path: |
            modules/horse/packages/horse-fork/bpl/Win64/Release/*.bpl
            packages/provider/bpl/Win64/Release/*.bpl
```

---

## Unit ownership – avoiding "duplicate unit in package" errors

A unit may only be compiled into **one** package in Delphi. The split is:

| Unit | Package |
|---|---|
| `Horse.Provider.Config` | `HorseCS` |
| `Horse.Provider.Abstract` | `HorseCS` |
| `Horse.Request` | `HorseCS` |
| `Horse.Response` | `HorseCS` |
| All other Horse units | `HorseCS` |
| `Horse.Provider.CrossSocket.*` (6 units) | `HorseProviderCrossSocket` |
| `Net.CrossSocket.*`, `Net.CrossHttp*` | `HorseProviderCrossSocket` |
| `Utils.*`, `OpenSSL.*` | `HorseProviderCrossSocket` |

If the Delphi linker reports `"Unit X was compiled with a different version of Y"`, it almost always means `HorseCS.dcp` is stale. Perform a Clean+Build of `HorseCS` first, then rebuild `HorseProviderCrossSocket`.
```

This revised `BUILD.md`:
- Reflects the actual repository structure of `horse-provider-crosssocket`.
- Uses the correct paths for dependencies fetched via Boss (`modules/`).
- Provides both IDE and MSBuild instructions.
- Includes a CI pipeline example that uses Boss to install dependencies.
- Retains the unit ownership table to prevent package conflicts.