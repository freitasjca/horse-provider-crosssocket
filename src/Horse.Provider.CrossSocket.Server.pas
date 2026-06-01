unit Horse.Provider.CrossSocket.Server;

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
    procedure SetPrivateKeyFile(const APKeyFile: string)
    procedure SetCertificate(const ACertStr: string)   overload
    procedure SetPrivateKey(const APKeyStr: string)    overload
    property Ssl: Boolean  (read-only)

    ── mTLS (Net.CrossSslSocket.Base patch + Net.CrossSslSocket.OpenSSL impl) ─
    procedure SetCACertificateFile(const ACACertFile: string)
      → loads CA cert, calls SSL_CTX_add_client_CA + X509_STORE_add_cert
    procedure SetVerifyPeer(const AVerify: Boolean)
      → SSL_CTX_set_verify(PEER|FAIL_IF_NO_PEER_CERT) / VERIFY_NONE
    Concrete implementations in TCrossOpenSslSocket call:
      SetCACertificate → SSL_CTX_add_client_CA + X509_STORE_add_cert
      SetVerifyPeer    → SSL_CTX_set_verify(SSL_VERIFY_PEER
                           or SSL_VERIFY_FAIL_IF_NO_PEER_CERT) / SSL_VERIFY_NONE

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
    SSLCACertFile    → FServer.SetCACertificateFile  (mTLS)
    SSLVerifyPeer    → FServer.SetVerifyPeer          (mTLS)

  Reserved (CrossSocket API not available):
    KeepAliveTimeout — no matching property confirmed in TCrossHttpServer
    ReadTimeout      — no matching property confirmed in TCrossHttpServer
    MaxConnections   — no matching property confirmed in TCrossHttpServer
    SSLKeyPassword   — no key-password API confirmed in TCrossSslSocketBase
    SSLCipherList    — no SetCipherList method on TCrossSslSocketBase;
                       cipher list is set internally in TCrossOpenSslSocket._InitSslCtx

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
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
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
  public
    constructor Create(const AConfig: THorseCrossSocketConfig); overload;
    constructor Create; overload;
    destructor  Destroy; override;

    procedure Start(const APort: Integer);
    // [SEC-6] Synchronous stop — waits up to Config.DrainTimeoutMs
    procedure Stop;

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
  //   procedure SetPrivateKeyFile(const APKeyFile: string)
  //     reads file bytes → calls abstract SetPrivateKey(Pointer, Integer)
  //     implemented by TCrossOpenSslSocket → SSL_CTX_use_PrivateKey(FContext,…)
  if FConfig.SSLEnabled then
  begin
    if FConfig.SSLCertFile <> '' then
      FServer.SetCertificateFile(FConfig.SSLCertFile);

    if FConfig.SSLKeyFile <> '' then
      FServer.SetPrivateKeyFile(FConfig.SSLKeyFile);

    // ── [MTLS-1] CA certificate for client-certificate verification ───────
    // SetCACertificateFile is implemented in TCrossOpenSslSocket (see
    // Net.CrossSslSocket.OpenSSL.pas — mTLS patch).  Must be called BEFORE
    // SetVerifyPeer so the X509_STORE is populated before verify mode is set.
    // SetCACertificateFile is the new method added to TCrossSslSocketBase


    // (Net.CrossSslSocket.Base patch).  The concrete implementation in
    // TCrossOpenSslSocket calls:
    //   SSL_CTX_add_client_CA(FContext, LCACert)   — advertises CA in TLS hello
    //   X509_STORE_add_cert(SSL_CTX_get_cert_store(FContext), LCACert)
    //                                               — enables chain verification
    // Must be called BEFORE SetVerifyPeer so the store is populated first.
    if FConfig.SSLCACertFile <> '' then
      FServer.SetCACertificateFile(FConfig.SSLCACertFile);

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

procedure THorseCrossSocketServer.Start(const APort: Integer);
begin
  // Port and Addr are confirmed properties on TCrossServer (Net.CrossServer.pas).
  // Must be set before calling Start.
  // Start signature: procedure Start(const ACallback: TCrossListenCallback = nil)
  FServer.Port := APort;
  FServer.Addr := '';   // '' = listen on all interfaces (IPv4 + IPv6)
  FServer.Start;
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
