unit Horse.BenchRoutes;

(*
  Horse Performance Benchmark — Shared Route Registration
  ========================================================

  Routes used by all bench server binaries (Delphi and Lazarus builds):
    HorseBenchIndy, HorseBenchCrossSocket, HorseBenchMormot  (Delphi)
    HorseBenchCrossSocket, HorseBenchFPCHttp                 (Lazarus)

  Routes:
    GET  /ping   — minimal routing overhead; no body
    POST /echo   — body read + write (pool / shadow-field hot path)
    GET  /alloc  — allocates and sends a 1 KB string (allocation path)

  Dual-compiler: compiles on both Delphi (dcc64) and FPC (fpc).
  No provider-specific units are referenced here.

  Middleware registration (THorseRequestGuard / THorseSecurityHeaders) is
  intentionally left to each server .dpr so that the bare-vs-middleware
  comparison uses exactly the same route code.
*)

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

interface

const
  BENCH_PORT_INDY_BARE        = 9001;
  BENCH_PORT_CROSSSOCKET_BARE = 9002;
  BENCH_PORT_MORMOT_BARE      = 9003;
  BENCH_PORT_MW_OFFSET        = 10;   // bare_port + offset = middleware port

  // Raw transport servers (no Horse framework — CrossSocket / mORMot / Indy directly)
  BENCH_PORT_RAW_CROSSSOCKET  = 9004;
  BENCH_PORT_RAW_MORMOT       = 9005;
  BENCH_PORT_RAW_INDY         = 9006;   // pure TIdHTTPServer, no WebBroker

  // Lazarus-only server (FPC default fphttpserver / HTTPApplication provider)
  BENCH_PORT_FPC_HTTP_BARE    = 9007;

  // Lazarus-only raw transport baseline: pure fphttpserver, no Horse.
  // FPC analog of BENCH_PORT_RAW_INDY (raw default self-hosted transport).
  BENCH_PORT_RAW_FPC_HTTP     = 9008;

  // OverbyteICS provider (Delphi; Windows + POSIX/Linux64).
  BENCH_PORT_ICS_BARE         = 9009;

  // Raw transport baseline: pure ICS THttpServer, no Horse. ICS analog of
  // BENCH_PORT_RAW_CROSSSOCKET. (Also defined locally in the raw server, which
  // does not use this unit.)
  BENCH_PORT_RAW_ICS          = 9010;

  { ── HTTP/2 and epoll providers (Linux-focused; see
      plans/bench-plan-all-providers.md) ──────────────────────────────────

    Placed at 9041+ rather than continuing 9011+, because of the offset
    arithmetic: middleware is bare+10 and TLS is bare+30, so a bare port at
    9021 would put its middleware variant on 9031 — which is already the TLS
    port of Indy at 9001. This block leaves both offsets collision-free
    (middleware 9051-9053, TLS 9071-9073).

    nghttp2 is the only HTTP/2 server here. Comparing it to the HTTP/1.1
    providers on a trivial route is NOT apples to apples — HTTP/2 pays for
    framing, HPACK and per-stream state that HTTP/1.1 keep-alive does not.
    See the plan's S1-vs-S4 split before drawing a conclusion from it. }
  BENCH_PORT_NGHTTP2_BARE     = 9041;   // Horse + nghttp2 (h2c)
  BENCH_PORT_RAW_NGHTTP2      = 9042;   // TNghttp2Server directly, no Horse
  BENCH_PORT_EPOLL_BARE       = 9043;   // Horse + built-in epoll provider

  // TLS / HTTPS variants. The TLS-capable self-hosted providers (CrossSocket,
  // mORMot, ICS) re-listen on bare_port + BENCH_PORT_TLS_OFFSET when started with
  // --tls. Chosen to avoid the integration-test TLS ports (9101/9111/9201).
  //   CrossSocket  9032   mORMot  9033   ICS  9039
  BENCH_PORT_TLS_OFFSET       = 30;

  ALLOC_BODY_SIZE = 1024;             // bytes returned by GET /alloc

procedure RegisterBenchRoutes;

implementation

uses
{$IF DEFINED(FPC)}
  SysUtils,
  Classes,
{$ELSE}
  System.SysUtils,
  System.Classes,
{$ENDIF}
  Horse;

// Route handlers are written as plain unit-scope procedures so the unit
// compiles on FPC without HORSE_FPC_FUNCTIONREFERENCES (anonymous procedures
// require {$MODESWITCH FUNCTIONREFERENCES+}, which only stable Horse builds
// enable). Delphi auto-promotes a plain procedure to its reference-to type;
// FPC's {$MODE DELPHI} accepts the same form. Do NOT add `@` — that would
// force a raw Pointer and fail Delphi's THorseCallbackRequestResponse type
// check.

procedure BenchPing(Req: THorseRequest; Res: THorseResponse);
begin
  Res.ContentType('text/plain; charset=utf-8');
  Res.Send('pong');
end;

procedure BenchEcho(Req: THorseRequest; Res: THorseResponse);
begin
  // Req.Body: string is safe on all three providers:
  //   CrossSocket — PATCH-REQ-9 caches the UTF-8-decoded body in FBodyString
  //   mORMot      — body is fully buffered in Ctxt.InContent before handler
  //   Indy        — body is buffered by TIdHTTPServer before handler
  Res.ContentType('text/plain; charset=utf-8');
  Res.Send(Req.Body);
end;

procedure BenchAlloc(Req: THorseRequest; Res: THorseResponse);
begin
  // Forces a heap allocation (StringOfChar) and a string send on every
  // request — measures allocator pressure under concurrent load.
  Res.ContentType('text/plain; charset=utf-8');
  Res.Send(StringOfChar('X', ALLOC_BODY_SIZE));
end;

procedure RegisterBenchRoutes;
begin
  // ── GET /ping — pure routing overhead, fixed 4-byte string ──────────────
  THorse.Get('/ping',  BenchPing);
  // ── POST /echo — body read + write ─────────────────────────────────────
  THorse.Post('/echo', BenchEcho);
  // ── GET /alloc — 1 KB allocation + serialisation ───────────────────────
  THorse.Get('/alloc', BenchAlloc);
end;

end.
