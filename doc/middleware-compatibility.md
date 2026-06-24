# Middleware Compatibility Matrix — CrossSocket Provider

This document enumerates each official Horse middleware package, the `THorseRequest` / `THorseResponse` surface it touches, and the mechanism by which it works on the CrossSocket provider without source changes.

The CrossSocket provider's compatibility goal is **drop-in replacement for Indy** — every middleware in the official ecosystem must compile and behave identically when `{$DEFINE HORSE_PROVIDER_CROSSSOCKET}` is set (or the legacy alias `HORSE_CROSSSOCKET` — PATCH-HORSE-2 keeps it working forever), with no per-middleware patch required.

The compatibility surface is:

| Mechanism | Provided by |
|---|---|
| `Req.RawWebRequest.*` | PATCH-REQ-8 hybrid adapter (`TCrossSocketWebRequest` → `IHorseRawRequest` → `ICrossHttpRequest`) |
| `Res.RawWebResponse.SetCustomHeader` | `TInterfacedWebResponse` inherited `CustomHeaders: TStrings` (merged by `TResponseBridge.CopyHeaders`) |
| `Res.RawWebResponse.Content` / `.ContentType` | **Dead path today.** `TInterfacedWebResponse.SetContent` and `SetStringVariable` are no-op stubs — writes are silently discarded; the COMPAT-1 bridge hook reads `''`. Use `Res.Send` / `Res.ContentType` instead. COMPAT-1 code in `WriteBody` / `Flush` is a forward hook for if the stubs are made to forward in the future. |
| `Req.Headers / Cookie / Query / Body / ContentType / Method / MethodType / Host / PathInfo / RemoteAddr` | PATCH-REQ-2/3/4/5/8/9/10 nil-guarded accessors with shadow fields |
| `Res.Send / Status / ContentType / AddHeader / RedirectTo / SendFile / Download` | PATCH-RES-1/4 nil-guarded setters with shadow fields |

---

## Compatibility table

| Middleware | Surface used | Mechanism | Test |
|---|---|---|---|
| **horse-cors** | `Req.RawWebRequest.Method`; `Res.RawWebResponse.SetCustomHeader` (×5) | PATCH-REQ-8 (Method via adapter); CopyHeaders merge of `TInterfacedWebResponse.CustomHeaders` | Test 30 (`HorseCSTestClient.dpr` — `OPTIONS /cors/check` → 204 + ACAO header; `GET /cors/check` → route body) |
| **horse-jhonson** | `Req.RawWebRequest.ContentType` (read); `Res.Send` / `Res.ContentType` (write — public API path) | PATCH-REQ-8 (request adapter delegates ContentType to `ICrossHttpRequest.ContentType`); PATCH-RES-4 shadow fields for `Send`/`ContentType`. **If** horse-jhonson writes via `Res.RawWebResponse.Content` / `.ContentType` directly, those writes are silently dropped on CrossSocket (stubs) and it would be incompatible — use the public `Res.Send` / `Res.ContentType` API. | Test 32 (`COMPAT-1 shadow-field precedence` — shadow field from `Res.Send` wins over `RawWebResponse.Content` write, which is a no-op stub) |
| **horse-jwt** | `Req.Headers['Authorization']` | PATCH-REQ-3 nil-guarded `Headers` accessor; populated by request bridge | Indirect — covered by every test that uses `Req.Headers` (Tests 21, 27 for header round-trip) |
| **horse-basic-authenticator** | `Req.Headers['Authorization']` | Same as `horse-jwt` | Indirect — same as `horse-jwt` |
| **horse-logger** | `Req.RawWebRequest.Method` / `.PathInfo` / `.Host` / `.RemoteAddr` | PATCH-REQ-8 adapter forwards all four to `ICrossHttpRequest` | Test 27 (`PATCH-REQ-8` adapter — verifies method, host, pathInfo, headers, remoteAddr) |
| **horse-handle-exception** | Catches Horse pipeline exceptions; calls `Res.Send` / `Res.Status` | PATCH-RES-4 nil-guarded setters; SEC-31 structured-JSON error path | Tests 22, 23 (explicit 400 / 500 status codes round-trip without stack-trace leak) |
| **horse-manipulate-request** | Stored callback `THorseManipulateRequest`; called per request, takes `THorseRequest` | No `Raw*` access — operates on Horse-level types | Compat by construction (no provider-specific surface) |
| **horse-manipulate-response** | Stored callback `THorseManipulateResponse`; takes `THorseResponse` | Same as above | Compat by construction |
| **horse-rate-limit** | `Req.RemoteAddr` (custom builds may use `Req.Headers['X-Forwarded-For']`) | PATCH-REQ-3 `RemoteAddr` accessor (always populated from `ICrossHttpRequest.PeerAddr`) | Test 27 (RemoteAddr round-trip) |
| **horse-octet-stream** | `Req.Body<TStream>`; `Res.RawWebResponse.ContentStream` | Non-owning stream contract — the body must be copied if held; `RawWebResponse.ContentStream` write goes through `TInterfacedWebResponse` (stub on the adapter today; use `Res.Send(stream)` instead) | Test 16 (file download with Content-Disposition); user code must follow the ownership rule documented in `Console.dpr` |
| **horse-request-guard** *(this fork)* | `Req.RawWebRequest.Method`; `Req.Host`; `Req.Headers`; `Req.PathInfo`; `Req.Query` | PATCH-REQ-8 adapter; PATCH-REQ-3 nil-guarded accessors | Built into the suite — every other test request passes through it without rejection |
| **horse-security-headers** *(this fork)* | `Res.AddHeader` only | PATCH-RES-1 / PATCH-RES-7 lazy `FCustomHeaders` | Indirect — every test response carries the security headers when the middleware is enabled |
| **horse-cors** *(this fork)* | Same as upstream `horse-cors` | Same as upstream | Test 30 |

---

## How the hybrid adapter satisfies `RawWebRequest` / `RawWebResponse`

Middleware that calls `Req.RawWebRequest.SomeProperty` does so to access a `TWebRequest` (Delphi) / `TRequest` (FPC) member. Before PATCH-REQ-8, `RawWebRequest` returned `FWebRequest` directly, which is `nil` on the CrossSocket path — every dereference AV'd.

PATCH-REQ-8 makes `RawWebRequest` return the `TCrossSocketWebRequest` adapter when `FWebRequest` is `nil`:

```pascal
function THorseRequest.RawWebRequest: TWebRequest;
begin
  if Assigned(FWebRequest) then
    Exit(FWebRequest);
  Result := FCSRawWebRequest;     // owned TCrossSocketWebRequest adapter
end;
```

`TCrossSocketWebRequest` descends from `TInterfacedWebRequest`, which descends from `TWebRequest`. It implements every abstract `TWebRequest` method by delegating through `IHorseRawRequest` to `TCrossSocketRawRequest`, which wraps `ICrossHttpRequest` in ~15 one-liner methods.

The same pattern applies to `RawWebResponse` via PATCH-RES-6 → `TCrossSocketWebResponse` → `IHorseRawResponse` → `TCrossSocketRawResponse`.

The response-write side of `TInterfacedWebResponse` (`SetContent`, `SetStatusCode`, `SetContentStream`, `SetStringVariable`, etc.) are all no-op stubs — they discard writes. `TResponseBridge.Flush` reads from `THorseResponse`'s shadow fields (PATCH-RES-4), not from the adapter. Middleware that writes via `Res.RawWebResponse.Content := X` or `Res.RawWebResponse.ContentType := X` will have those writes silently dropped on CrossSocket — use `Res.Send(X)` / `Res.ContentType(X)` (the public Horse API) instead.

The COMPAT-1 code in `WriteBody` and `Flush` checks `LRawRes.Content` / `LRawRes.ContentType` after the shadow fields are exhausted, as a forward hook for if those stubs are ever made to forward. Today they always return `''`, so COMPAT-1 for these two properties is dead. COMPAT-1 does NOT provide working compatibility for middleware that writes via `RawWebResponse.Content` or `.ContentType`.

`WriteBody` carries a third forward hook for `RawWebResponse.ContentStream`: it drains the stream synchronously via `TResponseBridge.TryReadBodyStream` and, when the raw response owns it (`FreeContentStream = True`), releases it via `ReleaseRawResponseContentStream` before sending the captured bytes. The synchronous read is deliberate — `ICrossHttpResponse.Send(TStream)` is async, so handing it a stream the bridge then frees would be a use-after-free. Like the other two, this hook is dormant today because `SetContentStream` is a stub (the stream can never be set through the adapter), but it is leak-safe the day the stub is made to forward — and it mirrors the mORMot bridge, which uses the same two helpers for a reachable `ContentStream` path.

---

## Cookies (`Res.Cookie` / `Res.AddCookie`)

The typed RFC 6265 cookie API (PATCH-COOKIE-1, `Horse.Core.Cookie`) is **fully
supported** on CrossSocket — unlike the stubbed `RawWebResponse.Content` path
above. Cookies set via `Res.Cookie(name,value).Path(...).HttpOnly(...)` are kept
in `THorseResponse.Cookies`; `TResponseBridge.CopyHeaders` iterates that list and
emits **one `Set-Cookie` line per cookie** via the `[MULTI-1]` path
(`ACrossRes.Header.Add('Set-Cookie', value, True)`), so multiple cookies are never
folded into a single header. All attributes (`Path/Domain/Expires/Max-Age/Secure/
HttpOnly/SameSite`) round-trip. The legacy `Res.AddHeader('Set-Cookie', …)` still
works but holds only one cookie (it goes through the single-value header map).

## What about `RawWebResponse.SendResponse`?

Some middleware calls `Res.RawWebResponse.SendResponse` to flush early (rare). On CrossSocket the call is a no-op stub — the response is flushed by `TResponseBridge.Flush` after the pipeline completes. Middleware that depends on early-flush semantics would need to call `ICrossHttpResponse.Send` directly, which means a per-provider branch. We have not encountered an official middleware that does this.

---

## Adding new middleware

A new Horse middleware is CrossSocket-compatible by construction if it:

- Reads request data via `Req.<accessor>` (Method / MethodType / Host / PathInfo / Headers / Query / Cookie / Body / ContentType / RemoteAddr).
- Reads / writes the raw layer via `Req.RawWebRequest.<property>` (read-only access works for all standard properties via the adapter) or `Res.RawWebResponse.SetCustomHeader` / `.CustomHeaders`.
- Writes response data via `Res.<setter>` (Send / Status / ContentType / AddHeader / RemoveHeader / RedirectTo / SendFile / Download).

A middleware needs review if it:

- Writes via `Res.RawWebResponse.Content`, `.ContentType`, or `.StatusCode` directly — these are stubbed on `TInterfacedWebResponse` and silently dropped today. Switch to the public `Res.Send` / `Res.ContentType` / `Res.Status` API.
- Calls `Res.RawWebResponse.SendResponse` for early flush — stubbed; use `Res.Send` instead.
- Holds a long-lived reference to `Req.Body<TStream>` past the handler return — this is a use-after-free on CrossSocket. Copy the bytes; see `samples/Delphi/console/Console.dpr` `/echo` route.
- Stores anonymous-method callbacks at unit scope — RTL finalisation will clear them while IO threads may still be active. Use the `Listen`-blocks-main-thread / `StopListen`-joins-IO-threads pattern (see `IsConsole` guard in `Horse.Provider.CrossSocket.pas` and the comment in `samples/Delphi/console/Console.dpr`) so finalisation doesn't run until IO threads have exited.

---

## Testing a middleware against CrossSocket

Use `HorseCSTestServer.dpr` as the harness:

1. Add the middleware to the server's `THorse.Use` chain near the top of `begin..end.`.
2. Add a test in `HorseCSTestClient.dpr` that exercises whatever the middleware reads or writes (method, header, body, status).
3. Run the full 32-test suite — regressions show up as failed checks; the exit code equals the number of failures.

For a middleware not in this matrix, please open an issue with the `RawWebRequest` / `RawWebResponse` surface it touches and a representative call site; we will add a row here and a test in the suite.
