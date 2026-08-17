# Demo: Azure Key Vault signing with POSIX storage on a managed disk

This demo runs `rekor-server-posix-azurekms` with:

| Component | Azure deployment |
| --- | --- |
| Checkpoint key | Azure Key Vault |
| Tiles, checkpoints, and driver state | ext4 on an Azure managed disk |
| Tile HTTP serving | nginx reading directly from the mounted disk |

The managed disk is the authoritative cloud-persisted tile store and is attached to one
writer VM.

## Prerequisites

- Azure CLI with `az login`
- Go 1.25+, `make`, `python3`, `curl`, and `openssl`
- Permission to create a resource group, Key Vault, role assignments, and optionally a VM

## Local walkthrough

The local run uses `/tmp/rekor-azure-demo/storage` to model the managed disk while using
a real Key Vault key:

```bash
cd demo/azure-keyvault
./01-setup-azure.sh
./02-run-server.sh       # terminal 1
PAUSE=0 ./03-demo.sh     # terminal 2
./99-teardown.sh
```

`02-run-server.sh` first runs `fscheck`, then starts a local static HTTP server over the
storage directory and the Rekor writer. `03-demo.sh` verifies signer validation, confirms
the Key Vault key, submits an entry, verifies the signed checkpoint, and shows the files
remaining on the POSIX filesystem.

## Managed-disk deployment

After `01-setup-azure.sh`, create the production-shaped VM:

```bash
cd vm
./provision.sh
./provision.sh --status
```

The provisioner:

1. Creates an Azure VM with a system-assigned managed identity.
2. Creates and attaches a Premium SSD managed disk.
3. Partitions and formats it as ext4, mounted at `/var/lib/rekor`.
4. Grants the VM `Key Vault Crypto User`.
5. Runs one Rekor writer using `/var/lib/rekor/log`.
6. Runs nginx on port 80, serving tiles directly from that directory.

Only one VM may mount and write this ext4 disk. Availability is failover-based: stop the
writer, detach the disk, attach it to a replacement VM, and restart. Do not attach an
Azure shared disk to two VMs with ext4.

## Filesystem requirements

Tessera POSIX storage relies on hard links, exclusive link creation, rename-over-existing,
directory `fsync`, `O_SYNC`, and `fcntl` locks. Test any candidate mount with:

```bash
go run ./fscheck --dir=/var/lib/rekor/log
```

An ext4 or XFS managed disk is suitable. Azure Files SMB and blobfuse2 are not.

## Caveat: witnessing

Azure Key Vault offers EC and RSA keys, but not Ed25519. Rekor witnessing requires
Ed25519, so do not combine `--signer-kmskey` with `--witness-policy-path`.

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| `Forbidden` from Key Vault | RBAC has not propagated; wait and retry |
| `does not exist in MSAL token cache` | Run `az login` |
| `no checkpoint at http://localhost:8000` | Start `02-run-server.sh` |
| Checkpoint verification fails | `--origin` differs from server `--hostname` |
| `fscheck` fails hard links | The mount is not suitable for Tessera POSIX storage |
