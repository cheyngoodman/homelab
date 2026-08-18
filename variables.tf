#  Proxmox connection 
variable "proxmox_endpoint" {
  description = "Proxmox API endpoint (any node works; the cluster shares state)"
  type        = string
  default     = "https://10.0.0.11:8006/"
}

#  Proxmox auth
# An API token, per PROXMOX.md. Leave blank to fall back to the provider's own
# PROXMOX_VE_* env vars, or set them in terraform.tfvars (gitignored).
variable "proxmox_api_token" {
  description = "Proxmox API token, e.g. root@pam!tofu=<uuid> (recommended auth method)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "proxmox_username" {
  description = "Proxmox username, e.g. root@pam or root@pam!tofu; only needed if not using env vars"
  type        = string
  default     = ""
  sensitive   = true
}

# Into the Proxmox hosts as root, for what the API cannot do (the disk import).
# Not ssh_public_key, which goes into the guest VMs.
variable "proxmox_ssh_private_key_path" {
  description = "Path to the private key the provider uses to SSH into Proxmox nodes as root (unencrypted key required)"
  type        = string
  default     = "~/.ssh/id_ed25519"
}

#  Storage
# Defaults are the working values, because terraform.tfvars is gitignored and a
# fresh clone runs on them. VM disks stay node-local so the NAS is not a single
# point of failure under all six nodes; that is also what forces one template
# per node, since Proxmox will not clone across hosts onto local disk.
variable "storage_iso" {
  description = "Proxmox storage for the downloaded cloud image (must support 'iso' content, and be reachable from every node)"
  type        = string
  default     = "qnap"
}

variable "storage_template" {
  description = "Proxmox storage for the per-node base template disks (must support 'images' content); node-local is correct here; each template is only ever cloned by its own node"
  type        = string
  default     = "local-lvm"
}

variable "storage_vm" {
  description = "Proxmox storage for cloned VM disks; node-local by design (must support 'images' content)"
  type        = string
  default     = "local-lvm"
}

variable "storage_snippets" {
  description = "Proxmox storage for cloud-init snippets (must support 'snippets' content)"
  type        = string
  default     = "qnap"
}

#  Network 
variable "gateway" {
  description = "Default gateway"
  type        = string
  default     = "10.0.0.1"
}

variable "dns_servers" {
  description = "DNS servers for VMs"
  type        = list(string)
  default     = ["10.0.0.1"]
}

variable "vm_bridge" {
  description = "Proxmox bridge for VM networking"
  type        = string
  default     = "vmbr0"
}

#  Bootstrap credentials
# The three identities that exist in someone else's system and cannot be minted
# from nothing: a GitHub deploy key, a Cloudflare token, a Tailscale OAuth
# client. Set them once in terraform.tfvars (gitignored); cloud-init writes them
# into k3s's auto-deploy directory, so a rebuilt cluster comes back with its
# credentials and needs no kubectl at all. What to create and where:
# terraform.tfvars.example, which links to the doc that issues each one.
#
# Everything else a Secret needs is generated (see cloud-init.tf). Empty here is
# valid and renders no Secret, which is how tests/render and CI work.
variable "github_token" {
  description = "GitHub token with repo scope. Registers Flux's deploy key; empty seeds no key and leaves Flux unable to clone"
  type        = string
  default     = ""
  sensitive   = true
}

variable "github_owner" {
  description = "GitHub account owning the repository Flux syncs from"
  type        = string
  default     = "cheyngoodman"
}

variable "github_repository" {
  description = "Repository Flux syncs from, without the owner"
  type        = string
  default     = "homelab"
}

variable "cloudflare_api_token" {
  description = "Cloudflare token for cert-manager DNS-01: Zone.DNS Edit + Zone.Zone Read, scoped to the zone"
  type        = string
  default     = ""
  sensitive   = true
}

variable "tailscale_oauth_client_id" {
  description = "Tailscale OAuth client ID for the operator"
  type        = string
  default     = ""
  sensitive   = true
}

variable "tailscale_oauth_client_secret" {
  description = "Tailscale OAuth client secret for the operator"
  type        = string
  default     = ""
  sensitive   = true
}

#  SSH
variable "ssh_public_key" {
  description = "SSH public key injected into all VMs via cloud-init"
  type        = string
  # Override in terraform.tfvars; your workstation key
}

#  Ubuntu cloud image
# A release move is these two variables; the image URL and the template names
# derive from them. It rebuilds the three templates and touches no running VM,
# because the clone blocks read local.template_vm_id rather than the template
# resource (vms.tf). Moving the running nodes onto the new release is a
# separate, deliberate rolling replace; the runbook is in AGENTS.md.
#
#   24.04 LTS  noble     / 2404   supported to May 2029
#   26.04 LTS  resolute  / 2604   supported to May 2031  (running today)
variable "ubuntu_codename" {
  description = "Ubuntu release codename, used to build the cloud image URL (e.g. noble = 24.04, resolute = 26.04)"
  type        = string
  default     = "resolute"

  validation {
    # A version number here ("24.04") produces a 404 at download time, well
    # after the plan looks fine. Catch it at parse time instead.
    condition     = can(regex("^[a-z]+$", var.ubuntu_codename))
    error_message = "ubuntu_codename must be the lowercase release codename (e.g. \"noble\", \"resolute\"), not a version number."
  }
}

variable "ubuntu_version_slug" {
  description = "Ubuntu version without the dot, used in template names (e.g. 2404, 2604). Keep in sync with ubuntu_codename."
  type        = string
  default     = "2604"
}

variable "ubuntu_cloud_image_url" {
  description = "Full cloud image URL. Leave empty to derive it from ubuntu_codename; only set this to pin a dated build instead of 'current'."
  type        = string
  default     = ""
}

variable "ubuntu_cloud_image_checksum" {
  description = "SHA256 of the cloud image (set to verify download integrity, or empty to skip)"
  type        = string
  default     = ""
}

#  VM specs 
variable "cp_spec" {
  description = "Control-plane VM specs"
  type = object({
    cores  = number
    memory = number # MB
    disk   = number # GB
  })
  default = {
    cores  = 2
    memory = 4096
    disk   = 20
  }
}

variable "worker_spec" {
  description = "Worker VM specs"
  type = object({
    cores  = number
    memory = number # MB
    disk   = number # GB
  })
  default = {
    cores  = 4
    memory = 8192
    disk   = 40
  }
}

#  Node list 
variable "proxmox_nodes" {
  description = "Proxmox node names"
  type        = list(string)
  default     = ["pve1", "pve2", "pve3"]
}
#  k3s version
# Pinned, never a channel. An unpinned installer is what made two nodes built a
# day apart run different k3s, and cost a control-plane node to find out.
variable "k3s_version" {
  description = "Exact k3s version installed by cloud-init, e.g. v1.36.3+k3s1. Never leave unset; an unpinned installer makes every node a coin flip."
  type        = string
  default     = "v1.36.3+k3s1"
}
