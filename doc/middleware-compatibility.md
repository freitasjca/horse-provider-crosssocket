# Middleware Compatibility Matrix — CrossSocket Provider

This document enumerates each official Horse middleware package, the `THorseRequest` / `THorseResponse` surface it touches, and the mechanism by which it works on the CrossSocket provider without source changes.

The CrossSocket provider's compatibility goal is **drop-in replacement for Indy** — every middleware in the official ecosystem must compile and behave identically when `{$DEFINE HORSE_CROSSSOCKET}` is set, with no per-middleware patch required.

The compatibility surface is:

| Mechanism | Provided by |
|---|---|
| `Req.RawWebRequest.*` | PATCH-REQ-8 hybrid adapter (`TCrossSocketWebRequest` → `IHorseRawRequest` → `ICrossHttpRequest`) |
| `Res.RawWebResponse.SetCustomHeader` | `TInterfacedWebResponse` inherited `CustomHeaders: TStrings` (merged by `TResponseBridge.CopyHeaders`) |
| `Res.RawWebResponse.Content` / `.ContentType` | COMPAT-1 fallback in `TResponseBridge.Flush` / `WriteBody` |
| `Req.Headers / Cookie / Query / Body / ContentType / Method / MethodType / Host / PathInfo / RemoteAddr` | PATCH-REQ-2/3/4/5/8/9/10 nil-guarded accessors with shadow fields |
| `Res.Send / Status / ContentType / AddHeader / RedirectTo / SendFile / Download` | PATCH-RES-1/4 nil-guarded setters with shadow fields |

---

## Compatibility table

| Middleware | Surface used | Mechanism | Test |
|---|---|---|---|
| **horse-cors** | `Req.RawWebRequest.Method`; `Res.RawWebResponse.SetCustomHeader` (×5) | PATCH-REQ-8 (Method via adapter); CopyHeaders merge of `TInterfacedWebResponse.CustomHeaders` | Test 30 (`HorseCSTestClient.dpr` — `OPTIONS /cors/check` → 204 + ACAO header; `GET /cors/check` → route body) |
| **horse-jhonson** | `Req.RawWebRequest.ContentType`; `Res.RawWebResponse.Content`; `Res.RawWebResponse.ContentType` | PATCH-REQ-8 (request adapter delegates ContentType); COMPAT-1 fallback (response shadow precedence with adapter pickup) | Test 32 (`COMPAT-1 shadow-field precedence`) |
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

The only abstract methods that remain stubs on `TInterfacedWebResponse` are the response-write side (`SetContent`, `SetStatusCode`, `SetContentStream`, `SetStringVariable`, etc.). These intentionally don't forward — `TResponseBridge.Flush` reads from `THorseResponse`'s shadow fields (PATCH-RES-4), not from the adapter — so middleware that writes via `Res.RawWebResponse.Content := X` should switch to `Res.Send(X)` (the public API). The COMPAT-1 fallback in the bridge picks up `RawWebResponse.Content` / `.ContentType` if a future change makes those stubs forward, but at present the recommended path is the public Horse API.

---

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
- Stores anonymous-method callbacks at unit scope — RTL finalisation will clear them while IO threads may still be active. Use `Listen`'s blocking pattern (PATCH-LISTEN-1) so finalisation doesn't run until `StopListen` has joined the IO threads.

---

## Testing a middleware against CrossSocket

Use `HorseCSTestServer.dpr` as the harness:

1. Add the middleware to the server's `THorse.Use` chain near the top of `begin..end.`.
2. Add a test in `HorseCSTestClient.dpr` that exercises whatever the middleware reads or writes (method, header, body, status).
3. Run the full 32-test suite — regressions show up as failed checks; the exit code equals the number of failures.

For a middleware not in this matrix, please open an issue with the `RawWebRequest` / `RawWebResponse` surface it touches and a representative call site; we will add a row here and a test in the suite.
