# Network

EdgeRouter at `10.0.0.1` & QNAP NAS at `10.0.0.10`, both with admin user `admin`.

## Domain Configurations

The code expects to deploy `lab.cheyn.net`. If you are changing the domain, you'll need to update all of these. Missing one does not fail an apply; it fails later as a certificate that never issues or a hostname that never resolves.

| Configuration | Setting |
|---|---|
| `apps/whoami.yaml` | `tls.hosts` & `rules.host` |
| `apps/hermes.yaml` | `tls.hosts` & `rules.host`, both Ingresses |
| `apps/hermes-web.yaml` | `spec.dnsNames`, `tls.hosts` & `rules.host` |
| `infra/tls/wildcard-certificate.yaml` | `spec.dnsNames` |
| `infra/tls/cert-manager-issuers.yaml` | `dnsZones` & ACME `email` |
| [Router DNS Forwarding](#dns-forwarding) | `address=/lab.cheyn.net/10.0.0.51` |
| [Cloudflare Token](#cloudflare-token) | the zone the token is scoped to |
| [Tailscale DNS Nameserver](#dns-nameserver) | the restricted domain |

The certificate resource names carry the domain too (`wildcard-lab-cheyn-net`), and so do the Secrets they write. Those are labels rather than addresses, so leaving them is cosmetic, not broken.

Hostnames under `*.hermes.lab.cheyn.net` are named in a config file on the NAS that this repository does not contain, so nothing here can update those for you.

## Address Plan

| IP / Range | Assignment |
|---|---|
| `10.0.0.0/28` | Reserved for Hardware |
| `10.0.0.1` | Gateway (EdgeRouter) |
| `10.0.0.10` | QNAP NAS |
| `10.0.0.11` | Proxmox `pve1` |
| `10.0.0.12` | Proxmox `pve2` |
| `10.0.0.13` | Proxmox `pve3` |
| `10.0.0.16/28` | Reserved for Kubernetes Control Planes |
| `10.0.0.16` | k3s `cp-1` |
| `10.0.0.17` | k3s `cp-2` |
| `10.0.0.18` | k3s `cp-3` |
| `10.0.0.32/28` | Reserved for Kubernetes Workers |
| `10.0.0.32` | k3s `wkr-1` |
| `10.0.0.33` | k3s `wkr-2` |
| `10.0.0.34` | k3s `wkr-3` |
| `10.0.0.48/28` | Reserved for Cluster VIPs |
| `10.0.0.50` | Kubernetes API VIP |
| `10.0.0.51` | Traefik Ingress VIP for `*.lab.cheyn.net` |
| `10.0.0.52 - 10.0.0.63` | MetalLB pool for further LoadBalancer services |
| `10.0.0.64/26` | Free for static guest IPs |
| `10.0.0.128/25` | DHCP Pool |

## EdgeRouter

- WebUI with CLI: https://10.0.0.1/
- SSH: `ssh admin@10.0.0.1`

### SSH Access

One `ed25519` key handles admin SSH for the codebase.

```bash
ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
```

Set `ssh_public_key` in `terraform.tfvars`.

#### CLI Configuration

Add the workstation's public key to allow passwordless SSH into the router as admin. The key is the one generated above, without the `ssh-ed25519` prefix or the trailing comment.

```bash
configure
set service ssh port 22
set system login user admin authentication public-keys workstation type ssh-ed25519
set system login user admin authentication public-keys workstation key AAAAC3NzaC1lZDI1NTE5AAAA...
commit
save
exit
```

#### CLI Verification

```bash
ssh admin@10.0.0.1 "/opt/vyatta/bin/vyatta-op-cmd-wrapper show configuration commands | grep public-keys" 2>/dev/null
```

<details>
<summary>Output</summary>

```
set system login user admin authentication public-keys workstation key AAAAC3Nz...
set system login user admin authentication public-keys workstation type ssh-ed25519
```

</details>

### DHCP Pool

#### WebUI Configuration

**Services > DHCP Server > LAN2 > Actions > Configure**
- Range Start: `10.0.0.128`
- Range Stop: `10.0.0.254`
- Domain: `internal`

#### CLI Verification

```bash
ssh admin@10.0.0.1 "/opt/vyatta/bin/vyatta-op-cmd-wrapper show configuration commands | grep -E '10.0.0.0/24 (start|domain-name)'" 2>/dev/null
```

<details>
<summary>Output</summary>

```
set service dhcp-server shared-network-name LAN2 subnet 10.0.0.0/24 domain-name internal
set service dhcp-server shared-network-name LAN2 subnet 10.0.0.0/24 start 10.0.0.128 stop 10.0.0.254
```

</details>

#### Show Leases

```bash
ssh admin@10.0.0.1 "/opt/vyatta/bin/vyatta-op-cmd-wrapper show dhcp leases" 2>/dev/null
```

### DNS Forwarding

#### CLI Configuration

```bash
configure
set service dns forwarding options address=/lab.cheyn.net/10.0.0.51
commit
save
exit
```

#### CLI Verification

```bash
ssh admin@10.0.0.1 "/opt/vyatta/bin/vyatta-op-cmd-wrapper show configuration commands | grep lab.cheyn.net" 2>/dev/null
```

<details>
<summary>Output</summary>

```
set service dns forwarding options address=/lab.cheyn.net/10.0.0.51
```

</details>

#### Resolve a Hostname

```bash
nslookup whoami.lab.cheyn.net 10.0.0.1
```

<details>
<summary>Output</summary>

```
Server:  UnKnown
Address:  10.0.0.1

Name:    whoami.lab.cheyn.net
Address:  10.0.0.51
```

</details>

## Storage

A QNAP NAS at `10.0.0.10` serving three NFSv4 exports.

| Export | Clients | Access | Holds |
|---|---|---|---|
| `/proxmox` | `10.0.0.11` `10.0.0.12` `10.0.0.13` | rw, no squash | cloud image, cloud-init snippets |
| `/k8s` | `10.0.0.16/28` `10.0.0.32/28` | rw, no squash | etcd snapshots |
| `/hermes` | `10.0.0.16/28` `10.0.0.32/28` | rw, no squash | Hermes agent workspace |

### WebUI Configuration

**Control Panel > Network & File Services > Win/Mac/NFS/WebDAV > NFS Service**
- Enable Network File System (NFS) service
- NFSv4: enabled

**Control Panel > Privilege > Shared Folders > Edit Shared Folder Permission > NFS host access**
- Add each client from the table above, `Read/Write`, no root squash

Full steps in the [QNAP NFS documentation](https://docs.qnap.com/operating-system/qts/5.1.x/en-us/configuring-nfs-service-settings-4A850D3A.html).

## Cloudflare

The domain registrar for `lab.cheyn.net`. Its DNS API is what lets cert-manager issue SSL for a private network.

### Cloudflare Token
https://dash.cloudflare.com/profile/api-tokens

Create an API Token with Zone.DNS Edit + Zone.Zone Read, scoped to the `cheyn.net` zone.

Set `cloudflare_api_token` in `terraform.tfvars`.

## Tailscale

VPN provider for `lab.cheyn.net`.

### Access Control Tags
https://login.tailscale.com/admin/acls/file

Add the tags to the ACL JSON.

```json
"tagOwners": {
	"tag:k8s-operator": ["autogroup:admin"],
	"tag:k8s":          ["tag:k8s-operator"],
},
"autoApprovers": {
	"routes": {
		"10.0.0.0/24": ["tag:k8s"],
	},
},
```

Without `tagOwners` the console will not let you tag the OAuth client. Without `autoApprovers` the route waits on manual approval every time the Connector is recreated.

### Tailscale OAuth Client
https://login.tailscale.com/admin/settings/oauth

- **+ Credential**, `OAuth` **Continue ->**
    - Scopes: `Custom scopes`
    - General > Services: `Read` `Write`
        - Tags: `tag:k8s-operator`
    - Devices > Core: `Read` `Write`
        - Tags: `tag:k8s-operator`
    - Keys > Auth Keys: `Read` `Write`
        - Tags: `tag:k8s-operator`

Set `tailscale_oauth_client_id` & `tailscale_oauth_client_secret` in `terraform.tfvars`.

### DNS Nameserver
https://login.tailscale.com/admin/dns

Add a custom nameserver restricted to the one domain:
- Nameserver: `10.0.0.1`
- Restrict to domain: `lab.cheyn.net`
