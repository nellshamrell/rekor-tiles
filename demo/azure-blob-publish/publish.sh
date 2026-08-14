#!/usr/bin/env bash
#
# Copyright 2026 The Sigstore Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Mirror the POSIX log directory into Azure Blob Storage.
#
#   ./publish.sh                    publish once
#   ./publish.sh --loop             publish every PUBLISH_INTERVAL seconds
#   ./publish.sh --checkpoint-only  publish ONLY the checkpoint (see below)
#
# ORDERING IS THE ENTIRE POINT OF THIS SCRIPT.
#
# A checkpoint is a signed commitment to a tree of a given size. Clients take
# the size from the checkpoint and then fetch the tiles and entry bundles that
# size implies. If the checkpoint reaches the read path before those tiles do,
# every client sees a log that promises data it cannot serve -- indistinguishable,
# from the outside, from a log that is misbehaving.
#
# So the publish is two phases, in this order, always:
#
#   1. tiles and entry bundles
#   2. the checkpoint that commits to them
#
# Publishing late is harmless: a client just sees an older tree, which is a
# state the log was legitimately in a moment ago. Publishing out of order is
# not harmless. --checkpoint-only exists purely so 03-demo.sh can show the
# difference; never use it for real.
#
# .state/ is never published. It holds the driver's internal coordination files
# (treeState, the lock files, the antispam database). It is not secret, but it
# is not part of the log's public API either, and clients must not read it.

set -euo pipefail
# shellcheck source=demo-env.sh
source "$(dirname "${BASH_SOURCE[0]}")/demo-env.sh"

MODE="once"
case "${1:-}" in
  "")                 MODE="once" ;;
  --loop)             MODE="loop" ;;
  --checkpoint-only)  MODE="checkpoint-only" ;;
  *) fail "unknown argument: $1 (expected --loop or --checkpoint-only)" ;;
esac

require_web_url

# Cache lifetimes follow mutability, which the tlog-tiles layout makes easy to
# reason about:
#
#   full tiles and entry bundles   written once, never modified -> cache forever
#   partial tiles (".p/" in path)  rewritten as the tree grows  -> cache briefly
#   checkpoint                     rewritten every interval     -> never cache
#
# Getting this wrong is not a correctness bug -- a stale checkpoint is a valid
# older checkpoint -- but it does decide whether clients see new entries within
# seconds or within a day.
CACHE_IMMUTABLE="public, max-age=31536000, immutable"
CACHE_PARTIAL="public, max-age=60"
CACHE_CHECKPOINT="no-cache"

# publish_data uploads tiles and entry bundles. Everything the log serves other
# than the checkpoint lives under tile/, so pointing at that one directory
# excludes both the checkpoint and .state/ by construction rather than by a
# filter that could later drift.
publish_data() {
  local src="${STORAGE_DIR}/tile"
  [[ -d "${src}" ]] || { note "no tiles yet"; return 0; }

  # Two passes. The first marks everything immutable; the second corrects the
  # partial tiles, which are the only mutable files under tile/. Partials are
  # therefore uploaded twice, which for the handful that exist at any moment is
  # cheaper than enumerating and classifying every file locally.
  az storage blob upload-batch \
    --account-name "${STORAGE_ACCOUNT}" \
    --auth-mode login \
    --destination "${WEB_CONTAINER}" \
    --destination-path tile \
    --source "${src}" \
    --pattern '*' \
    --overwrite \
    --content-cache "${CACHE_IMMUTABLE}" \
    --no-progress -o none

  # A tree smaller than a full tile has partials; a tree that lands exactly on a
  # tile boundary has none, and upload-batch is fine with matching nothing.
  az storage blob upload-batch \
    --account-name "${STORAGE_ACCOUNT}" \
    --auth-mode login \
    --destination "${WEB_CONTAINER}" \
    --destination-path tile \
    --source "${src}" \
    --pattern '*.p/*' \
    --overwrite \
    --content-cache "${CACHE_PARTIAL}" \
    --no-progress -o none
}

# publish_checkpoint uploads the checkpoint. Call this only after publish_data
# has returned successfully.
publish_checkpoint() {
  local cp="${STORAGE_DIR}/checkpoint"
  [[ -f "${cp}" ]] || { note "no checkpoint yet"; return 0; }

  az storage blob upload \
    --account-name "${STORAGE_ACCOUNT}" \
    --auth-mode login \
    --container-name "${WEB_CONTAINER}" \
    --name checkpoint \
    --file "${cp}" \
    --overwrite \
    --content-cache "${CACHE_CHECKPOINT}" \
    --content-type "text/plain; charset=utf-8" \
    --no-progress -o none
}

publish_once() {
  publish_data
  publish_checkpoint
}

case "${MODE}" in
  once)
    info "Publishing to ${TILES_URL}"
    publish_once
    note "done"
    ;;

  checkpoint-only)
    # Deliberately wrong. Used by 03-demo.sh to show what a client sees when a
    # checkpoint commits to tiles that have not been published.
    info "Publishing ONLY the checkpoint (deliberately out of order)"
    publish_checkpoint
    note "done"
    ;;

  loop)
    info "Publishing to ${TILES_URL} every ${PUBLISH_INTERVAL}s"
    note "This models the systemd timer in vm/rekor-publish.timer."
    while true; do
      if [[ -f "${PAUSE_FILE}" ]]; then
        sleep 1
        continue
      fi
      # A failed cycle must not kill the publisher. The next cycle re-uploads
      # from scratch, so a partial publish heals itself, and the ordering
      # guarantee holds within each cycle regardless.
      publish_once || note "publish cycle failed; retrying in ${PUBLISH_INTERVAL}s"
      sleep "${PUBLISH_INTERVAL}"
    done
    ;;
esac
