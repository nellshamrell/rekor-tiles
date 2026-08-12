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
# Step 2: run the server, signing checkpoints with the Key Vault key.
#
# Run this in its own terminal; it stays in the foreground so you can watch
# the log. Then run ./03-demo.sh in a second terminal.

set -euo pipefail
# shellcheck source=demo-env.sh
source "$(dirname "${BASH_SOURCE[0]}")/demo-env.sh"

[[ -x "${SERVER_BIN}" ]] || fail "${SERVER_BIN} not found; run ./01-setup-azure.sh first"

mkdir -p "${STORAGE_DIR}"

# With the POSIX driver the server writes tiles and checkpoints to disk but
# doesn't serve them. Publish the storage directory so the demo client can read
# checkpoints, the same role nginx plays in posix-compose.yml.
info "Publishing ${STORAGE_DIR} on ${TILES_URL}"
python3 -m http.server "${TILES_PORT}" --directory "${STORAGE_DIR}" >/dev/null 2>&1 &
TILES_PID=$!
trap 'kill "${TILES_PID}" 2>/dev/null || true' EXIT

info "Starting rekor-server-posix-azurekms"
note "storage:  ${STORAGE_DIR}  (POSIX driver -- no Azure storage involved)"
note "signer:   ${KMS_KEY_URI}"
note "origin:   ${REKOR_HOSTNAME}"
echo
note "Watch for 'Loaded signing key' -- that public key comes from Key Vault."
echo

# Authentication uses DefaultAzureCredential, so an 'az login' session is
# enough here. On an Azure VM or AKS this would pick up a managed identity
# with no credentials on disk at all.
#
# Note: no --witness-policy-path. Witnessing requires an Ed25519 key, which
# Azure Key Vault does not offer.
"${SERVER_BIN}" serve \
  --storage-dir="${STORAGE_DIR}" \
  --hostname="${REKOR_HOSTNAME}" \
  --signer-kmskey="${KMS_KEY_URI}" \
  --checkpoint-interval=2s \
  --log-level=info
