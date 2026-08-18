# Hermes

The `nousresearch/hermes-agent` image runs as one pod in the `hermes` namespace, reconciled by Flux from `apps/hermes.yaml` and `apps/hermes-web.yaml`.

## Ownership Boundary

Hermes gets its own space.

| Owned by | What | Where it lives |
|---|---|---|
| This codebase | Namespace, Deployment, Service, PV/PVC, Ingresses, certificate | `apps/hermes.yaml`, `apps/hermes-web.yaml` |
| The agent | Its own state, sites, jobs, memory, and the Caddyfile that publishes them | `/opt/data` on the NAS, never in git |

The split means Hermes can publish a web application without a commit to this codebase. Everything Caddy serves is one wildcard route into a config file the agent can rewrite. The route, the certificate and the storage are waiting before it asks.

## Containers

Two containers in one pod share `/opt/data`.

| Container | Image | Serves | Mount |
|---|---|---|---|
| `agent` | `nousresearch/hermes-agent:v2026.8.3` | dashboard 9119, gateway API 8642 | `/opt/data` rw |
| `caddy` | `caddy:2.9-alpine` | web 8080 | `/opt/data` ro |

Both containers share a pod, so Caddy proxies the gateway over loopback and the API key never crosses the network.

A third workload, the `hermes-image-prepull` DaemonSet, holds the agent image in every worker's containerd store. It is not part of the running agent; it exists so a failover does not pay a pull.

## Storage

| Mount | Backing | Survives |
|---|---|---|
| `/opt/data` | QNAP `/hermes` export ([NETWORK.md](NETWORK.md#storage)) | Cluster loss |

The PV is static NFS rather than a Longhorn volume or a StorageClass. Longhorn replicates across the workers' own disks, so a `tofu destroy` would take every replica at once. A provisioner-generated `pvc-<uuid>` path could not be mounted by anything outside the cluster. The export is `ReadWriteMany`, so the pod schedules on any worker without detaching anything first.

Everything the agent keeps is on the NAS. The container can be replaced and the cluster destroyed without losing it.

SQLite runs in WAL mode on this export. WAL over a network filesystem is only safe with a single writer, since the WAL index is shared memory local to one host. `replicas: 1` and `strategy: Recreate` in `apps/hermes.yaml` are what hold that true, so scaling the Deployment is the corruption case.

## Endpoints

| Host | External port | Backend | Credential |
|---|---|---|---|
| `hermes.lab.cheyn.net` | 443 | Dashboard (9119) | `dashboard-username`, `dashboard-password` |
| `hermes.lab.cheyn.net` | 8642 | Gateway API (8642) | `api-server-key` |
| `*.hermes.lab.cheyn.net` | 443 | Caddy (8080) | whatever the Caddyfile sets |

The dashboard and the gateway both serve from `/`, so they split by port rather than by hostname. Traefik carries them on the `websecure` and `websecure-api` entrypoints. The Android app expects one host with a gateway port and a dashboard port, which is why.

Two certificates cover these hostnames, and a rebuild reissues both:

| Certificate | Namespace | Covers |
|---|---|---|
| `wildcard-lab-cheyn-net` | `kube-system` | `hermes.lab.cheyn.net`, via Traefik's default TLSStore |
| `wildcard-hermes-lab-cheyn-net` | `hermes` | `*.hermes.lab.cheyn.net`, referenced by the `hermes-web` Ingress |

A wildcard covers one label, so `*.lab.cheyn.net` does not cover `app.hermes.lab.cheyn.net`. That second-level wildcard is the whole reason the agent can name a new site without asking for a certificate.

## Credentials

The `hermes` Secret holds four keys, generated at apply time by `random_password` and delivered through cloud-init ([KUBERNETES.md](KUBERNETES.md#bootstrap)). `dashboard-username` is the literal `admin`, and the other three are random.

```bash
kubectl -n hermes get secret hermes -o jsonpath='{.data.dashboard-password}' | base64 -d; echo
```

Swap the key for `dashboard-username` or `api-server-key`. `dashboard-secret` signs dashboard sessions server-side and is never typed anywhere.

A rebuilt cluster has new credentials. Nothing preserves the old ones, so every client is re-pointed after a rebuild.

## CLI

`exec` lands as root, so `setpriv` drops to the UID the agent runs as. Without it the CLI writes root-owned files into `/opt/data` that the agent cannot edit.

```bash
kubectl -n hermes exec deploy/hermes -c agent -- \
  setpriv --reuid=1000 --regid=1000 --clear-groups hermes version
```

<details>
<summary>Output</summary>

```
Hermes Agent v0.20.0 (2026.8.3) · upstream 3c27eb62
Install directory: /opt/hermes
Install method: docker
Python: 3.13.5
OpenAI SDK: 2.24.0
```

</details>

Swap `version` for any subcommand: `backup`, `import`, `webhook`, `config`, `status`. `hermes --help` lists them.

Take a shell instead of prefixing each command when running several in a row.

```bash
kubectl -n hermes exec -it deploy/hermes -c agent -- \
  setpriv --reuid=1000 --regid=1000 --clear-groups sh -c 'export HOME=/opt/data; exec bash'
```

## Initial Setup

Run these once from the shell above, on a fresh state directory.

```bash
hermes config set DEEPSEEK_API_KEY sk-...

hermes tools enable delegation terminal file web session_search memory clarify skills cronjob vision image_gen code_execution
hermes tools disable browser computer_use video_gen tts

hermes config set delegation.max_concurrent_children 3
hermes config set delegation.max_iterations 50

hermes setup
hermes doctor --fix

hermes -z "Confirm your model, provider, and that tools work. One sentence."
```

## Caddyfile

The live file is `/opt/data/Caddyfile` on the NAS and is never committed, so the running site list stays out of git. `apps/Caddyfile.example` is the reference shape.

The auth gate is a Caddy snippet, and it is the only gate: a site block without `import auth` is served to anyone who can reach the hostname. Nothing in this codebase can tell you which blocks have it.

### Validate

Run before every reload. A rejected reload keeps the old config serving, but a bad file at pod start crashloops Caddy.

```bash
kubectl -n hermes exec deploy/hermes -c caddy -- \
  sh -c 'caddy validate --config /opt/data/Caddyfile --adapter caddyfile'
```

### Reload

Reloads in place. Never restart the pod to pick up a Caddyfile change.

```bash
kubectl -n hermes exec deploy/hermes -c caddy -- \
  sh -c 'caddy reload --config /opt/data/Caddyfile --adapter caddyfile'
```

The caddy image has no `curl`. The agent reloads a different way, from its own container ([Briefing the Agent](#briefing-the-agent)).

### Hash a Password

Caddy accepts bcrypt only. An apr1 hash parses, then rejects every login as a wrong password.

```bash
kubectl -n hermes exec deploy/hermes -c caddy -- caddy hash-password --plaintext '<password>'
```

## Briefing the Agent

Paste this once into a fresh state directory, adjusted for what is true when you run it. The agent has no `kubectl` and no `caddy` binary, so it reloads over the admin API rather than with the operator command above.

````
You run in a Kubernetes pod on a private homelab cluster. Facts you cannot
discover from inside the container:

WHAT IS AVAILABLE
- Your state directory is /opt/data, a network share on the NAS. It survives
  the cluster being destroyed and rebuilt. It is the only thing that does.
- You share the pod with a Caddy container serving *.hermes.lab.cheyn.net.
  It reads /opt/data/Caddyfile and serves files out of /opt/data.
- Any hostname under *.hermes.lab.cheyn.net already resolves and already has
  a valid certificate. You do not request DNS or TLS for a new site; you add
  a block to the Caddyfile and reload.
- Your own gateway API is on localhost:8642. Caddy can proxy to it and attach
  the key, so a page you serve never has to hold a credential.
- The lab is not reachable from the internet. Access is the LAN or Tailscale.
  Nothing you publish is public, but everything you publish is visible to
  anyone already on the tailnet.

WHAT YOU OWN
- Everything under /opt/data, including the Caddyfile.
- Adding, changing and removing sites, on your own, without asking anyone.
- Your own backups. HERMES_WRITE_SAFE_ROOT stops write_file and patch outside
  /opt/data, but it does not stop your terminal, and nothing else copies that
  directory anywhere. `hermes backup` writes a zip and `hermes import` reads
  one back. Keep a recent zip before you do anything sweeping.

WHAT YOU MUST NOT TOUCH
- Anything in Kubernetes. The namespace, Deployment, Service, Ingresses and
  certificate are reconciled by Flux from a git repository. Editing them in
  the cluster is reverted automatically, so it looks like it worked and then
  silently undoes itself.
- The idea that you can install things into the cluster. You cannot. If you
  need a platform change, say so and stop.

HOW TO PUBLISH A SITE
1. Put the files somewhere under /opt/data.
2. Add a site block to /opt/data/Caddyfile, following the blocks already in
   it. A block without `import auth` is readable by anyone on the tailnet;
   that is a decision, so make it deliberately and say which you chose.
3. Reload over the admin API. You have no caddy binary and no kubectl, so
   this is the only way, and the response is also your validation:

   curl -X POST localhost:2019/load -H "Content-Type: text/caddyfile" \
     --data-binary @/opt/data/Caddyfile

   A rejected load is harmless and leaves the old config serving. A bad
   file at pod start crashloops the web container instead, so never
   restart the pod to pick up a change.
4. Tell me the hostname you used.
````

## Verification

### Pod

```bash
kubectl -n hermes get pod -l app=hermes
```

`2/2 Running`. A `1/2` pod is the agent up behind a crashlooping Caddy, so the sites are down while the dashboard and gateway still work. The label matters, since the namespace also holds three `hermes-image-prepull` pods.

### Gateway Refuses Unauthenticated

```bash
curl -s -o /dev/null -w '%{http_code}\n' --max-time 10 https://hermes.lab.cheyn.net:8642/api/sessions
```

<details>
<summary>Output</summary>

```
401
```

</details>

The gateway serves 8642 without authentication unless `API_SERVER_ENABLED` and `API_SERVER_KEY` engage. That port is published to the LAN and the tailnet. A `200` means an open agent API, so pull the Ingress before doing anything else.

### Dashboard

```bash
curl -s -o /dev/null -w '%{http_code}\n' --max-time 10 https://hermes.lab.cheyn.net/
```

<details>
<summary>Output</summary>

```
302
```

</details>

A `302` is the dashboard redirecting to its login page.

### State Directory Ownership

```bash
kubectl -n hermes exec deploy/hermes -c agent -- sh -c 'ls -ln /opt/data'
```

Every entry `1000 1000`. A root-owned entry is a file written by an `exec` that skipped `setpriv`, and the agent cannot edit it.

### Pod Writes as 1000

```bash
kubectl -n hermes exec deploy/hermes -c agent -- setpriv --reuid=1000 --regid=1000 --clear-groups sh -c 'touch /opt/data/.rw && ls -ln /opt/data/.rw && rm /opt/data/.rw'
```

Owner and group both `1000`. The export's squash policy is correct, checked from the only place that matters: the pod, as the UID the agent actually uses.

`setpriv` is load-bearing. `exec` bypasses the entrypoint that drops privileges and lands as root. Without it the check writes as root, reports `0 0`, and proves nothing.

### Survives a Restart

```bash
kubectl -n hermes delete pod -l app=hermes
```

A replacement reaches `2/2` in about a minute with `/opt/data` unchanged. It may come back on a different worker; the export is `ReadWriteMany`, so nothing detaches first.

## Failover

Losing the worker Hermes runs on costs a pod reschedule, not a volume migration. Three things make that true, and removing any one brings the migration back:

- The state is an NFS export, not node-local storage, so any worker can mount it and no volume has to detach and reattach
- `tolerationSeconds: 15` on the pod, against the 300s default, which is otherwise the dominant term
- The agent image is pre-pulled onto every worker by the `hermes-image-prepull` DaemonSet. Without it, the pull was measured at 111s of a 218s recovery on the previous Longhorn-backed storage

The image tag appears twice in `apps/hermes.yaml`, on the Deployment and on the pre-pull DaemonSet. Bump one without the other and the next failover quietly pays that 111s again.

### Test It

Stop the VM rather than draining the node, since an abrupt loss is the failure being tested. VM IDs float, so find it by name:

```bash
ssh root@10.0.0.11 "pvesh get /cluster/resources --type vm --output-format yaml | grep -E 'vmid|name|node' | paste - - - | grep wkr"
```

Then `qm stop <id>` on that VM's pve host, watch the pod move, and `qm start <id>` afterwards.

