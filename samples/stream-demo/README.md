# stream-demo — `Res.Send<TStream>` regression & correctness suite

Server + client demo pair that verifies `Res.Send<TStream>(AStream).Status(200)` puts stream bytes correctly on the wire, and cross-checks against the always-worked `Res.SendFile(AStream, ...)` path as a regression control.

## TL;DR — What this demo proves

**`Res.Send<TStream>(S)` and `Res.Send(S)` now work correctly** on every Horse provider (CrossSocket, Indy, mORMot, HTTP.sys, IOCP, Epoll, nghttp2) via **PATCH-RES-8** in `patches/horse/src/Horse.Response.pas`.

### History — what was broken

Before PATCH-RES-8, `Send<T: class>(AContent: T)` set `THorseResponse.FContent := AContent` and returned. `FContent` is a `TObject` slot for content-type middleware (e.g. `horse-jhonson` picks it up to serialize JSON) — no provider bridge ever read it as a stream. Every `Res.Send<TStream>(S)` call produced `HTTP 200 Content-Length: 0` regardless of payload, `Position`, or stream type. Downstream symptoms included the community-reported "TFDMemTable LoadFromStream: format invalid" (the client was receiving zero bytes to parse).

### What PATCH-RES-8 does

- Adds a private `DoSendStream` helper to `THorseResponse` that copies the source stream into the active body slot (`FCSContentStream` on CrossSocket/mORMot/nghttp2/IOCP/Epoll; `FWebResponse.ContentStream` on Indy/WebBroker).
- Adds a non-generic `Send(const AContent: TStream): THorseResponse` overload so `Res.Send(S)` works without the `<TStream>` type parameter.
- Modifies the generic `Send<T>` to detect TStream at runtime and route through `DoSendStream`; non-stream `Send<T>` callers (JSON middleware) hit the unchanged `else FContent := AContent` branch.
- Defaults `Content-Type` to `application/octet-stream` if the caller didn't set one explicitly.
- **Takes ownership** of the source stream (copies then Frees it) — matches the historical `Send<T>` contract where `Clear` freed `FContent`.
- Resets `Position := 0` internally, so the "position at end after writing" gotcha is a non-issue.

### API surface — all three now work identically

| Call | Behavior |
|---|---|
| `Res.Send<TStream>(S).Status(200)` | Copies S to body, defaults Content-Type, frees S |
| `Res.Send(S).Status(200)` | Same — picks the typed overload |
| `Res.SendFile(S, 'name.ext', 'type').Status(200)` | Same, with explicit filename and Content-Disposition |

`SendStream(callback)` remains the choice for chunked/incremental streaming; `Send<TStream>`/`SendFile` are for one-shot buffered bodies.

## The four failure modes originally suspected (all debunked, then fixed)

| Mode | Original theory | Real cause | Post-PATCH-RES-8 behavior |
|---|---|---|---|
| **1. Position bug** | Position left at end blocks sending | `Send<TStream>` never read the stream | `DoSendStream` resets Position internally — full body sent regardless |
| **2. Position fixed** | `Position := 0` should fix it | Same as above | Full body sent |
| **3. FDMemTable format mismatch** | Server used one format, client expected another | Client received zero bytes; no format could parse empty | Server sends full FDMemTable stream; client `LoadFromStream(..., sfBinary)` loads the 3 sample rows |
| **4. Chunked encoding not stripped** | Large body triggers chunked; naive clients don't dechunk | Wire was `Content-Length: 0`, nothing to strip | 64 KB body sent correctly via CL or chunked (transport's choice); TCrossHttpClient dechunks either way |

All seven `Send<TStream>` endpoints in this demo now return real bytes matching the SendFile group's payloads. Run it to prove it.

## Build

Delphi IDE (10.4+ Enterprise, so FireDAC is present):

1. Open `StreamDemoServer.dpr`. Delphi offers to create a `.dproj` — accept.
2. Project → Options → Building → Delphi Compiler → Search path:
   ```
   ..\..\..\horse-provider-crosssocket\src
   ..\..\..\horse\src
   ..\..\..\Delphi-Cross-Socket\Net
   ```
   (Adjust paths as needed for your workspace layout.)
3. Ensure the `HORSE_PROVIDER_CROSSSOCKET` define is set (already in the `.dpr`).
4. Project → Build → produces `StreamDemoServer.exe`.

Repeat for `StreamDemoClient.dpr`. Same search paths.

## Run

Two terminals, or two windows:

**Terminal 1** — server:
```
StreamDemoServer.exe
```
Expected output:
```
StreamDemoServer — CrossSocket TStream diagnostics on port 9080

Endpoints:
  GET /stream/position-bug        — should return 0 bytes (proves position bug)
  GET /stream/position-fixed      — should return 30 bytes
  ...
Ctrl-C to stop.
```

**Terminal 2** — client:
```
StreamDemoClient.exe
```

Server and client both use port **18080** — see Troubleshooting below for why 9080 was avoided.

The client runs 10 test cases across 7 Send<TStream> endpoints and 3 SendFile endpoints, prints PASS/FAIL for each check, and writes `received-*.bin` files next to its .exe (one per endpoint). Expected summary on a machine with the PATCH-RES-8 Horse.Response.pas + MSXML registered:
```
[StreamDemo] 35 passed, 0 failed
[StreamDemo] All tests PASSED.
```

If MSXML is missing, the xml endpoint SKIPs (33/33) instead of failing.

## Diagnostic workflow — you still see empty body from Send<TStream>

If you're running against a patched Horse but still seeing empty bodies, work through these in order:

1. **Confirm PATCH-RES-8 is in your Horse.Response.pas.** Grep for `DoSendStream` — should return matches in both `patches/horse/src/Horse.Response.pas` and (after re-copy) `horse/src/Horse.Response.pas`. If missing from the live copy, re-copy from `patches/`.

2. **Confirm your build picked up the patched file.** `.dcu` cache may still hold the old code — do a Delphi IDE **Project → Clean** followed by **Project → Build**. Check `.exe` timestamps.

3. **Confirm with curl** on any `/stream/*` endpoint (not the client — clients can mask):
   ```
   curl -v http://127.0.0.1:18080/stream/position-fixed
   ```
   Expected: `Content-Length: 30` and body `Hello CrossSocket Stream World`. If you get `Content-Length: 0`, PATCH-RES-8 isn't in the compiled binary — go back to step 1.

4. **If curl shows the correct body but your client sees empty**, your client-side parsing is off — check dechunking and buffer handling.

### Ownership caveat — Horse frees your source stream

**PATCH-RES-8 takes ownership**: `Res.Send<TStream>(S)` and `Res.Send(S)` copy S into an internal buffer and then call `S.Free`. Do **not** `try ... finally S.Free` around them — that's a double-free.

**`Res.SendFile(AStream, name, type)`** also copies into a response-owned buffer, but does **not** free your source stream — the caller is expected to `try ... finally S.Free`. This is a legacy behavior kept for compatibility with existing code.

**`Res.SendStream(callback)`** (chunked streaming) runs the callback synchronously in the request thread — free your resources after it returns.

Summary:
| API | Copies source? | Frees source? |
|---|---|---|
| `Res.Send<TStream>(S)` / `Res.Send(S)` | Yes (PATCH-RES-8) | Yes — do NOT free yourself |
| `Res.SendFile(S, ...)` | Yes | No — you must free |
| `Res.SendStream(callback)` | N/A (writer callback) | You free after callback returns |

## Endpoint reference

**Send<TStream> group — PATCH-RES-8 fixed; all produce correct bodies:**

| Endpoint | Server code | Wire result |
|---|---|---|
| `GET /stream/position-bug` | Send<TStream> with position at end | 30 bytes `Hello CrossSocket Stream World` (DoSendStream resets Position) |
| `GET /stream/position-fixed` | Send<TStream> with `Position:=0` | 30 bytes `Hello CrossSocket Stream World` |
| `GET /stream/pattern` | Send<TStream> 1024-byte pattern | 1024 bytes `0,1,2...255,0,1,...` (byte-perfect) |
| `GET /stream/large` | Send<TStream> 64 KB | 65536 bytes |
| `GET /stream/fdmemtable-binary` | Send<TStream> TFDMemTable sfBinary | full FDMemTable stream, 3 rows loadable |
| `GET /stream/fdmemtable-xml` | Send<TStream> TFDMemTable sfXML | full stream (or 500 if MSXML missing — see Troubleshooting) |
| `GET /stream/fdmemtable-json` | Send<TStream> TFDMemTable sfJSON | full FDMemTable stream |

**SendFile group — regression checks; always worked:**

| Endpoint | Server code | Wire result |
|---|---|---|
| `GET /stream/send-file-fixed` | SendFile 30-byte payload | 30 bytes `Hello CrossSocket Stream World` |
| `GET /stream/send-file-pattern` | SendFile 1024-byte pattern | 1024 bytes byte-perfect pattern |
| `GET /stream/send-file-fdmemtable-binary` | SendFile TFDMemTable sfBinary | full FDMemTable stream, 3 rows loadable |

## Requirements

- Delphi 10.4 Sydney or later
- FireDAC (Enterprise or Architect SKU — Professional does not include it)
- HashLoad/Horse 3.3.0+
- horse-provider-crosssocket
- Delphi-Cross-Socket (source or via Boss)

## Troubleshooting

### Every request returns `301 Moved Permanently` with `Location: about:blank`

The response isn't coming from your server — a **background service is squatting on the port**. `about:blank` as a redirect target is a specific fingerprint of OEM audio/vendor control services (Nahimic, MSI Center, Alienware Command Center, HP Omen, etc.) that bind localhost ports in the 9000-9100 range for their internal web UIs and return that 301 to anything they don't recognize.

Verify with:
```
netstat -ano | findstr :<port>
tasklist /FI "PID eq <pid-of-127.0.0.1-binding>"
```

You'll see two listeners on the same port:
- **`0.0.0.0:<port>`** → `StreamDemoServer.exe` (the wildcard binding)
- **`127.0.0.1:<port>`** → some vendor service (the more-specific binding)

Windows routes localhost traffic to the more-specific binding, so your server never sees the requests.

**Fix:** change `DEMO_PORT` in `StreamDemoServer.dpr` AND `BASE_URL` in `StreamDemoClient.dpr` to a port outside the vendor-service range. This demo defaults to **18080** for that reason. Do **not** kill the vendor service (it may affect audio/lighting/other hardware); just move off its ports.

### Client shows all tests failing with `status 400`

If you also see `301 → about:blank` in a curl trace, this is the same Nahimic-style issue above — the client is faithfully reporting whatever the squatting service returns. Fix by changing ports as above.

### `Internal Application Error: No active document`

Downstream of the MSXML-not-installed error, but distinct. Happens when MSXML is registered (via `Xml.Win.msxmldom` in uses) but the request handler runs on a thread that hasn't called `CoInitialize`. CrossSocket dispatches requests on IOCP worker threads which are NOT COM-initialized by default — MSXML's `CoCreateInstance(IXMLDOMDocument)` silently returns a broken interface reference, and the first DOM operation fails with this message.

**Fix — wrap any handler that touches MSXML (directly or via FireDAC's sfXML/sfADT):**

```pascal
uses ..., Winapi.ActiveX;

procedure GetFDMemTableXml(Req: THorseRequest; Res: THorseResponse);
begin
  CoInitialize(nil);
  try
    // ... MSXML / FireDAC sfXML code here ...
  finally
    CoUninitialize;
  end;
end;
```

Only handlers that actually use COM need this — `sfBinary` and `sfJSON` are pure Delphi and don't touch COM at all, so leave those alone.

If you have many handlers touching MSXML, consider a middleware that calls `CoInitialize` on the current thread once per request. Or use OmniXML (pure Pascal) which sidesteps COM entirely — see the "Zero-dependency alternative" below.

### `EOleException: Microsoft MSXML is not installed`

Only affects `/stream/fdmemtable-xml` (sfXML uses MSXML; sfBinary and sfJSON don't). The error is misleading — 99% of the time `msxml6.dll` IS on the machine (it ships with Windows 7+), but Delphi's DOM-vendor factory doesn't know about it because no unit in the app's uses graph has triggered MSXML's `RegisterDOMVendor` call.

**The fix — Delphi side, no admin required:** add one unit to your uses clause. `StreamDemoServer.dpr` already does this:

```pascal
uses
  ...,
  Xml.Win.msxmldom;   // initialization calls RegisterDOMVendor for MSXML;
                      // FireDAC then picks it as the DOM vendor automatically.
```

No `DefaultDOMVendor` assignment is needed — the uses reference alone triggers the registration at unit initialization time.

If you still see the error after adding this unit, MSXML6 really is missing (extremely rare). Confirm with:
```
dir C:\Windows\SysWOW64\msxml6.dll     :: 32-bit — needed by a Win32 build
dir C:\Windows\System32\msxml6.dll     :: 64-bit — needed by a Win64 build
```
If genuinely absent, install **MSXML 6.0 SP1** from Microsoft's download center.

**Zero-dependency alternative** — replace MSXML with OmniXML (pure Pascal, no COM):
```pascal
uses
  ...,
  Xml.omnixmldom;   // registers OmniXML instead of MSXML
```

The client-side `TestFDMemTable` still handles the "MSXML not installed" case gracefully with a SKIP so this specific endpoint failing doesn't red-fail the whole run on stripped-down machines.

If curl works but the client fails, the issue is in `TCrossHttpClient` response parsing. Check your `Delphi-Cross-Socket` version — versions before mid-2026 had a `TCrossHttpClient` zero-body hang (PATCH-CSHTTP-1) that has since been fixed upstream.

## What this DOES prove

- Whether the position bug is the root cause of an "empty body" report
- Which FDMemTable format the server is actually using vs what the client expects
- Whether TCrossHttpClient dechunks correctly for large payloads (spoiler: it does)
- Whether the transport preserves byte-for-byte integrity for arbitrary binary payloads

## What this does NOT prove

- **`Res.SendStream(S)` semantics** (non-owning variant) — this demo uses only `Send<TStream>`. If your issue is around stream ownership, adding a `/stream/send-non-owning` endpoint using `SendStream` would extend coverage.
- **Compression / Content-Encoding: gzip** — CrossSocket doesn't compress by default, but middleware might. Not exercised here.
- **HTTPS / mTLS** — plain HTTP only. TLS wouldn't change the failure modes above, but is worth testing separately if your production endpoint uses HTTPS.
- **Concurrent stream responses** — the demo runs sequentially. Ownership bugs are much more visible under load. Add a stress test if pool/lifetime issues are suspected.
