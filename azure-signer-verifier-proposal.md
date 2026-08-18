# Draft GitHub Issue — sigstore/rekor-tiles

**Suggested labels:** `enhancement`, `server`
**Suggested title:** Support deploying Rekor v2 on Azure

---

## Summary

Rekor v2 currently ships backend-specific binaries for GCP, AWS, and POSIX (plus
`gcpcloudsql` as an alternative GCP shape). There is no supported path to deploy on
Azure. I'd like to propose adding one, and I want to get maintainer input on the approach
before writing code.

The blocker isn't the signing side — it's storage. I've done some investigation and
believe there's a low-cost path that doesn't require any new upstream Tessera work.

## Background: why there's no Azure option today

Tessera provides storage drivers for `aws` (S3 + MySQL), `gcp` (GCS + Spanner), `mysql`
(self-contained), and `posix`. There is no Azure driver, and I found no upstream issue,
discussion, or branch proposing one.

Writing one is a substantial undertaking and can't be done in this repo: a Tessera driver
imports `tessera/storage/internal` (`Integrate`, `NewQueue`, `TileID`), which is a Go
`internal/` package, so a driver must live inside the Tessera module tree. That makes a
native Azure Blob driver an upstream contribution with uncertain acceptance — not a good
first step.

## Proposal: a MySQL storage backend

Tessera's self-contained `mysql` driver stores tiles, entry bundles, and checkpoints
entirely in MySQL. Pointed at Azure Database for MySQL (Flexible Server), it gives a
working Azure deployment with **no new Tessera driver at all** — only rekor-tiles-side
wiring, following the existing backend pattern.

**I'd suggest naming the backend `mysql` rather than `azure`,** since it's cloud-agnostic:
the same binary would serve Azure Database for MySQL, AWS RDS/Aurora, Cloud SQL, and
on-prem MySQL. Azure becomes a documented deployment target rather than a hardcoded one.
Happy to go with `azure` instead if maintainers prefer explicitness — this is one of the
main things I'd like feedback on.

### The viability question: tile reads

Tessera's docs note the MySQL backend is architecturally different from the others — reads
"must be served via the personality rather than directly" from object storage
(`docs/performance.md`).

**Rekor v2 already works this way.** It serves `/api/v2/checkpoint`,
`/api/v2/tile/{L}/{N}`, and `/api/v2/tile/entries/{N}` through its own API
(`api/proto/rekor/v2/rekor_service.proto`), with no dependency on a publicly-served
bucket. So the driver's primary architectural constraint is already satisfied by Rekor's
existing design.

### Other findings

- `storage/mysql` implements `Appender`, `MigrationWriter`, and the full reader surface;
  its constructor is just `New(ctx, *sql.DB)`.
- **Persistent antispam works.** `storage/aws/antispam` has no S3/AWS coupling — it's
  plain MySQL and self-initializes its tables. This repo already reuses it with GCP Cloud
  SQL in `internal/tessera/gcpcloudsql`.
- **Schema isn't auto-created.** `storage/mysql`'s `ensureVersion` only *validates* the
  compatibility version; `schema.sql` must be applied out-of-band, and it can't be
  `go:embed`ed across module boundaries. Tessera's own conformance binary handles this
  with an `--init_schema_path` flag. How this repo wants to handle schema provisioning is
  a second thing I'd like input on.

## Checkpoint signing on Azure

An Azure deployment will want Azure Key Vault signing. This would mean an
`internal/tessera/azure/signerverifier` package built on
`sigstore/pkg/signature/kms/azure` (scheme `azurekms://`), supporting KMS and file
signers.

I want to flag explicitly that this **doesn't reverse #647**. That PR moved signer
initialization into backend-specific packages to shrink the dependency graph (~75 MB →
~50 MB for GCP), dropping AWS/Azure/Hashivault KMS from the GCP binary. This proposal
adds an Azure KMS dependency *only* to a new backend-specific package where it's the
correct minimal choice — the GCP and AWS binaries are untouched. It applies #647's
principle to a new cloud rather than working against it.

**Tink would not be supported for Azure.** There is no `tink-go-azurekms` in any language,
and upstream Tink declined to build one (`google/tink#158`, closed Jan 2024, maintainer
citing maintenance cost). `WithTink` would return an explicit "not supported for Azure"
error. Note there's precedent here: #647 already dropped Tink KEK support for AWS.

## Tradeoffs I want to be upfront about

- **Write throughput.** Tessera measured roughly 300–400 writes/s for the MySQL backend on
  a small GCP VM, and recommends cloud-native drivers where they exist. For Azure none
  exists, so this is the best available option — but I'd validate throughput against
  realistic Rekor volume early and report numbers before building anything polished.
- **Read load moves to the database** rather than a CDN-fronted bucket. Production
  deployments would likely want caching in front of the read API. Read scaling is possible
  via MySQL read replicas plus read-only instances.
- **A third near-identical signerverifier package.** The aws and gcp ones are ~95%
  identical already. Happy to extract a shared package instead if that's preferred.

## Proposed scope

1. Spike: validate append + read-back through the tile API against a MySQL container, with
   throughput numbers. **Gate — reassess if this doesn't hold up.**
2. `internal/tessera/mysql` driver wrapper (mirroring `internal/tessera/gcpcloudsql`).
3. Schema provisioning approach.
4. `internal/tessera/azure/signerverifier` (KMS + file). **Already implemented** — see
   "Update: the signer package has landed independently" below.
5. `cmd/rekor-server/mysql` command.
6. Makefile + `.goreleaser.yaml` entries.
7. Unit + integration tests against a MySQL container.
8. Docs, including an Azure deployment recipe (Flexible Server sizing, TLS, private
   networking, Key Vault signing).

This also doesn't preclude a native Azure Blob driver later. If MySQL throughput proves
inadequate, that remains the fallback — and the signer package, command scaffold, and
deployment docs would all carry over.

## Questions for maintainers

1. Is an Azure-deployable backend something you'd want in-tree?
2. `mysql` (cloud-agnostic) or `azure` (explicit) for the backend name?
3. Preferred approach for schema provisioning — vendored `schema.sql` with an opt-in
   `--init-schema` flag, or operator-managed migrations only?
4. Third signerverifier package, or extract a shared one and refactor aws/gcp?

Happy to adjust scope based on your feedback before starting.

---

## Update: the signer package has landed independently

Item 4 of the proposed scope (`internal/tessera/azure/signerverifier`) does not depend on
the MySQL storage work and has been implemented ahead of it, wired to a POSIX-storage
binary rather than a MySQL one. This decouples the signing question from the storage
question, so the storage discussion above can proceed on its own merits.

What shipped:

- `internal/tessera/azure/signerverifier` — `New()` with `WithFile`, `WithKMS`, and
  `WithTink`, linking only the Azure KMS provider, exactly as proposed.
- `cmd/rekor-server/posix-azurekms` — a new binary pairing Tessera's POSIX storage driver
  with Azure Key Vault checkpoint signing.

Two details that differ from what this document originally assumed:

**No hash algorithm flag.** The gcp and aws commands expose `--signer-kmshash`, so mirroring
them looked correct. It isn't: the Azure provider ignores the `crypto.Hash` passed to
`kms.Get` and derives the digest from the Key Vault key's own algorithm. Exposing the flag
would let an operator set `sha512`, see it accepted, and still get SHA-256 signatures. So
`WithKMS` takes only the URI and the command has no `--signer-kmshash`.

**A separate binary rather than extending `rekor-server-posix`.** The README bills POSIX as
"lightweight, no cloud dependencies". Adding an unconditional Azure SDK import would have
broken that, and a build tag was not viable because nothing in the Makefile, GoReleaser
config, Dockerfile, or container workflow passes build tags today. A separate command keeps
`rekor-server-posix` untouched. The cost is that `serve.go` is duplicated between the two
POSIX commands, which is the same duplication the repo already carries between the gcp and
gcpcloudsql commands.

The Tink question resolved as described above: `WithTink` exists but returns an explicit
"not supported for Azure Key Vault" error, and no `--signer-tink-*` flags are exposed. This
gives a clear diagnostic to anyone copying gcp flags, rather than a confusing
"insufficient signing parameters" fallthrough.

Question 4 for maintainers still stands — this is now genuinely the third near-identical
signerverifier package, and extracting a shared one remains a reasonable alternative.
