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

    ── mTLS additions (Net.CrossSslSocket.Base patch) ───────────────────────
    procedure SetCACertificate(const ACACertBuf: Pointer; ACACertBufSize: Int) abstract
    procedure SetCACertificate(const ACACertBytes: TBytes)  overload
    procedure SetCACertificate(const ACACertStr: string)    overload
    procedure SetCACertificateFile(const ACACertFile: string)
    procedure SetVerifyPeer(const AVerify: Boolean)         abstract
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

  ── Properties that DO NOT EXIST anywhere in the confirmed source ────────────
  KeepAlive, KeepAliveTimeout, Timeout, MaxConnections, ServerName,
  CertFile, KeyFile, KeyPassword, CipherList.
  These were assumed in the original design but have no real counterparts.
  SSLCACertFile and SSLVerifyPeer ARE now supported via the patched
  SetCACertificateFile / SetVerifyPeer methods on TCrossSslSocketBase.

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
    FConfig:          THorseCrossSocketConfig;
    FActiveConns:     Integer;   // interlocked counter for drain wait
    FDrainEvent:      TEvent;
    // [FIX-CS-1a] Stores the provider's request handler so the
    // method-of-object OnRequest event can forward to it.
    FRequestCallback: TServerRequestCallback;

    procedure ApplyConfig;
    // [FIX-CS-1a] Method-of-object handler assigned to FServer.OnRequest.
    // TCrossHttpRequestEvent = procedure(const Sender: TObject;
    //   const ARequest: ICrossHttpRequest; const AResponse: ICrossHttpResponse;
    //   var AHandled: Boolean) of object;
    procedure InternalOnRequest(
      const Sender:   TObject;
      const ARequest: ICrossHttpRequest;
      const AResponse: ICrossHttpResponse;
      var   AHandled: Boolean
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

  // [FIX-CS-1a] Wire the method-of-object event.  The provider assigns
  // FRequestCallback before calling Start; InternalOnRequest forwards to it.
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
  FServer.Free;
  FDrainEvent.Free;
  inherited Destroy;
end;

procedure THorseCrossSocketServer.ApplyConfig;
begin
  // ── [SEC-1] Size limits ───────────────────────────────────────────────────
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

// [FIX-CS-1a] Method-of-object bridge.
// TCrossHttpRequestEvent fires on TCrossHttpServer.OnRequest.
// We forward to FRequestCallback (set by the provider) and mark AHandled
// so CrossSocket knows the request has been taken over.
procedure THorseCrossSocketServer.InternalOnRequest(
  const Sender:    TObject;
  const ARequest:  ICrossHttpRequest;
  const AResponse: ICrossHttpResponse;
  var   AHandled:  Boolean
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
