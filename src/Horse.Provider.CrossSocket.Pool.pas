unit Horse.Provider.CrossSocket.Pool;

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
             FBody       := nil   (non-owning CrossSocket buffer ref)
             FSession    := nil   (stale session = wrong-request auth)
             FWebRequest := nil   (previous Indy context, now invalid)
             FHeaders, FParams    Dictionary.Clear in place
             FQuery, FContentFields, FCookie  FreeAndNil (lazy rebuild)
             FSessions            FreeAndNil + THorseSessions.Create
           THorseResponse.Clear (PATCH-RES-2) handles:
             FWebResponse  := nil
             FContent      := nil
             FCustomHeaders.Clear in place
           Reset sets FRequest.Body(nil) BEFORE calling Clear as a belt-and-
           suspenders guard: Clear already sets FBody := nil, but the explicit
           call here documents the ownership contract at the call site.

           NOTE: THorseRequest exposes no settable properties for Method,
           PathInfo, RawPathInfo, RemoteAddr, or ContentType.  Those fields
           all delegate to FWebRequest, which Clear sets to nil, making them
           unreachable.  There is nothing further to explicitly zero.

  [SEC-8]  DEBUG build poison.
           In DEBUG mode the InUse flag is checked on Acquire and Release to
           catch double-acquire and double-release programming errors.

  [SEC-9]  FBody ownership.
           FBody is a non-owning reference into CrossSocket's receive buffer.
           It must NEVER be freed by the pool.  Reset calls
           FRequest.Body(nil) — the setter overload — which in the patched
           Request sets FBody := nil without freeing it.  The destructor uses
           the same call for the same reason.

  [SEC-10] Pool counter uses TInterlocked for the hot-path IdleCount read.
           Structural changes (Push/Pop) still happen under FLock.

  [SEC-11] WarmUp runs outside the lock to avoid re-entrancy if
           THorseRequest.Create ever acquires FLock indirectly.
}

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.Generics.Collections,
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
  // [SEC-9] Body is a non-owning CrossSocket buffer reference.
  // Use the setter overload Body(ABody: TObject) which sets FBody := ABody
  // WITHOUT freeing the old value.  Never call FBody.Free directly here.
  FRequest.Body(nil);

  FRequest.Free;
  FResponse.Free;
  inherited Destroy;
end;

procedure THorseContext.Reset;
begin
  // ── [SEC-9] Clear non-owning Body reference FIRST ────────────────────────
  // Body(AObject) is the setter overload: THorseRequest.Body(const ABody: TObject): THorseRequest
  // It sets FBody := ABody WITHOUT freeing the old value.
  // This must happen before Clear so that Clear's own safety check
  // (FBody := nil) fires on an already-nil value, not a stale pointer.
  FRequest.Body(nil);

  // ── [SEC-7] Delegate to patched Clear methods ─────────────────────────────
  // Request.Clear (PATCH-REQ-2) wipes:
  //   FBody, FSession, FWebRequest → nil
  //   FHeaders.Dictionary.Clear
  //   FQuery, FContentFields, FCookie → FreeAndNil (lazy rebuild on next use)
  //   FParams.Dictionary.Clear
  //   FSessions → FreeAndNil + THorseSessions.Create
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
      // [SEC-9] Clear non-owning Body ref before final free
      Ctx.FRequest.Body(nil);
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
  Result := TInterlocked.CompareExchange(FIdleCount, 0, 0);
end;

end.
