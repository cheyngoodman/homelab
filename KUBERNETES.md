# Kubernetes

Six node `k3s` cluster with `etcd`.

## Kubeconfig

### kubectl

Get the `root` owned `k3s.yaml` config from the lab cluster and configure it as `~/.kube/config` for this system.

```bash
bash scripts/kubeconfig.sh
```

Writes the `homelab` context into `~/.kube/config` and selects it, so plain `kubectl` works against this cluster.

### Over SSH

A configured `kubectl` also exists on each of the nodes. If there's an issue with local `kubectl`, try the remote node.

```bash
ssh ubuntu@10.0.0.16 "sudo k3s kubectl get nodes"
```

## Storage

Pick storage by what the workload cannot afford to lose.

| Workload | Ask for | Survives |
|---|---|---|
| Database | `longhorn` | Worker loss |
| Shared files | Static NFS PV | Cluster loss |
| Scratch | `local-path`, the default | Node reboot |

Longhorn gives the pod ordinary ext4, which is what lets a database keep SQLite and still move between workers. It replicates onto the workers' own disks, so it survives losing a worker and does not survive `tofu destroy`. Anything that has to outlive the cluster takes the static NFS PV instead, and pays for it: SQLite over NFS holds together only while a single writer is enforced.

`longhorn-static` is created by the chart, not by this codebase. It exists for volumes made outside the provisioner and nothing here asks for it.

### Storage Classes

Verify the classes a workload can ask for.

```bash
kubectl get storageclass
```

<details>
<summary>Output</summary>

`longhorn` and `local-path` are both present.
```
NAME                   PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION   AGE
local-path (default)   rancher.io/local-path   Delete          WaitForFirstConsumer   false                  66m
longhorn               driver.longhorn.io      Delete          Immediate              true                   61m
longhorn-static        driver.longhorn.io      Delete          Immediate              true                   61m
```

</details>

## Flux

Everything above bare k3s is reconciled from this codebase. Nothing under these directories is ever applied by hand; Flux reverts drift, and `prune: true` means a file deleted from git is deleted from the cluster.

| Path | Kustomization | Holds |
|---|---|---|
| `clusters/homelab/` | the entry point | the Kustomizations below, and nothing else |
| `infra/controllers/` | `infra-controllers` | MetalLB, cert-manager, csi-driver-nfs, Tailscale, kube-vip, kured, Longhorn |
| `infra/configs/` | `infra-configs` | the address pool, the Traefik override, the subnet router |
| `infra/tls/` | `infra-tls` | the ACME issuers and the wildcard certificate |
| `apps/` | `apps` | whoami and Hermes |

### Apply Order

Controllers first, because a config is a custom resource and its CRD has to exist before the manifest naming it is valid. `infra-configs` and `infra-tls` both depend on `infra-controllers`, and `apps` depends on `infra-configs`.

`apps` deliberately does not depend on `infra-tls`. An application needs ingress to serve, not a certificate; waiting on one would hold every app down for the several minutes an ACME issuance takes, on every rebuild.

`infra-tls` is the one Kustomization with `wait: false`. A Certificate reports Ready only once Let's Encrypt has actually issued, which is minutes away at best and never at all if the Cloudflare token is missing or the weekly limit is spent. Waiting on it would put a permanent NotReady in a cluster whose only real symptom is a browser warning, so it is applied and left to settle on its own.

### Why MetalLB

k3s ships servicelb, and cloud-init disables it. servicelb binds the service port on every node, so "the address of the ingress" is whichever node you happened to ask. The EdgeRouter forwards `*.lab.cheyn.net` to exactly one address ([NETWORK.md](NETWORK.md#dns-forwarding)), so the cluster has to be able to hold one.

MetalLB in L2 mode does that: one node answers ARP for `10.0.0.51`, and another takes over if it dies. The FRR-K8s BGP machinery is disabled in the HelmRelease, because BGP needs a router speaking it and this is a flat `/24` behind an EdgeRouter that is not.

### Why DNS-01

Nothing here is reachable from the internet, which rules out HTTP-01: the ACME server cannot fetch a challenge file it cannot route to. DNS-01 proves control of the zone instead, by writing a TXT record through the Cloudflare API. That is the only reason Cloudflare hosts the zone at all; no record under `lab.cheyn.net` is ever published.

cert-manager checks propagation before asking Let's Encrypt to validate, and by default it asks the cluster's own resolver. That is the EdgeRouter, which answers for `lab.cheyn.net` out of its wildcard forwarding line and knows nothing about a TXT record in Cloudflare, so the self-check waits for a record it will never be shown. The `--dns01-recursive-nameservers` flags in [`infra/controllers/cert-manager.yaml`](infra/controllers/cert-manager.yaml) point it at public resolvers, which ask the real authority.

A staging issuer is kept and referenced by nothing. Let's Encrypt allows five identical certificates per week, counted per name set, and a rebuild spends one against each set this cluster asks for. Issuance is debugged against staging, whose limits are far looser, without spending that budget.

### Deploy Key

Flux clones over SSH with a read-only deploy key that `tofu` generates and registers on GitHub. Nothing to paste.

Needs a token with `repo` scope, which an authenticated `gh` already has. Pass it as an environment variable so it never lands in a file:

```bash
export TF_VAR_github_token="$(gh auth token)"
```

`terraform.tfvars` works too, but it is the one file OpenTofu quotes back verbatim when it fails to parse, which puts the token on screen.

Which repository it targets is named in three places, and a fork changes all three: `github_owner` and `github_repository` in `variables.tf`, and the FluxInstance `url` in `files/cp-cloud-config.yml`. Leave them and tofu registers a deploy key against a repository it cannot write to, then Flux sits NotReady cloning one it cannot read.

An initialize creates the key, a destroy removes it from GitHub, and a rebuild rotates it.

```bash
gh api repos/{owner}/{repo}/keys --jq '.[] | "\(.id) \(.title)"'
```

<details>
<summary>Output</summary>

Only `flux-homelab` should be listed.
```
159867492 flux-homelab
```

</details>

### Bootstrap

Cloud-init writes the Secrets into `/var/lib/rancher/k3s/server/manifests/` alongside the flux-operator and FluxInstance manifests, and k3s applies whatever lands there. There is no `kubectl create secret` step anywhere, and adding one would be a defect: it would not survive the next rebuild.

Four Secrets arrive this way. An empty variable is skipped rather than failing, so a partial `terraform.tfvars` still builds a cluster and nothing shouts:

- No Cloudflare token leaves the certificate `Pending` behind a self-signed fallback
- No Tailscale OAuth client holds `infra-controllers` NotReady, taking `infra-configs`, `infra-tls` and `apps` with it

The k3s join token and three of the four `hermes` values need no variable; `random_password` generates them at apply time. GitHub's host keys are fetched at apply time rather than pinned, because a pinned copy becomes a silent clone failure the day GitHub rotates them.

Applying only rewrites snippets. The plan must read three `cp_cloud_config` replacements and zero VM changes; the Secrets reach a node at its next rebuild.

#### Verification

```bash
kubectl get secret -A --no-headers | awk '$2=="flux-system"||$2=="cloudflare-api-token"||$2=="operator-oauth"||$2=="hermes"{print $1, $2, $4}'
```

<details>
<summary>Output</summary>

```
cert-manager cloudflare-api-token 1
flux-system flux-system 2
hermes hermes 4
tailscale operator-oauth 2
```

</details>

### Hello World!

Confirm the cluster is up by verifying the `whoami` service.

https://whoami.lab.cheyn.net
