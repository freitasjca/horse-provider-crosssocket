# Horse Transport Architecture — Indy vs CrossSocket

| # | Diagram | What it explains |
|---|---|---|
| 1 | **Request lifecycle** | Full path from TCP accept to response for both Indy and CrossSocket — shows the pool, validation, shadow fields, and flush steps |
| 2 | **Thread model** | Why Indy hits a wall at ~1 000 connections (N threads = N stacks) vs CrossSocket's fixed IO thread pool serving 10 000+ |
| 3 | **Object lifecycle** | Indy: allocate + free on every request. CrossSocket: pre-warm pool at startup, `Clear()` on reuse, no allocator on the hot path |
| 4 | **Security boundary** | All 6 validation checks in `TRequestBridge.Populate` (inbound) + CRLF-strip / hop-by-hop filter / security header injection (outbound) |
| 5 | **Activation** | Single compiler define switches `THorseProvider` type alias — existing middleware is untouched and unaware |
| 6 | **Hybrid interface architecture** | How IHorseRawRequest/IHorseRawResponse decouple provider-specific code from TWebRequest/TWebResponse stubs — new providers implement ~15 methods instead of 30+ |

---

## 1. Request lifecycle comparison

```mermaid
flowchart TD
    Client(["🌐 HTTP Client"])

    %% ── Indy path ──────────────────────────────────────────────────────────
    subgraph INDY["🔵  Horse + Indy  (default — no define)"]
        direction TB
        I_ACCEPT["TIdHTTPServer\naccept() on a single thread\n────────────────────\none OS thread allocated\nper accepted connection"]
        I_BROKER["TIdHTTPWebBrokerBridge\n→ WebRequestHandler\n→ THorseWebModule"]
        I_OBJ["THorseRequest.Create(TWebRequest)\nTHorseResponse.Create(TWebResponse)\n────────────────────\nnew heap allocation every request\nFWebRequest / FWebResponse always set"]
        I_PIPE["Horse Middleware Pipeline\nRoutes.Execute"]
        I_HANDLER["Route Handler\nRes.Send(...)"]
        I_RESP["TWebResponse written\n→ Indy → TCP → Client\n(blocking write on connection thread)"]

        I_ACCEPT --> I_BROKER --> I_OBJ --> I_PIPE --> I_HANDLER --> I_RESP
    end

    %% ── CrossSocket path ───────────────────────────────────────────────────
    subgraph CS["🟢  Horse + CrossSocket  ({$DEFINE HORSE_PROVIDER_CROSSSOCKET}, legacy alias: HORSE_CROSSSOCKET)"]
        direction TB
        CS_ACCEPT["TCrossHttpServer\nIOCP (Windows) · epoll (Linux) · kqueue (macOS)\n────────────────────\nasync I/O event on IO thread pool\n4–16 threads regardless of connection count"]
        CS_VALIDATE{"TRequestBridge.Populate\nvalidates before touching the pool\n────────────────────\nmethod · host · smuggling · size · URL length"}
        CS_ERROR["SendError 400 / 405\nJSON error response via ICrossHttpResponse\n────────────────────\npool never acquired\nmiddleware never entered"]
        CS_POOL["THorseContextPool.Acquire\n────────────────────\npre-warmed 32–512 THorseContext objects\nno heap allocation on hot path"]
        CS_OBJ["THorseRequest + THorseResponse\nfrom pool — shadow fields populated\n────────────────────\nFWebRequest = nil  FWebResponse = nil\nnil-guards route all accessors to\nFCS* shadow fields"]
        CS_PIPE["THorse.Execute\nHorse Middleware Pipeline\nRoutes.Execute"]
        CS_HANDLER["Route Handler\nRes.Send(...)"]
        CS_FLUSH["TResponseBridge.Flush\n────────────────────\nCRLF-strip on all header values\nhop-by-hop headers filtered\nsecurity headers injected\n(X-Content-Type-Options, X-Frame-Options, Server)"]
        CS_SEND["ICrossHttpResponse.Send\nasync — returns immediately to IO thread\nIO thread free for next event"]
        CS_RELEASE["THorseContextPool.Release\n────────────────────\nTHorseRequest.Clear + THorseResponse.Clear\nwipe all fields, FBody := nil (never freed)\nobject returned to pool"]

        CS_ACCEPT --> CS_VALIDATE
        CS_VALIDATE -->|"rvBadRequest\nrvMethodNotAllowed"| CS_ERROR
        CS_VALIDATE -->|rvOK| CS_POOL
        CS_POOL --> CS_OBJ --> CS_PIPE --> CS_HANDLER --> CS_FLUSH --> CS_SEND --> CS_RELEASE
    end

    Client -->|TCP connection| I_ACCEPT
    Client -->|TCP connection| CS_ACCEPT
```

---

## 2. Thread model

```mermaid
flowchart LR
    subgraph INDY_T["🔵  Indy — one thread per connection"]
        direction TB
        T1["Thread 1\n(Connection A — active)"]
        T2["Thread 2\n(Connection B — idle, waiting for data)"]
        T3["Thread 3\n(Connection C — idle, waiting for data)"]
        T4["Thread 4\n(Connection D — idle, waiting for data)"]
        T5["Thread 5\n(Connection E — active)"]
        TN["Thread N\n(Connection N — ...)"]
        WARN["⚠️  1 000 connections\n≈ 1–2 GB reserved stack\nOS scheduler overhead\naccept() bottleneck"]

        T1 ~~~ T2 ~~~ T3 ~~~ T4 ~~~ T5 ~~~ TN ~~~ WARN
    end

    subgraph CS_T["🟢  CrossSocket — fixed IO thread pool"]
        direction TB
        IO1["IO Thread 1  (IOCP / epoll)"]
        IO2["IO Thread 2  (IOCP / epoll)"]
        IO3["IO Thread 3  (IOCP / epoll)"]
        IO4["IO Thread 4  (IOCP / epoll)"]
        HANDLES["10 000+ connection handles\n(kernel-managed, no per-connection thread)\nidle connections cost nothing"]
        NOTE["✅  4–16 IO threads\nregardless of connection count\nnear-zero idle CPU"]

        IO1 ~~~ IO2 ~~~ IO3 ~~~ IO4 ~~~ HANDLES ~~~ NOTE
    end
```

---

## 3. Object lifecycle

```mermaid
flowchart TD
    subgraph INDY_OBJ["🔵  Indy — allocate / free per request"]
        direction LR
        IA["Request arrives"] --> IB["new THorseRequest\nnew THorseResponse\nnew TDictionary (headers)\nnew TDictionary (params)\n..."]
        IB --> IC["Pipeline runs"]
        IC --> ID["Free THorseRequest\nFree THorseResponse\nFree all dictionaries"]
        ID --> IE["GC pressure under load\nOS allocator called on every request"]
    end

    subgraph CS_OBJ["🟢  CrossSocket — pre-warmed pool, Clear on reuse"]
        direction LR
        CA["Startup\nTHorseContextPool.WarmUp"] --> CB["32 × THorseContext\npre-allocated\n(THorseRequest + THorseResponse\n+ all dictionaries)"]
        CB --> CC{"Request arrives\nAcquire from pool"}
        CC -->|"pool has free object"| CD["Populate shadow fields\nno heap allocation"]
        CC -->|"pool exhausted\n(burst load)"| CE["Create new THorseContext\n(pool grows up to 512)"]
        CD --> CF["Pipeline runs"]
        CE --> CF
        CF --> CG["Release to pool\nClear() — wipes all fields\nFBody := nil direct assign\n(never frees — CrossSocket owns stream)"]
        CG --> CC
    end
```

---

## 4. Security boundary

```mermaid
flowchart TD
    subgraph REQ["Inbound request validation  (TRequestBridge.Populate)"]
        direction TB
        V1{"Method allowed?\nCONNECT · TRACE → 405"}
        V2{"Host present\nand printable? → 400"}
        V3{"Content-Length AND\nTransfer-Encoding both set?\nRFC 7230 §3.3.3 → 400"}
        V4{"URL length\n≤ 8 KB? → 414"}
        V5{"Header count ≤ 100\nname ≤ 256 bytes\nvalue ≤ 8 KB? → 431 / 400"}
        V6{"Body size\n≤ MaxBodySize? → 413"}
        VOK["rvOK — enter pool + pipeline"]
        VERR["rvBadRequest / rvMethodNotAllowed\nSendError — pool never acquired\nno middleware entered"]

        V1 -->|pass| V2 -->|pass| V3 -->|pass| V4 -->|pass| V5 -->|pass| V6 -->|pass| VOK
        V1 -->|fail| VERR
        V2 -->|fail| VERR
        V3 -->|fail| VERR
        V4 -->|fail| VERR
        V5 -->|fail| VERR
        V6 -->|fail| VERR
    end

    subgraph RESP["Outbound response hardening  (TResponseBridge.Flush)"]
        direction TB
        R1["CRLF-strip\nall header values stripped of CR · LF · NUL\n(CRLF injection prevention)"]
        R2["Hop-by-hop filter\nConnection · Transfer-Encoding · Keep-Alive\nProxy-* removed from response headers"]
        R3["Security headers injected\nX-Content-Type-Options: nosniff\nX-Frame-Options: DENY\nServer: unknown (or configured banner)\nReferrer-Policy · Cache-Control"]
        R4["ICrossHttpResponse.Send\nasync write to socket buffer"]

        R1 --> R2 --> R3 --> R4
    end
```

---

## 5. Activation — the three-axis define model (PATCH-HORSE-2)

PATCH-HORSE-2 replaces the original single `HORSE_CROSSSOCKET` switch with three orthogonal namespaces. Legacy define names (`HORSE_CROSSSOCKET`, `HORSE_VCL`, `HORSE_DAEMON`, `HORSE_LCL`, `HORSE_APACHE`, `HORSE_ISAPI`, `HORSE_CGI`, `HORSE_FCGI`) continue to work — an alias block at the top of `Horse.pas` translates them.

```mermaid
flowchart TD
    START["Project defines\n(in .dproj / .lpi or via {$DEFINE})"]

    subgraph AXES["Three orthogonal axes"]
        direction TB
        A["Axis A · Provider\n(HTTP transport)\n────────────────────\nHORSE_PROVIDER_CROSSSOCKET\nHORSE_PROVIDER_MORMOT (reserved)\n────────────────────\n(no define = Indy on Delphi,\n fphttpserver on FPC)"]
        B["Axis B · Application type\n(binary shape)\n────────────────────\nHORSE_APPTYPE_VCL\nHORSE_APPTYPE_DAEMON\nHORSE_APPTYPE_LCL\n────────────────────\n(no define = Console / HTTPApplication)"]
        C["Axis C · Host-managed\n(web server owns the socket)\n────────────────────\nHORSE_HOST_APACHE\nHORSE_HOST_ISAPI\nHORSE_HOST_CGI\nHORSE_HOST_FCGI"]
    end

    CHAIN["Horse.pas two-stage selection chain\n────────────────────\nStage 1: HORSE_HOST_* wins outright\n(Axis A ignored — host owns the socket)\n────────────────────\nStage 2: compose Axis A × Axis B\n(self-hosted — Provider + lifecycle wrapper)"]

    subgraph UNIT["Concrete Provider unit selected"]
        direction TB
        U1["Horse.Provider.CrossSocket\n(Console — Axis A only)"]
        U2["Horse.Provider.CrossSocket.VCL\n(A + APPTYPE_VCL)"]
        U3["Horse.Provider.CrossSocket.Daemon\n(A + APPTYPE_DAEMON on Delphi)\n────────────────────\n{$IFDEF MSWINDOWS}\n  THorseCrossSocketService\n{$ELSE}\n  THorseCrossSocketLinuxDaemonApp\n{$ENDIF}\nOne unit, two helpers"]
        U4["Horse.Provider.CrossSocket.FPC.Daemon\nHorse.Provider.CrossSocket.FPC.LCL\nHorse.Provider.CrossSocket.FPC.HTTPApplication\n(FPC variants)"]
    end

    FATAL["{$MESSAGE FATAL}\n────────────────────\nOnly fires for architecturally\nimpossible combinations:\nHORSE_PROVIDER_* + HORSE_HOST_*"]

    BC["G1–G8 BACKWARDS-COMPATIBILITY CONTRACT\n────────────────────\nEvery existing .dproj / .lpi compiles unchanged.\nLegacy aliases translate to the new namespaces.\nMiddleware code is untouched.\nNo provider class renamed or removed."]

    START --> AXES
    AXES --> CHAIN
    CHAIN --> UNIT
    CHAIN -.->|invalid combo| FATAL
    UNIT --> BC
```

The selected concrete Provider class is assigned to `THorseProvider` via a parallel type-alias chain with the same structure.

---

## 6. Hybrid interface architecture — provider abstraction

```mermaid
flowchart TD
    subgraph HORSE["Horse-level units  (reusable by any provider)"]
        direction TB
        IRAW["IHorseRawRequest\n────────────────────\n~15 methods:\nGetMethod, GetHost, GetPathInfo,\nGetContent, GetFieldByName,\nPopulateQueryFields, ReadBody, ...\n────────────────────\nIHorseRawResponse\n~1 method:\nSetCustomHeader"]
        ADAPT["TInterfacedWebRequest\n(subclasses TWebRequest / TRequest)\n────────────────────\nDelegates ALL 30+ abstract stubs\nto IHorseRawRequest methods\n────────────────────\nTInterfacedWebResponse\n(subclasses TWebResponse / TResponse)\nDelegates stubs to IHorseRawResponse\nSetCustomHeader inherited — works as-is"]
        IRAW -->|"implements"| ADAPT
    end

    subgraph CS["CrossSocket provider"]
        direction TB
        CSRAW["TCrossSocketRawRequest\nimplements IHorseRawRequest\n────────────────────\n~15 one-liner wrappers:\nFCrossReq.Method\nFCrossReq.HostName\nFCrossReq.Header[Name]\n...\n────────────────────\nTCrossSocketRawResponse\nimplements IHorseRawResponse"]
        CSADAPT["TCrossSocketWebRequest\n= TInterfacedWebRequest subclass\n(thin constructor only)\n────────────────────\nTCrossSocketWebResponse\n= TInterfacedWebResponse subclass\n(thin constructor only)"]
        CSRAW --> CSADAPT
    end

    subgraph FUTURE["Future provider  (e.g. nghttp2, libuv)"]
        direction TB
        FRAW["TNghttp2RawRequest\nimplements IHorseRawRequest\n~15 one-liner wrappers\n────────────────────\nTNghttp2RawResponse\nimplements IHorseRawResponse"]
        FADAPT["TInterfacedWebRequest.Create(\n  TNghttp2RawRequest.Create(ANgReq))\n────────────────────\nNo 30+ stubs to duplicate\nFull TWebRequest compat for free"]
        FRAW --> FADAPT
    end

    subgraph MW["Middleware  (unchanged)"]
        direction TB
        CORS["Horse.CORS\nRes.RawWebResponse.SetCustomHeader\nReq.RawWebRequest.Method"]
        OTHER["Horse.JWT · Horse.Logger · ...\nReq.Body · Req.Headers · Res.Send"]
    end

    CSADAPT -->|"RawWebRequest\nreturns TWebRequest"| CORS
    FADAPT -->|"RawWebRequest\nreturns TWebRequest"| CORS
    CSADAPT --> OTHER
    FADAPT --> OTHER
```

**Key benefit:** A new provider implements `IHorseRawRequest` (~15 methods) + `IHorseRawResponse` (~1 method) and wraps them in `TInterfacedWebRequest` / `TInterfacedWebResponse`. All 30+ `TWebRequest` / `TWebResponse` abstract stubs are handled by the generic adapter — no duplication.

**Compiler-version guard:** `GetIntegerVariable` / `SetIntegerVariable` return `Int64` on Delphi 10.2+ and `Integer` on XE7 / FPC. Controlled by `{$IF CompilerVersion >= 32.0}` in both interface and adapter units.
