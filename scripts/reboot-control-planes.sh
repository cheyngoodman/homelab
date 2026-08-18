#!/usr/bin/env bash
# Reboot the k3s control planes one at a time for pending kernel updates.
# kured does the workers and never touches these (infra/controllers/kured.yaml).
#
# Waits on boot_id, not NotReady. A node stays Ready for seconds after
# `systemctl reboot` returns, so polling NotReady falls through and the next
# control plane goes down while the first is still shutting down.
#
# Stops at the first node it cannot confirm.
#
#   bash scripts/reboot-control-planes.sh [-y]
set -euo pipefail

SSH_USER=${SSH_USER:-ubuntu}
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=6 -o StrictHostKeyChecking=accept-new)
DOWN_TIMEOUT=${DOWN_TIMEOUT:-300}
READY_TIMEOUT=${READY_TIMEOUT:-300}

die() { echo "reboot-control-planes: $*" >&2; exit 1; }
ssh_to() { ssh "${SSH_OPTS[@]}" "${SSH_USER}@${1}" "${2}"; }

command -v kubectl >/dev/null || die "kubectl not found"

echo "== preflight"
not_ready=$(kubectl get nodes --no-headers | awk '$2!="Ready"{print $1}')
[ -z "$not_ready" ] || die "not every node is Ready, refusing to start: $not_ready"
echo "all nodes Ready"

# VIP holder last: rebooting it moves 10.0.0.50, which kubectl points at.
vip=$(kubectl -n kube-system get lease plndr-cp-lock \
  -o jsonpath='{.spec.holderIdentity}' 2>/dev/null || true)
echo "API VIP holder: ${vip:-unknown}"

mapfile -t cps < <(kubectl get nodes -l node-role.kubernetes.io/control-plane=true \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}')
[ "${#cps[@]}" -gt 0 ] || die "found no control-plane nodes"

ordered=()
for e in "${cps[@]}"; do
  if [ "${e%% *}" != "$vip" ]; then ordered+=("$e"); fi
done
for e in "${cps[@]}"; do
  if [ "${e%% *}" = "$vip" ]; then ordered+=("$e"); fi
done

echo
echo "== who needs a reboot"
pending=()
for e in "${ordered[@]}"; do
  name=${e%% *}; ip=${e##* }
  if ssh_to "$ip" 'test -e /var/run/reboot-required'; then
    pending+=("$e"); echo "  $name ($ip) pending"
  else
    echo "  $name ($ip) clear, skipping"
  fi
done

[ "${#pending[@]}" -gt 0 ] || { echo; echo "nothing to do."; exit 0; }

echo
echo "will reboot ${#pending[@]} control plane(s), one at a time, in this order:"
for e in "${pending[@]}"; do echo "  ${e%% *}"; done
if [ "${1:-}" != "-y" ]; then
  read -r -p "proceed? [y/N] " reply
  [ "$reply" = "y" ] || [ "$reply" = "Y" ] || { echo "aborted."; exit 1; }
fi

echo
echo "== etcd snapshot"
ssh_to "${ordered[0]##* }" "sudo k3s etcd-snapshot save --name pre-reboot" >/dev/null
echo "saved"

for e in "${pending[@]}"; do
  name=${e%% *}; ip=${e##* }
  echo
  echo "== $name ($ip)"

  before=$(ssh_to "$ip" 'cat /proc/sys/kernel/random/boot_id')

  # Connection dies with the machine; non-zero is expected.
  ssh_to "$ip" 'sudo systemctl reboot' >/dev/null 2>&1 || true
  echo "reboot issued, waiting for a new boot_id"

  deadline=$((SECONDS + DOWN_TIMEOUT))
  while :; do
    if now=$(ssh_to "$ip" 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null); then
      if [ "$now" != "$before" ]; then break; fi
    fi
    [ "$SECONDS" -lt "$deadline" ] || die "$name did not come back in ${DOWN_TIMEOUT}s. Stopping; console at https://10.0.0.11/"
    sleep 5
  done

  # Ask the node, not the API. These reboot in under 10s, well inside the ~40s
  # kubelet lease, so the Node object never leaves Ready and checking it first
  # would pass on a stale status even if k3s came back broken.
  echo "booted, waiting for k3s on the node"
  deadline=$((SECONDS + READY_TIMEOUT))
  while :; do
    if [ "$(ssh_to "$ip" 'sudo k3s kubectl get --raw /readyz' 2>/dev/null)" = "ok" ]; then break; fi
    [ "$SECONDS" -lt "$deadline" ] || die "$name booted but k3s is not ready after ${READY_TIMEOUT}s. Stopping."
    sleep 5
  done

  echo "waiting for Ready"
  deadline=$((SECONDS + READY_TIMEOUT))
  while :; do
    state=$(kubectl get node "$name" --no-headers 2>/dev/null | awk '{print $2}' || true)
    if [ "$state" = "Ready" ]; then break; fi
    [ "$SECONDS" -lt "$deadline" ] || die "$name booted but reads '$state' after ${READY_TIMEOUT}s. Stopping."
    sleep 5
  done

  bad=$(kubectl get nodes -l node-role.kubernetes.io/etcd=true --no-headers | awk '$2!="Ready"{print $1}')
  [ -z "$bad" ] || die "etcd members not Ready after $name: $bad. Stopping."

  if ssh_to "$ip" 'test -e /var/run/reboot-required'; then
    echo "$name Ready, but still reports a pending reboot"
  else
    echo "$name Ready, etcd healthy, flag cleared"
  fi
done

echo
echo "== done"
kubectl get nodes -l node-role.kubernetes.io/etcd=true
