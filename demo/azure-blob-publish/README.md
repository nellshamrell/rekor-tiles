# Demo: a disk-backed rekor log published to Azure Blob Storage

A runnable demo of the deployment shape that gets you a fully-Azure rekor-tiles log
today, without a Tessera Azure storage driver:

| Piece | Where it lives | What it does |
| --- | --- | --- |
| Checkpoint signing key | Azure Key Vault | Signs; the private key never leaves the vault |
| The log | A POSIX filesystem | Tiles and checkpoints as ordinary files, written by one process |
| The read path | Azure Blob Storage | Serves those files to clients, independently of the writer |

The companion demo in [`../azure-keyvault`](../azure-keyvault) shows the signing half.
This one is about the other two: what the filesystem under `--storage-dir` actually has
to guarantee, and how to get the log onto Blob Storage **without ever publishing a
checkpoint that commits to tiles clients cannot fetch**.

## Prerequisites

- An Azure subscription and the Azure CLI (`az login` completed)
- Go 1.25+ and `make`
- `curl`
- Permission to create a resource group, a Key Vault, a storage account, and role
  assignments

Azure cost is negligible: one standard-tier vault, one key, and a Standard_LRS storage
account holding a few kilobytes, all deleted at the end.

## What gets created

| Resource | Name | Purpose |
| --- | --- | --- |
| Resource group | `rekor-azure-blob-demo` | Holds everything, so teardown is one command |
| Key Vault | `rekor-blob-<random>` | RBAC-authorized; vault names are globally unique |
| Key | `rekor-checkpoint-key` | EC P-256, `sign`/`verify` |
| Storage account | `rekorblob<random>` | Static website hosting enabled; serves the `$web` container |
| Role assignments | Crypto Officer + Crypto User + Storage Blob Data Contributor | Sign with the key, write to the blobs |

Static website hosting is used rather than a container with anonymous read access,
because many subscriptions disable anonymous blob access at the account level while
still permitting the static website endpoint. It is also the shape of a real
deployment, where Front Door or a CDN sits in front of that endpoint.

The scripts are re-runnable: `01-setup-azure.sh` reuses an existing vault, key, storage
account, and role assignments, so an interrupted setup can simply be run again.

Local state lives in `/tmp/rekor-azure-blob-demo/` and in dotfiles beside these scripts.
All of it is removed by the teardown script.

## Running it

Two terminals, from this directory.

**Terminal 1 — set up Azure, then run the server and publisher:**

```bash
./01-setup-azure.sh    # ~2 minutes, includes a 45s wait for RBAC propagation
./02-run-server.sh     # stays in the foreground
```

`02-run-server.sh` does three things: it verifies the storage filesystem with `fscheck`,
starts a background publish loop, and runs the server. Those last two are one process
here and two systemd units on the deployment in [`vm/`](vm).

**Terminal 2 — the demo:**

```bash
./03-demo.sh           # pauses between sections; set PAUSE=0 to run straight through
```

Allow a couple of minutes: section 4 deliberately waits out a 30-second client timeout.

**When done:**

```bash
./99-teardown.sh
```

## What the demo shows

1. **The filesystem is a real requirement.** `fscheck` probes the five POSIX guarantees
   Tessera's driver depends on. See below.
2. **What is published, and what is not.** The checkpoint and tiles go to Blob; `.state/`
   never does. The demo fails loudly if it ever finds `.state` in the container.
3. **Cache lifetimes follow mutability.** Full tiles are immutable and cached for a year;
   partial tiles briefly; the checkpoint not at all.
4. **Publishing late is safe.** The publisher is held still and an entry submitted. The
   client times out waiting for the tree to grow, and Blob keeps serving an older
   checkpoint that still verifies. Clients see a slightly stale log, which is a state
   they are built to tolerate.
5. **Publishing out of order is not.** `publish.sh --checkpoint-only` puts a checkpoint on
   the read path ahead of its tiles. The entry bundle that checkpoint commits to returns
   `404`: a signed, valid promise the log cannot honour, indistinguishable from the
   outside from a log that is misbehaving.
6. **Correct ordering, and end-to-end verification.** The publisher is released, the same
   URL returns `200`, and the client submits and verifies a checkpoint fetched from Blob
   against the public key exported from Key Vault.
7. **Where each piece runs**, and what this design does not give you.

The client is the one from `../azure-keyvault/client`, unmodified — only `--tiles-url`
changes, from a local static file server to the Blob endpoint. That is the whole point:
to a client, Blob Storage is just a static file server.

## The filesystem check

Tessera's POSIX driver needs more than writable space. From
`storage/posix/file_ops.go` upstream, it relies on:

| Guarantee | Used for |
| --- | --- |
| Hard links | `createEx` publishes a fully written temp file into its final name |
| `EEXIST` from `link` | Detecting a name that must not be clobbered |
| Rename over an existing file | `overwrite` replaces the checkpoint in one step |
| Directory `fsync` | Making the metadata for both of the above durable |
| `fcntl` record locks | `.state/treeState.lock`, `.state/publish.lock` |
| `O_SYNC` writes | Durability of the temp file before it is linked |

`fscheck` probes each of these and exits non-zero if any fails:

```bash
go run ./fscheck --dir=/var/lib/rekor/log
```

Run it against any candidate mount before pointing `--storage-dir` at it:

| Azure option | Result |
| --- | --- |
| **Managed disk (Premium SSD v2 / Ultra), ext4 or XFS** | Passes. What `vm/` uses. |
| Azure NetApp Files, Azure Files NFS 4.1 | May pass; upstream warns against NFS. Follow up with [pjdfstest](https://github.com/saidsay-so/pjdfstest). |
| Azure Files (SMB) | Fails `hard links`. |
| blobfuse2, Blob NFS 3.0 | Fails `hard links` and `rename over existing`. |

The failure mode matters as much as the failure: none of these refuse to mount. They
accept the mount and fail later, during a write, possibly after clients have already
seen a checkpoint. Hence a preflight rather than a runtime error.

`fscheck` establishes that the required operations are *supported*, not that they are
atomic under concurrent access — a distinction worth keeping in mind for anything
networked or clustered.

## Publish ordering

A checkpoint is a signed commitment to a tree of a given size. Clients read that size and
then fetch the tiles and entry bundles it implies. So `publish.sh` is two phases, always
in this order:

1. tiles and entry bundles (everything under `tile/`)
2. the checkpoint that commits to them

Pointing phase 1 at the `tile/` subtree excludes both the checkpoint and `.state/` by
construction, rather than by a filter that could later drift.

Publishing **late** is harmless — a client sees an older tree, a state the log genuinely
was in a moment ago. Publishing **out of order** is not, and section 5 of the demo shows
exactly what it looks like. `--checkpoint-only` exists solely for that demonstration.

Superseded partial tiles are left in place rather than deleted (`--delete-destination=false`
in the azcopy formulation). Clients only request paths derived from the size in the
current checkpoint, so an orphaned partial is unreferenced garbage rather than wrong
data; reaping it is a cost concern for its own schedule, not something worth racing
against the publish path.

## The disk-backed deployment

[`vm/`](vm) holds the artifacts for the deployment this demo models:

| File | Role |
| --- | --- |
| `cloud-init.yaml` | Partitions, formats, and mounts the managed disk at `/var/lib/rekor` |
| `rekor-server.service` | The single writer, signing via the VM's managed identity |
| `rekor-publish.sh` | One publish cycle, same two phases as `publish.sh` |
| `rekor-publish.service` | Runs one cycle, `Type=oneshot` |
| `rekor-publish.timer` | Triggers a cycle every 30s |

> These are illustrative and are **not** exercised by the demo scripts, which run the same
> binary against a local filesystem. Substitute the vault, key, hostname, and storage
> account names before use.

Two details in there are load-bearing:

- **`Type=oneshot` plus a timer means cycles cannot overlap.** Two concurrent publishers
  could interleave their phases and land a checkpoint ahead of its tiles — the one
  failure the ordering exists to prevent.
- **`Requires=var-lib-rekor.mount`.** Without it, a failed mount would start the server on
  the root filesystem and quietly begin a brand new, empty log.

Sketch of the surrounding infrastructure:

```bash
az vm create -g $RG -n rekor --image Ubuntu2404 \
  --assign-identity --custom-data vm/cloud-init.yaml
az vm disk attach -g $RG --vm-name rekor --name rekor-log \
  --new --size-gb 256 --sku PremiumV2_LRS --lun 0

PRINCIPAL=$(az vm identity show -g $RG -n rekor --query principalId -o tsv)
az role assignment create --assignee "$PRINCIPAL" --role "Key Vault Crypto User" \
  --scope "$(az keyvault show -n $VAULT --query id -o tsv)"
az role assignment create --assignee "$PRINCIPAL" --role "Storage Blob Data Contributor" \
  --scope "$(az storage account show -n $ACCOUNT -g $RG --query id -o tsv)"
```

## Scale and availability

The read path scales and survives independently of the writer: it is static files behind
a CDN, and it keeps serving while the VM is down.

The write path does not. One disk, one VM, one writer. HA is failover — detach the disk,
attach it to a replacement, accept the write outage — not active-active. **Do not attach
an Azure shared disk to two VMs with ext4 on it.** The driver's advisory locks coordinate
multiple frontends on a genuinely shared POSIX filesystem such as CephFS; a managed disk
is not one, and two writers will corrupt it.

Blob is a mirror, not a backup: it has no `.state/`, so you cannot resume writing from
it. Snapshot the disk.

Removing the single-writer bound means a real Tessera Azure storage driver (Blob plus a
coordination store), which does not exist today.

## Caveat: this log cannot be witnessed

Ed25519 is the only key type compatible with witnessing (see `pkg/note/note.go`), and
Azure Key Vault offers EC and RSA but not Ed25519. So do not pass `--witness-policy-path`
alongside `--signer-kmskey`. This is a Key Vault limitation, not a rekor one.

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| `Forbidden` / `403` from Key Vault or Blob | RBAC hasn't propagated yet; wait a minute and retry |
| `vault name is already in use` | A soft-deleted vault holds the name — `az keyvault purge -n <name>` |
| `static website endpoint unknown` | `01-setup-azure.sh` hasn't completed |
| `no checkpoint at https://...web.core.windows.net` | The publisher hasn't had a cycle yet; wait `PUBLISH_INTERVAL` seconds |
| Checkpoint verification fails | `--origin` doesn't match the server's `--hostname` |
| The tree never grows in Blob | A stale `.publish-paused` from an interrupted demo; `02-run-server.sh` clears it at startup |
| `fscheck` fails on `hard links` | The mount is SMB or blobfuse2; use a managed disk |
| `does not exist in MSAL token cache` | `az account show` can succeed from cached config with no live token — run `az login` |
