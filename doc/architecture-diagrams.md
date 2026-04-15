# Horse Transport Architecture — Indy vs CrossSocket

| # | Diagram | What it explains |
|---|---|---|
| 1 | **Request lifecycle** | Full path from TCP accept to response for both Indy and CrossSocket — shows the pool, validation, shadow fields, and flush steps |
| 2 | **Thread model** | Why Indy hits a wall at ~1 000 connections (N threads = N stacks) vs CrossSocket's fixed IO thread pool serving 10 000+ |
| 3 | **Object lifecycle** | Indy: allocate + free on every request. CrossSocket: pre-warm pool at startup, `Clear()` on reuse, no allocator on the hot path |
| 4 | **Security boundary** | All 6 validation checks in `TRequestBridge.Populate` (inbound) + CRLF-strip / hop-by-hop filter / security header injection (outbound) |
| 5 | **Activation** | Single compiler define switches `THorseProvider` type alias — existing middleware is untouched and unaware |

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
    subgraph CS["🟢  Horse + CrossSocket  ({$DEFINE HORSE_CROSSSOCKET})"]
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

## 5. Activation — single compiler define

```mermaid
flowchart TD
    DEFINE{"{$DEFINE HORSE_CROSSSOCKET}\nset in project options?"}

    subgraph NO["Without define  (default)"]
        direction TB
        N1["Horse.pas uses clause:\nHorse.Provider.Console\nHorse.Provider.Daemon\n..."]
        N2["THorseProvider =\nTHorseProviderConsole\n(Indy / web-broker stack)"]
        N3["All CrossSocket units\nexcluded from compilation\nzero binary size impact"]
        N1 --> N2 --> N3
    end

    subgraph YES["With define"]
        direction TB
        Y1["Horse.pas uses clause:\nHorse.Provider.CrossSocket"]
        Y2["THorseProvider =\nTHorseProviderCrossSocket\n(IOCP / epoll / kqueue)"]
        Y3["All existing Horse middleware\n(JWT · CORS · Jhonson · Logger ...)\nwork identically — zero changes needed\nthey only call THorseRequest / THorseResponse API"]
        Y1 --> Y2 --> Y3
    end

    DEFINE -->|No| NO
    DEFINE -->|Yes| YES
```
