unit Horse.Provider.CrossSocket.StreamWriter;

{
  [STREAM-WRITER-1] CrossSocket push stream writer — Phase 2 (2026-07-18, rev 2)
  =============================================================================
  Implements upstream's PUSH streaming (IHorseStreamWriter, engaged by
  Res.SendStream) on CrossSocket. Replaces the retired PULL engine
  (Horse.Provider.CrossSocket.ResponseStream).

  WHY NOT THorseStreamWriterBase + raw SendBytes (rev 1, reverted): the base
  class frames chunks itself, and — critically — raw ICrossConnection.SendBytes
  BYPASSES CrossSocket's per-request response queue (TCrossHttpResponse._Send ->
  _QueueResponseReady). The queue item never completes, so the connection never
  advances to the next request: streaming worked but the keep-alive /ping after a
  stream WEDGED. A response MUST go through ICrossHttpResponse's own send.

  DESIGN (rev 2): implement IHorseStreamWriter DIRECTLY (no base class, so nothing
  pre-frames) and drive CrossSocket's queue-based SendNoCompress(chunkSource) —
  the same primitive the old validated pull model used. Write() enqueues raw chunk
  data to a thread-safe queue; the FIRST Write (or Close) kicks off SendNoCompress,
  whose chunk source BLOCK-dequeues from the queue on CrossSocket IO threads;
  Close() enqueues EOF and BLOCKS until SendNoCompress fully drains. SendNoCompress
  adds Transfer-Encoding: chunked + framing + terminator AND completes the queue
  item -> keep-alive advances correctly. Because Close blocks until drain, the whole
  response is sent before the handler returns -> the provider releases the pool
  inline (no deferred-completion machinery).

  Threading / v1 limitation: the handler (SendStream callback) runs synchronously
  on the CrossSocket IO thread; its own pacing (Sleep between Writes) ties up that
  IO thread, and the chunk source blocks another IO thread while the queue is empty.
  Fine for the test load (IoThreads = CPU count); a dedicated worker pool for
  long-lived SSE is Phase 3.
}

{$IF DEFINED(FPC)}
{$MODE DELPHI}{$H+}
{ reference-to-procedure/function closures (SendNoCompress source + callback). }
{$MODESWITCH FUNCTIONREFERENCES}
{$MODESWITCH ANONYMOUSFUNCTIONS}
{$ENDIF}

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
  Net.CrossHttpServer,
  Net.CrossSocket.Base,
  Horse.Response,
  Horse.Provider.RawAdapters,
  Horse.Provider.CrossSocket.RawResponse;

type
  { Fired (once) when the async SendNoCompress send has fully drained — used by the
    provider to defer the pooled-context release until the stream is really done. }
  TStreamDoneProc = reference to procedure;

  TCrossSocketStreamWriter = class(TInterfacedObject, IHorseStreamWriter)
  private
    FResponse:   THorseResponse;
    FCrossRes:   ICrossHttpResponse;
    FQueue:      TQueue<TBytes>;
    FLock:       TCriticalSection;
    FDataEvent:  TEvent;   // signals: a chunk was enqueued, or EOF was set
    FDoneEvent:  TEvent;   // signals: SendNoCompress fully drained (completion fired)
    FCurrent:    TBytes;   // holds the chunk currently handed to CrossSocket
    FEOF:        Boolean;
    FStarted:    Boolean;
    FConnected:  Boolean;
    FCompleted:  Boolean;         // the async send has drained (completion fired)
    FOnComplete: TStreamDoneProc; // provider's deferred pool-release, run once on drain
    procedure EnsureStarted;
    function  PullChunk(const AData: PPointer; const ACount: PNativeInt): Boolean;
    procedure CopyHeaders;
    { Hand the writer a proc to run when the async send completes. True if the send
      is still in flight (deferred — completion runs AOnComplete); False if it
      already drained (caller runs cleanup inline — safe, the send is done). }
    function TryDeferCompletion(const AOnComplete: TStreamDoneProc): Boolean;
  public
    constructor Create(const AResponse: THorseResponse);
    destructor Destroy; override;
    { [STREAM-2] Provider handshake, atomic: claim the writer that ran on THIS
      thread during the just-executed pipeline and hand it AOnComplete. Returns
      True if release was deferred to the writer's completion, False if the caller
      must release inline (no streaming writer, or it already drained). An interface
      pin keeps the writer alive across the claim even if the send just finished. }
    class function TryDeferActive(const AOnComplete: TStreamDoneProc): Boolean; static;
    { IHorseStreamWriter }
    procedure Write(const AText: string); overload;
    procedure Write(const ABytes: TBytes); overload;
    procedure Flush;
    procedure Close;
    function IsConnected: Boolean;
  end;

procedure RegisterCrossSocketStreamWriter;

implementation

const
  DRAIN_TIMEOUT_MS = 60000;   // safety cap on a stuck stream

{ Per-thread handle to the stream writer created during the current pipeline.
  The pipeline runs synchronously on one CrossSocket IO thread, so a threadvar
  cleanly bridges the writer (created deep in Horse's SendStream) to the provider
  (which runs right after, on the same thread) without touching Horse core.
  GActiveWriterPin holds an interface reference so the writer stays alive across
  the claim even if its async send has already released the send-closure refs. }
threadvar
  GActiveWriter:    TCrossSocketStreamWriter;
  GActiveWriterPin: IHorseStreamWriter;

constructor TCrossSocketStreamWriter.Create(const AResponse: THorseResponse);
var
  LRaw: TObject;
begin
  inherited Create;
  FResponse  := AResponse;
  FQueue     := TQueue<TBytes>.Create;
  FLock      := TCriticalSection.Create;
  FDataEvent := TEvent.Create(nil, True {manual reset}, False, '');
  FDoneEvent := TEvent.Create(nil, True {manual reset}, False, '');
  FConnected := True;

  { Reach the live ICrossHttpResponse via the adapter chain. }
  LRaw := AResponse.RawWebResponse;
  if (LRaw <> nil) and (LRaw is TInterfacedWebResponse) then
    FCrossRes := TCrossSocketRawResponse(TInterfacedWebResponse(LRaw).RawRes).CrossRes;
  if not Assigned(FCrossRes) then
    FConnected := False;
end;

destructor TCrossSocketStreamWriter.Destroy;
begin
  FCrossRes := nil;
  FDoneEvent.Free;
  FDataEvent.Free;
  FLock.Free;
  FQueue.Free;
  inherited;
end;

procedure TCrossSocketStreamWriter.CopyHeaders;
{$IF DEFINED(FPC)}
var
  I: Integer;
  LList: TStrings;
{$ELSE}
var
  LList: TDictionary<string, string>;
  LPair: TPair<string, string>;
{$ENDIF}
begin
  { The normal TResponseBridge.Flush is skipped for streaming responses, so copy
    the app's Res.AddHeader'd headers onto the CrossSocket response here.
    Transfer-Encoding: chunked is added by SendNoCompress itself — do NOT copy it. }
  LList := FResponse.CustomHeaders;
  if LList = nil then
    Exit;
  {$IF DEFINED(FPC)}
  for I := 0 to LList.Count - 1 do
    if (LList.Names[I] <> '') and not SameText(LList.Names[I], 'Transfer-Encoding') then
      FCrossRes.Header[LList.Names[I]] := LList.ValueFromIndex[I];
  {$ELSE}
  for LPair in LList do
    if (LPair.Key <> '') and not SameText(LPair.Key, 'Transfer-Encoding') then
      FCrossRes.Header[LPair.Key] := LPair.Value;
  {$ENDIF}
end;

procedure TCrossSocketStreamWriter.EnsureStarted;
var
  LSelf: IHorseStreamWriter;
begin
  if FStarted then
    Exit;
  FStarted := True;

  { Register on this thread so the provider can claim us after the pipeline and
    defer the pooled-context release until our async send completes. The interface
    pin keeps us alive until the provider claims (even if the send drains first). }
  GActiveWriter    := Self;
  GActiveWriterPin := Self;

  if not Assigned(FCrossRes) then
  begin
    { No live CrossSocket response — nothing to stream. Mark completed so the
      provider's TryDeferCompletion returns False and it releases the pool inline. }
    FConnected := False;
    FCompleted := True;
    FDoneEvent.SetEvent;
    Exit;
  end;

  FCrossRes.StatusCode := FResponse.Status;
  if FResponse.CSContentType <> '' then
    FCrossRes.ContentType := FResponse.CSContentType;
  CopyHeaders;

  { Strong self-reference captured by both closures pins this writer for the whole
    async send (independent of the handler returning / interface going out of scope). }
  LSelf := Self;
  FCrossRes.SendNoCompress(
    function(const AData: PPointer; const ACount: PNativeInt): Boolean
    begin
      Result := (LSelf <> nil) and PullChunk(AData, ACount);
    end,
    procedure(const AConnection: ICrossConnection; const ASuccess: Boolean)
    var
      LDone: TStreamDoneProc;
    begin
      if LSelf <> nil then
        FConnected := FConnected and ASuccess;
      FLock.Enter;
      try
        FCompleted := True;
        LDone := FOnComplete;   // provider's deferred pool-release, if registered
        FOnComplete := nil;
      finally
        FLock.Leave;
      end;
      FDoneEvent.SetEvent;
      { Run the deferred release OUTSIDE the lock (it must not re-enter the writer). }
      if Assigned(LDone) then
        LDone();
    end);
end;

function TCrossSocketStreamWriter.TryDeferCompletion(
  const AOnComplete: TStreamDoneProc): Boolean;
begin
  FLock.Enter;
  try
    if FCompleted then
      { Already drained — the send is done, so releasing the pool inline is safe. }
      Result := False
    else
    begin
      FOnComplete := AOnComplete;
      Result := True;
    end;
  finally
    FLock.Leave;
  end;
end;

class function TCrossSocketStreamWriter.TryDeferActive(
  const AOnComplete: TStreamDoneProc): Boolean;
var
  LWriter: TCrossSocketStreamWriter;
begin
  LWriter := GActiveWriter;
  GActiveWriter := nil;
  try
    Result := (LWriter <> nil) and LWriter.TryDeferCompletion(AOnComplete);
  finally
    { Release the pin AFTER the call — LWriter stays alive throughout. If deferral
      succeeded the in-flight send-closures keep it alive until completion; if not,
      it may free here, which is fine (the send already drained). }
    GActiveWriterPin := nil;
  end;
end;

function TCrossSocketStreamWriter.PullChunk(const AData: PPointer;
  const ACount: PNativeInt): Boolean;
begin
  { Called by CrossSocket on IO threads, sequentially — the previous chunk is fully
    sent before the next pull, so FCurrent (overwritten each pull) is safe. Block
    until a chunk is available or EOF is reached. }
  while True do
  begin
    FLock.Enter;
    try
      if FQueue.Count > 0 then
      begin
        FCurrent := FQueue.Dequeue;
        { Defensive: never take @FCurrent[0] on an empty array — that dereferences
          a nil dynamic array (Read of address 00000000). Write already skips empty
          payloads, but skip any that slip through rather than crash the IO thread. }
        if Length(FCurrent) = 0 then
          Continue;
        AData^  := @FCurrent[0];
        ACount^ := Length(FCurrent);
        Exit(True);
      end;
      if FEOF then
      begin
        AData^  := nil;
        ACount^ := 0;
        Exit(False);
      end;
      FDataEvent.ResetEvent;
    finally
      FLock.Leave;
    end;
    if FDataEvent.WaitFor(DRAIN_TIMEOUT_MS) <> wrSignaled then
    begin
      AData^  := nil;
      ACount^ := 0;
      Exit(False);   // stuck producer — end the stream rather than hang forever
    end;
  end;
end;

procedure TCrossSocketStreamWriter.Write(const AText: string);
begin
  Write(TEncoding.UTF8.GetBytes(AText));
end;

procedure TCrossSocketStreamWriter.Write(const ABytes: TBytes);
begin
  if Length(ABytes) = 0 then
    Exit;
  { Enqueue BEFORE starting. CrossSocket's SendNoCompress pulls the FIRST chunk
    synchronously and inline on THIS thread (to decide chunked-vs-not), so the
    data must already be queued — otherwise that first pull blocks forever inside
    EnsureStarted and the enqueue never happens (deadlock). }
  FLock.Enter;
  try
    FQueue.Enqueue(Copy(ABytes, 0, Length(ABytes)));
    FDataEvent.SetEvent;
  finally
    FLock.Leave;
  end;
  EnsureStarted;
end;

procedure TCrossSocketStreamWriter.Flush;
begin
  { No-op: each Write already enqueues; CrossSocket drains asynchronously. }
end;

procedure TCrossSocketStreamWriter.Close;
begin
  { Mark EOF BEFORE starting. For a zero-write (empty) stream this is the first
    EnsureStarted call, and SendNoCompress's synchronous inline first-pull must
    see EOF (return no data) rather than block. For a non-empty stream
    EnsureStarted already ran in Write, so here it is a no-op. }
  FLock.Enter;
  try
    FEOF := True;
    FDataEvent.SetEvent;
  finally
    FLock.Leave;
  end;
  EnsureStarted;
  { Do NOT block here. ExecutePipeline runs the handler INLINE on the CrossSocket IO
    thread, under the connection's recv-lock. Blocking until the send drains holds
    that lock across the send's completion, so CrossSocket's keep-alive advance for
    the NEXT request is lost — the /ping after a stream wedges. Returning immediately
    lets the async SendNoCompress pump finish after the handler unwinds and the lock
    is released, matching the proven pull model. Safe because: (a) the producer ran
    synchronously before Close, so every chunk + EOF is already queued; (b) the
    strong self-ref captured in the SendNoCompress closures pins this writer until
    the send completes; (c) after EnsureStarted the async send touches only the
    writer's own queue and FCrossRes (a separately ref-counted ICrossHttpResponse) —
    never the pooled Ctx — so the provider's inline pool release stays safe. }
end;

function TCrossSocketStreamWriter.IsConnected: Boolean;
begin
  Result := FConnected and Assigned(FCrossRes);
end;

{ ── Factory ────────────────────────────────────────────────────────────────── }

function TCrossSocketStreamWriter_Factory(const AResponse: THorseResponse): IHorseStreamWriter;
begin
  Result := TCrossSocketStreamWriter.Create(AResponse);
end;

procedure RegisterCrossSocketStreamWriter;
begin
  THorseResponse.RegisterStreamWriterFactory(TCrossSocketStreamWriter_Factory);
end;

end.
