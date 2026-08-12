# Demo: Azure Key Vault checkpoint signing with POSIX storage

A runnable demo of `rekor-server-posix-azurekms`, which signs log checkpoints with a
key that lives in Azure Key Vault while keeping Tessera's POSIX (local filesystem)
storage driver.

The point of the demo is that **storage and signing are orthogonal**. The private key
never leaves the vault; the tiles are ordinary files on disk.

## Prerequisites

- An Azure subscription and the Azure CLI (`az login` completed)
- Go 1.25+ and `make`
- `python3`, `curl`, `openssl`
- Permission to create a resource group, a Key Vault, and role assignments

Azure cost is negligible: one standard-tier vault and one key, deleted at the end.

## What gets created

| Resource | Name | Purpose |
| --- | --- | --- |
| Resource group | `rekor-azure-demo` | Holds everything, so teardown is one command |
| Key Vault | `rekor-demo-<random>` | RBAC-authorized; vault names are globally unique |
| Key | `rekor-checkpoint-key` | EC P-256, `sign`/`verify` |
| Role assignments | Crypto Officer + Crypto User | Officer to create the key; User is all rekor needs |

Local state lives in `/tmp/rekor-azure-demo/` and in two dotfiles beside these scripts
(`.demo-env` caches the random vault suffix, `.demo-pubkey.pem` is the exported public
key). All of it is removed by the teardown script.

## Running it

Two terminals, from this directory.

**Terminal 1 — set up Azure, then run the server:**

```bash
./01-setup-azure.sh    # ~2 minutes, includes a 45s wait for RBAC propagation
./02-run-server.sh     # stays in the foreground
```

`02-run-server.sh` also starts a `python3 -m http.server` on port 8000 publishing the
storage directory. The POSIX driver writes tiles and checkpoints to disk but does not
serve them, so a static file server is required — the same role nginx plays in
`posix-compose.yml`.

**Terminal 2 — the demo:**

```bash
./03-demo.sh           # pauses between sections; set PAUSE=0 to run straight through
```

**When done:**

```bash
./99-teardown.sh
```

## What the demo shows

1. **The flag surface.** `--signer-kmskey` is new. `--signer-kmshash` is deliberately
   absent: Azure Key Vault derives the digest from the key's own algorithm and ignores
   any hash handed to it, so the flag would let you ask for SHA-512 and silently get
   SHA-256. No `--signer-tink-*` flags either — there is no Tink Azure KMS provider in
   any language ([google/tink#158](https://github.com/google/tink/issues/158)).
2. **Signer config is validated up front.** Setting neither flag, or both, fails at
   startup with a specific message. The `gcp` binary silently prefers the file when both
   are set; this one refuses to guess.
3. **The key is really the one in Key Vault.** `az keyvault key show` and the exported
   public key agree with what the server logged at startup.
4. **A signed checkpoint.** The raw note, straight from the storage directory.
5. **Submit and verify.** The Go client in `client/` submits a hashedrekord entry, waits
   for the tree to grow, and verifies each checkpoint against the exported public key
   using `note.Open`. That call fails unless the signature verifies, so a green result
   is the actual proof that Key Vault signed the checkpoint — not something the server
   asserted about itself.
6. **Storage is still plain POSIX.** A listing of the tile files on local disk.

## Talking points

- **No Tessera changes were needed.** The driver comes from `posixDriver.NewDriver(...)`
  and the signer is passed independently into `tessera.NewAppendOptions(...)`.
- **This is not an Azure storage backend.** Tessera has GCS, S3, MySQL, and POSIX
  drivers — there is no Azure blob driver. The binary is named for
  storage-plus-signer (`posix-azurekms`) rather than `azure` so it doesn't imply one.
- **It's a separate binary on purpose.** The README bills POSIX as "lightweight, no
  cloud dependencies," and build tags aren't used anywhere in this repo's build
  plumbing. `rekor-server-posix` stays byte-for-byte identical; the Azure SDK is linked
  only into the new binary.
- **Auth is `DefaultAzureCredential`.** The demo rides on your `az login` session. On an
  Azure VM or AKS the same binary picks up a managed identity with no credentials on
  disk.

## Caveat: this log cannot be witnessed

Ed25519 is the only key type compatible with witnessing (see `pkg/note/note.go`), and
Azure Key Vault offers EC and RSA but not Ed25519. So do not pass
`--witness-policy-path` alongside `--signer-kmskey`. This is a Key Vault limitation, not
a rekor one, and it's documented in the main README as well.

`--identity-mode` is unaffected — it constrains the algorithms clients may use for
*entries*, which is independent of the checkpoint key.

## Trying the client without Azure

The client works against any rekor-tiles server, so the submit-and-verify path can be
exercised with the file signer:

```bash
# terminal 1
make rekor-server-posix-azurekms
./rekor-server-posix-azurekms serve \
  --storage-dir=/tmp/demo-local --hostname=rekor-azure-demo \
  --signer-filepath=tests/testdata/pki/ed25519-priv-key.pem --checkpoint-interval=2s
python3 -m http.server 8000 --directory /tmp/demo-local

# terminal 2
go run ./demo/azure-keyvault/client \
  --pubkey=tests/testdata/pki/ed25519-pub-key.pem --origin=rekor-azure-demo
```

`--origin` must match the server's `--hostname`; the origin is part of the key hash, so
verification fails if they differ.

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| `Forbidden` / `403` from Key Vault | RBAC hasn't propagated yet; wait a minute and retry |
| `vault name is already in use` | A soft-deleted vault holds the name — `az keyvault purge -n <name>` |
| `no checkpoint at http://localhost:8000` | The static file server isn't running; start `02-run-server.sh` |
| Checkpoint verification fails | `--origin` doesn't match the server's `--hostname` |
| `409 Conflict` on submit | The entry already exists; the client generates a unique artifact per run |
