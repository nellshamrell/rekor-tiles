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
# Step 2: run the server on a POSIX filesystem, publishing to Blob Storage.
#
# Run this in its own terminal; it stays in the foreground so you can watch the
# log. Then run ./03-demo.sh in a second terminal.
#
# This is one process doing what two systemd units do on the deployment in vm/:
# rekor-server.service writes the log to a disk, and rekor-publish.timer mirrors
# it into Blob.

set -euo pipefail
# shellcheck source=demo-env.sh
source "$(dirname "${BASH_SOURCE[0]}")/demo-env.sh"

[[ -x "${SERVER_BIN}" ]] || fail "${SERVER_BIN} not found; run ./01-setup-azure.sh first"
require_web_url

PUBLISH_LOG="${DEMO_DIR}/.publish.log"

# A previous run may have been interrupted mid-demo while the publisher was
# paused; starting up paused would be baffling.
rm -f "${PAUSE_FILE}"

mkdir -p "${STORAGE_DIR}"

################################################################################
info "Checking that ${STORAGE_DIR} can host a Tessera POSIX log"
################################################################################
# The POSIX driver needs more from a filesystem than the ability to write files:
# hard links, rename over an existing file, directory fsync, and fcntl record
# locks. Local disks provide all of it, and so does an ext4 volume on an Azure
# managed disk -- which is exactly why the deployment in vm/ uses one. Azure
# Files over SMB and blobfuse2 do not, and they fail during a write rather than
# at mount time, so the check belongs here, before any data exists.
go run "${REPO_ROOT}/demo/azure-blob-publish/fscheck" --dir="${STORAGE_DIR}" \
  || fail "${STORAGE_DIR} is not safe for a POSIX log; see the output above"

################################################################################
info "Starting the publisher"
################################################################################
note "log: ${PUBLISH_LOG}"
"${DEMO_DIR}/publish.sh" --loop >"${PUBLISH_LOG}" 2>&1 &
PUBLISH_PID=$!
trap 'kill "${PUBLISH_PID}" 2>/dev/null || true' EXIT

################################################################################
info "Starting rekor-server-posix-azurekms"
################################################################################
note "storage:   ${STORAGE_DIR}  (local POSIX filesystem; models a managed disk)"
note "signer:    ${KMS_KEY_URI}"
note "origin:    ${REKOR_HOSTNAME}"
note "write path: ${SERVER_URL}"
note "read path:  ${TILES_URL}"
echo
note "The server never talks to Blob Storage. It writes files; publish.sh"
note "mirrors them. That separation is what lets the read path scale and stay"
note "up independently of the single writer."
echo

# Authentication uses DefaultAzureCredential, so an 'az login' session is enough
# here. On the VM deployment this picks up the machine's managed identity, and
# no credential exists on disk for either signing or publishing.
#
# Note: no --witness-policy-path. Witnessing requires an Ed25519 key, which
# Azure Key Vault does not offer.
"${SERVER_BIN}" serve \
  --storage-dir="${STORAGE_DIR}" \
  --hostname="${REKOR_HOSTNAME}" \
  --signer-kmskey="${KMS_KEY_URI}" \
  --checkpoint-interval=2s \
  --log-level=info
