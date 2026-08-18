# Proxmox

Three nodes `pve1` `pve2` `pve3`, admin user is `root`.

| Storage | Type | Scope | Holds |
|---|---|---|---|
| `local-lvm` | lvmthin | per-node | templates, VM disks (~348 GB/node) |
| `local` | dir | per-node | unused |
| `qnap` | nfs | shared | cloud image, cloud-init snippets |

## Bare Metal

Three HP ProDesk 400 G3 Minis, `F9` at power on for the boot menu, then the Proxmox ISO.

Each node installs standalone, taking its address from the [Address Plan](NETWORK.md#address-plan) with `10.0.0.1` as both gateway and DNS. Configuration runs on the node, the checks run from the workstation.

Order matters: the nodes reach the same package set before they cluster, and the NFS export exists before the storage is defined.

### Reset Node Host Keys

A reinstalled node keeps its IP and gets a new host key. SSH refuses until the old one is dropped.

```bash
for ip in 10.0.0.{11,12,13}; do
  ssh-keygen -R $ip
  ssh-keyscan -H $ip >> ~/.ssh/known_hosts 2>/dev/null
done
```

### Package Repositories

The installer enables the enterprise repositories, which need a subscription and fail `apt update` with `401`. Swap them for `pve-no-subscription` on every node.

```bash
cd /etc/apt/sources.list.d/

rm -f pve-enterprise.sources ceph.sources

cat > proxmox.sources <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF

apt update && apt -y dist-upgrade

reboot
```

`ceph.sources` goes too; nothing here runs Ceph. `debian.sources` stays. The deb822 `.sources` format and the `trixie` suite are Proxmox 9; an older release uses a `.list` file and a different suite.

### Verify Repositories

```bash
ssh root@10.0.0.11 "ls /etc/apt/sources.list.d/ && cat /etc/apt/sources.list.d/proxmox.sources"
```

<details>
<summary>Output</summary>

No `pve-enterprise.sources` and no `ceph.sources`.
```
debian.sources
proxmox.sources
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
```

</details>

### Create the Cluster

From `10.0.0.11`.

```bash
pvecm create lab
```

### Join the Cluster

From `10.0.0.12` and `10.0.0.13`.

```bash
pvecm add 10.0.0.11
```

The join asks for `10.0.0.11`'s root password and refuses a node that already holds a VM.

### Verify Quorum

```bash
ssh root@10.0.0.11 "pvecm status | grep -E 'Name:|Nodes:|Quorate:'"
```

<details>
<summary>Output</summary>

```
Name:             lab
Nodes:            3
Quorate:          Yes
```

</details>

### NFS Storage

The export exists first ([NETWORK.md](NETWORK.md#storage)). Storage is cluster-wide configuration, so this runs once, on any node; a second run fails on `storage ID already defined`.

```bash
pvesm add nfs qnap \
  --server 10.0.0.10 \
  --export /proxmox \
  --content iso,snippets \
  --options vers=4.1
```

`/proxmox` is the export name, not the NAS filesystem path underneath it. `iso` and `snippets` are the two content types this codebase asks for, the cloud image and the six cloud-init snippets (`storage_iso` and `storage_snippets` in [variables.tf](variables.tf)). Without them the image download and every snippet upload fail mid-apply.

The live storage carries `rootdir,images,backup,vztmpl` as well, because VMs 120, 121 and 9000 keep their disks there and are outside this module. No VM this module builds does. `storage_vm` and `storage_template` default to `local-lvm`, and that default is what keeps root disks off the NAS, not the content flags.

### Verify Storage

```bash
ssh root@10.0.0.11 "pvesm status"
```

<details>
<summary>Output</summary>

All three `active`.
```
Name             Type     Status     Total (KiB)      Used (KiB) Available (KiB)        %
local             dir     active        98497780         5509280        87938952    5.59%
local-lvm     lvmthin     active       364797952        28454240       336343711    7.80%
qnap              nfs     active       519107072       111853056       406713344   21.55%
```

</details>

## API Token

On any PVE node as root:

```bash
pveum user token add root@pam tofu --privsep 0
pveum acl modify / --tokens 'root@pam!tofu' --roles Administrator --propagate 1
```

The token is shown once, set the values into `terraform.tfvars`:

- `proxmox_username`: `root@pam!tofu`
- `proxmox_api_token`: `root@pam!tofu=<uuid>`

## Virtual Machines

Deploy the VMs using `tofu`.

### NFS Exports

The cloud image and the snippets are written to `qnap`, so the export has to be live before anything below runs. The exports themselves are [NETWORK.md](NETWORK.md#storage).

```bash
ssh root@10.0.0.11 "showmount -e 10.0.0.10"
```

<details>
<summary>Output</summary>

```
Export list for 10.0.0.10:
/k8s     10.0.0.32/28,10.0.0.16/28
/hermes  10.0.0.32/28,10.0.0.16/28
/proxmox 10.0.0.13,10.0.0.12,10.0.0.11
```

</details>

### Initialize

```bash
tofu init &&
tofu plan -parallelism=3 -out=apply.tfplan &&
tofu apply -parallelism=3 apply.tfplan
```

<details>
<summary>Output ~9m</summary>

```
Apply complete! Resources: 20 added, 0 changed, 0 destroyed.
```

</details>

#### Reset SSH Known Hosts

Cloud-init runs for about four minutes on each node and reboots it. SSH refuses until that finishes, so this fails if run too early.

Rebuilt VMs keep their IPs and get new host keys.

```bash
for ip in 10.0.0.{16,17,18,32,33,34}; do
  ssh-keygen -R $ip
  ssh-keyscan -H $ip >> ~/.ssh/known_hosts 2>/dev/null
done
```

#### Cloud-init Snippets

`Apply complete!` doesn't guarantee the snippets were generated.

```bash
ssh root@10.0.0.11 "pvesh get /nodes/pve1/storage/qnap/content --content snippets --output-format yaml | grep volid"
```

<details>
<summary>Output</summary>

Six `k3s-` entries, one per node. Anything else in this storage was put there by hand and is not managed by tofu.
```
  volid: qnap:snippets/k3s-cp-1-cloud-config.yml
  volid: qnap:snippets/k3s-cp-2-cloud-config.yml
  volid: qnap:snippets/k3s-cp-3-cloud-config.yml
  volid: qnap:snippets/k3s-wkr-1-cloud-config.yml
  volid: qnap:snippets/k3s-wkr-2-cloud-config.yml
  volid: qnap:snippets/k3s-wkr-3-cloud-config.yml
  volid: qnap:snippets/ubuntu-base.yaml
```

</details>

Fewer than six `k3s-` entries is the failure this check exists for. Re-apply; it plans as `1 to add, 0 to destroy`.

### Tear Down

Plan the destruction of the environment.

```bash
tofu plan -destroy -parallelism=1 -out=destroy.tfplan
```

Every rebuild issues two new wildcard certificates, and Let's Encrypt allows five per week for the same names. That is five rebuilds a week, not ten; the two cover different names and are counted separately. Past that, Traefik serves its self-signed fallback until the window rolls.

Destroy the environment... Did you backup first?!

```bash
tofu apply destroy.tfplan
```

<details>
<summary>Output ~6s</summary>

```
Apply complete! Resources: 0 added, 0 changed, 20 destroyed.
```

</details>
