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
# Tear down everything the demo created.

set -euo pipefail
# shellcheck source=demo-env.sh
source "$(dirname "${BASH_SOURCE[0]}")/demo-env.sh"

info "Deleting resource group ${RESOURCE_GROUP}"
note "This removes the vault and the key. Runs in the background; it takes a few minutes."
az group delete -n "${RESOURCE_GROUP}" --yes --no-wait -o none || true

# A soft-deleted vault keeps the name reserved, so purge it to allow reuse.
info "Purging the soft-deleted vault"
az keyvault purge -n "${VAULT_NAME}" --no-wait -o none 2>/dev/null || \
  note "nothing to purge (or purge protection is enabled)"

info "Removing local demo state"
rm -rf "${STORAGE_DIR}" /tmp/rekor-azure-demo
rm -f "${PUBKEY_PEM}" "${ENV_FILE}"
rm -f "${SERVER_BIN}"
note "done"

info "Teardown started"
note "Confirm with: az group list -o table"
