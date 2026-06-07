unit Horse.BenchRoutes;

(*
  Horse Performance Benchmark — Shared Route Registration
  ========================================================

  Three provider-agnostic routes used by all three bench server binaries
  (HorseBenchIndy, HorseBenchCrossSocket, HorseBenchMormot).

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

procedure RegisterBenchRoutes;
begin
  // ── GET /ping — pure routing overhead ──────────────────────────────────
  // Returns a fixed 4-byte string.  No body parsing, no serialisation.
  // Measures the provider's per-request overhead at its lowest.
  THorse.Get('/ping',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('text/plain; charset=utf-8');
      Res.Send('pong');
    end);

  // ── POST /echo — body read + write ─────────────────────────────────────
  // Req.Body: string is safe on all three providers:
  //   CrossSocket — PATCH-REQ-9 caches the UTF-8-decoded body in FBodyString
  //   mORMot      — body is fully buffered in Ctxt.InContent before handler
  //   Indy        — body is buffered by TIdHTTPServer before handler
  // No stream ownership concern: using the string accessor only.
  THorse.Post('/echo',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('text/plain; charset=utf-8');
      Res.Send(Req.Body);
    end);

  // ── GET /alloc — 1 KB allocation + serialisation ───────────────────────
  // Forces a heap allocation (StringOfChar) and a string send on every
  // request.  Useful for measuring allocator pressure under concurrent load.
  THorse.Get('/alloc',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('text/plain; charset=utf-8');
      Res.Send(StringOfChar('X', ALLOC_BODY_SIZE));
    end);
end;

end.
