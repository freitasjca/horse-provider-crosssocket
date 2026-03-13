unit Horse.Provider.CrossSocket.WorkerPool;

{
  Horse CrossSocket Provider  -  Worker Thread Pool  (hardened)
  --------------------------------------------------------------
  Security fixes applied vs previous version
  -------------------------------------------
  [SEC-25] Exception swallowing removed.
  [SEC-26] Queue depth limit — Submit raises HTTP 503 when full.
  [SEC-27] Graceful shutdown drain.
  [SEC-28] Thread names for debuggability.

  ── Fix log ─────────────────────────────────────────────────────────────────
  [FIX-WP-1] class var contamination (E2356 x3) — singleton moved to
             unit-level var GHorseWorkerPool.
  [FIX-WP-2] THTTPStatus undeclared — Horse.Commons added to uses.
  [FIX-WP-3] Chained raise syntax — local var LEx used instead.
  [FIX-WP-4] TQueue<TWorkerTask> + anonymous method = E2010/E2089 on
             pre-10.4 compilers.
             Root cause: on older Delphi compilers, specialising a generic
             container over an anonymous method type ('reference to procedure')
             produces an internal type that the compiler cannot unify with the
             original named type on assignment or dequeue. No cast syntax fixes
             this — 'TWorkerTask(q.Dequeue)' is E2089 because anonymous methods
             are interface types, not objects.
             Fix: store tasks as raw interface pointers (Pointer) in a
             TQueue<Pointer>.  Enqueue manually calls _AddRef to keep the
             closure alive; Dequeue calls _Release after copying the reference
             to a typed local.  This is exactly how Delphi's own anonymous
             method infrastructure works internally and compiles cleanly on
             all versions back to Delphi XE.
}

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.Generics.Collections;

const
  WORKER_POOL_MIN_THREADS  = 4;
  WORKER_POOL_MAX_THREADS  = 64;
  MAX_QUEUE_DEPTH          = 4096;
  SHUTDOWN_DRAIN_MS        = 5000;

type
  // Declared as a named interface so the compiler never needs to specialise
  // a generic over it — avoids E2010 / E2089 on pre-10.4 compilers.
  IWorkerTask = interface
    ['{8F3A1B2C-4D5E-6F70-8192-A3B4C5D6E7F8}']
    procedure Execute;
  end;

  // Public alias kept for callers: pass any 'reference to procedure' as
  // TWorkerTask — the bridge below wraps it into IWorkerTask automatically.
  TWorkerTask = reference to procedure;

  // [SEC-25]
  TWorkerErrorProc = reference to procedure(const E: Exception; ATaskIndex: Int64);

  TWorkerThread = class(TThread)
  private
    FPool:      TObject;
    FThreadIdx: Integer;
  protected
    procedure Execute; override;
  end;

  THorseWorkerPool = class
  private
    // [FIX-WP-1] Singleton is a unit-level var (see GHorseWorkerPool below).
    // All fields here are plain instance fields — no 'class var' in this block.
    FQueue:         TQueue<Pointer>;  // [FIX-WP-4] stores IWorkerTask as Pointer
    FLock:          TCriticalSection;
    FWorkEvent:     TEvent;
    FDrainEvent:    TEvent;
    FThreads:       TList<TWorkerThread>;
    FShutdown:      Boolean;
    FThreadCount:   Integer;
    FRunningTasks:  Integer;
    FTaskIndex:     Int64;
    FOnTaskError:   TWorkerErrorProc;

    procedure SpawnThread(AIndex: Integer);
    procedure WorkerLoop(AThreadIdx: Integer);
    procedure TaskStarted;  inline;
    procedure TaskFinished; inline;

    // [FIX-WP-4] Queue helpers — manual refcount on the interface pointer
    procedure EnqueueTask(const ATask: TWorkerTask);
    function  DequeueTask(out ATask: IWorkerTask): Boolean;

  public
    constructor Create(AMinThreads, AMaxThreads: Integer);
    destructor  Destroy; override;

    procedure Submit(ATask: TWorkerTask);

    property OnTaskError: TWorkerErrorProc read FOnTaskError write FOnTaskError;

    class function  Instance: THorseWorkerPool;
    class procedure Initialize(
      AMinThreads: Integer = WORKER_POOL_MIN_THREADS;
      AMaxThreads: Integer = WORKER_POOL_MAX_THREADS
    );
    class procedure Finalize;

    property ThreadCount: Integer read FThreadCount;
  end;

implementation

uses
  Horse.Commons,
  Horse.Exception;

// ── Singleton ─────────────────────────────────────────────────────────────────
var
  GHorseWorkerPool: THorseWorkerPool;

// ── TWorkerTaskWrapper ────────────────────────────────────────────────────────
// Wraps a TWorkerTask (anonymous proc) in a named IWorkerTask interface so that
// the queue never needs to be specialised over an anonymous method type.
type
  TWorkerTaskWrapper = class(TInterfacedObject, IWorkerTask)
  private
    FProc: TWorkerTask;
  public
    constructor Create(const AProc: TWorkerTask);
    procedure Execute;
  end;

constructor TWorkerTaskWrapper.Create(const AProc: TWorkerTask);
begin
  inherited Create;
  FProc := AProc;
end;

procedure TWorkerTaskWrapper.Execute;
begin
  if Assigned(FProc) then
    FProc;
end;

{ TWorkerThread }

procedure TWorkerThread.Execute;
begin
  TThread.NameThreadForDebugging('HorseWorker-' + IntToStr(FThreadIdx));
  THorseWorkerPool(FPool).WorkerLoop(FThreadIdx);
end;

{ THorseWorkerPool }

constructor THorseWorkerPool.Create(AMinThreads, AMaxThreads: Integer);
var
  I: Integer;
begin
  inherited Create;
  FQueue        := TQueue<Pointer>.Create;
  FLock         := TCriticalSection.Create;
  FWorkEvent    := TEvent.Create(nil, False, False, '');
  FDrainEvent   := TEvent.Create(nil, True, True, '');
  FThreads      := TList<TWorkerThread>.Create;
  FShutdown     := False;
  FThreadCount  := 0;
  FRunningTasks := 0;
  FTaskIndex    := 0;

  FOnTaskError :=
    procedure(const E: Exception; ATaskIndex: Int64)
    begin
      System.WriteLn(ErrOutput,
        Format('[HorseWorkerPool] Task #%d raised %s: %s',
               [ATaskIndex, E.ClassName, E.Message]));
    end;

  for I := 0 to AMinThreads - 1 do
    SpawnThread(I);
end;

destructor THorseWorkerPool.Destroy;
var
  T:    TWorkerThread;
  Task: IWorkerTask;
begin
  FLock.Acquire;
  FShutdown := True;
  FLock.Release;

  FWorkEvent.SetEvent;

  if FRunningTasks > 0 then
    FDrainEvent.WaitFor(SHUTDOWN_DRAIN_MS);

  for T in FThreads do
  begin
    T.WaitFor;
    T.Free;
  end;

  // Release any tasks still in the queue
  while DequeueTask(Task) do
    Task := nil;

  FThreads.Free;
  FQueue.Free;
  FWorkEvent.Free;
  FDrainEvent.Free;
  FLock.Free;
  inherited Destroy;
end;

// [FIX-WP-4] Wrap the anonymous proc and push its interface pointer onto the
// queue.  We call _AddRef manually so the closure survives until Dequeue.
procedure THorseWorkerPool.EnqueueTask(const ATask: TWorkerTask);
var
  Wrapper: IWorkerTask;
  Ptr:     Pointer;
begin
  Wrapper := TWorkerTaskWrapper.Create(ATask);
  // Extract the raw interface pointer and addref it.
  // The queue owns one reference; DequeueTask releases it.
  Ptr := Pointer(Wrapper);
  IInterface(Ptr)._AddRef;
  FQueue.Enqueue(Ptr);
end;

// Returns True and sets ATask when a task was dequeued; False when queue empty.
// Transfers ownership: the interface reference is now in ATask; _Release is
// called via ATask going out of scope normally (reference counting).
function THorseWorkerPool.DequeueTask(out ATask: IWorkerTask): Boolean;
var
  Ptr: Pointer;
begin
  Result := FQueue.Count > 0;
  if not Result then Exit;
  Ptr   := FQueue.Dequeue;
  // Assign into the typed interface variable — this does NOT addref again
  // (we use the ref that EnqueueTask already added).
  // We must use Pointer() trick to avoid the compiler inserting an extra addref.
  ATask := IWorkerTask(Ptr);
  // Now release the extra ref we held: ATask holds one ref, we drop the
  // queued ref so the net count stays at 1.
  IInterface(Ptr)._Release;
end;

procedure THorseWorkerPool.SpawnThread(AIndex: Integer);
var
  T: TWorkerThread;
begin
  T                  := TWorkerThread.Create(True);
  T.FPool            := Self;
  T.FThreadIdx       := AIndex;
  T.FreeOnTerminate  := False;
  FThreads.Add(T);
  Inc(FThreadCount);
  T.Start;
end;

procedure THorseWorkerPool.TaskStarted;
begin
  if TInterlocked.Increment(FRunningTasks) = 1 then
    FDrainEvent.ResetEvent;
end;

procedure THorseWorkerPool.TaskFinished;
begin
  if TInterlocked.Decrement(FRunningTasks) = 0 then
    FDrainEvent.SetEvent;
end;

procedure THorseWorkerPool.WorkerLoop(AThreadIdx: Integer);
var
  Task:    IWorkerTask;
  HasTask: Boolean;
  TaskIdx: Int64;
begin
  while True do
  begin
    FWorkEvent.WaitFor(INFINITE);

    while True do
    begin
      HasTask := False;
      FLock.Acquire;
      try
        if FShutdown and (FQueue.Count = 0) then
          Exit;

        HasTask := DequeueTask(Task);

        if FQueue.Count > 0 then
          FWorkEvent.SetEvent;
      finally
        FLock.Release;
      end;

      if not HasTask then Break;

      TaskIdx := TInterlocked.Increment(FTaskIndex);
      TaskStarted;
      try
        try
          Task.Execute;
        except
          on E: Exception do
            if Assigned(FOnTaskError) then
              FOnTaskError(E, TaskIdx);
        end;
      finally
        Task := nil;  // release interface ref before TaskFinished
        TaskFinished;
      end;
    end;
  end;
end;

procedure THorseWorkerPool.Submit(ATask: TWorkerTask);
var
  LEx: EHorseException;
begin
  FLock.Acquire;
  try
    if FShutdown then
    begin
      LEx := EHorseException.Create;
      LEx.Error('Server is shutting down').Status(THTTPStatus.ServiceUnavailable);
      raise LEx;
    end;

    if FQueue.Count >= MAX_QUEUE_DEPTH then
    begin
      LEx := EHorseException.Create;
      LEx.Error('Worker queue full — server overloaded').Status(THTTPStatus.ServiceUnavailable);
      raise LEx;
    end;

    EnqueueTask(ATask);
  finally
    FLock.Release;
  end;
  FWorkEvent.SetEvent;
end;

class function THorseWorkerPool.Instance: THorseWorkerPool;
begin
  if not Assigned(GHorseWorkerPool) then
    Initialize;
  Result := GHorseWorkerPool;
end;

class procedure THorseWorkerPool.Initialize(AMinThreads, AMaxThreads: Integer);
begin
  if not Assigned(GHorseWorkerPool) then
    GHorseWorkerPool := THorseWorkerPool.Create(AMinThreads, AMaxThreads);
end;

class procedure THorseWorkerPool.Finalize;
begin
  FreeAndNil(GHorseWorkerPool);
end;

initialization
  GHorseWorkerPool := nil;

finalization
  THorseWorkerPool.Finalize;

end.
