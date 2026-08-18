# Session notes: Azure Key Vault signing for the POSIX backend

Handoff notes for a future session. Written 2026-08-14.

This file is **deliberately untracked** (see "Untracked files" below). It's working
notes, not repo documentation.

---

## TL;DR

Added the ability to sign log checkpoints with a key in Azure Key Vault while keeping
Tessera's POSIX (local filesystem) storage driver. Implemented, tested, demoed against
live Azure, committed, and pushed. **The work is complete** — there is no unfinished
task waiting to be picked up.

- Branch: `add-azure-signerverifier`, pushed to `origin` (= `nellshamrell/rekor-tiles`, the fork)
- HEAD: `82e717d`
- **No PR was opened against upstream (`sigstore/rekor-tiles`), by explicit instruction.**
  Don't open one without asking.

## Commits (oldest first)

| SHA | What |
| --- | --- |
| `74a8089` | The feature: Azure signerverifier package + `posix-azurekms` binary (13 files) |
| `22815b5` | README: Key Vault key types and the witnessing constraint |
| `0811b2a` | The `demo/azure-keyvault/` demo |
| `82e717d` | Demo fixes found by running it against live Azure |

`598f247` is the last upstream commit the branch is based on.

## What was built

**`internal/tessera/azure/signerverifier/`** — mirrors the existing gcp/aws packages.
`New()` with `WithFile` / `WithKMS(uri)` / `WithTink` (an error stub). Blank-imports only
`sigstore/pkg/signature/kms/azure`.

**`cmd/rekor-server/posix-azurekms/`** — a fork of `cmd/rekor-server/posix` that wires in
the Azure signer. Also touched: `Makefile`, `.goreleaser.yaml`, `build_container.yml`,
`test.yml` (container-build matrix), `README.md`, `go.mod`/`go.sum`
(`kms/azure v1.10.9` promoted to a direct dep).

**`demo/azure-keyvault/`** — a runnable demo: `demo-env.sh`, `01-setup-azure.sh`,
`02-run-server.sh`, `03-demo.sh`, `99-teardown.sh`, `client/main.go`, `README.md`.

---

## Design decisions worth not relitigating

**Why a separate binary rather than a flag on `rekor-server-posix`.**
The README bills POSIX as "lightweight, no cloud dependencies," and build tags are not
viable here — nothing passes tags in `Makefile`, `.goreleaser.yaml`, `Dockerfile`, or
`build_container.yml`. So the Azure SDK is linked only into the new binary;
`rekor-server-posix` stays byte-for-byte identical (verified: 31,286,953 bytes both
before and after). The Dockerfile already parameterizes
`./cmd/rekor-server/${STORAGE_BACKEND}`, so it needed no change. Accepted cost: ~150
duplicated lines of `serve.go`, the same duplication gcp/gcpcloudsql already have.

**Why there is no `--signer-kmshash` flag.**
`kms/azure@v1.10.9/client.go:48` discards the `crypto.Hash` and RPC options handed to
`kms.Get`; the digest is derived from the Key Vault key's own algorithm
(`signer.go:94-99`, `client.go:283-298`). A hash flag would therefore be a silent no-op —
you could ask for SHA-512 and still get SHA-256. So `WithKMS(uri)` takes only a URI and
passes `crypto.Hash(0)`. This intentionally diverges from gcp's
`WithKMS(uri, hash, rpcOpts)` and aws's `WithKMS(uri, hash)` — which already differ from
each other anyway.

**Why setting both signer flags is an error.**
The new binary refuses when both `--signer-filepath` and `--signer-kmskey` are set. The
gcp binary silently prefers the file (`gcp/app/serve.go:69-84`). Refusing to guess seemed
better. The logic lives in an extracted `signerOptions(filepath, password, kmsKey)` helper
so it's testable without `os.Exit`.

**Tink is an error stub** because there is no Tink Azure KMS provider in any language
(google/tink#158).

## Constraints and gotchas

**This log cannot be witnessed.** `pkg/note/note.go:111` — Ed25519 is the only key type
compatible with witnessing, and Azure Key Vault offers EC and RSA but not Ed25519. Do not
pass `--witness-policy-path` alongside `--signer-kmskey`. Documented in both READMEs.

**`--identity-mode` is unaffected.** It constrains `client-signing-algorithms` for
*entries* (`serve.go:158-169`), not the checkpoint key. (I got this wrong once mid-session
and corrected it; don't re-derive the wrong conclusion.)

**URI scheme** is exactly `azurekms://`, form
`azurekms://<vault>.vault.azure.net/<key>[/<version>]` (`client.go:69-100`). Auth is
`DefaultAzureCredential` (`client.go:120`).

**The POSIX driver does not serve tiles or checkpoints.** It writes them to disk; a
separate static file server publishes them. The e2e suite uses nginx
(`posix-compose.yml`); the demo uses `python3 -m http.server`. `GET /api/v2/checkpoint`
on the rekor server returns "method GetCheckpoint not implemented" — don't be fooled by
this again, it cost time.

**The client's `--origin` must equal the server's `--hostname`**, since the origin is
folded into the key hash. Mismatch produces `note has no verifiable signatures`.

## Answered question: are gcp/aws signers coupled to cloud storage?

No. Verified three ways: (1) grepping `bucket|gcs|s3|storage|driver|spanner` across all
signerverifier packages returns nothing; (2) in every binary the signer is passed to
`tessera.NewAppendOptions(...)` while the driver is built independently 30-40 lines later
(gcp 91/140, aws 80/130, posix 65/112); (3) gcp and aws both already accept
`--signer-filepath`, so "cloud storage + local key" is an existing shipped combination.
The only coupling is packaging — each binary links exactly one KMS provider, so
`kms.SupportedProviders()` only ever contains that cloud's prefix.

---

**Blast radius** (verified with `git diff --name-only 598f247..82e717d`): outside the three
new directories (`internal/tessera/azure/`, `cmd/rekor-server/posix-azurekms/`, `demo/`),
the branch touches only `Makefile`, `.goreleaser.yaml`, the two workflow files,
`README.md`, and `go.mod`/`go.sum`. No existing Go source file was modified.

## Verification already done (don't redo unless something changed)

Build, `go vet`, full unit suite, golangci-lint (0 issues), addlicense, shellcheck on all
five demo scripts, POSIX e2e (`TestPOSIX` via `posix-compose.yml`), container build,
binary-size comparison, and `go list -deps` confirming `kms/azure` reaches only the new
command.

**Live Azure run (2026-08-13):** clean-slate setup on a new vault (1m55s), server loading
the key from Key Vault with the logged pubkey matching the exported PEM byte for byte,
checkpoints signed ECDSA P-256 and verified by the client, tree growth 0 -> 1, repeat
runs, restart against existing storage, graceful Ctrl-C, and teardown leaving zero
resources. Negative controls: verification fails with the wrong key and with a mismatched
origin.

**All Azure resources were torn down.** `az group list` and `az keyvault list-deleted`
are both clean. Nothing is accruing cost.

Four bugs were found *only* by running it live, all fixed in `82e717d`: setup wasn't
idempotent (`az keyvault create` fails if the vault exists, so an interrupted run couldn't
be re-run); `03-demo.sh` queried `key_ops` where the CLI emits `keyOps`; teardown purged
the vault after starting an async group delete, so the purge always no-oped and left the
name soft-deleted; and two README troubleshooting gaps.

## Environment notes

- WSL originally had only the **Windows** `az` on PATH (`/mnt/c/Program Files (x86)/...`).
  Nell installed the Linux CLI (now `/usr/bin/az`, 2.89.1). The setup script needs the
  Linux one to write PEMs to Linux paths.
- `az account show` can succeed from cached config while there is **no live token**; the
  giveaway is `does not exist in MSAL token cache` on the first real call. Fix: `az login`.
- Docker is not currently reachable from this WSL distro (Docker Desktop WSL integration
  appears to be off), so the Makefile's dockerized golangci-lint target can't run. I used
  a `shellcheck-py` venv instead for shell linting.
- Subscription used: "AOCTO OSS Ecosystem Proof of Concepts", user `nells@microsoft.com`.
- In this agent's bash tool, `kill` requires numeric PIDs — no `pkill`/`killall`, and
  `kill -INT -<pgid>` is rejected. Find PIDs with `pgrep -af` first.

## Untracked files at repo root (intentionally not committed)

- `azure-signer-verifier-proposal.md` — pre-existing draft, plus an appended "Update: the
  signer package has landed independently" section that exists only in the working tree.
- `tessera-azure-issue-draft.md` — pre-existing draft.
- `NOTES-azure-signerverifier.md` — this file.

These two drafts were briefly committed and then removed via `git rm --cached` with a
commit `--amend` + force-push, so they never appear in branch history. **Keep them
untracked** unless asked otherwise.

## If you want to run the demo again

```bash
cd demo/azure-keyvault
./01-setup-azure.sh     # ~2 min, creates rg + vault + EC P-256 key; re-runnable
./02-run-server.sh      # terminal 1, foreground; also starts the static file server
PAUSE=0 ./03-demo.sh    # terminal 2; omit PAUSE=0 to pause between sections
./99-teardown.sh        # deletes everything, including purging the vault
```

Prerequisites: Linux `az` with a live `az login`, Go, make, python3, curl, openssl.
`demo/azure-keyvault/README.md` has the full walkthrough and a troubleshooting table.

## Plausible next steps (none started, none requested)

- Upstream it: `sigstore/rekor-tiles` would likely want the Tessera Azure storage driver
  discussion resolved first — see `tessera-azure-issue-draft.md`.
- An e2e test for the new binary would need either a Key Vault in CI or a fake KMS
  provider; currently only unit tests plus the manual demo cover it.
- The ~150 duplicated lines of `serve.go` could be factored into a shared helper if a
  fourth POSIX-ish variant ever appears.
