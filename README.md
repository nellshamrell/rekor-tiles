# Rekor v2

Rekor v2, aka rekor-tiles or Rekor on Tiles, is a redesigned and modernized [Rekor](https://github.com/sigstore/rekor),
Sigstore's signature transparency log, transitioning its backend to a modern,
[tile-backed transparency log](https://transparency.dev/articles/tile-based-logs/) implementation to
simplify maintenance and lower operational costs.

More information (**documents are shared with [sigstore-dev](https://groups.google.com/g/sigstore-dev), join the group to get access, please don't request access**):

* [Proposal](https://docs.google.com/document/d/1Mi9OhzrucIyt-UCLk_FxO2_xSQZW9ow9U3Lv0ZB_PpM/edit?resourcekey=0-4rPbZPyCS7QDj26Hk0UyvA&tab=t.0#heading=h.bjitqo6lwsmn)
* [Design doc](https://docs.google.com/document/d/1ZYlt_VFB-lxbZCcTZHN-6KVDox3h7-ePp85pNpOUF1U/edit?resourcekey=0-V3WqDB22nOJfI4lTs59RVQ&tab=t.0#heading=h.xzptrog8pyxf)

## Storage Backends

Rekor v2 supports multiple storage backends. Separate binaries for each backend are provided:

* `rekor-server-gcp`: GCP-specific binary (includes only Google Cloud dependencies)
* `rekor-server-aws`: AWS-specific binary (includes only AWS dependencies)
* `rekor-server-posix`: POSIX-based storage (lightweight, no cloud dependencies)
* `rekor-server-posix-azurekms`: POSIX-based storage with Azure Key Vault checkpoint signing
* `rekor-server-gcpcloudsql`: Alternative to GCP binary that uses CloudSQL instead of Spanner

### Google Cloud Platform (GCP)

* Binary: `rekor-server-gcp`
* Container `rekor-tiles/gcp`
* Sequencing entries: Cloud Spanner
* Tile storage: Google Cloud Storage (GCS)
* Use case: Preferred deployment architecture for GCP, highly scalable

### Amazon Web Services (AWS)

* Binary: `rekor-server-aws`
* Container `rekor-tiles/aws`
* Sequencing: Aurora MySQL or RDS MySQL
* Tile storage: Amazon S3
* Use case: Deployment architecture for AWS

### POSIX

* Binary: `rekor-server-posix`
* Container `rekor-tiles/posix`
* Sequencing: Atomic POSIX operations
* Tile storage: POSIX-compliant filesystem
* Use case: Lower cost, easy to serve

### POSIX + Azure Key Vault

* Binary: `rekor-server-posix-azurekms`
* Container `rekor-tiles/posix-azurekms`
* Sequencing: Atomic POSIX operations
* Tile storage: POSIX-compliant filesystem
* Checkpoint signing: Azure Key Vault, or a private key file
* Use case: POSIX storage where the checkpoint signing key should stay in Azure Key Vault

This is the same storage backend as `rekor-server-posix` and is configured identically,
including `--storage-dir`. It is shipped as a separate binary so that `rekor-server-posix`
stays free of cloud SDK dependencies.

Note that there is no Azure *storage* driver — Tessera provides drivers for GCS, S3,
MySQL, and POSIX only, so tiles are still written to a filesystem (for example an Azure
Files share mounted on the server).

To sign checkpoints with a Key Vault key, pass its URI:

```shell
rekor-server-posix-azurekms serve \
  --storage-dir=/var/lib/rekor \
  --hostname=rekor.example.com \
  --signer-kmskey=azurekms://[VAULT_NAME].vault.azure.net/[KEY_NAME]
```

A specific key version may be pinned by appending it:
`azurekms://[VAULT_NAME].vault.azure.net/[KEY_NAME]/[KEY_VERSION]`.

`--signer-kmskey` and `--signer-filepath` are mutually exclusive; exactly one must be set.

To confirm the key is wired up correctly, check that the server logs `Loaded signing key`
with a base64 DER public key matching
`az keyvault key show --vault-name [VAULT_NAME] -n [KEY_NAME]`, then fetch a signed
checkpoint, whose signature is produced by Key Vault:

```shell
curl -s http://localhost:3000/api/v2/checkpoint
```

Reading the public key and signing are separate Key Vault permissions, so a missing role
assignment can surface at either step.

There is deliberately no hash algorithm flag. Azure Key Vault determines the digest
(SHA-256, SHA-384, or SHA-512) from the algorithm of the key itself, so a flag would have
no effect. Tink is not supported for Azure, as there is no Tink Azure Key Vault
integration.

The identity used by the server needs the **Key Vault Crypto User** role on the key or
vault, which grants the `sign` and `get` permissions required to sign checkpoints and read
the public key. Authentication uses `DefaultAzureCredential`, so any of the standard
mechanisms work, including a managed identity when running on Azure, or these environment
variables:

* `AZURE_TENANT_ID`
* `AZURE_CLIENT_ID`
* `AZURE_CLIENT_SECRET`

#### Supported key types, and witnessing

Azure Key Vault supports EC (P-256, P-384, P-521, P-256K) and RSA keys. It does not offer
Ed25519, and Ed25519 is the only key type compatible with witnessing, so a log whose
checkpoints are signed by a Key Vault key cannot be witnessed. Don't pass
`--witness-policy-path` when signing with `--signer-kmskey`.

If you need witnessing, sign with an Ed25519 key file via `--signer-filepath` instead.
This constraint is a property of the signed-note format rather than of this binary, and
applies equally to the gcp and aws backends when signing with a KMS key.

Note that `--identity-mode` is unaffected: it constrains the algorithms accepted for
*client entries*, not the checkpoint signing key, so it can be combined with Key Vault
signing.

### GCP CloudSQL + Cloud Storage

* Binary: `rekor-server-gcpcloudsql`
* Container `rekor-tiles/gcpcloudsql`
* Sequencing: CloudSQL
* Tile storage: Google Cloud Storage (GCS)
* Use case: Alternative to Spanner sequencing, would only recommend if Spanner cannot be used

To authenticate to GCS, you must create
[HMAC access keys](https://docs.cloud.google.com/storage/docs/authentication/hmackeys)
and set the following environment variables:

* `GCS_HMAC_ACCESS_KEY_ID`
* `GCS_HMAC_SECRET`
* `GCS_REGION`, the region of the bucket
* `GCS_ENDPOINT_URL`, which should equal `https://storage.googleapis.com`

## Public-good instance

The Sigstore community hosts a productionized instance of Rekor v2 with a 99.5% availability SLO.
See the [status page](https://status.sigstore.dev/) for uptime metrics.

Use the public-good instance's TUF repository to determine the URL of the active instance.
Note that the community instance's URL will change approximately every 6 months when
we "shard" the log, creating a new log instance to keep the size of the log maintainable.
Sigstore clients will pull the latest log shard URL from the TUF-distributed
[SigningConfig](https://github.com/sigstore/root-signing/blob/main/targets/signing_config.v0.2.json),
and will fetch both active and inactive shard public keys from the
[TrustedRoot](https://github.com/sigstore/root-signing/blob/main/targets/trusted_root.json).

As of October 2025, we have not yet distributed the current Rekor v2 URL in the SigningConfig, to give users
adequate time to update their clients to support verifying entries from Rekor v2. We are planning to distribute
the latest Rekor v2 URL by end of 2025/early 2026.

If you want to start using Rekor v2, construct a signing config, using the
[TUF-distributed signing config](https://github.com/sigstore/root-signing/blob/main/targets/signing_config.v0.2.json)
as a base, and adding the following instance as the first entry in the `rekorTlogUrls` list:

```shell
    {
      "url": "https://log2025-1.rekor.sigstore.dev",
      "majorApiVersion": 2,
      "validFor": {
        "start": "2025-10-06T00:00:00Z"
      },
      "operator": "sigstore.dev"
    },
```

**Note**: We will eventually turn down the 2025 Rekor v2 instance when we deploy a 2026 instance. We strongly
advise against hardcoding this URL into any pipelines that cannot be easily updated.

## Installation

We provide prebuilt binaries and containers for private deployments.

* Download the latest binary from [Releases](https://github.com/sigstore/rekor-tiles/releases)
* Pull the latest container from [GHCR](https://github.com/sigstore/rekor-tiles/pkgs/container/rekor-tiles)
* Install Rekor v2 via [Helm](https://github.com/sigstore/helm-charts/tree/main/charts/rekor-tiles)

## Security Reports

If you find any issues, follow Sigstore's [security policy](https://github.com/sigstore/rekor-tiles/security/policy)
to report them.

## Local Development

### Deployment

Run `docker compose up --build --wait` to start the service along with emulated Google Cloud Storage and Spanner instances.

Run `docker compose down` to turn down the service, or `docker compose down --volumes` to turn down the service and delete
persisted tiles.

### Making a request

Follow the [client documentation](https://github.com/sigstore/rekor-tiles/blob/main/CLIENTS.md#rekor-v2-the-bash-way)
for constructing a request and parsing a response.

### Testing

Run unit tests with `go test ./...`.

Follow the [end-to-end test documentation](https://github.com/sigstore/rekor-tiles/blob/main/tests/README.md)
for how to run integration tests against a local instance.

## Adding a storage backend

Tessera supports multiple [storage backends](https://github.com/transparency-dev/tessera/tree/main/storage) for
different cloud providers and infrastructure. We will add support in Rekor for different storage backends with
user demand.

Rekor will produce different binaries and containers for each storage backend. Binaries will be named
`rekor-server-<backend>` and containers `github.com/sigstore/rekor-tiles/pkgs/container/rekor-tiles/<backend>`.

To add support for a new backend, with the example below for the `gcp` backend from [PR #630](https://github.com/sigstore/rekor-tiles/pull/630):

* Create a [backend-specific driver](https://github.com/sigstore/rekor-tiles/blob/d596e236da3ce44024986f24c34005714430dda5/internal/tessera/gcp/gcp.go)
* If needed, create a [backend-specific signer/verifier](https://github.com/sigstore/rekor-tiles/blob/682236adf5e63118853b00c5bfa33ba36a381fce/internal/tessera/gcp/signerverifier/signerverifier.go).
  At a minimum, you should support the file-based signer/verifier. To support a KMS-backed key, import the cloud provider-specific driver
  ([example](https://github.com/sigstore/rekor-tiles/blob/682236adf5e63118853b00c5bfa33ba36a381fce/internal/tessera/gcp/signerverifier/signerverifier.go#L33)).
* Create a [backend-specific main package](https://github.com/sigstore/rekor-tiles/tree/d596e236da3ce44024986f24c34005714430dda5/cmd/rekor-server/gcp)
* Create a Docker compose file, and set the [`STORAGE_BACKEND`](https://github.com/sigstore/rekor-tiles/blob/d596e236da3ce44024986f24c34005714430dda5/compose.yml#L52-L53)
  arg for building the containerized binary
* Add an [end-to-end test configuration](https://github.com/sigstore/rekor-tiles/blob/d596e236da3ce44024986f24c34005714430dda5/tests/e2e_test.go#L77-L93)
* Add the binary to [goreleaser](https://github.com/sigstore/rekor-tiles/blob/d596e236da3ce44024986f24c34005714430dda5/.goreleaser.yaml#L30-L46)
* Add the storage backend to the [matrix for container building](https://github.com/sigstore/rekor-tiles/blob/d596e236da3ce44024986f24c34005714430dda5/.github/workflows/build_container.yml#L51)
* Update the [build test matrix](https://github.com/sigstore/rekor-tiles/blob/69bc24a7269a3a0b6d8df3f4938f6eb77c2194b9/.github/workflows/test.yml#L50)
* Update the [end-to-end test matrix](https://github.com/sigstore/rekor-tiles/blob/69bc24a7269a3a0b6d8df3f4938f6eb77c2194b9/.github/workflows/test.yml#L115)
* Add a [Makefile target](https://github.com/sigstore/rekor-tiles/blob/d596e236da3ce44024986f24c34005714430dda5/Makefile#L76-L77) and update
  [`make all`](https://github.com/sigstore/rekor-tiles/blob/d596e236da3ce44024986f24c34005714430dda5/Makefile#L18)
* Once merged, update the list of [required tests](https://github.com/sigstore/community/blob/ff0761c37ab63c55f50609ed32c27e2bc9497572/github-sync/github-data/sigstore/repositories.yaml#L1513)
