# Homelab

[![CI](https://github.com/cheyngoodman/homelab/actions/workflows/ci.yml/badge.svg)](https://github.com/cheyngoodman/homelab/actions/workflows/ci.yml)

A private lab for hosting technical agency.

## Hardware

Three HP ProDesk 400 G3 Minis, a QNAP TS-451D2 and a Ubiquiti EdgeRouter.

## Requirements

Software: `git` `bash` `ssh` `tofu` `kubectl` `flux` `gh` `python`

Configuration: `terraform.tfvars` (Reference `terraform.tfvars.example`)

## The Tostada

**[Network](NETWORK.md)**
- Cloudflare DNS
- Tailscale VPN
- Local DHCP, SSH, NFS

**[Proxmox](PROXMOX.md)**
- Virtualization Cluster
- Terraform/Tofu Infrastructure as Code
  - `tofu apply` ~10min build process
  - `tofu destroy` quick cleanup

**[Kubernetes](KUBERNETES.md)**
- SSL Encryption
- Containerization Cluster
- Hardware and node failover

**[Hermes](HERMES.md)**
- AI Agency
- Web Namespace: `*.hermes.lab.cheyn.net`

