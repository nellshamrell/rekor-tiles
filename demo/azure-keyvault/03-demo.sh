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
# Step 3: demonstrate the new functionality against the running server.
# Run ./02-run-server.sh in another terminal first.

set -euo pipefail
# shellcheck source=demo-env.sh
source "$(dirname "${BASH_SOURCE[0]}")/demo-env.sh"

PAUSE="${PAUSE:-1}"
pause() { [[ "${PAUSE}" == "1" ]] && { printf '\n    (press enter)'; read -r; } || true; }

[[ -x "${SERVER_BIN}" ]] || fail "${SERVER_BIN} not found; run ./01-setup-azure.sh first"
[[ -f "${PUBKEY_PEM}" ]] || fail "${PUBKEY_PEM} not found; run ./01-setup-azure.sh first"
curl -sf "${SERVER_URL}/healthz" >/dev/null || fail "server not responding at ${SERVER_URL}; run ./02-run-server.sh"
curl -sf "${TILES_URL}/checkpoint" >/dev/null || fail "no checkpoint at ${TILES_URL}; run ./02-run-server.sh"

################################################################################
info "1. The flag surface"
################################################################################
note "The new binary offers --signer-kmskey. Note what is NOT here:"
note "no --signer-kmshash, and no --signer-tink-* flags."
echo
"${SERVER_BIN}" serve --help | grep -E '^\s+--signer' || true
echo
note "--signer-kmshash is absent on purpose. Azure Key Vault derives the digest"
note "from the key's own algorithm and ignores any hash passed to it, so the flag"
note "would let you set sha512 and silently still get SHA-256."
pause

################################################################################
info "2. Signer configuration is validated up front"
################################################################################
note "Neither signer flag set:"
"${SERVER_BIN}" serve --storage-dir=/tmp/rekor-azure-demo/scratch1 \
  --hostname="${REKOR_HOSTNAME}" 2>&1 | grep -E 'level=(ERROR|FATAL)' || true
echo
note "Both signer flags set (the gcp binary would silently prefer the file):"
"${SERVER_BIN}" serve --storage-dir=/tmp/rekor-azure-demo/scratch2 \
  --hostname="${REKOR_HOSTNAME}" \
  --signer-filepath="${REPO_ROOT}/tests/testdata/pki/ed25519-priv-key.pem" \
  --signer-kmskey="${KMS_KEY_URI}" 2>&1 | grep -E 'level=(ERROR|FATAL)' || true
pause

################################################################################
info "3. The key really is the one in Key Vault"
################################################################################
note "Public key as Azure reports it:"
az keyvault key show --vault-name "${VAULT_NAME}" -n "${KEY_NAME}" \
  --query 'key.{kty:kty, crv:crv, keyOps:key_ops}' -o json | sed 's/^/    /'
echo
note "Public key downloaded from Key Vault, which the server logged at startup"
note "as 'Loaded signing key':"
# Captured first rather than piped into head: head exiting early would SIGPIPE
# the producer and trip `set -o pipefail`.
PUBKEY_TEXT="$(openssl pkey -pubin -in "${PUBKEY_PEM}" -text -noout)"
printf '%s\n' "${PUBKEY_TEXT}" | head -4 | sed 's/^/    /'
pause

################################################################################
info "4. A signed checkpoint, verified against the Key Vault key"
################################################################################
note "The POSIX driver writes the checkpoint to disk; the static file server"
note "started by 02-run-server.sh publishes it, exactly as nginx does in the"
note "e2e compose file. Raw checkpoint:"
curl -s "${TILES_URL}/checkpoint" | sed 's/^/    | /'
echo
note "Line 1 is the origin, line 2 the tree size, line 3 the root hash,"
note "and the last line is the signature produced by Key Vault."
pause

################################################################################
info "5. Submit an entry and watch the log advance"
################################################################################
note "The demo client verifies each checkpoint signature against the downloaded"
note "public key. Verification fails loudly if the signature isn't from that key."
echo
go run "${REPO_ROOT}/demo/azure-keyvault/client" \
  --url="${SERVER_URL}" \
  --tiles-url="${TILES_URL}" \
  --pubkey="${PUBKEY_PEM}" \
  --origin="${REKOR_HOSTNAME}"
pause

################################################################################
info "6. Storage is still plain POSIX"
################################################################################
note "No Azure storage is involved -- Tessera has no Azure blob driver. Tiles and"
note "checkpoints are ordinary files, which is the point: only the signing key"
note "moved to Azure."
echo
STORAGE_FILES="$(find "${STORAGE_DIR}" -type f)"
printf '%s\n' "${STORAGE_FILES}" | head -10 | sed 's/^/    /'
echo
note "$(printf '%s\n' "${STORAGE_FILES}" | wc -l) files under ${STORAGE_DIR}"

################################################################################
info "Demo complete"
################################################################################
note "Tear down the Azure resources with ./99-teardown.sh"
