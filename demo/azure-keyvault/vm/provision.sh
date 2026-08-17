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
# Build the disk-backed deployment for real: a VM with a managed disk holding
# the log and signing via its own managed identity. nginx serves tiles directly
# from the mounted disk.
#
# Run ../01-setup-azure.sh first -- this reuses its resource group, vault, and
# key. Costs a few cents an hour until ../99-teardown.sh runs,
# which deletes the VM along with everything else in the resource group.
#
#   ./provision.sh          create the VM and start the log
#   ./provision.sh --status show what is running on it

set -euo pipefail
VM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../demo-env.sh
source "${VM_DIR}/../demo-env.sh"

VM_NAME="${VM_NAME:-rekor}"
# Left empty on purpose: which sizes a subscription can actually deploy varies
# by region and by capacity at that moment, and a hardcoded default fails in
# exactly the annoying way -- at deployment, minutes in. Set VM_SIZE to pin one,
# or let pick_vm_sizes discover what this subscription is offered.
VM_SIZE="${VM_SIZE:-}"
VM_IMAGE="${VM_IMAGE:-Ubuntu2404}"
VM_ADMIN="${VM_ADMIN:-azureuser}"
# Premium_LRS rather than the PremiumV2_LRS the README recommends: v2 disks
# require the VM to be pinned to an availability zone, which is a regional
# capacity gamble this script does not need to take. Either is fully POSIX,
# which is the only property that matters here.
DISK_SKU="${DISK_SKU:-Premium_LRS}"
DISK_SIZE_GB="${DISK_SIZE_GB:-128}"

[[ -f "${PUBKEY_PEM}" ]] || fail "${PUBKEY_PEM} not found; run ../01-setup-azure.sh first"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

vm_ip() {
  az vm show -d -g "${RESOURCE_GROUP}" -n "${VM_NAME}" --query publicIps -o tsv 2>/dev/null
}

# pick_vm_sizes lists deployable sizes in LOCATION with 2-8 vCPUs, smallest
# first. The log is not CPU-bound -- the POSIX driver fsyncs every write, so
# storage latency is the limit -- so the smallest thing that boots will do.
pick_vm_sizes() {
  az vm list-skus -l "${LOCATION}" --resource-type virtualMachines \
    --query "[?!not_null(restrictions[?type=='Location'] | [0])].[capabilities[?name=='vCPUs'].value|[0], name]" \
    -o tsv 2>/dev/null | awk '$1 >= 2 && $1 <= 8' | sort -n | cut -f2
}

# create_vm tries the candidate sizes in turn. Capacity restrictions only
# surface at deployment, so trying is the only way to find out.
create_vm() {
  local sizes=("$@") size
  for size in "${sizes[@]}"; do
    note "trying size ${size}"
    if az vm create \
        -g "${RESOURCE_GROUP}" \
        -n "${VM_NAME}" \
        --image "${VM_IMAGE}" \
        --size "${size}" \
        --admin-username "${VM_ADMIN}" \
        --generate-ssh-keys \
        --assign-identity \
        --data-disk-sizes-gb "${DISK_SIZE_GB}" \
        --data-disk-caching None \
        --storage-sku "os=StandardSSD_LRS" "0=${DISK_SKU}" \
        --custom-data "${VM_DIR}/cloud-init.yaml" \
        -o none 2>"${BUILD_DIR}/vmcreate.err"; then
      note "created ${VM_NAME} (${size})"
      return 0
    fi
    if grep -q "SkuNotAvailable\|capacity\|Capacity" "${BUILD_DIR}/vmcreate.err"; then
      note "${size} is unavailable here right now; trying the next one"
      continue
    fi
    sed 's/^/    /' "${BUILD_DIR}/vmcreate.err" >&2
    return 1
  done
  return 1
}

if [[ "${1:-}" == "--status" ]]; then
  IP="$(vm_ip)"
  [[ -n "${IP}" ]] || fail "no VM named ${VM_NAME} in ${RESOURCE_GROUP}"
  # shellcheck disable=SC2029  # remote expansion is intended
  ssh "${SSH_OPTS[@]}" "${VM_ADMIN}@${IP}" \
    'systemctl is-active rekor-server.service nginx; echo; df -h /var/lib/rekor | tail -1'
  exit 0
fi

################################################################################
info "Building the server for linux/amd64"
################################################################################
# The demo builds for the host; this needs a Linux binary regardless of where
# the script runs. CGO stays off so the binary has no libc version dependency
# on the image it lands on.
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "${BUILD_DIR}"' EXIT
(cd "${REPO_ROOT}" && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
  go build -trimpath -o "${BUILD_DIR}/rekor-server-posix-azurekms" ./cmd/rekor-server/posix-azurekms)
note "$(du -h "${BUILD_DIR}/rekor-server-posix-azurekms" | cut -f1)"

################################################################################
info "Creating the VM"
################################################################################
# The data disk is created with the VM rather than attached afterwards, so that
# it exists by the time cloud-init's runcmd looks for it.
#
# The Rekor API binds to localhost; submitters use a private network or SSH
# tunnel. nginx exposes the tile files from the managed disk on port 80.
if az vm show -g "${RESOURCE_GROUP}" -n "${VM_NAME}" -o none 2>/dev/null; then
  note "${VM_NAME} already exists, reusing it"
else
  if [[ -n "${VM_SIZE}" ]]; then
    CANDIDATES=("${VM_SIZE}")
  else
    mapfile -t CANDIDATES < <(pick_vm_sizes | head -4)
    [[ "${#CANDIDATES[@]}" -gt 0 ]] || fail "no 2-8 vCPU VM sizes are offered in ${LOCATION}; set VM_SIZE or LOCATION"
  fi
  create_vm "${CANDIDATES[@]}" || fail "could not create the VM; see the error above"
fi

IP="$(vm_ip)"
[[ -n "${IP}" ]] || fail "could not determine the VM's public IP"
note "public IP: ${IP}"
az vm open-port -g "${RESOURCE_GROUP}" -n "${VM_NAME}" --port 80 --priority 1010 -o none

################################################################################
info "Granting the VM's managed identity its roles"
################################################################################
# This is the payoff of running on Azure: the VM signs with Key Vault as itself.
# No credential is stored anywhere on the machine.
VM_PRINCIPAL="$(az vm identity show -g "${RESOURCE_GROUP}" -n "${VM_NAME}" --query principalId -o tsv)"
VAULT_SCOPE="$(az keyvault show -n "${VAULT_NAME}" --query id -o tsv)"

ROLES_ADDED=0
if [[ -n "$(az role assignment list --assignee "${VM_PRINCIPAL}" --scope "${VAULT_SCOPE}" \
    --role "Key Vault Crypto User" --query "[0].id" -o tsv 2>/dev/null)" ]]; then
  note "already assigned: Key Vault Crypto User"
else
  note "assigning: Key Vault Crypto User"
  az role assignment create --role "Key Vault Crypto User" \
    --assignee-object-id "${VM_PRINCIPAL}" \
    --assignee-principal-type ServicePrincipal --scope "${VAULT_SCOPE}" -o none
  ROLES_ADDED=1
fi

################################################################################
info "Waiting for cloud-init to finish"
################################################################################
note "It formats the log disk and configures nginx; allow a few minutes."
# `cloud-init status --wait` blocks until the run completes and exits non-zero
# if it failed, which is a far better signal than sleeping and hoping.
ssh "${SSH_OPTS[@]}" -o ConnectTimeout=10 -o ConnectionAttempts=30 \
  "${VM_ADMIN}@${IP}" 'sudo cloud-init status --wait' \
  || fail "cloud-init failed; inspect /var/log/cloud-init-output.log on ${IP}"

################################################################################
info "Uploading the binary and units"
################################################################################
STAGE="${BUILD_DIR}/stage"
mkdir -p "${STAGE}"
cp "${BUILD_DIR}/rekor-server-posix-azurekms" "${STAGE}/"

# The units ship with placeholders rather than a config file the reader has to
# go and find. Fill them in here.
sed -e "s|VAULT_NAME|${VAULT_NAME}|" \
    -e "s|KEY_NAME|${KEY_NAME}|" \
    -e "s|rekor.example.com|${REKOR_HOSTNAME}|" \
    "${VM_DIR}/rekor-server.service" >"${STAGE}/rekor-server.service"

scp "${SSH_OPTS[@]}" -q "${STAGE}"/* "${VM_ADMIN}@${IP}:/tmp/"

ssh "${SSH_OPTS[@]}" "${VM_ADMIN}@${IP}" 'sudo bash -euo pipefail -s' <<'REMOTE'
install -m 0755 -o root -g root /tmp/rekor-server-posix-azurekms /usr/local/bin/
install -m 0644 -o root -g root /tmp/rekor-server.service /etc/systemd/system/
rm -f /tmp/rekor-server-posix-azurekms /tmp/rekor-server.service
systemctl daemon-reload
systemctl enable --now rekor-server.service
REMOTE

################################################################################
info "Checking the log came up"
################################################################################
if [[ "${ROLES_ADDED}" == "1" ]]; then
  note "RBAC was just granted; allowing time for it to propagate."
  sleep 45
  ssh "${SSH_OPTS[@]}" "${VM_ADMIN}@${IP}" 'sudo systemctl restart rekor-server.service' || true
fi
sleep 20

ssh "${SSH_OPTS[@]}" "${VM_ADMIN}@${IP}" \
  'systemctl is-active rekor-server.service nginx && curl -fsS http://localhost/checkpoint >/dev/null && sudo journalctl -u rekor-server.service -n 5 --no-pager' \
  || fail "rekor-server.service is not running; ssh in and check journalctl -u rekor-server"

info "Provisioned"
note "VM:        ${VM_ADMIN}@${IP}"
note "read path: http://${IP}"
note "API tunnel: ssh -L 3000:localhost:3000 ${VM_ADMIN}@${IP}"
note "status:    ./provision.sh --status"
note "teardown:  ../99-teardown.sh (deletes the whole resource group)"
