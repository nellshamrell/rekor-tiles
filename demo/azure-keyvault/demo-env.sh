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

# Shared configuration for the Azure Key Vault demo.
# Source this file, or let the numbered scripts source it for you.

# Vault names must be globally unique across Azure, so a suffix is generated
# once and cached in .demo-env next to these scripts.
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

export RESOURCE_GROUP="${RESOURCE_GROUP:-rekor-azure-demo}"
export LOCATION="${LOCATION:-eastus}"
export VAULT_NAME="${VAULT_NAME:-rekor-demo-${DEMO_SUFFIX}}"
export KEY_NAME="${KEY_NAME:-rekor-checkpoint-key}"

# The log's origin string. This is baked into every checkpoint and into the
# key hash, so the server and the verifier must agree on it.
export REKOR_HOSTNAME="${REKOR_HOSTNAME:-rekor-azure-demo}"

export STORAGE_DIR="${STORAGE_DIR:-/tmp/rekor-azure-demo/storage}"

# The write path: the rekor server's own HTTP API.
export SERVER_URL="${SERVER_URL:-http://localhost:3000}"

# The read path. With the POSIX driver the server writes tiles and checkpoints
# to the filesystem and does not serve them itself, so a static file server
# publishes STORAGE_DIR. The e2e suite does the same thing with nginx in
# posix-compose.yml; this demo uses python3's http.server to keep it dependency
# free.
export TILES_URL="${TILES_URL:-http://localhost:8000}"
export TILES_PORT="${TILES_PORT:-8000}"

export KMS_KEY_URI="azurekms://${VAULT_NAME}.vault.azure.net/${KEY_NAME}"
export PUBKEY_PEM="${PUBKEY_PEM:-${DEMO_DIR}/.demo-pubkey.pem}"

# Repository root, so the scripts work regardless of where they're invoked from.
REPO_ROOT="$(cd "${DEMO_DIR}/../.." && pwd)"
export REPO_ROOT
export SERVER_BIN="${REPO_ROOT}/rekor-server-posix-azurekms"

info()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
note()  { printf '    %s\n' "$*"; }
fail()  { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
