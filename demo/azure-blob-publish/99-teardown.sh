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

# Delete the vault first and wait for it. `az group delete --no-wait` would
# return before the vault is gone, and the purge below would then have nothing
# to purge -- leaving a soft-deleted vault holding the name.
info "Deleting the Key Vault"
if az keyvault show -n "${VAULT_NAME}" -o none 2>/dev/null; then
  az keyvault delete -n "${VAULT_NAME}" -g "${RESOURCE_GROUP}" -o none
  note "deleted (soft-delete keeps it recoverable for 90 days)"
else
  note "${VAULT_NAME} not found, skipping"
fi

# A soft-deleted vault keeps the name reserved and still bills nothing, but
# purging keeps the subscription tidy and frees the name.
info "Purging the soft-deleted vault"
az keyvault purge -n "${VAULT_NAME}" -o none 2>/dev/null || \
  note "nothing to purge (or purge protection is enabled)"

# The storage account goes with the resource group, but delete it explicitly
# first so the published log stops being served promptly rather than whenever
# the group deletion gets to it.
info "Deleting the storage account"
if az storage account show -n "${STORAGE_ACCOUNT}" -g "${RESOURCE_GROUP}" -o none 2>/dev/null; then
  az storage account delete -n "${STORAGE_ACCOUNT}" -g "${RESOURCE_GROUP}" --yes -o none
  note "deleted ${STORAGE_ACCOUNT}"
else
  note "${STORAGE_ACCOUNT} not found, skipping"
fi

info "Deleting resource group ${RESOURCE_GROUP}"
note "Runs in the background; it takes a few minutes."
az group delete -n "${RESOURCE_GROUP}" --yes --no-wait -o none || true

info "Removing local demo state"
rm -rf "${STORAGE_DIR}" /tmp/rekor-azure-blob-demo
rm -f "${PUBKEY_PEM}" "${ENV_FILE}" "${WEB_URL_FILE}" "${PAUSE_FILE}" "${DEMO_DIR}/.publish.log"
rm -f "${SERVER_BIN}"
note "done"

info "Teardown started"
note "Confirm with: az group list -o table"
