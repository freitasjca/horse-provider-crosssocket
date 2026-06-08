# README Update Proposal

## Replace Delphi-Cross-Socket dependency row

| Dependency | Version | Notes |
|---|---|---|
| Delphi-Cross-Socket | latest | Transport layer. **When installed through Boss as a dependency of `horse-provider-crosssocket`, Boss resolves to `freitasjca/Delphi-Cross-Socket v1.0.3`**, which bundles the required CnPack subset and the mTLS additions. This fork exists primarily to make Delphi-Cross-Socket Boss-installable and may lag behind upstream `winddriver/Delphi-Cross-Socket`, which is under active development. See the Installation section for details and trade-offs. |

---

## Add before Installation paths

> ## Important: Boss dependency resolution
>
> `horse-provider-crosssocket` declares a dependency on
> `freitasjca/Delphi-Cross-Socket` and Boss currently resolves that
> dependency to **v1.0.3**.
>
> The fork exists for packaging reasons:
>
> - Upstream `winddriver/Delphi-Cross-Socket` does not provide a
>   `boss.json` manifest.
> - Delphi-Cross-Socket depends on CnPack crypto units, and the upstream
>   `cnpack/cnvcl` repository is not Boss-installable.
> - The fork vendors the minimal required CnPack subset and includes the
>   current mTLS additions, making the package directly consumable through Boss.
>
> The fork is **not intended to permanently diverge from upstream**. Its
> primary purpose is Boss compatibility and packaging convenience.
> However, `winddriver/Delphi-Cross-Socket` is actively developed and new
> fixes or features may appear upstream before they are synchronized into
> the fork. If you require the latest upstream functionality, review the
> upstream project and compare it with the fork release you are using.
>
> For maintainers: the fork contains a curated subset of CnPack under
> `CnPack/Common` and `CnPack/Crypto`. This subset must remain a complete
> transitive dependency closure and stay synchronized with the fork-sync
> automation described in the Delphi-Cross-Socket repository's
> maintenance documentation.

---

## Replace Path B description

Single dependency to clone (CnPack subset and mTLS additions already included).

The fork's primary goal is **Boss compatibility**, not feature divergence.
It vendors the minimal CnPack subset required by Delphi-Cross-Socket,
adds a `boss.json` manifest, and currently carries the mTLS extensions.

The trade-off is synchronization lag: upstream
`winddriver/Delphi-Cross-Socket` is under active development and may
contain fixes or features that have not yet been merged into the fork.
Before relying on newly released upstream functionality, verify that the
fork release you're using has been synchronized accordingly.

---

## Optional maintainer note

> **Maintainer note**
>
> The Delphi-Cross-Socket dependency resolved by Boss is
> `freitasjca/Delphi-Cross-Socket v1.0.3`, which vendors a curated CnPack
> subset specifically to make the package Boss-installable. The fork is
> synchronized from upstream `winddriver/Delphi-Cross-Socket`, but
> synchronization is periodic rather than continuous. Users needing the
> latest upstream changes should evaluate the upstream repository directly.
