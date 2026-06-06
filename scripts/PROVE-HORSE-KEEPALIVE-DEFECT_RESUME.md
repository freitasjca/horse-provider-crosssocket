> ⚠️ **CORRECTION:** the defect is **Indy-provider-only**. Correctly-built CrossSocket and mORMot providers serve the same load at **0%**; only Indy shows ~60%. The earlier "all three providers / shared Horse code" finding came from **mis-built CrossSocket/mORMot binaries that were silently running Indy** (`HORSE_PROVIDER_*` not effective). This summary is corrected accordingly.

### Problem summary

Any Horse middleware that **adds response headers**, **on the Indy provider**, causes Horse to return **HTTP 500 errors** for approximately **60% of requests** when the following three conditions occur simultaneously:

1. **HTTP keep-alive connection reuse is enabled**
2. **Concurrency reaches approximately 40 or more requests**
3. **Response headers are added**, for example:

   * `SecurityHeaders` using `Res.AddHeader`
   * `CORS` using `Res.RawWebResponse.SetCustomHeader`

---

### Observed behavior

* Failures occur **before the routing pipeline executes**.
* The number of requests that enter the Horse pipeline equals the number of 2xx responses (`entered == 2xx`) — i.e., every 500 is for a request that never entered the pipeline.
* No exceptions are raised.
* The 500 is emitted **below `HandlerAction`**, in the Indy / `TIdHTTPWebBrokerBridge` layer (Horse's WebModule and pipeline are clean).
* The issue reproduces **only on the Indy provider**:

  * Indy — **~60%** (affected)
  * CrossSocket — **0%** (unaffected)
  * mORMot — **0%** (unaffected)
* The behavior is consistently observed in **Release builds**.

---

### Impact of removing conditions

When any one of the three triggering factors is removed, the failure rate drops dramatically:

| Configuration                | HTTP 500 Rate |
| ---------------------------- | ------------- |
| All three conditions present | ~60%          |
| No header-adding middleware  | ~3%           |
| No keep-alive (ApacheBench)  | ~1%           |
| Single/sequential connection | 0%            |

---

### Evidence that the defect is in the Horse Indy provider

The issue is isolated to the **Horse Indy/Console provider**, not the transports and not Horse's shared response code.

#### Provider comparison (correctly-built binaries, c=100, keep-alive)

| Provider | headers-only 5xx | cors 5xx |
| -------- | ---------------- | -------- |
| **Indy** | **~59%** | **~61%** |
| CrossSocket | **0%** | **0%** |
| mORMot | **0%** | **0%** |

The same `THorseResponse`/`AddHeader` code runs on all three providers, but only Indy fails — so the fault is **not** in Horse's shared response handling.

#### Cross-check — raw transports (no Horse)

The same headers added natively to raw CrossSocket and raw mORMot servers (no Horse) also give **0% errors** at c=100 keep-alive — so the transports themselves are fine too.

---

### Why it is the Indy provider specifically

Indy uses `TIdHTTPWebBrokerBridge` + a **single shared `THorseWebModule`** + WebBroker dispatch. The 500 is emitted in that dispatch layer (below `HandlerAction`) when a header-laden response on a reused connection is followed by another request under concurrency ≥ ~40. CrossSocket and mORMot use their own native async servers and do not have this path.

---

### Potential causes already eliminated

Experimental testing has ruled out:

* Horse pipeline race conditions (pre-pipeline; 0 exceptions)
* Host/server saturation
* Debug vs. Release build differences
* Post-`Send` timing issues
* Header accumulation effects
* **Transport bug** and **Horse shared-code bug** (CrossSocket/mORMot providers and raw transports are all 0%)
* **"All three providers" scope** — a mis-build (CrossSocket/mORMot binaries running Indy)

---

### Conclusion

This is a **concurrency defect in the Horse Indy/Console provider** (the `TIdHTTPWebBrokerBridge` dispatch + single shared `THorseWebModule`), triggered by any header-adding middleware under production-like keep-alive load. The **CrossSocket and mORMot providers are unaffected** — the recommended providers for header middleware under high concurrent keep-alive.

The exact internal line has not yet been identified; the next step is to instrument the **Indy/WebBroker dispatch** layer (Stage A localized it to below `HandlerAction`).
