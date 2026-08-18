# Agent Context

OpenTofu-managed Proxmox cluster running k3s, platform reconciled by Flux. Read this first: current state, rules, and the process every change follows. The system and why: [NETWORK.md](NETWORK.md), [PROXMOX.md](PROXMOX.md), [KUBERNETES.md](KUBERNETES.md), [HERMES.md](HERMES.md). Operations: [README.md](README.md).

## Validate

Everything checkable without touching the cluster, from the codebase root. Run it before opening a PR. CI repeats all of it and adds `cloud-init schema` and kubeconform; CI is the net, not the first try.

```bash
tofu init -backend=false -input=false && tofu fmt -recursive . && tofu validate && (cd tests/render && tofu init -backend=false -input=false && tofu apply -auto-approve)
```

Rendering proves a template parses. It does not prove the output is valid YAML, which is the claim that catches a rendered value landing at the wrong indentation:

```bash
cd tests/render && for o in rendered_cp_first rendered_cp_first_no_secrets rendered_cp_join rendered_worker; do tofu output -raw $o | python -c "import sys,yaml; yaml.safe_load(sys.stdin.read()); print('$o ok')"; done
```

Four `ok` lines. This is the subset of the CI check that fails when a `${...}` or `%{...}` gets into a comment, where it is a live directive rather than documentation.

Nothing here contacts Proxmox, GitHub or the cluster. There is no offline check for `infra/`, `clusters/` or `apps/`; those are rendered against the live cluster with `flux diff` ([Ship a Change](#ship-a-change)).

## State

| | |
|---|---|
| Nodes | 6 x k3s v1.36.3+k3s1 on Ubuntu 26.04 LTS, all Ready |
| Control plane | cp-1 `.16`/pve1, cp-2 `.17`/pve2, cp-3 `.18`/pve3; all etcd, tainted NoSchedule |
| Workers | wkr-1 `.32`/pve1, wkr-2 `.33`/pve2, wkr-3 `.34`/pve3 |
| Platform | Flux v2.9.4 (flux-operator, self-seeded from cloud-init) syncing `clusters/homelab/`; MetalLB L2; Traefik on `10.0.0.51`; kube-vip holding the API VIP on `10.0.0.50`; cert-manager holding two wildcards; csi-driver-nfs; Longhorn installed and currently claimed by nothing; kured rebooting workers only; Tailscale operator with the subnet router that carries remote access; whoami and Hermes; etcd snapshots on the NAS |
| Proxmox | pve1 `10.0.0.11`, pve2 `.12`, pve3 `.13`; templates 9100-9102, one per node |
| QNAP | `10.0.0.10`; `/proxmox` to the pve hosts (storage `qnap`), `/k8s` and `/hermes` to the k3s nodes (no squash). `/hermes` is owned `1000:1000` mode `2775`, and stays a separate export because squash policy is per-export: folding it into `/k8s` would hand unsquashed root over every PVC and every etcd snapshot |
| Not managed here | VM 120 `workspace`, VM 121 `hermes`, VM 9000 `ubuntu-2604-tmpl` |

Do not trust this table over the cluster.

### etcd Members

View `etcd` cluster nodes.

```bash
kubectl get nodes -l node-role.kubernetes.io/etcd=true
```

<details>
<summary>Output</summary>

All `k3s-cp...` should be `Ready`.
```
NAME       STATUS   ROLES                AGE   VERSION
k3s-cp-1   Ready    control-plane,etcd   46m   v1.36.3+k3s1
k3s-cp-2   Ready    control-plane,etcd   47m   v1.36.3+k3s1
k3s-cp-3   Ready    control-plane,etcd   46m   v1.36.3+k3s1
```

</details>

### Taints and Versions

Verify control plane taints.

```bash
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints[*].key,VERSION:.status.nodeInfo.kubeletVersion
```

<details>
<summary>Output</summary>

Control planes are tainted, workers are not, and every node matches the pinned version.
```
NAME        TAINTS                                  VERSION
k3s-cp-1    node-role.kubernetes.io/control-plane   v1.36.3+k3s1
k3s-cp-2    node-role.kubernetes.io/control-plane   v1.36.3+k3s1
k3s-cp-3    node-role.kubernetes.io/control-plane   v1.36.3+k3s1
k3s-wkr-1   <none>                                  v1.36.3+k3s1
k3s-wkr-2   <none>                                  v1.36.3+k3s1
k3s-wkr-3   <none>                                  v1.36.3+k3s1
```

</details>

## How Changes Ship

Every change walks the same ladder. [Why the gates exist](#why-the-gates-exist) is what skipping steps costs.

1. Branch off `main`. Nothing lands on `main` directly. Commits are Conventional Commits, scoped to what changed: `docs(hermes):`, `feat(flux):`, `fix(proxmox):`. The subject says what changed; the body says why, and why is the part worth writing.
2. Validate offline: everything in [Validate](#validate), from the codebase root.
3. PR with CI green. State the expected diff so the reviewer can hold the change to it. Both engines can be asked before they act: `tofu plan` for `*.tf` and `files/` ("snippets only, zero VM changes"), `flux diff kustomization` for `infra/`, `clusters/` and `apps/` ([Flux](#ship-a-change)). A change that touches neither says so: "no apply, Flux only".
4. Merge, then let the right engine act.
   - `*.tf` or `files/`: `tofu apply -parallelism=1` from the codebase root, read the plan against the shape the PR promised, stop on any surprise. Plain applies never touch running VMs.
   - `infra/`, `clusters/`, `apps/`: Flux applies within its sync interval, or force it ([Flux](#ship-a-change)).
5. Live gates for anything a node boots from: one node at a time, worker first, control planes after, etcd snapshot before any control-plane replacement, delete the old node identity before the replace. Commands in [Maintenance](#upgrade-k3s).
6. Verify and record: the checks in the doc for whatever you touched, plus the change's own done-when. Surprises go into the troubleshooting table or that doc's warts, in the same PR.

## Why the Gates Exist

"The rendered YAML parses" and "the node will boot" are two claims, and only the first is free. Treating them as one cost a control-plane node and a full rebuild once. So before any change to `files/` reaches a machine:

1. Run `cloud-init schema --config-file` against the rendered config. It is offline, takes seconds, needs no VM, and CI runs it too.
2. Boot a worker first. No quorum implications; pods reschedule.
3. Only then a control-plane node, etcd snapshot taken first.
4. Proxmox console access open before the rebuild starts, not arranged mid-incident.

The same episode is why nothing here floats. An unpinned installer and `package_upgrade: true` meant two nodes built a day apart were not the same node, so a failure could not be reproduced from this codebase at all. The version policy below exists to keep that from being true again.

The one no gate can enforce: replacing a running control-plane node to test unproven config is still touching production, whatever the tool. Ask instead of rationalising, and say a cause is unknown rather than naming a plausible one under pressure.

## Version Policy

Track the latest stable of everything; pin every version to an exact release in git. Never a channel, never `latest`, never an unpinned installer (the root cause above). An upgrade is a one-line PR that walks the ladder.

Pins: k3s in `variables.tf` (`k3s_version`); flux-operator and the Flux distribution in the seed in `files/cp-cloud-config.yml`; chart versions in their HelmRelease under `infra/`; image tags in `apps/`; Ubuntu in `variables.tf` (`ubuntu_codename`); provider versions in `.terraform.lock.hcl`, which is committed for exactly this reason. The `~>` constraints in `providers.tf` are the floor, not the pin; the lock is the pin.

One thing is deliberately not pinned: the cloud image URL, which points at `current/`, so templates built at different times embed different packages. Accepted because rebuilds are rare and deliberate; pin `ubuntu_cloud_image_url` plus a checksum when it matters.

## Rules

- Nothing is reachable from the internet. No inbound ports, no port forwards, ever. Remote access is the tailnet.
- Flux owns everything under `infra/`, `clusters/`, `apps/`. Never `kubectl apply` there; Flux reverts drift, and `prune` means a file deleted from git is deleted from the cluster. That is a feature, not a bug.
- Never create Proxmox resources by hand. The root tofu module owns them.
- VM root disks stay on `local-lvm`, never the NAS. They lived on NFS once, which made one box a correlated failure domain for all six nodes and put ~40 synchronous etcd writes per second across the network. The cost is that VMs cannot relocate between hosts, which is fine: failover is Kubernetes' job.
- `tofu apply -parallelism=3` for Initialize, `-parallelism=1` everywhere else. From empty, `=3` measured 8m48s against 10m54s at `=1` ([PROXMOX.md](PROXMOX.md#initialize)). `=1` is the fallback when a build dies on `cfs-lock 'storage-X' ... timeout`; two clean `=3` runs are not proof against that race.
- Append to `proxmox_nodes`, never reorder; index position sets template IDs.
- k3s VM IDs float. Never encode them.
- A rebuilt cp-1 starts a new cluster. Flip `is_first` in `vms.tf` first; replace cp-1 last.
- Never edit the Traefik Service or HelmChart; k3s reconciles them back. The override is `infra/configs/traefik.yaml` (HelmChartConfig).
- Nothing imperative survives. Every setting lives in the root tofu module or in git under Flux; anything applied by hand is gone at the next rebuild and does not exist.
- Secrets never enter this codebase. The four that exist (Flux deploy key, Cloudflare token, Tailscale OAuth client, `hermes`) reach the cluster through cloud-init, out of `terraform.tfvars` ([KUBERNETES.md](KUBERNETES.md#bootstrap)). There is no `kubectl create secret` step anywhere, and adding one would be a defect: it would not survive the next rebuild.
- Kubeconfig comes from `scripts/kubeconfig.sh`, never by hand. It renames k3s's cluster, user and context off `default` before merging, because a raw merge collides with whatever else is in `~/.kube/config`. Re-run it after a tear down and initialize, which mints a new CA and leaves the old entry failing on `certificate signed by unknown authority`. Replacing a node does not, since it joins the existing cluster.
- A change to behaviour updates every doc that describes it, in the same PR. Moving Hermes' state from Longhorn to NFS left five claims and one check in this file describing a system that no longer existed, and they read as authoritative for five days. Grep for what you changed before opening the PR; the four system docs and this file both make claims about the same things.
- `tofu fmt` before committing.

## Doc Standard

[README.md](README.md) and [NETWORK.md](NETWORK.md) are the reference. A new doc, or an edit to an old one, matches those two.

- README is the index and stays casual and short: what it does, the hardware, the requirements, the list of docs. Nothing else belongs there.
- One doc each for the network, Proxmox, Kubernetes and Hermes, shaped "what must be true / why this way / check it / warts". Headings are Title Case, four words at most.
- Tables carry the facts. Prose is for what a table cannot hold: a constraint, a trap, a reason a passing check can still lie. Never restate in a sentence what the table or the command output already says.
- Every claim carries the command that proves it, and every command carries its real output. Run it before shipping it; a command that needs an edit to work is a broken doc.
- Expected output is collapsed, so the page reads as commands and the output is there on demand:

````
<details>
<summary>Output</summary>

```
what the command actually printed
```

</details>
````

  The blank line after `</summary>` and before `</details>` is what keeps GitHub rendering the fence. Label it `Output`. A command slow enough that the reader would wonder if it hung carries its measured time, `<summary>Output ~5m</summary>`, and only ever a time someone actually measured.
- One check per heading. An Output toggle is followed by the next heading, never by another bare command, or the collapsed blocks run together and stop reading as a list of things to do. A section with two commands in it is two sections.
- ASCII only, no em dashes. One line per paragraph and per list item; no hard wrapping.
- A doc only runs commands for the thing it documents. If checking something needs `kubectl`, the check belongs in [KUBERNETES.md](KUBERNETES.md), not [NETWORK.md](NETWORK.md).
- Links point at what a thing is built on, never the other way: [HERMES.md](HERMES.md) links to [KUBERNETES.md](KUBERNETES.md), and never the reverse.
- Nothing temporal. Something not done yet is a fact about now, in warts, never a plan.

## Where Things Are

| | |
|---|---|
| [NETWORK.md](NETWORK.md), [PROXMOX.md](PROXMOX.md), [KUBERNETES.md](KUBERNETES.md), [HERMES.md](HERMES.md) | the system, one doc each: what, why, checks, warts |
| [README.md](README.md) | the index: what it does, the hardware, the requirements, and what each doc covers |
| `*.tf`, `files/` | the root tofu module: Proxmox resources + the cloud-init that seeds Flux |
| `clusters/`, `infra/`, `apps/` | everything Flux reconciles |
| `tests/render/` | renders both cloud-init templates with dummy values, offline, no providers and no network. A template that no longer parses fails here in seconds instead of mid-apply against live Proxmox |
| `scripts/` | workstation-side helpers, not platform. `kubeconfig.sh` rebuilds `~/.kube/config` from a cluster; `reboot-control-planes.sh` does the reboots kured will not |

The EdgeRouter and the NAS are manual and not in this codebase; both contracts are [NETWORK.md](NETWORK.md).

## Maintenance

Recurring work lives here, kept out of the four system docs so those stay "get it running".

### Kubernetes

#### Upgrade k3s

Bump `k3s_version` in `variables.tf` and apply; the plan must show snippet replacements and zero VM changes. Then snapshot etcd and replace nodes one at a time, workers first and cp-1 last, waiting for `Ready` between each.

```bash
ssh ubuntu@10.0.0.16 "sudo k3s etcd-snapshot save --name pre-upgrade"
```

```bash
kubectl delete node k3s-wkr-1
tofu apply -parallelism=1 '-replace=proxmox_virtual_environment_vm.worker["wkr-1"]'
```

Deleting the node object first is not optional; the replacement loops on `duplicate hostname` without it. A control plane also needs `sudo systemctl stop k3s` before the delete, or its etcd member re-registers and counts toward quorum. Set `is_first = false` in `vms.tf` before replacing cp-1, or the rebuilt node starts a new empty cluster.

#### Reboots

kured cordons, drains, reboots and uncordons one node at a time, 07:00-10:00 UTC, workers only. **The three control planes never reboot themselves.** They are patched like the workers and then wait indefinitely for a human.

```bash
for i in 16 17 18 32 33 34; do ssh ubuntu@10.0.0.$i "hostname; ls /var/run/reboot-required 2>/dev/null"; done
```

#### Reboot the Control Planes

```bash
bash scripts/reboot-control-planes.sh
```

Shows the plan and asks first. Skips any node with no pending reboot, does the VIP holder last, and stops at the first node it cannot confirm came back.

It waits on `boot_id` rather than NotReady. Measured on 2026-08-15, these reboot in 7 to 9 seconds, well inside the ~40s kubelet lease, so the Node object never leaves Ready and a wait on it would pass against a stale status. After the boot it asks the node itself for `/readyz` before believing the API.

## Flux

Everything past the bootstrap seed lives here, and none of it is needed to stand the platform up.

### Ship a Change

Nothing under `infra/`, `clusters/` or `apps/` is ever applied by hand.

1. Branch off `main` and make the edit.

2. Validate offline from the codebase root. CI runs the same checks.

3. Render the branch against the live cluster. Nothing is applied:

   ```bash
   flux diff kustomization apps --path ./apps
   ```

   A new file shows as created, a deleted file as deleted. Anything else is drift or a mistake in the branch.

4. PR with CI green.

5. Merge, then reconcile rather than waiting out the sync interval:

   ```bash
   kubectl -n flux-system annotate gitrepository flux-system reconcile.fluxcd.io/requestedAt=$(date +%s) --overwrite
   ```

6. Watch it land:

   ```bash
   kubectl -n flux-system get kustomization
   ```

   Every Kustomization `READY True`, on the new revision.

Rollback is `git revert` and reconcile again. `prune: true` deletes whatever the change created, with no second step.

Only `flux diff` needs the flux CLI and a kubeconfig ([KUBERNETES.md](KUBERNETES.md#kubeconfig)).

### Verification

#### Flux

```bash
kubectl -n flux-system get fluxinstance,kustomization
```

All `True`. A `False` Kustomization is usually a bad manifest on `main`, and STATUS names it. The FluxInstance reports separately and can sit `False` on a GitRepository timeout while every Kustomization below it is `True` on the current revision, so read the revisions before calling that an outage.

#### Distribution Pinned

```bash
kubectl -n flux-system get fluxinstance flux -o jsonpath='{.spec.distribution.version} {.status.lastAppliedRevision}'; echo
```

<details>
<summary>Output</summary>

```
2.9.4 v2.9.4@sha256:...
```

</details>

A range (`2.9.x`) means the seed drifted back to a channel, and two control planes seeded a week apart can come up on different patch releases.

#### Traefik Address

```bash
kubectl -n kube-system get svc traefik
```

`EXTERNAL-IP` is `10.0.0.51`.

#### Traefik Redirects

```bash
curl -sI --max-time 5 http://10.0.0.51 | head -1
```

<details>
<summary>Output</summary>

```
HTTP/1.1 308 Permanent Redirect
```

</details>

`-I` sends HEAD, which Traefik answers `308`. A GET to the same URL answers `301`.

#### Wildcard Certificates

There are two, in two namespaces, both issued from `letsencrypt-prod`, and a rebuild spends one of each.

```bash
kubectl get certificate -A
```

Both `READY True`. `wildcard-lab-cheyn-net` in `kube-system` is Traefik's default certificate and covers every first-level name; `wildcard-hermes-lab-cheyn-net` in `hermes` covers `*.hermes.lab.cheyn.net`, which the first one cannot, because a wildcard covers exactly one label.

A staging issuer is kept and used by nothing. Only issued certificates count against Let's Encrypt's five-duplicates-per-week limit, so point a test Certificate at `letsencrypt-staging` to debug issuance without spending that budget.

#### End to End

```bash
curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 https://whoami.lab.cheyn.net
```

<details>
<summary>Output</summary>

```
200
```

</details>

No `-k`. With it this also passes against Traefik's self-signed fallback, which is the one failure it exists to catch.

A browser shows a closed padlock and a `Hostname:` that alternates on reload.

## Hermes

The agent's namespace, and the one part of this system whose contents are not in git. What it is, how it is operated, and its own checks: [HERMES.md](HERMES.md).

What a change to this codebase has to respect:

- One operator action lives outside this repo: the QNAP `/hermes` export ([NETWORK.md](NETWORK.md#storage)). The apps Kustomization runs `wait: true`, so a pod that cannot mount it takes the whole apps Kustomization NotReady.
- The namespace and the `hermes` Secret arrive with the node, generated by `random_password` and delivered through the seed ([KUBERNETES.md](KUBERNETES.md#bootstrap)). There is no create-secret step to remember, and adding one would be a defect.
- `/opt/data` is the QNAP export mounted as a static NFS PV, not cluster storage. It is the one thing `tofu destroy` does not take, which is why the agent's state lives there. Its credentials do not, and are regenerated on every rebuild.
- The agent image tag appears twice in `apps/hermes.yaml`, on the Deployment and on the `hermes-image-prepull` DaemonSet. Bump one without the other and the next failover silently pays a 111s image pull.
- The Deployment deliberately has no `securityContext`, unlike `whoami.yaml`. The image starts as root and drops privileges itself; forcing `runAsUser` pre-empts that and breaks it.
- Two certificates cover Hermes' hostnames, in two namespaces. They name different hosts, so Let's Encrypt counts them separately and a rebuild spends one against each ([HERMES.md](HERMES.md#endpoints)).
- The pod runs two containers. A `1/2` pod is a working agent behind a broken Caddyfile, not a failed deploy.

The Caddyfile, the site list, and everything else the agent writes are on the NAS and never enter this repository. `apps/Caddyfile.example` is the shape, not the file.

## Troubleshooting

These failures have each been seen at least once, kept out of the four system docs so those stay instructions rather than a catalogue of what might go wrong.

### Proxmox

| Symptom | Cause | Fix |
|---|---|---|
| `can't clone to non-shared storage 'local-lvm'` | cross-node clone onto node-local storage; the check is on the target | one template per node, clone same-node |
| `you can't convert a template to a template` | VM ID already in use; fails late | pick a free ID: `pvesh get /cluster/resources --type vm` |
| `cfs-lock 'storage-X' ... timeout` | concurrent disk allocation | `-parallelism=1` |
| `Cannot move ... not owned by this VM!` | changed an existing template's storage | `-replace` the template |
| snippet upload fails mid-apply | `storage_snippets` on `local-lvm`, which cannot hold snippets | use `qnap` |
| one snippet missing after an apply that replaced all six | unproven. Seen once, 2026-08-08: the destroy landed, the create did not, and the apply still reported success | re-apply; it plans as `1 to add, 0 to destroy`. Run the Cloud-init Snippets check in [PROXMOX.md](PROXMOX.md#cloud-init-snippets) before any rebuild |
| apply succeeds, cluster never forms | nodes poll cp-1 300s then install anyway | check cp-1 first |
| destroy dies partway on `HTTP 596` waiting for a `qmshutdown` task | `pveproxy` timed out forwarding to the node holding that VM; the shutdown itself usually landed | re-run the destroy, it resumes. `stop_on_destroy` makes this unlikely by hard-stopping instead |

### Kubernetes

| Symptom | Cause | Fix |
|---|---|---|
| replacement loops on `duplicate hostname` | old node object owns the node-password entry | `kubectl delete node <name>` |
| a node sits `SchedulingDisabled` for hours | kured drained it, then the reboot or the uncordon did not finish | `kubectl -n kube-system logs ds/kured`; uncordon by hand once it is back |
| `k3s-cp-1.local` resolves to a pod IP | avahi published on CNI interfaces | fixed; cloud-init pins `allow-interfaces` |
| node hostnames resolve inconsistently, or to an `fe80::` address | the router has no records for them; static IPs never take a DHCP lease, so only mDNS answers | use IPs, or add `set system static-host-mapping host-name <name> inet <ip>` on the EdgeRouter |
| etcd snapshots never appear on the NAS | the `/k8s` mount is `nofail`, so a node boots and reports Ready with the export unmounted | `ssh ubuntu@10.0.0.16 "mountpoint /mnt/qnap-k8s && sudo touch /mnt/qnap-k8s/.rw && sudo rm /mnt/qnap-k8s/.rw && echo writable"` |
| a Longhorn volume will not attach though the node is Ready | `iscsid` missing on that node; `nodes.longhorn.io` reports Ready anyway and only fails at attach time | `kubectl -n longhorn-system get nodes.longhorn.io`, then `volumes.longhorn.io` for `degraded` |

### Flux

| Symptom | Cause | Fix |
|---|---|---|
| certificate stuck `Pending` | missing/misscoped Cloudflare token, or propagation check | `kubectl -n kube-system describe certificate`; Events name the step |
| certificate `False`, order `errored` with `429 rateLimited` | five certificates already issued for that exact SAN set in 168h; each rebuild spends one | nothing to fix. The error carries a `retry after` timestamp and cert-manager retries itself. Do not rebuild or recreate the Certificate meanwhile; repeated failures trip the separate failed-validation limit |
| browser warns on a working site | cert not issued yet; self-signed fallback | create the token Secret, wait 3 min |
| Kustomization `False` after a merge | bad manifest on `main` | STATUS column names the resource |
| `_acme-challenge` never propagates | the router's wildcard line intercepts it | cert-manager's self-check is pointed at public resolvers in [`infra/controllers/cert-manager.yaml`](infra/controllers/cert-manager.yaml) |
