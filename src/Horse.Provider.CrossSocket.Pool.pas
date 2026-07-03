unit Horse.Provider.CrossSocket.Pool;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

{
  Horse CrossSocket Provider  -  Context Object Pool
  ---------------------------------------------------

  ── Prerequisite: Horse fork patches must be applied ────────────────────────
  This unit depends on two patches to the Horse fork (horse-fork/src/):

    PATCH-REQ-1 (Horse.Request.pas)
      constructor THorseRequest.Create;  overload;
      — Parameterless constructor. Required because the pool pre-allocates
        THorseRequest instances at startup, before any TWebRequest exists.

    PATCH-REQ-2 (Horse.Request.pas)
      procedure THorseRequest.Clear;
      — Resets all internal state. Sets FBody := nil (non-owning ref, NEVER
        freed), FSession := nil, FWebRequest := nil, clears param collections.

    PATCH-RES-2 (Horse.Response.pas)
      procedure THorseResponse.Clear;
      — Sets FWebResponse := nil, FContent := nil, clears FCustomHeaders.

  The unpatched upstream THorseRequest.Create requires a TWebRequest argument.
  The unpatched classes have no Clear method.  This unit will not compile
  against unpatched Horse sources.

  ── Why the pool exists ─────────────────────────────────────────────────────
  THorseRequest and THorseResponse own multiple TDictionary and TList objects
  (headers, params, query, cookies, content fields).  Allocating and freeing
  these on every request generates significant GC pressure under load.  The
  pool pre-allocates POOL_WARMUP_SIZE contexts at startup and recycles them
  after each request via Reset, which calls the patched Clear methods instead
  of Free/Create.

  ── Security contract (Reset) ───────────────────────────────────────────────
  [SEC-7]  Complete Reset guarantee.
           THorseRequest.Clear (PATCH-REQ-2) handles every security-sensitive
           field internally:
             FBody       — nil'd if FOwnsBody=False (CrossSocket non-owning ref);
                           freed if FOwnsBody=True (middleware-owned object, e.g.
                           Jhonson JSON).  FOwnsBody reset to False. (PATCH-REQ-11)
             FSession    — freed if FOwnsSession=True; nil'd otherwise.
             FWebRequest := nil   (previous Indy context, now invalid)
             FHeaders, FParams    Clear in place
             FQuery, FContentFields, FCookie  FreeAndNil (lazy rebuild)
             FSessions            Clear in place (PATCH-SES-1)
           THorseResponse.Clear (PATCH-RES-2) handles:
             FWebResponse  := nil
             FContent      := nil
             FCustomHeaders.Clear in place
           Reset delegates entirely to Clear — no Body() setter calls needed.

           NOTE: THorseRequest exposes no settable properties for Method,
           PathInfo, RawPathInfo, RemoteAddr, or ContentType.  Those fields
           all delegate to FWebRequest, which Clear sets to nil, making them
           unreachable.  There is nothing further to explicitly zero.

  [SEC-8]  DEBUG build poison.
           In DEBUG mode the InUse flag is checked on Acquire and Release to
           catch double-acquire and double-release programming errors.

  [SEC-9]  FBody ownership — non-owning CrossSocket buffer reference.
           MapBody calls Body(stream, {AOwnsBody=False) so FOwnsBody stays
           False on the CrossSocket path.  THorseRequest.Clear checks FOwnsBody
           before calling FreeAndNil — False means only nil the pointer, never
           free the referent.  CrossSocket's TCrossHttpRequest remains the sole
           owner and frees its own stream in its Destroy.
           If middleware (e.g. Jhonson) later calls Body(ParsedObj) [default
           AOwnsBody=True], Clear will correctly free that owned object on pool
           recycle — no Body() setter calls needed anywhere in this unit.

  [SEC-10] Pool counter uses TInterlocked for the hot-path IdleCount read.
           Structural changes (Push/Pop) still happen under FLock.

  [SEC-11] WarmUp runs outside the lock to avoid re-entrancy if
           THorseRequest.Create ever acquires FLock indirectly.
}

interface

uses
{$IF DEFINED(FPC)}
  SysUtils,
  Classes,
  SyncObjs,
  Generics.Collections,
{$ELSE}
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.Generics.Collections,
{$ENDIF}
  Horse.Request,
  Horse.Response;

const
  POOL_MAX_SIZE    = 512;
  POOL_WARMUP_SIZE = 32;

type
  THorseContext = class
  private
    FRequest:  THorseRequest;
    FResponse: THorseResponse;
    FInUse:    Boolean;   // [SEC-8] debug guard: detects double-acquire/release
  public
    constructor Create;
    destructor  Destroy; override;

    { [SEC-7] Guaranteed complete Reset — delegates to patched Clear methods }
    procedure Reset;

    property Request:  THorseRequest  read FRequest;
    property Response: THorseResponse read FResponse;
    property InUse:    Boolean        read FInUse write FInUse;
  end;

  THorseContextPool = class
  private
    class var FPool:      TStack<THorseContext>;
    class var FLock:      TCriticalSection;
    class var FIdleCount: Integer;   // [SEC-10] written under lock, read via TInterlocked

    class procedure InternalWarmUp;
  public
    class constructor Create;
    class destructor  Destroy;

    class function  Acquire: THorseContext;
    class procedure Release(AContext: THorseContext);
    class function  IdleCount: Integer; inline;
  end;

implementation

{ THorseContext }

constructor THorseContext.Create;
begin
  inherited Create;
  // PATCH-REQ-1: parameterless constructor — FWebRequest is set to nil.
  // Populate() in the CrossSocket bridge will assign the real FWebRequest
  // before the context enters the middleware pipeline.
  FRequest  := THorseRequest.Create;
  // THorseResponse.Create also requires a TWebResponse argument in unpatched
  // Horse.  If a patched parameterless overload is unavailable, the bridge
  // must call FResponse.RawWebResponse := ... before use.
  // For now we rely on the Response.Clear path setting FWebResponse := nil
  // and the bridge assigning a fresh one on each request.
  FResponse := THorseResponse.Create(nil);
  FInUse    := False;
end;

destructor THorseContext.Destroy;
begin
  // [SEC-9] Clear before Free: FOwnsBody=False on the CrossSocket path so
  // Clear nils FBody without freeing it.  THorseRequest.Destroy then sees
  // FOwnsBody=False and skips the Free, preventing double-free.  If middleware
  // set an owned body (FOwnsBody=True), Clear frees it here — correct.
  FRequest.Clear;
  FRequest.Free;
  FResponse.Free;
  inherited Destroy;
end;

procedure THorseContext.Reset;
begin
  // ── [SEC-7][SEC-9] Delegate to patched Clear methods ─────────────────────
  // THorseRequest.Clear (PATCH-REQ-2) safely wipes all fields including FBody:
  //   FBody — nil'd (FOwnsBody=False, CrossSocket non-owning ref) or freed
  //           (FOwnsBody=True, e.g. Jhonson JSON object owned by middleware).
  //           FOwnsBody reset to False. (PATCH-REQ-11)
  //   FSession, FWebRequest → nil / freed per FOwnsSession
  //   FHeaders, FParams   → Clear in place
  //   FQuery, FContentFields, FCookie → FreeAndNil (lazy rebuild on next use)
  //   FSessions → Clear in place (PATCH-SES-1)
  FRequest.Clear;

  // Response.Clear (PATCH-RES-2) wipes:
  //   FWebResponse, FContent → nil
  //   FCustomHeaders.Clear
  FResponse.Clear;

  // Mark as available — used by DEBUG double-release guard [SEC-8]
  FInUse := False;
end;

{ THorseContextPool }

class constructor THorseContextPool.Create;
begin
  FPool      := TStack<THorseContext>.Create;
  FLock      := TCriticalSection.Create;
  FIdleCount := 0;
  // [SEC-11] WarmUp outside the lock — avoids re-entrancy
  InternalWarmUp;
end;

class destructor THorseContextPool.Destroy;
var
  Ctx: THorseContext;
begin
  FLock.Acquire;
  try
    while FPool.Count > 0 do
    begin
      Ctx := FPool.Pop;
      // [SEC-9] Idle pool contexts have FBody = nil (cleared by the last Reset).
      // Ctx.Free → THorseContext.Destroy → FRequest.Clear (sets FBody := nil)
      // → FRequest.Free → THorseRequest.Destroy (FBody already nil, no Free).
      // DO NOT call Ctx.FRequest.Body(nil) here — the setter would free FBody.
      Ctx.Free;
    end;
    FIdleCount := 0;
  finally
    FLock.Release;
  end;
  FPool.Free;
  FLock.Free;
end;

class procedure THorseContextPool.InternalWarmUp;
var
  I:     Integer;
  Batch: array[0..POOL_WARMUP_SIZE - 1] of THorseContext;
begin
  // Allocate outside the lock — construction should not need FLock [SEC-11]
  for I := 0 to POOL_WARMUP_SIZE - 1 do
    Batch[I] := THorseContext.Create;

  FLock.Acquire;
  try
    for I := 0 to POOL_WARMUP_SIZE - 1 do
    begin
      FPool.Push(Batch[I]);
      Inc(FIdleCount);
    end;
  finally
    FLock.Release;
  end;
end;

class function THorseContextPool.Acquire: THorseContext;
begin
  FLock.Acquire;
  try
    if FPool.Count > 0 then
    begin
      Result := FPool.Pop;
      Dec(FIdleCount);
    end
    else
      Result := THorseContext.Create;
  finally
    FLock.Release;
  end;

  {$IFDEF DEBUG}
  // [SEC-8] Programming error: Acquire called on an already in-use context
  Assert(not Result.InUse,
    'THorseContextPool.Acquire: context already marked in-use (double-acquire?)');
  {$ENDIF}
  Result.InUse := True;
end;

class procedure THorseContextPool.Release(AContext: THorseContext);
begin
  if AContext = nil then Exit;

  {$IFDEF DEBUG}
  // [SEC-8] Programming error: Release called on a context not in use
  Assert(AContext.InUse,
    'THorseContextPool.Release: context was not acquired (double-release?)');
  {$ENDIF}

  // [SEC-7] Reset BEFORE re-entering the pool.
  // If Reset raises, the context is discarded rather than returned dirty.
  try
    AContext.Reset;
  except
    AContext.Free;
    Exit;
  end;

  FLock.Acquire;
  try
    if FIdleCount < POOL_MAX_SIZE then
    begin
      FPool.Push(AContext);
      Inc(FIdleCount);
    end
    else
      AContext.Free;   // pool full — discard surplus
  finally
    FLock.Release;
  end;
end;

class function THorseContextPool.IdleCount: Integer;
begin
  // [SEC-10] Atomic read — safe from any thread without the lock
  {$IF DEFINED(FPC)}
  Result := InterlockedCompareExchange(FIdleCount, 0, 0);
  {$ELSE}
  Result := TInterlocked.CompareExchange(FIdleCount, 0, 0);
  {$ENDIF}
end;

end.
