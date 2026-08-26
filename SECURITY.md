# Security Policy

## Reporting a vulnerability

**Please report privately, not as a public issue.**

Use GitHub's private reporting: the **Security** tab -> **Report a vulnerability**. That
opens a private thread visible only to the maintainers, so a fix can be prepared before
the details are public.

If that is unavailable to you, open a public issue saying only that you have a security
report and asking for a contact -- no details -- and you will be given one.

## What to expect

A small project maintained by one person. There is no service-level agreement and there
will not be a same-day response.

What is promised instead: your report gets read and acknowledged; a real issue gets
fixed, released, and credited to you unless you decline; a non-issue gets an explanation
rather than silence; and you will not be asked to stay quiet indefinitely -- if a fix
runs long, a disclosure date is agreed together.

## Scope -- what this provider touches

This is a transport provider: it parses bytes sent by whoever connects to your server,
and hands them to Horse.

- HTTP/1.1 request framing, headers and bodies, via Delphi-Cross-Socket
- WebSocket frames after upgrade
- TLS records, when SSL is configured (OpenSSL 3.x)
- The per-request context pool, which is REUSED across requests

In scope, roughly in priority order:

- Memory safety anywhere reachable from network input
- **Anything that lets one request see another's data.** The context pool reuses
  `THorseRequest`/`THorseResponse` objects, so a field that survives a reset is a
  cross-request leak. This provider's own test suite guards that specifically, which
  should tell you how seriously it is taken
- Request smuggling, header injection or response splitting through the bridge
- TLS/mTLS configuration that does not enforce what it claims to
- Resource exhaustion driven by a *small* request -- an allocation or loop whose cost is
  disproportionate to what the peer sent

Note the body-stream ownership rule documented in the provider: `Req.Body` is a
**non-owning** reference into the transport's buffer. A report involving body lifetime
is worth making even if it looks like misuse; that boundary has bitten before.

## Not in scope

**Denial of service by sheer request volume.** That is a deployment concern; connection
caps and request limits exist for it, and tuning them is your decision.

**Vulnerabilities in Horse itself.** Report those to
[HashLoad/horse](https://github.com/HashLoad/horse). If you cannot tell whether an issue
belongs to Horse or to this provider, report it here and it will be routed -- do not
spend time deciding.

## Supported versions

Only the **latest release** receives security fixes. There are no long-term support
branches.

| Version | Supported |
|---|---|
| 1.0.16.x | Yes |
| earlier | No |

Your exposure also depends on the versions of the transport library and of Horse that
were resolved alongside this provider, not on this provider's version alone.
