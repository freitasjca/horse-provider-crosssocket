# CrossSocket TLS / mutual-TLS integration test

Proves the CrossSocket provider serves **HTTPS** and enforces **mutual TLS**
(client-certificate authentication).

| File | Role |
|---|---|
| `HorseCSTLSTestServer.dpr` | HTTPS server on **port 9101**; `GET /ping`, `POST /echo` |
| `HorseCSTLSTestClient.dpr` | Driver; exit code = number of failed assertions |
| `certs/` | Self-signed fixture PKI (shared with the other providers) |

## Certificates (`certs/`)

Generated once by `certs/gen-certs.sh` (OpenSSL) and committed so the Windows
build machine needs no OpenSSL:

```
ca.crt / ca.key          test CA (signs the two below)
server.crt / server.key  server cert — CN/SAN = localhost, 127.0.0.1, ::1
client.crt / client.key  client cert — for mutual TLS
```

Regenerate with `cd certs && ./gen-certs.sh`. **Test-only throwaway keys** —
never reuse them anywhere real. Copy the `certs/` folder next to the built
binaries (or run from this `tests/` folder); both programs locate it via
`FindCertDir` (checks `.\certs`, `..\certs`, `.\tests\certs`, `..\tests\certs`).

## Build

Set `HORSE_PROVIDER_CROSSSOCKET` in each project's Conditional Defines (same as
the param tests). The client also needs `Delphi-Cross-Socket` on the search path
(`TCrossHttpClient` is the HTTPS driver). OpenSSL libraries must be present at
runtime for both ends.

## Run

**One-way TLS** (server presents a cert; client verifies the transport works):

```
HorseCSTLSTestServer            # terminal 1
HorseCSTLSTestClient            # terminal 2  → T1, T2 pass
```

**Mutual TLS** (server also *requires* a client cert) — pass `mtls` to **both**:

```
HorseCSTLSTestServer mtls       # terminal 1
HorseCSTLSTestClient mtls        # terminal 2  → T3, T4 pass
```

## What each assertion proves

| Mode | Check | Proves |
|---|---|---|
| one-way | T1 `GET /ping` → 200 "pong" | TLS handshake + request/response over HTTPS |
| one-way | T2 `POST /echo` → body echoed | request body survives the TLS path |
| mTLS | T3 `GET /ping` **with** client cert → 200 | server accepts a CA-signed client cert |
| mTLS | T4 `GET /ping` **without** client cert → rejected | `SSLVerifyPeer` actually enforces mTLS |

The mTLS client certificate is injected by subclassing `TCrossHttpClient` and
overriding the virtual `CreateHttpCli` to call `SetCertificateFile` /
`SetPrivateKeyFile` on the HTTPS socket before it connects.

## Provider config exercised

`THorseCrossSocketConfig`: `SSLEnabled`, `SSLCertFile`, `SSLKeyFile`,
`SSLCACertFile`, `SSLVerifyPeer` — passed via
`THorseProviderCrossSocket.ListenWithConfig(9101, Config)`.

> Server-side mutual TLS needs the two `Net.CrossSslSocket.*` mTLS patches (or the
> pre-built fork release) — see the provider README's TLS section. One-way TLS
> works on stock upstream.
