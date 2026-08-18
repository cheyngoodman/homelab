terraform {
  required_version = ">= 1.8.0"
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.73"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    github = {
      source  = "integrations/github"
      version = "~> 6.0"
    }
  }
}

provider "github" {
  # Empty leaves the provider unconfigured, which is fine while no github
  # resource is being created: CI and the render harness never set it.
  token = var.github_token != "" ? var.github_token : null
  owner = var.github_owner
}

provider "proxmox" {
  endpoint = var.proxmox_endpoint
  insecure = true # self-signed Proxmox certs

  # terraform.tfvars, or the provider's own PROXMOX_VE_* env vars. Passing ""
  # would break that fallback, so empty becomes null here.
  api_token = var.proxmox_api_token != "" ? var.proxmox_api_token : null
  username  = var.proxmox_username != "" ? var.proxmox_username : null

  # Separate from API auth above; the provider SSHes into the Proxmox
  # nodes directly (as root) for operations the API doesn't cover, e.g.
  # importing the downloaded cloud image into the base VM's disk.
  ssh {
    username    = "root"
    private_key = file(pathexpand(var.proxmox_ssh_private_key_path))
  }
}