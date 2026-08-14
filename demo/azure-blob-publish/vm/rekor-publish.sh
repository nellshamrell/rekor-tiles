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
# One publish cycle on the VM deployment. Install as
# /usr/local/bin/rekor-publish.sh; run by rekor-publish.service.
#
# Same two phases as ../publish.sh, for the same reason: a checkpoint is a
# signed commitment to a tree of a given size, so the tiles that size implies
# must reach the read path first. Publishing late is harmless. Publishing out of
# order puts a signed promise on the internet that the log cannot honour.
#
# For a large log, replace the uploads below with `azcopy sync`, which transfers
# only what changed instead of re-uploading every tile each cycle. Keep the two
# phases and their order exactly as they are.
#
# NOT exercised by the demo scripts.

set -euo pipefail

STORAGE_DIR="${REKOR_STORAGE_DIR:?REKOR_STORAGE_DIR is required}"
STORAGE_ACCOUNT="${REKOR_STORAGE_ACCOUNT:?REKOR_STORAGE_ACCOUNT is required}"

CACHE_IMMUTABLE="public, max-age=31536000, immutable"
CACHE_PARTIAL="public, max-age=60"

# Azure's static website container is literally named '$web'. Single quotes stop
# the shell expanding it; nothing here is a variable reference.
# shellcheck disable=SC2016
WEB_CONTAINER='$web'

# Phase 1: tiles and entry bundles.
#
# Pointing at the tile/ subtree excludes both the checkpoint and .state/ by
# construction rather than by a filter that could later drift.
#
# Two passes: the first marks everything immutable, the second corrects the
# partial tiles, which are the only mutable files under tile/.
if [[ -d "${STORAGE_DIR}/tile" ]]; then
  for pass in "*:${CACHE_IMMUTABLE}" "*.p/*:${CACHE_PARTIAL}"; do
    az storage blob upload-batch \
      --account-name "${STORAGE_ACCOUNT}" \
      --auth-mode login \
      --destination "${WEB_CONTAINER}" \
      --destination-path tile \
      --source "${STORAGE_DIR}/tile" \
      --pattern "${pass%%:*}" \
      --overwrite \
      --content-cache "${pass#*:}" \
      --no-progress -o none
  done
fi

# Phase 2: the checkpoint, and only once phase 1 has succeeded. `set -e` is what
# enforces that ordering; do not reorder these or merge them.
if [[ -f "${STORAGE_DIR}/checkpoint" ]]; then
  az storage blob upload \
    --account-name "${STORAGE_ACCOUNT}" \
    --auth-mode login \
    --container-name "${WEB_CONTAINER}" \
    --name checkpoint \
    --file "${STORAGE_DIR}/checkpoint" \
    --overwrite \
    --content-cache "no-cache" \
    --content-type "text/plain; charset=utf-8" \
    --no-progress -o none
fi
