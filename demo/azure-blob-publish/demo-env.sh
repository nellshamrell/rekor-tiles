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

# Shared configuration for the Azure Blob publishing demo.
# Source this file, or let the numbered scripts source it for you.

# Vault and storage account names must be globally unique across Azure, so a
# suffix is generated once and cached in .demo-env next to these scripts.
DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${DEMO_DIR}/.demo-env"

if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
else
  # Deliberately not a `tr ... | head -c` pipeline: head exiting early sends
  # SIGPIPE to tr, which trips the callers' `set -o pipefail`.
  DEMO_SUFFIX="$(od -An -tx1 -N3 /dev/urandom | tr -d ' \n')"
  echo "DEMO_SUFFIX=${DEMO_SUFFIX}" >"${ENV_FILE}"
fi

export RESOURCE_GROUP="${RESOURCE_GROUP:-rekor-azure-blob-demo}"
export LOCATION="${LOCATION:-eastus}"

# Key Vault signs the checkpoints, exactly as in ../azure-keyvault.
export VAULT_NAME="${VAULT_NAME:-rekor-blob-${DEMO_SUFFIX}}"
export KEY_NAME="${KEY_NAME:-rekor-checkpoint-key}"
export KMS_KEY_URI="azurekms://${VAULT_NAME}.vault.azure.net/${KEY_NAME}"

# Storage account names are 3-24 characters, lowercase letters and digits only.
export STORAGE_ACCOUNT="${STORAGE_ACCOUNT:-rekorblob${DEMO_SUFFIX}}"

# Azure's static website container is literally named '$web'. Single quotes stop
# the shell expanding it; nothing here is a variable reference.
# shellcheck disable=SC2016
export WEB_CONTAINER='$web'

# The log's origin string. This is baked into every checkpoint and into the key
# hash, so the server and the verifier must agree on it. In a real deployment
# this would be the public read hostname (the CDN in front of Blob), not the
# machine running the server.
export REKOR_HOSTNAME="${REKOR_HOSTNAME:-rekor-azure-blob-demo}"

# The log lives on a local POSIX filesystem. On the deployment this demo models
# that is an ext4 volume on an Azure managed disk; here it is whatever backs
# /tmp, which 02-run-server.sh verifies with fscheck before starting.
export STORAGE_DIR="${STORAGE_DIR:-/tmp/rekor-azure-blob-demo/storage}"

# The write path: the rekor server's own API, reachable only by submitters.
export SERVER_URL="${SERVER_URL:-http://localhost:3000}"

# The read path: the Blob static website endpoint, discovered at setup time and
# cached here because it embeds an unpredictable zone number
# (https://<account>.z##.web.core.windows.net/).
export WEB_URL_FILE="${DEMO_DIR}/.demo-web-url"
if [[ -f "${WEB_URL_FILE}" ]]; then
  TILES_URL="$(cat "${WEB_URL_FILE}")"
  export TILES_URL
fi

# How often the publisher mirrors the log into Blob. Publishing late is always
# safe -- clients simply see an older tree -- so this is a freshness knob, not a
# correctness one. Correctness comes from the ordering inside publish.sh.
export PUBLISH_INTERVAL="${PUBLISH_INTERVAL:-5}"

# Touched by 03-demo.sh to hold the publish loop still while it demonstrates
# what happens when a checkpoint outruns its tiles.
export PAUSE_FILE="${DEMO_DIR}/.publish-paused"

export PUBKEY_PEM="${PUBKEY_PEM:-${DEMO_DIR}/.demo-pubkey.pem}"

# Repository root, so the scripts work regardless of where they're invoked from.
REPO_ROOT="$(cd "${DEMO_DIR}/../.." && pwd)"
export REPO_ROOT
export SERVER_BIN="${REPO_ROOT}/rekor-server-posix-azurekms"

info()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
note()  { printf '    %s\n' "$*"; }
fail()  { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# require_web_url exits unless the static website endpoint has been discovered.
require_web_url() {
  [[ -n "${TILES_URL:-}" ]] || fail "static website endpoint unknown; run ./01-setup-azure.sh first"
}
