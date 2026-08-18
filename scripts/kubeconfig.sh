#!/usr/bin/env bash
# Merge the k3s kubeconfig into ~/.kube/config as the "homelab" context.
# Re-run after every rebuild: new certificates make the old entry stop verifying.
# k3s names its cluster, user and context all "default", so they are renamed
# first or they collide with whatever else is already in the file.
set -euo pipefail

NODE=${1:-10.0.0.16}
VIP=10.0.0.50
NAME=homelab
CONFIG="${HOME}/.kube/config"

mkdir -p "${HOME}/.kube"
tmp=$(mktemp)
trap 'rm -f "$tmp" "$tmp.merged"' EXIT

ssh "ubuntu@${NODE}" "sudo cat /etc/rancher/k3s/k3s.yaml" |
sed -e "s/127.0.0.1/${VIP}/" \
    -e "s/name: default/name: ${NAME}/" \
    -e "s/cluster: default/cluster: ${NAME}/" \
    -e "s/user: default/user: ${NAME}/" \
    -e "s/current-context: default/current-context: ${NAME}/" > "$tmp"

# Prove the fetch before touching the real config; everything below deletes
# the existing entries first, so a silent empty read would leave no kubeconfig.
if ! grep -q '^clusters:' "$tmp"; then
  echo "kubeconfig.sh: ${NODE} did not return a kubeconfig" >&2
  exit 1
fi

if [ -s "$CONFIG" ]; then
  cp "$CONFIG" "${CONFIG}.bak-$(date +%Y%m%d-%H%M%S)"
  # Drop the previous entries first; a merge keeps the existing ones on a
  # name clash, so without this a re-run silently keeps the dead certificate.
  for kind in context cluster user; do
    KUBECONFIG="$CONFIG" kubectl config "delete-${kind}" "$NAME" >/dev/null 2>&1 || true
  done
  KUBECONFIG="${CONFIG}:${tmp}" kubectl config view --flatten > "${tmp}.merged"
  mv "${tmp}.merged" "$CONFIG"
else
  cp "$tmp" "$CONFIG"
fi

chmod 600 "$CONFIG"
kubectl config use-context "$NAME" >/dev/null
kubectl get nodes
