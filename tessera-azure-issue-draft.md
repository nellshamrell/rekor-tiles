# Feature: Azure storage support (Blob Storage + Azure Database for MySQL)

> **Draft — not submitted.** Target: https://github.com/transparency-dev/tessera/issues/new
> Suggested label: `enhancement`
>
> Per [CONTRIBUTING.md](https://github.com/transparency-dev/tessera/blob/main/CONTRIBUTING.md),
> this issue is opened *before* any implementation work, and states an intent to do the work
> so it can be assigned.

---

**Description**

This issue proposes adding an Azure storage driver to Tessera (Azure Blob Storage for
tiles/entry bundles, Azure Database for MySQL as the sequencer), and serves as a demand
signal for Azure support generally.

I'm raising it as a question first rather than a PR, since I can see from #845, #900 and
#991 that new backends carry a real maintenance cost for the team, and I'd rather find out
whether this is wanted at all before writing code.

## Use case

I work on [Sigstore's Rekor v2](https://github.com/sigstore/rekor-tiles), which is built on
Tessera. It currently ships four backends: GCP (GCS + Spanner), AWS (S3 + MySQL), POSIX,
and a GCP Cloud SQL variant that reuses your AWS driver against GCS's S3-compatible
endpoint.

There is no Azure option today. The people this affects are operators running private
Sigstore instances on Azure — organisations who want their own transparency log for
internal artifact signing, but whose infrastructure, identity, and compliance posture are
all Azure-based. Right now those operators either run cross-cloud or don't run Rekor v2
at all.

## What I've already tried

Following the advice in the [`storage/mysql` removal
notice](https://github.com/transparency-dev/tessera/blob/main/storage/mysql/README.md)
and your comment in #845, I looked at running the existing AWS driver against Azure
infrastructure. Azure Blob has no native S3 API, so this needs an S3 gateway in front of
it. I traced the compatibility in detail and it does appear workable:

- The driver's object-store surface is small: `GetObject`, `PutObject` (+`ContentType`,
  `CacheControl`), `PutObject` with `IfNoneMatch: "*"`, `ListObjectsV2`, `DeleteObjects`.
- The critical contract is that a failed precondition surfaces as the S3 error code
  `PreconditionFailed`, which `setObjectIfNoneMatch` relies on for its idempotent-write
  path. [`gaul/s3proxy`](https://github.com/gaul/s3proxy)'s `azureblob` backend maps
  Azure's `BLOB_ALREADY_EXISTS`/`CONDITION_NOT_MET` to HTTP 412 and emits exactly that
  code.
- Importantly it performs the conditional PUT **on the backend** rather than emulating it
  with a read-then-write, so it should hold under concurrent writers.

So I want to be upfront: **a workaround exists, and I don't think this proposal is
justified purely on "it's impossible today."** It isn't impossible. My argument is about
what that workaround costs.

## Why I think native support is still worth considering

**1. Authentication.** This is the main one. The gateway route requires minting long-lived
static credentials and handing them to a proxy, because that's what SigV4 needs. Native
Azure SDK access would use Entra ID workload identity / managed identities with no
long-lived secrets at all. For a transparency log — where the integrity of the write path
is the entire product — "no static credentials in the deployment" is a meaningful
difference rather than a cosmetic one.

This is the same argument @xingao267 makes in #957 for native Cloud SQL + GCS support:
> I think that's a prerequisite before any GCP native authentication can be enforced.

Azure is that situation one step further along, in that the S3-compat shim is a separate
process rather than an endpoint override.

**2. An extra component in the read and write path.** s3proxy is a JVM service that has to
be deployed, scaled, monitored and patched alongside the log. It's stateless and scales
horizontally, so it isn't the database-in-the-read-path pattern you removed the MySQL
driver for — but it is another failure domain and another thing to be on call for, in an
otherwise all-Go deployment.

**3. Out-of-tree isn't really available.** `Driver` is explicitly documented as
[not for public use](https://github.com/transparency-dev/tessera/blob/main/log.go#L44-L45),
and drivers depend on `storage/internal`, so they can't live outside the module. As #991
worked through, the practical options are in-tree or a fork. I'd much rather not fork.

I'd also note this doesn't ask you to support a new database technology: the sequencer
would be MySQL, which the AWS driver already exercises. The genuinely new surface is the
object store.

## Proposed shape

Deliberately minimal, mirroring `storage/aws`:

- `storage/azure/` — an `objStore` implementation over `azblob` (Azure Blob supports
  `If-None-Match: *` natively), reusing the existing MySQL sequencer against Azure
  Database for MySQL (Flexible Server).
- `storage/azure/antispam/` — the existing MySQL antispam implementation appears reusable
  more or less as-is.
- `cmd/conformance/azure/`, integration tests, `deployment/modules/azure/` terraform, and
  a `storage/azure/README.md`, to match what the GCP and AWS drivers ship.

Appender lifecycle first. Happy to leave Migration/GC out of the initial scope, or to
follow whatever staging you'd prefer.

If you'd rather this were structured as an Azure `objStore` slotted into the existing AWS
driver's machinery rather than a separate top-level driver, I'm glad to go that way — I
suspect there's a shared-code question here that overlaps with the refactoring @mhutchinson
mentioned in #991. I'd welcome direction on it rather than guessing.

## Scale and latency

Taking the questions you asked in #845 up front:

- **Target deployments:** private/self-hosted Sigstore instances rather than a
  public-good log, so volumes are well below CT-scale.
- **Write pattern:** entries trickle in as CI pipelines sign artifacts, and are
  latency-tolerant — Rekor v2 already batches writes and waits for publication, so
  checkpoint-interval-scale delays are acceptable.
- **Throughput:** I don't want to quote numbers I can't back up. If it would help, I can
  run your hammer tooling against a prototype and report real figures rather than
  estimates.

## Maintenance commitment

You've been clear in #845 and #991 that a new backend needs someone to implement it *and*
own it, so to be explicit: **I'm volunteering for both.** I'm willing to be listed as the
owner for `storage/azure`, respond to issues against it, keep it current as internal APIs
evolve, and maintain the test/deployment infrastructure it needs. I have Azure
infrastructure available to test against.

I'd rather commit to that up front than have it become an unowned corner of the repo.

## Questions

1. Is Azure support something you'd accept in-tree at all, given the maintenance
   position in #991?
2. If so, is a separate `storage/azure` driver the right shape, or would you prefer an
   Azure object-store implementation reusing the AWS driver's structure?
3. What would you need to see to consider it production-ready — conformance, integration
   tests, hammer results, terraform, something else?
4. Is there anything about CI (Azure credentials for integration tests) that would be a
   blocker on your side?

Happy to discuss on Slack or at a team meeting if that's easier than an issue thread.
