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
# Step 1: create the Azure infrastructure and build the server binary.
#
# Two independent pieces of Azure are involved, and keeping them straight is
# the point of the whole demo:
#
#   Key Vault       signs checkpoints (the write path)
#   Blob Storage    serves tiles and checkpoints to clients (the read path)
#
# The log itself lives on neither. It lives on a POSIX filesystem, which in a
# real deployment is an ext4 volume on an Azure managed disk.

set -euo pipefail
# shellcheck source=demo-env.sh
source "$(dirname "${BASH_SOURCE[0]}")/demo-env.sh"

command -v az >/dev/null || fail "the Azure CLI (az) is required: https://learn.microsoft.com/cli/azure/install-azure-cli"
az account show >/dev/null 2>&1 || fail "not logged in to Azure; run 'az login' first"

info "Using subscription: $(az account show --query name -o tsv)"
note "resource group:  ${RESOURCE_GROUP}"
note "vault:           ${VAULT_NAME}"
note "storage account: ${STORAGE_ACCOUNT}"

info "Creating resource group"
az group create -n "${RESOURCE_GROUP}" -l "${LOCATION}" -o none

################################################################################
# The signing side: Key Vault.
################################################################################

info "Creating Key Vault (RBAC authorization)"
# Skipped when the vault already exists, so this script can be re-run after an
# interruption without starting over.
if az keyvault show -n "${VAULT_NAME}" -g "${RESOURCE_GROUP}" -o none 2>/dev/null; then
  note "${VAULT_NAME} already exists, reusing it"
else
  az keyvault create \
    -n "${VAULT_NAME}" \
    -g "${RESOURCE_GROUP}" \
    -l "${LOCATION}" \
    --enable-rbac-authorization true \
    -o none
fi

################################################################################
# The publishing side: a storage account with static website hosting.
################################################################################

info "Creating the storage account"
# Static website hosting is used rather than a container with anonymous read
# access, because many subscriptions disable anonymous blob access at the
# account level (allowBlobPublicAccess=false) while still permitting the static
# website endpoint. It also matches the shape of a real deployment, where a CDN
# or Front Door sits in front of this endpoint.
if az storage account show -n "${STORAGE_ACCOUNT}" -g "${RESOURCE_GROUP}" -o none 2>/dev/null; then
  note "${STORAGE_ACCOUNT} already exists, reusing it"
else
  az storage account create \
    -n "${STORAGE_ACCOUNT}" \
    -g "${RESOURCE_GROUP}" \
    -l "${LOCATION}" \
    --sku Standard_LRS \
    --kind StorageV2 \
    --min-tls-version TLS1_2 \
    -o none
fi

################################################################################
# Roles. The demo identity needs to sign with the key and write to the blobs.
################################################################################

info "Granting this identity the roles it needs"
# Key Vault Crypto Officer -- lets THIS script create and download the key.
# Key Vault Crypto User    -- read the public key and sign. This is the only
#                             vault role a production rekor identity needs.
# Storage Blob Data Contributor -- lets the publisher write tiles into $web.
#
# On the VM deployment these three are attached to the VM's managed identity
# instead, and nothing holds a credential on disk.
PRINCIPAL_ID="$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)"
if [[ -z "${PRINCIPAL_ID}" ]]; then
  PRINCIPAL_ID="$(az account show --query user.name -o tsv)"
fi
VAULT_SCOPE="$(az keyvault show -n "${VAULT_NAME}" --query id -o tsv)"
ACCOUNT_SCOPE="$(az storage account show -n "${STORAGE_ACCOUNT}" -g "${RESOURCE_GROUP}" --query id -o tsv)"

ROLES_ADDED=0
assign_role() {
  local role="$1" scope="$2"
  if [[ -n "$(az role assignment list --assignee "${PRINCIPAL_ID}" --scope "${scope}" \
      --role "${role}" --query "[0].id" -o tsv 2>/dev/null)" ]]; then
    note "already assigned: ${role}"
    return
  fi
  note "assigning: ${role}"
  az role assignment create --role "${role}" --assignee "${PRINCIPAL_ID}" --scope "${scope}" -o none
  ROLES_ADDED=1
}

assign_role "Key Vault Crypto Officer" "${VAULT_SCOPE}"
assign_role "Key Vault Crypto User" "${VAULT_SCOPE}"
assign_role "Storage Blob Data Contributor" "${ACCOUNT_SCOPE}"

# Only wait when something actually changed.
if [[ "${ROLES_ADDED}" == "1" ]]; then
  note "RBAC changes take up to a minute to propagate; waiting before using them."
  sleep 45
fi

info "Enabling static website hosting"
# Set Blob Service Properties over AAD needs control-plane rights on the
# account, which the account's creator has. Where it doesn't (a scoped-down CI
# principal, say), fall back to the account key, which az resolves via ARM.
if ! az storage blob service-properties update \
    --account-name "${STORAGE_ACCOUNT}" \
    --auth-mode login \
    --static-website true \
    --index-document index.html \
    --404-document index.html \
    -o none 2>/dev/null; then
  note "AAD auth was refused for service properties; retrying with the account key"
  az storage blob service-properties update \
    --account-name "${STORAGE_ACCOUNT}" \
    --static-website true \
    --index-document index.html \
    --404-document index.html \
    -o none
fi

# The web endpoint embeds an unpredictable zone number, so discover it rather
# than constructing it, and cache it for the other scripts.
WEB_URL="$(az storage account show -n "${STORAGE_ACCOUNT}" -g "${RESOURCE_GROUP}" \
  --query 'primaryEndpoints.web' -o tsv)"
WEB_URL="${WEB_URL%/}"
echo "${WEB_URL}" >"${WEB_URL_FILE}"
note "read path: ${WEB_URL}"

################################################################################
# The checkpoint signing key.
################################################################################

info "Creating the checkpoint signing key (EC P-256)"
# Azure Key Vault offers EC and RSA keys, but NOT Ed25519. That's fine for
# checkpoint signing, but it does mean this log cannot be witnessed --
# Ed25519 is the only key type compatible with witnessing. See pkg/note/note.go.
#
# Reused if it already exists: creating again would mint a new key version and
# invalidate the public key downloaded by an earlier run.
if az keyvault key show --vault-name "${VAULT_NAME}" -n "${KEY_NAME}" -o none 2>/dev/null; then
  note "${KEY_NAME} already exists, reusing it"
else
  az keyvault key create \
    --vault-name "${VAULT_NAME}" \
    -n "${KEY_NAME}" \
    --kty EC \
    --curve P-256 \
    --ops sign verify \
    -o none
fi

info "Downloading the public key for independent verification"
rm -f "${PUBKEY_PEM}"
az keyvault key download \
  --vault-name "${VAULT_NAME}" \
  -n "${KEY_NAME}" \
  -e PEM \
  -f "${PUBKEY_PEM}"
note "wrote ${PUBKEY_PEM}"

info "Building rekor-server-posix-azurekms"
make -C "${REPO_ROOT}" rekor-server-posix-azurekms

info "Setup complete"
note "Key URI:   ${KMS_KEY_URI}"
note "Read path: ${WEB_URL}"
note "Next:      ./02-run-server.sh"
