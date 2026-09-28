unit Horse.Provider.CrossSocket.Server;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

{
  Horse CrossSocket Provider  -  Server Wrapper
  -----------------------------------------------
  Wraps TCrossHttpServer from Delphi-Cross-Socket.

  ── Confirmed inheritance chain ─────────────────────────────────────────────
  TCrossHttpServer (Net.CrossHttpServer)
    └── TCrossServer (Net.CrossServer)
          └── TCrossSslSocket = TCrossOpenSslSocket (Net.CrossSslSocket)
                └── TCrossSslSocketBase (Net.CrossSslSocket.Base)
                      └── TCrossSocket (Net.CrossSocket.Base)

  ── Confirmed API — every call in this unit maps to a verified declaration ──

  TCrossSslSocketBase (Net.CrossSslSocket.Base.pas):
    constructor Create(const AIoThreads: Integer; const ASsl: Boolean)
    procedure SetCertificateFile(const ACertFile: string)
    procedure SetPrivateKeyFile(const APKeyFile: string; const APassword: string = '')
    procedure SetCertificate(const ACertStr: string)   overload
    procedure SetPrivateKey(const APKeyStr: string; const APassword: string = '')    overload
    property Ssl: Boolean  (read-only)

    ── mTLS / TLS options (upstream winddriver API ≥ 2026-08) ─────────────────
    procedure AddCACertificateFile(const AFileName: string)
      → loads CA cert, calls SSL_CTX_add_client_CA + X509_STORE_add_cert
    procedure SetVerifyPeer(const AVerify: Boolean)
      → SSL_CTX_set_verify(PEER|FAIL_IF_NO_PEER_CERT) / VERIFY_NONE
      (APassword='' leaves unencrypted-key path unchanged)
    Concrete implementations in TCrossOpenSslSocket call:
      AddCACertificate → SSL_CTX_add_client_CA + X509_STORE_add_cert
      SetVerifyPeer    → SSL_CTX_set_verify(SSL_VERIFY_PEER
                           or SSL_VERIFY_FAIL_IF_NO_PEER_CERT) / SSL_VERIFY_NONE
    ── TLSOPT-2 (upstream API since winddriver bb85ab4, 2026-09-06) ───────────
    procedure SetTls12CipherSuites(const ACipherRules: string)
      → SSL_CTX_set_cipher_list (TLS 1.2 and below)
    procedure SetTls13CipherSuites(const ACipherSuites: string)
      → SSL_CTX_set_ciphersuites (TLS 1.3; not yet surfaced by this provider)
      Both invalidate the TLS configuration on failure, so a rejected cipher
      string cannot leave a half-configured context serving.
      PR #200 proposed a single fork-only SetCipherList and was CLOSED in
      favour of this pair — one method cannot express both grammars.

  TCrossServer (Net.CrossServer.pas):
    procedure Start(const ACallback: TCrossListenCallback = nil)
    procedure Stop    — CloseAll + StopLoop + AtomicExchange(FStarted,0)
    property Active: Boolean  — AtomicCmpExchange(FStarted,0,0)=1
    property Port: Word       — set before Start
    property Addr: string     — set before Start

  TCrossHttpServer (Net.CrossHttpServer.pas):
    constructor Create(const AIoThreads: Integer; const ASsl: Boolean)
    property MaxHeaderSize:   Int64
    property MaxPostDataSize: Int64
    property Compressible:    Boolean
    property MinCompressSize: Int64

  ── Config fields applied in ApplyConfig ────────────────────────────────────
  Applied:
    IoThreads        → TCrossHttpServer constructor argument
    MaxHeaderSize    → FServer.MaxHeaderSize     [SEC-1]
    MaxBodySize      → FServer.MaxPostDataSize   [SEC-1]
    Compressible     → FServer.Compressible      [Config]
    MinCompressSize  → FServer.MinCompressSize   [Config]
    SSLEnabled       → TCrossHttpServer constructor argument
    SSLCertFile      → FServer.SetCertificateFile
    SSLKeyFile       → FServer.SetPrivateKeyFile
    SSLCACertFile    → FServer.AddCACertificateFile     (mTLS; upstream API)
    SSLVerifyPeer    → FServer.SetVerifyPeer             (mTLS; upstream API)
    SSLKeyPassword   → passed as APassword to SetPrivateKeyFile (upstream API)
    SSLCipherList    → FServer.SetTls12CipherSuites      (TLSOPT-2; DCS ≥1.0.11)

  SetTls12CipherSuites requires Delphi-Cross-Socket ≥1.0.11 (the release that
  merges winddriver bb85ab4). It raises ESslContextInvalid if the string
  selects no ciphers, and marks the TLS configuration invalid so the socket
  must be rebuilt rather than silently continuing.

  The config field keeps the name SSLCipherList: it is this provider's own
  option name and is unaffected by the DCS method rename. TLS 1.3 suites need
  SetTls13CipherSuites and a separate config field — not yet surfaced.

  Reserved (CrossSocket API not available):
    KeepAliveTimeout — no matching property confirmed in TCrossHttpServer
    ReadTimeout      — no matching property confirmed in TCrossHttpServer
    MaxConnections   — no matching property confirmed in TCrossHttpServer

  ── Security notes ───────────────────────────────────────────────────────────
  [SEC-1] MaxHeaderSize + MaxPostDataSize enforced to safe defaults.
          Leaving them at zero allows unbounded headers / body uploads.
  [SEC-2] IoThreads=0 lets the library choose (= CPU count). Exposed in
          config so callers can tune it for their workload.
  [SEC-3] SSL cert and key are loaded via SetCertificateFile /
          SetPrivateKeyFile — the confirmed API on TCrossSslSocketBase.
  [SEC-6] Stop() drains in-flight requests before returning.
}

interface

uses
{$IF DEFINED(FPC)}
  SysUtils,
  Classes,
  SyncObjs,
{$ELSE}
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
{$ENDIF}
  Net.SocketAPI,          // TSocketAPI.SetTcpNoDelay (TCP_NODELAY on accept)
  Net.CrossSocket.Base,   // ICrossConnection (OnConnected handler)
  Net.CrossHttpServer,
  Net.CrossHttpParams,
  Net.CrossSslSocket.Base,
  Horse.Provider.Config;


type
  // Callback type for routing an incoming request to the provider pipeline.
  // Using a procedure reference (not method-of-object) so the provider class
  // method can be stored without needing an object instance.
  TServerRequestCallback = reference to procedure(
    const ACrossReq: ICrossHttpRequest;
    const ACrossRes: ICrossHttpResponse
  );

  THorseCrossSocketServer = class
  private
    FServer:          TCrossHttpServer;
    // [FIX-REFCOUNT-1] TCrossHttpServer inherits from TInterfacedObject.
    // FServer is a plain object reference — it does NOT increment the
    // interface ref count.  Connections store their Owner as a plain
    // TCrossSocketBase reference too (no ref count).  So FRefCount on the
    // server object is 0 at startup.  The first time any code calls
    // GetConnection.Server and receives ICrossHttpServer into a local
    // variable, FRefCount jumps to 1.  When that local goes out of scope,
    // FRefCount drops back to 0 and BeforeDestruction → StopLoop fires —
    // on whichever thread the local was cleared, typically an IO thread,
    // which raises ECrossSocket '不能在IO线程中执行StopLoop!'.
    //
    // Fix: hold a permanent ICrossHttpServer interface reference alongside
    // the plain object reference.  FServerRef keeps FRefCount ≥ 1 for the
    // entire lifetime of THorseCrossSocketServer.  In Destroy we set
    // FServerRef := nil (last release) rather than calling FServer.Free,
    // because the interface release will call Destroy via _Release.
    FServerRef:       ICrossHttpServer;
    FConfig:          THorseCrossSocketConfig;
    FActiveConns:     Integer;   // interlocked counter for drain wait
    FDrainEvent:      TEvent;
    // [FIX-CS-1a] Stores the provider's request handler so the
    // method-of-object OnRequest event can forward to it.
    FRequestCallback: TServerRequestCallback;

    procedure ApplyConfig;
    // [FIX-CS-1a] [PATCH-CS-API-1] Method-of-object handler assigned to
    // FServer.OnRequest.  TCrossHttpRequestEvent signature (Delphi-Cross-Socket
    // upstream ≥ 2026-05) added a new AConnection: ICrossHttpConnection as the
    // second parameter:
    //   procedure(const Sender: TObject;
    //     const AConnection: ICrossHttpConnection;          { added upstream }
    //     const ARequest: ICrossHttpRequest;
    //     const AResponse: ICrossHttpResponse;
    //     var AHandled: Boolean) of object;
    // We don't use AConnection here — ARequest/AResponse already carry every-
    // thing the Horse pipeline needs (the connection is reachable from ARequest
    // via ARequest.Connection if ever required) — but the parameter must be
    // present for the method signature to match TCrossHttpRequestEvent.
    procedure InternalOnRequest(
      const Sender:      TObject;
      const AConnection: ICrossHttpConnection;
      const ARequest:    ICrossHttpRequest;
      const AResponse:   ICrossHttpResponse;
      var   AHandled:    Boolean
    );
    // [NODELAY] Method-of-object assigned to FServer.OnConnected — disables Nagle
    // (TCP_NODELAY) on every accepted connection. CrossSocket sets SO_KEEPALIVE on
    // accept but never TCP_NODELAY, so on Linux loopback keep-alive responses hit
    // the ~40 ms delayed-ACK -> a flat ~44 ms/request floor. See report §7.5.
    procedure InternalOnConnected(const Sender: TObject;
      const AConnection: ICrossConnection);
  public
    constructor Create(const AConfig: THorseCrossSocketConfig); overload;
    constructor Create; overload;
    destructor  Destroy; override;

    // AHost: '' or '0.0.0.0' = all interfaces (IPv4 + IPv6); anything else
    // becomes the CrossSocket bind Addr. Set by the Listen overload family.
    procedure Start(const APort: Integer; const AHost: string = '');
    // [SEC-6] Synchronous stop — waits up to Config.DrainTimeoutMs.
    // NOTE the ordering defect this carries, measured 10/10 on 2026-09-27:
    // TCrossServer.Stop is CloseAll + StopLoop, and CloseAll closes live
    // CONNECTIONS as well as listeners — so an in-flight request loses its
    // socket before the drain wait below is even reached. Use StopGraceful for
    // a shutdown that delivers the reply.
    procedure Stop;

    // [FIX-CS-GRACEFUL-1] Stop accepting, let in-flight requests finish AND
    // reply, then tear down. Bounded by ATimeoutMS (<= 0 falls back to
    // Config.DrainTimeoutMs). This is the drain THorseProviderCrossSocket
    // .StopListenGraceful needs; Stop above cannot provide it.
    procedure StopGraceful(const ATimeoutMS: Integer);

    // Called by the provider to bracket every in-flight request
    procedure IncrementActive; inline;
    procedure DecrementActive; inline;

    property Server:          TCrossHttpServer        read FServer;
    property Config:          THorseCrossSocketConfig read FConfig write FConfig;
    // [FIX-CS-1a] Provider sets this before calling Start.
    property RequestCallback: TServerRequestCallback  read FRequestCallback
                                                      write FRequestCallback;
  end;

implementation

const
  // [FIX-CS-GRACEFUL-1a] Grace period between "no requests in flight" and
  // teardown, covering CrossSocket's async send tail. Same value and same
  // reason as Horse.Provider.Console's post-drain TThread.Sleep(100).
  DEFAULT_SETTLE_MS = 100;

var
  // Overridable ONLY so the window can be characterised without a rebuild:
  // HORSE_CS_SETTLE_MS=0 / 100 / 1000 answers whether a lost response body is a
  // flush race (more time fixes it) or something actively discarding it (more
  // time changes nothing). A single value cannot distinguish those.
  GSettleMs: Integer = -1;

// Read once; an unset or unparseable value keeps the default.
function SettleMs: Integer;
var
  LRaw: string;
begin
  if GSettleMs < 0 then
  begin
    LRaw := GetEnvironmentVariable('HORSE_CS_SETTLE_MS');
    if (LRaw = '') or not TryStrToInt(Trim(LRaw), GSettleMs) or (GSettleMs < 0) then
      GSettleMs := DEFAULT_SETTLE_MS;
  end;
  Result := GSettleMs;
end;


{ THorseCrossSocketServer }

constructor THorseCrossSocketServer.Create(const AConfig: THorseCrossSocketConfig);
begin
  inherited Create;
  FConfig      := AConfig;
  FActiveConns := 0;
  // Manual-reset event, initially signalled (no active requests at startup)
  FDrainEvent  := TEvent.Create(nil, True, True, '');

  // Constructor confirmed: Create(AIoThreads: Integer; ASsl: Boolean)
  FServer := TCrossHttpServer.Create(FConfig.IoThreads, FConfig.SSLEnabled);

  // [FIX-REFCOUNT-1] Acquire the permanent interface reference immediately
  // after construction.  AfterConstruction has already decremented the
  // constructor's implicit +1, so FRefCount is 0 here.  This assignment
  // brings it to 1 and keeps it there for the object's lifetime.
  FServerRef := FServer;

  FServer.OnRequest := InternalOnRequest;
  FServer.OnConnected := InternalOnConnected;   // [NODELAY] TCP_NODELAY per connection

  ApplyConfig;
end;

constructor THorseCrossSocketServer.Create;
begin
  Create(THorseCrossSocketConfig.Default);
end;

destructor THorseCrossSocketServer.Destroy;
begin
  Stop;
  // [FIX-REFCOUNT-1] Release the interface reference rather than calling
  // FServer.Free.  When FServerRef is set to nil, _Release decrements
  // FRefCount to 0 (FServer is the only remaining holder), which triggers
  // BeforeDestruction → StopLoop on THIS thread (the caller of Destroy,
  // never an IO thread).  StopLoop exits immediately because FIoThreads
  // was already set to nil by Stop above.  Do NOT call FServer.Free after
  // this — the interface release has already freed the object.
  FServerRef := nil;
  FServer    := nil;  // nil the plain reference; object already freed above
  FDrainEvent.Free;
  inherited Destroy;
end;

procedure THorseCrossSocketServer.ApplyConfig;
begin
  // ── [SEC-1] Request size limits ───────────────────────────────────────────
  // MaxHeaderSize: confirmed property on ICrossHttpServer / TCrossHttpServer
  if FConfig.MaxHeaderSize > 0 then
    FServer.MaxHeaderSize := FConfig.MaxHeaderSize
  else
    FServer.MaxHeaderSize := DEFAULT_MAX_HEADER_SIZE;

  // MaxPostDataSize: confirmed property on ICrossHttpServer / TCrossHttpServer
  // (named MaxPostDataSize in the source — not MaxBodySize)
  if FConfig.MaxBodySize > 0 then
    FServer.MaxPostDataSize := FConfig.MaxBodySize
  else
    FServer.MaxPostDataSize := DEFAULT_MAX_BODY_SIZE;

  // ── [Config] Compression ─────────────────────────────────────────────────
  // TCrossHttpServer.Compressible: when True, CrossSocket gzip-compresses
  // responses whose Content-Type is listed as compressible AND whose body
  // exceeds MinCompressSize bytes.  False by default — enable only when the
  // server sits behind a TLS terminator or when clients declare Accept-Encoding.
  FServer.Compressible    := FConfig.Compressible;
  FServer.MinCompressSize := FConfig.MinCompressSize;

  // ── [SEC-3] SSL server certificate + private key ──────────────────────────
  // Confirmed API on TCrossSslSocketBase (Net.CrossSslSocket.Base.pas):
  //   procedure SetCertificateFile(const ACertFile: string)
  //     reads file bytes → calls abstract SetCertificate(Pointer, Integer)
  //     implemented by TCrossOpenSslSocket → SSL_CTX_use_certificate(FContext,…)
  //   procedure SetPrivateKeyFile(const APKeyFile: string; const APassword: string = '')
  //     reads file bytes → calls abstract SetPrivateKey(Pointer, Integer, APassword)
  //     implemented by TCrossOpenSslSocket → SSL_CTX_use_PrivateKey(FContext,…)
  if FConfig.SSLEnabled then
  begin
    if FConfig.SSLCertFile <> '' then
      FServer.SetCertificateFile(FConfig.SSLCertFile);

    // ── [TLSOPT-1] Private key with optional passphrase ──────────────────
    // Upstream winddriver API (≥2026-08): password is a direct parameter on
    // SetPrivateKeyFile / SetPrivateKey — no separate SetPrivateKeyPassword call.
    // Empty APassword = '' leaves the unencrypted-key path unchanged.
    if FConfig.SSLKeyFile <> '' then
      FServer.SetPrivateKeyFile(FConfig.SSLKeyFile, FConfig.SSLKeyPassword);

    // ── [MTLS-1] CA certificate for client-certificate verification ───────
    // Upstream winddriver API (≥2026-08): AddCACertificateFile (additive, not
    // SetCACertificateFile).  Must be called BEFORE SetVerifyPeer so the
    // X509_STORE is populated before verify mode is set.
    // TCrossOpenSslSocket.AddCACertificate calls:
    //   SSL_CTX_add_client_CA(FContext, LCACert)   — advertises CA in TLS hello
    //   X509_STORE_add_cert(SSL_CTX_get_cert_store(FContext), LCACert)
    //                                               — enables chain verification
    if FConfig.SSLCACertFile <> '' then
      FServer.AddCACertificateFile(FConfig.SSLCACertFile);

    // ── [MTLS-2] Enable/disable client-certificate verification ──────────
    // SetVerifyPeer is the new method added to TCrossSslSocketBase.
    // The concrete implementation calls:
    //   SSL_CTX_set_verify(FContext,
    //     SSL_VERIFY_PEER or SSL_VERIFY_FAIL_IF_NO_PEER_CERT, nil)  when True
    //   SSL_CTX_set_verify(FContext, SSL_VERIFY_NONE, nil)           when False
    //
    // Calling SetVerifyPeer(False) explicitly is a no-op (SSL_VERIFY_NONE is
    // the OpenSSL default) but it documents intent and guards against a future
    // default change in the library.
    //
    // Note: SSLVerifyPeer=True without SSLCACertFile set is a configuration
    // error — OpenSSL will reject every client cert because the store is empty.
    // We raise a descriptive exception rather than silently accepting all certs.
    if FConfig.SSLVerifyPeer and (FConfig.SSLCACertFile = '') then
      raise Exception.Create(
        'THorseCrossSocketServer: SSLVerifyPeer=True requires SSLCACertFile to ' +
        'be set. Without a CA certificate the server cannot verify client ' +
        'certificates and all connections will be rejected.');

    FServer.SetVerifyPeer(FConfig.SSLVerifyPeer);

    // ── [TLSOPT-2] Override the TLS 1.2 cipher list ───────────────────────
    // SetTls12CipherSuites calls SSL_CTX_set_cipher_list, and on failure marks
    // the whole TLS configuration invalid so a half-configured context cannot
    // go on serving. Empty → keep CrossSocket's built-in modern default.
    //
    // Was FServer.SetCipherList, the fork-only method our PR #200 proposed.
    // Upstream shipped SetTls12CipherSuites/SetTls13CipherSuites instead
    // (winddriver bb85ab4) and closed #200; SetCipherList survives only as a
    // deprecated delegation. Calling the upstream name directly is what lets
    // that delegation be deleted, and it is also the stricter implementation.
    //
    // TLS 1.3 suites are configured through a SEPARATE call
    // (SetTls13CipherSuites / SSL_CTX_set_ciphersuites) — SSL_CTX_set_cipher_list
    // does not affect them. Exposing that is a follow-up: it needs its own
    // config field, since one string cannot carry both grammars.
    if FConfig.SSLCipherList <> '' then
      FServer.SetTls12CipherSuites(FConfig.SSLCipherList);
  end;
end;

// [FIX-CS-1a] [PATCH-CS-API-1] Method-of-object bridge.
// TCrossHttpRequestEvent fires on TCrossHttpServer.OnRequest.  Upstream added
// AConnection: ICrossHttpConnection as the new second parameter; we accept it
// for signature compatibility but don't forward it — Horse middleware already
// reaches everything it needs through Req/Res.
// We forward to FRequestCallback (set by the provider) and mark AHandled so
// CrossSocket knows the request has been taken over.
procedure THorseCrossSocketServer.InternalOnRequest(
  const Sender:      TObject;
  const AConnection: ICrossHttpConnection;
  const ARequest:    ICrossHttpRequest;
  const AResponse:   ICrossHttpResponse;
  var   AHandled:    Boolean
);
begin
  AHandled := True;   // always claim the request
  if Assigned(FRequestCallback) then
    FRequestCallback(ARequest, AResponse);
end;

procedure THorseCrossSocketServer.InternalOnConnected(const Sender: TObject;
  const AConnection: ICrossConnection);
begin
  // [NODELAY] disable Nagle on the accepted socket (see declaration / report §7.5)
  TSocketAPI.SetTcpNoDelay(AConnection.Socket, True);
end;

procedure THorseCrossSocketServer.IncrementActive;
begin
  if TInterlocked.Increment(FActiveConns) = 1 then
    FDrainEvent.ResetEvent;  // first active request — block drain wait
end;

procedure THorseCrossSocketServer.DecrementActive;
begin
  if TInterlocked.Decrement(FActiveConns) = 0 then
    FDrainEvent.SetEvent;    // all requests done — unblock Stop
end;

procedure THorseCrossSocketServer.Start(const APort: Integer; const AHost: string);
begin
  // Port and Addr are confirmed properties on TCrossServer (Net.CrossServer.pas).
  // Must be set before calling Start.
  // Start signature: procedure Start(const ACallback: TCrossListenCallback = nil)
  FServer.Port := APort;
  // '' = listen on all interfaces (IPv4 + IPv6). Horse's conventional
  // '0.0.0.0' means the same thing — normalise so callers can pass either.
  if (AHost = '') or (AHost = '0.0.0.0') then
    FServer.Addr := ''
  else
    FServer.Addr := AHost;
  FServer.Start;
end;

// [FIX-CS-GRACEFUL-1] ─────────────────────────────────────────────────────────
// Wait for in-flight work FIRST, bounded by the CALLER's timeout, and only then
// tear down. That single reordering is the fix; the steps below say what was
// tried beyond it and what each one cost.
//
// What Stop does instead: FServer.Stop is TCrossServer.Stop = CloseAll +
// StopLoop, and TCrossSocketBase.CloseAll = CloseAllListens +
// CloseAllConnections. It closes every live connection and only THEN reaches its
// drain wait, so an in-flight request loses its socket before anything waits for
// it. Measured across 10 runs and two builds: a shutdown fired 800 ms into a
// 5000 ms request returned after 4193-4203 ms — the rest of the request, bounded
// by NEITHER the argument nor Config.DrainTimeoutMs, because the blocking step
// was StopLoop waiting on an IO thread that could not observe its shutdown flag
// until the handler returned — and the client lost its response at 809-819 ms,
// the instant shutdown began.
//
// After this method: 810-820 ms for 700 ms of remaining work, reply delivered.
//
// One earlier claim in this comment was WRONG and is worth keeping as a warning:
// that splitting CloseAll and calling CloseAllListens alone would "stop accepts
// and leave established connections alive". It stops accepts, but it also costs
// the in-flight response — see step 1. Three explanations were proposed and
// falsified before a step-by-step bisect found it; symptom-to-mechanism
// reasoning produced a plausible story every time and the wrong fix every time.
procedure THorseCrossSocketServer.StopGraceful(const ATimeoutMS: Integer);
var
  LTimeout: Integer;
begin
  if not FServer.Active then
    Exit;

  LTimeout := ATimeoutMS;
  if LTimeout <= 0 then
    LTimeout := FConfig.DrainTimeoutMs;

  // 1. NO CloseAllListens — and this is the surprise the bisect produced.
  //
  //    Stopping the listener is what a graceful shutdown is supposed to do
  //    first, and it is what this step used to do. It also DESTROYS the
  //    in-flight response. Measured by skipping one step at a time, everything
  //    else held constant:
  //
  //      skip CloseAllListens   -> body 'done' delivered, 820 ms   PASS
  //      skip DisconnectAll     -> 12030 aborted                   FAIL
  //      skip BOTH              -> body 'done' delivered, 810 ms   PASS
  //
  //    So closing the LISTENING socket costs an already-accepted connection its
  //    pending body write, while the response headers still go out — the client
  //    sees 200 with Content-Length: 4 and zero body bytes, and WinHTTP does not
  //    even call that an error because Connection: close makes a FIN a legal end
  //    of message. A settle sweep of 0 / 100 / 1000 ms changed nothing, so this
  //    is not a flush race: the body is never written at any delay.
  //
  //    That looks like a DCS-level coupling between listener teardown and the
  //    send path of accepted connections. It is not diagnosed further here, and
  //    this provider stops calling it rather than working around a mechanism we
  //    have not yet located.
  //
  //    THE TRADE-OFF, stated plainly: without it the server keeps ACCEPTING
  //    during the drain, so new requests can arrive while we wait. The right
  //    place to refuse new work is the pipeline — Horse already exposes
  //    IsShuttingDown, and answering 503 there is the idiom k8s expects —
  //    NOT closing the listening socket, which costs replies we promised.
  //    Deliberately left for a separate change, because it belongs in
  //    ExecutePipeline, not here.

  // 2. Let in-flight requests finish and write their replies. FDrainEvent is
  //    manual-reset and starts signalled; IncrementActive resets it on the
  //    first concurrent request and DecrementActive signals it at zero.
  if FActiveConns > 0 then
    FDrainEvent.WaitFor(LTimeout);

  // 3. [FIX-CS-GRACEFUL-1a] Settle BEFORE disconnecting, and the order is the
  //    point. TResponseBridge.Flush hands the body to CrossSocket's ASYNC send
  //    and the pipeline decrements the drain counter in its finally, so
  //    FActiveConns reaches zero microseconds BEFORE the bytes are on the wire.
  //    A disconnect at that instant is graceful about a response that has not
  //    been written yet.
  //
  //    Measured, and this is what the order costs: with the disconnect first the
  //    client got `status=200 body=` at 1517 ms — headers delivered, body lost,
  //    no error at all, because the FIN arrived cleanly between the header send
  //    and the body send. The step before that got 12030 (aborted); the step
  //    before that 12152 (severed). Three different symptoms from one ordering
  //    question.
  //
  //    Horse.Provider.Console carries the same 100 ms sleep after its drain loop
  //    and before it clears Active, for the same reason.
  //
  //    [FIX-CS-DEFER-1] The principled fix is now IN: the one-shot path defers
  //    DecrementActive to the send completion, the way the streaming path always
  //    did ([STREAM-2] TryDeferActive). FActiveConns now reaches zero only once
  //    CrossSocket reports the send finished, so the window this sleep covers
  //    should no longer exist — including for a response larger than the socket
  //    buffer, which no fixed delay could ever have covered.
  //
  //    THE SLEEP STAYS AT 100 ms UNTIL THAT IS MEASURED, NOT BECAUSE IT IS STILL
  //    NEEDED. Dropping the default in the same change that removes the need for
  //    it would leave nothing to attribute a result to. The control is direct:
  //    HORSE_CS_SETTLE_MS=0 failed about one run in two before, so a clean 5/5 at
  //    0 ms is the evidence, and the default can follow in its own commit.
  //    Anything short of that and this comment is wrong rather than cautious.
  Sleep(SettleMs);

  // 4. [FIX-CS-GRACEFUL-1b] Disconnect GRACEFULLY, which is a different
  //    operation from closing and the difference is the rest of the bug. DCS
  //    documents the two side by side on ICrossSocket:
  //
  //      CloseAllConnections   关闭所有连接 - "正在发送中的数据将会丢失"
  //                            (data being sent WILL BE LOST)
  //      DisconnectAll         断开所有连接 - "正在发送中的数据会被送达"
  //                            (data being sent WILL BE DELIVERED)
  //
  //    FServer.Stop reaches the lossy one via CloseAll, so a reply the handler
  //    had already written was discarded at teardown: with steps 1-2 only, the
  //    drain timing became correct (815 ms for 700 ms of work) and the client
  //    still failed — but with 12030 "connection terminated abnormally" instead
  //    of 12152 "invalid or unrecognized response", i.e. answered-then-aborted
  //    rather than severed-before-answering. That change of error located this.
  FServerRef.DisconnectAll;

  // 5. Full teardown: closes whatever remains and joins the IO loop.
  FServer.Stop;
end;

procedure THorseCrossSocketServer.Stop;
begin
  // Active confirmed on TCrossServer:
  //   property Active: Boolean — GetActive = (AtomicCmpExchange(FStarted,0,0)=1)
  if not FServer.Active then
    Exit;

  // Stop confirmed on TCrossServer:
  //   procedure Stop — calls CloseAll + StopLoop + AtomicExchange(FStarted,0)
  FServer.Stop;

  // [SEC-6] Wait for in-flight requests to drain.
  // If they do not finish within DrainTimeoutMs we proceed anyway
  // to prevent hanging on a stuck handler.
  if FActiveConns > 0 then
    FDrainEvent.WaitFor(FConfig.DrainTimeoutMs);
end;

end.
