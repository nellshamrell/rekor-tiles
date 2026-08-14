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
# Step 3: demonstrate the split between a disk-backed log and a Blob read path.
# Run ./02-run-server.sh in another terminal first.

set -euo pipefail
# shellcheck source=demo-env.sh
source "$(dirname "${BASH_SOURCE[0]}")/demo-env.sh"

PAUSE="${PAUSE:-1}"
pause() { [[ "${PAUSE}" == "1" ]] && { printf '\n    (press enter)'; read -r; } || true; }

[[ -x "${SERVER_BIN}" ]] || fail "${SERVER_BIN} not found; run ./01-setup-azure.sh first"
[[ -f "${PUBKEY_PEM}" ]] || fail "${PUBKEY_PEM} not found; run ./01-setup-azure.sh first"
require_web_url
curl -sf "${SERVER_URL}/healthz" >/dev/null || fail "server not responding at ${SERVER_URL}; run ./02-run-server.sh"
curl -sf "${TILES_URL}/checkpoint" >/dev/null || fail "no checkpoint at ${TILES_URL}; is ./02-run-server.sh running and has the publisher had a cycle?"

# The publisher runs as a background loop inside 02-run-server.sh. Several
# sections below need it held still; make sure it is released however this
# script exits, or the next run would sit there wondering why nothing updates.
trap 'rm -f "${PAUSE_FILE}"' EXIT

blob_list() {
  az storage blob list \
    --account-name "${STORAGE_ACCOUNT}" \
    --auth-mode login \
    --container-name "${WEB_CONTAINER}" \
    --query '[].name' -o tsv
}

# checkpoint_size returns the tree size, which is line 2 of the signed note.
checkpoint_size() {
  curl -s "${TILES_URL}/checkpoint" | sed -n 2p
}

# bundle_path returns the entry bundle path a tree of the given size commits to.
# The demo never exceeds 256 entries, so everything lives in bundle 0; a partial
# bundle carries a ".p/<width>" suffix, a full one does not. An empty tree
# commits to no bundle at all.
bundle_path() {
  local size="$1" width=$(( $1 % 256 ))
  if [[ "${size}" -eq 0 ]]; then
    return 1
  fi
  if [[ "${width}" -eq 0 ]]; then
    echo "tile/entries/000"
  else
    echo "tile/entries/000.p/${width}"
  fi
}

http_status() {
  curl -s -o /dev/null -w '%{http_code}' "$1"
}

# cache_header prints the Cache-Control header for a URL, tolerating its
# absence: grep finding nothing must not take the whole script down.
cache_header() {
  local hdr
  hdr="$(curl -sI "$1" | grep -i '^cache-control' || true)"
  if [[ -n "${hdr}" ]]; then
    printf '    %s\n' "${hdr}"
  else
    printf '    (no cache-control header returned)\n'
  fi
}

################################################################################
info "Preparing: the log needs at least one entry to be worth looking at"
################################################################################
SIZE="$(checkpoint_size)"
if [[ "${SIZE:-0}" -eq 0 ]]; then
  note "The log is empty. Submitting one entry, and waiting for the publisher"
  note "to mirror the resulting tiles into Blob Storage."
  go run "${REPO_ROOT}/demo/azure-keyvault/client" \
    --url="${SERVER_URL}" \
    --tiles-url="${TILES_URL}" \
    --pubkey="${PUBKEY_PEM}" \
    --origin="${REKOR_HOSTNAME}" >/dev/null \
    || fail "could not seed the log; check the server and publisher output"
  note "done: tree size is now $(checkpoint_size)"
else
  note "The log already holds ${SIZE} entries."
fi

################################################################################
info "1. The log lives on a POSIX filesystem, and that is a real requirement"
################################################################################
note "Tessera's POSIX driver needs specific guarantees, not just writable space."
note "This is the same preflight you would run against an ext4 volume on an"
note "Azure managed disk before pointing --storage-dir at it."
echo
go run "${REPO_ROOT}/demo/azure-blob-publish/fscheck" --dir="${STORAGE_DIR}" | sed 's/^/    /'
echo
note "Azure Files over SMB fails 'hard links'. blobfuse2 fails that and"
note "'rename over existing'. Neither fails at mount time -- they fail during a"
note "write, which is why this runs before the log has any data in it."
pause

################################################################################
info "2. What is on disk, and what is published"
################################################################################
note "On disk (${STORAGE_DIR}):"
find "${STORAGE_DIR}" -mindepth 1 -maxdepth 1 | sed "s|${STORAGE_DIR}/|    |"
echo
note "In Blob Storage:"
BLOBS="$(blob_list)"
printf '%s\n' "${BLOBS}" | sed 's/^/    /'
echo
note "The checkpoint and the tiles are published. .state/ is not: it holds the"
note "driver's coordination files -- treeState, the lock files, the antispam"
note "database. Not secret, but not part of the log's public API either."
echo
if printf '%s\n' "${BLOBS}" | grep -q '^\.state'; then
  fail "'.state' was published; publish.sh should never do that"
fi
note "Confirmed: nothing under .state/ was published."
pause

################################################################################
info "3. Cache lifetimes follow mutability"
################################################################################
note "checkpoint -- rewritten every --checkpoint-interval:"
cache_header "${TILES_URL}/checkpoint"
echo
SIZE="$(checkpoint_size)"
BUNDLE="$(bundle_path "${SIZE}")"
note "${BUNDLE} -- a partial bundle, rewritten as the tree grows:"
cache_header "${TILES_URL}/${BUNDLE}"
echo
note "Full tiles and full entry bundles are written once and never modified, so"
note "publish.sh sends them with 'immutable' and a one-year lifetime. That is"
note "what makes a CDN in front of this endpoint worth having. None are visible"
note "above: a tile only becomes full at 256 entries, and this tree is smaller,"
note "so every file it has is still a partial."
pause

################################################################################
info "4. Publishing LATE is safe"
################################################################################
note "Holding the publisher still, then submitting an entry."
touch "${PAUSE_FILE}"
sleep "$(( PUBLISH_INTERVAL + 3 ))"   # let any in-flight publish cycle finish
BEFORE_SIZE="$(checkpoint_size)"
note "Blob currently advertises tree size ${BEFORE_SIZE}."
echo
note "The client below is the one from ../azure-keyvault, unmodified: only"
note "--tiles-url changed, from a local static file server to Blob Storage."
note "It will submit an entry and then time out after 30s waiting for the tree"
note "to grow, because nothing is publishing. The ERROR below is the expected"
note "result of this section, not a failure of the demo."
echo
go run "${REPO_ROOT}/demo/azure-keyvault/client" \
  --url="${SERVER_URL}" \
  --tiles-url="${TILES_URL}" \
  --pubkey="${PUBKEY_PEM}" \
  --origin="${REKOR_HOSTNAME}" || true
echo
note "The log advanced on disk. Blob still serves size ${BEFORE_SIZE}, and that"
note "checkpoint still verifies -- it is a state the log genuinely was in a"
note "moment ago. Clients see a slightly old log, which is a state they are"
note "built to tolerate. Nothing is broken."
pause

################################################################################
info "5. Publishing OUT OF ORDER is not safe"
################################################################################
note "Now the mistake: publish the checkpoint without first publishing the"
note "tiles it commits to."
echo
"${DEMO_DIR}/publish.sh" --checkpoint-only
echo
AFTER_SIZE="$(checkpoint_size)"
BUNDLE="$(bundle_path "${AFTER_SIZE}")"
note "Blob now advertises tree size ${AFTER_SIZE}."
note "A client reads that size and goes looking for ${BUNDLE}:"
echo
STATUS="$(http_status "${TILES_URL}/${BUNDLE}")"
note "GET ${BUNDLE} -> HTTP ${STATUS}"
echo
if [[ "${STATUS}" == "404" ]]; then
  note "A signed, valid checkpoint committing to data the log cannot serve."
  note "From outside there is no way to tell this apart from a log that is"
  note "misbehaving -- and the signature makes it look authoritative."
else
  note "Expected a 404 here; the tiles may already have been published."
fi
note "This is why publish.sh is two phases and why the checkpoint goes last."
pause

################################################################################
info "6. Correct ordering, and end-to-end verification from Blob"
################################################################################
note "Releasing the publisher, which publishes tiles first, checkpoint second."
rm -f "${PAUSE_FILE}"
sleep "$(( PUBLISH_INTERVAL + 5 ))"
STATUS="$(http_status "${TILES_URL}/${BUNDLE}")"
note "GET ${BUNDLE} -> HTTP ${STATUS}"
echo
note "Full run: submit to the server, verify from Blob Storage."
echo
go run "${REPO_ROOT}/demo/azure-keyvault/client" \
  --url="${SERVER_URL}" \
  --tiles-url="${TILES_URL}" \
  --pubkey="${PUBKEY_PEM}" \
  --origin="${REKOR_HOSTNAME}"
echo
note "That checkpoint was signed by the Key Vault key and served by Blob"
note "Storage, and it was verified against the public key exported in step 1."
pause

################################################################################
info "7. Where each piece actually runs"
################################################################################
note "Key Vault      signs checkpoints; the private key never leaves it"
note "POSIX disk     holds the log; the single writer owns it"
note "Blob Storage   serves tiles and checkpoints; scales and stays up"
note "               independently of the writer"
echo
note "Tessera has no Azure storage driver, so Blob here is a mirror of the"
note "filesystem rather than the log's storage. The source of truth is still"
note "one disk on one machine, which is what bounds write throughput and write"
note "availability in this design."

################################################################################
info "Demo complete"
################################################################################
note "Tear down the Azure resources with ./99-teardown.sh"
