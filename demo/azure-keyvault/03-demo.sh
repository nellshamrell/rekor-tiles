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
info "1. The Azure-specific signer surface"
################################################################################
note "The binary offers --signer-kmskey. It deliberately has no"
note "--signer-kmshash or --signer-tink-* flags."
echo
"${SERVER_BIN}" serve --help | grep -E '^\s+--signer' || true
pause

################################################################################
info "2. Signer configuration is validated up front"
################################################################################
note "Neither signer flag set:"
"${SERVER_BIN}" serve --storage-dir=/tmp/rekor-azure-demo/scratch1 \
  --hostname="${REKOR_HOSTNAME}" 2>&1 | grep -E 'level=(ERROR|FATAL)' || true
echo
note "Both signer flags set:"
"${SERVER_BIN}" serve --storage-dir=/tmp/rekor-azure-demo/scratch2 \
  --hostname="${REKOR_HOSTNAME}" \
  --signer-filepath="${REPO_ROOT}/tests/testdata/pki/ed25519-priv-key.pem" \
  --signer-kmskey="${KMS_KEY_URI}" 2>&1 | grep -E 'level=(ERROR|FATAL)' || true
pause

################################################################################
info "3. The key really is the one in Key Vault"
################################################################################
az keyvault key show --vault-name "${VAULT_NAME}" -n "${KEY_NAME}" \
  --query 'key.{kty:kty, crv:crv, keyOps:keyOps}' -o json | sed 's/^/    /'
echo
PUBKEY_TEXT="$(openssl pkey -pubin -in "${PUBKEY_PEM}" -text -noout)"
printf '%s\n' "${PUBKEY_TEXT}" | sed -n '1,4s/^/    /p'
pause

################################################################################
info "4. The storage filesystem satisfies Tessera's POSIX requirements"
################################################################################
go run "${REPO_ROOT}/demo/azure-keyvault/fscheck" --dir="${STORAGE_DIR}" | sed 's/^/    /'
echo
note "The local run models the ext4 filesystem placed on an Azure managed disk"
note "by vm/provision.sh. Azure Files SMB and blobfuse2 are not substitutes."
pause

################################################################################
info "5. Submit an entry and verify the Key Vault-signed checkpoint"
################################################################################
go run "${REPO_ROOT}/demo/azure-keyvault/client" \
  --url="${SERVER_URL}" \
  --tiles-url="${TILES_URL}" \
  --pubkey="${PUBKEY_PEM}" \
  --origin="${REKOR_HOSTNAME}"
pause

################################################################################
info "6. Tiles remain on the POSIX filesystem"
################################################################################
note "The static HTTP server reads these files directly; there is no mirror."
STORAGE_FILES="$(find "${STORAGE_DIR}" -type f)"
printf '%s\n' "${STORAGE_FILES}" | sed -n '1,12s/^/    /p'
echo
note "In the VM deployment this directory is /var/lib/rekor/log on an Azure"
note "managed disk, and nginx serves the same files from that mount."

################################################################################
info "Demo complete"
################################################################################
note "Deploy the managed-disk shape with ./vm/provision.sh."
note "Tear down Azure resources with ./99-teardown.sh."
