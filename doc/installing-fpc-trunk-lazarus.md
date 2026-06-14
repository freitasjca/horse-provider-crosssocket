# Installing FPC 3.3.1 Trunk for Lazarus (fpcupdeluxe)

Delphi-Cross-Socket requires `{$MODESWITCH FUNCTIONREFERENCES}` and
`{$MODESWITCH ANONYMOUSFUNCTIONS}` (in `zLib.inc`), which were introduced in
FPC 3.3.1 (the development branch). FPC 3.2.2, the last stable release, does
not support these directives and **cannot compile this provider**.

The recommended way to get a working FPC trunk build is **fpcupdeluxe** — a
GUI installer that downloads, compiles, and configures FPC trunk and a matching
Lazarus in one pass, completely isolated from any existing FPC 3.2.2
installation.

---

## Prerequisites

- An existing Delphi or FPC 3.2.2 / Lazarus installation on the same machine
  (fpcupdeluxe uses it as the bootstrap compiler)
- A C compiler on `PATH` — on Windows: MinGW-w64 (ships with msys2) or the
  one bundled with Lazarus; on Linux: `gcc` from the distro package manager
- Internet access (fpcupdeluxe checks out FPC trunk from the official SVN
  mirror)
- ~3 GB free disk space for the SVN checkout + compiled output

---

## Step 1 — Download fpcupdeluxe

Go to the [releases page](https://github.com/LongDirtyAnimAlf/fpcupdeluxe/releases)
and download the binary for your OS. It is a single executable — no installer.

| OS | File to download |
|---|---|
| Windows 64-bit | `fpcupdeluxe-x86_64-win64.exe` |
| Windows 32-bit | `fpcupdeluxe-i386-win32.exe` |
| Linux 64-bit | `fpcupdeluxe-x86_64-linux` |
| macOS | `fpcupdeluxe-x86_64-darwin` |

Place it in a permanent directory, for example `C:\fpcupdeluxe\` on Windows or
`~/fpcupdeluxe/` on Linux/macOS. Do **not** put it inside your existing Lazarus
or FPC directories.

---

## Step 2 — Configure and install

Launch the executable. The GUI presents two main dropdowns and an install
directory field:

| Field | Value |
|---|---|
| **FPC version** | `trunk` |
| **Lazarus version** | `trunk` (**not** `stable` — see note below) |
| **Install directory** | A new, empty directory — e.g. `C:\lazarus-trunk\` or `~/lazarus-trunk/` |

Leave all other settings at their defaults, then click **Install/Update**.

> **Both versions must be trunk.** FPC trunk changes internal RTL APIs without
> notice (for example, `TFPCanvas.Scale` gained a second parameter between the
> 3.2 and 3.3 series). Lazarus stable is only tested against the FPC 3.2.x
> series and breaks unpredictably when compiled against trunk FPC — typically
> with errors like `Wrong number of parameters` in packages such as `TAChart`
> or `fcl-image`. The FPC and Lazarus teams keep trunk↔trunk in sync; that is
> the only supported pairing when FPC trunk is required.

fpcupdeluxe will:

1. Check out FPC trunk source from the official SVN mirror
2. Bootstrap FPC trunk using the FPC compiler it detects on your system
3. Compile the full FPC trunk RTL and packages
4. Check out and compile a matching Lazarus trunk IDE against the new RTL
5. Write a ready-to-launch `lazarus` executable into the install directory

This takes **20–40 minutes** on the first run. Subsequent **Install/Update**
calls are incremental (SVN update + recompile only what changed) and are much
faster.

---

## Step 3 — Launch the trunk Lazarus

Open `<install-dir>/lazarus.exe` (Windows) or `<install-dir>/lazarus` (Linux /
macOS). This instance is fully independent of your existing Lazarus — it will
not affect your current projects or IDE settings.

To confirm the compiler version, go to:

```
Help → About → Compiler info
```

You should see `Free Pascal Compiler version 3.3.1` (or a later 3.3.x date
stamp).

You can also verify from the command line:

```bash
C:\lazarus-trunk\fpc\bin\x86_64-win64\fpc.exe -iV
# expected output: 3.3.1
```

---

## Step 4 — Verify FUNCTIONREFERENCES support

Create a minimal test program and compile it with the trunk `fpc.exe` to
confirm the required mode switches are available:

```pascal
{$MODE DELPHI}
{$MODESWITCH FUNCTIONREFERENCES}
{$MODESWITCH ANONYMOUSFUNCTIONS}
var
  F: reference to procedure;
begin
  F := procedure begin WriteLn('FPC trunk OK'); end;
  F();
end.
```

Save as `test.pas` and compile:

```bash
# Windows
C:\lazarus-trunk\fpc\bin\x86_64-win64\fpc.exe test.pas

# Linux / macOS
~/lazarus-trunk/fpc/bin/x86_64-linux/fpc test.pas
```

If the binary runs and prints `FPC trunk OK`, the compiler is ready and
Delphi-Cross-Socket will build.

---

## Keeping the trunk build up to date

FPC trunk moves fast. Re-run fpcupdeluxe's **Install/Update** button
periodically (monthly is usually sufficient) to pull the latest SVN commits and
rebuild. The update is incremental — only changed units are recompiled.

---

## Coexistence with FPC 3.2.2

fpcupdeluxe installs into a completely separate directory and does not modify
any system-wide `PATH`, registry entries, or your existing Lazarus configuration.
Both installations can run simultaneously. To switch between them, simply launch
the corresponding `lazarus.exe`.

If you need both versions in the same project tree, use fpcupdeluxe's
**Profiles** feature (top-left dropdown in the GUI) to maintain named
environments — for example `stable-3.2.2` and `trunk`.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `Error: Illegal compiler switch FUNCTIONREFERENCES` | Still using FPC 3.2.2 | Confirm you launched `<install-dir>/lazarus.exe`, not the existing one |
| `Wrong number of parameters` in `TAChart`, `fcl-image`, or other Lazarus packages | **Lazarus stable** selected with FPC trunk — unsupported combination | In fpcupdeluxe, change **Lazarus version** to `trunk` and re-run **Install/Update** |
| `Cannot find Masks used by Utils.IOUtils. Check if package LazUtils is in the dependencies` | `LazUtils` not declared as a required package | In Lazarus IDE: **Project → Project Inspector → Required Packages → Add → LazUtils** |
| Bootstrap fails — `fpc: command not found` | No FPC on `PATH` | Set the bootstrap compiler path manually in fpcupdeluxe → **Options** → `FPC compiler` |
| SVN checkout stalls or fails | Firewall / proxy blocking SVN port 3690 | Use fpcupdeluxe → **Options** → `Use GIT mirror` to switch to the GitHub mirror over HTTPS |
| Build fails with missing C headers on Linux | `gcc` / `binutils` not installed | `sudo apt install build-essential` (Debian/Ubuntu) or equivalent |
| `lazarus.exe` opens but has no packages | Lazarus compiled before FPC finished | Re-run **Install/Update** once FPC is fully built; the Lazarus step will re-link against the correct RTL |

---

## See also

- [Requirements](../README.md#requirements) — minimum FPC version table
- [fpcupdeluxe releases](https://github.com/LongDirtyAnimAlf/fpcupdeluxe/releases)
- [Free Pascal development page](https://www.freepascal.org/develop.html) —
  manual trunk source snapshots (alternative to fpcupdeluxe)
