# k3s cluster token; generated once, shared across all nodes
resource "random_password" "k3s_token" {
  length  = 48
  special = false
}

# Hermes credentials. Generated, never typed: nothing outside this cluster
# knows them, so a human in that loop only adds a step that can fail.
resource "random_password" "hermes_dashboard_password" {
  length  = 24
  special = false
}

resource "random_password" "hermes_dashboard_secret" {
  length  = 43
  special = false
}

resource "random_password" "hermes_api_server_key" {
  length  = 64
  special = false
}

# GitHub's SSH host keys for the deploy key's known_hosts. Fetched, not pinned:
# a pinned copy is a silent clone failure the day GitHub rotates. Skipped when
# there is no deploy key, so CI and the render harness never hit the network.
data "http" "github_meta" {
  count = var.github_token != "" ? 1 : 0
  url   = "https://api.github.com/meta"
}

# The Secrets a cluster cannot start without, as manifests for k3s's auto-deploy
# directory: the same mechanism that seeds Flux, so a rebuilt control plane
# restores its own credentials with no kubectl (KUBERNETES.md#bootstrap).
#
# yamlencode, not heredocs. This YAML ends up nested inside cloud-init's own
# block scalar, where a lost indent is still valid YAML meaning something else.
# Generating it makes that unrepresentable; the render harness checks the nesting.
locals {
  # Empty when no GitHub token is set, which is how CI and the render
  # harness run: no key, no Secret, no network.
  flux_deploy_key = join("", tls_private_key.flux[*].private_key_openssh)

  github_known_hosts = local.flux_deploy_key == "" ? "" : join("\n", [
    for k in jsondecode(data.http.github_meta[0].response_body).ssh_keys : "github.com ${k}"
  ])

  bootstrap_manifests = join("---\n", concat(
    local.flux_deploy_key == "" ? [] : [yamlencode({
      apiVersion = "v1"
      kind       = "Secret"
      metadata   = { name = "flux-system", namespace = "flux-system" }
      data = {
        identity    = base64encode(local.flux_deploy_key)
        known_hosts = base64encode(local.github_known_hosts)
      }
    })],
    var.cloudflare_api_token == "" ? [] : [
      yamlencode({ apiVersion = "v1", kind = "Namespace", metadata = { name = "cert-manager" } }),
      yamlencode({
        apiVersion = "v1"
        kind       = "Secret"
        metadata   = { name = "cloudflare-api-token", namespace = "cert-manager" }
        data       = { api-token = base64encode(var.cloudflare_api_token) }
      }),
    ],
    var.tailscale_oauth_client_id == "" ? [] : [
      yamlencode({ apiVersion = "v1", kind = "Namespace", metadata = { name = "tailscale" } }),
      yamlencode({
        apiVersion = "v1"
        kind       = "Secret"
        metadata   = { name = "operator-oauth", namespace = "tailscale" }
        data = {
          client_id     = base64encode(var.tailscale_oauth_client_id)
          client_secret = base64encode(var.tailscale_oauth_client_secret)
        }
      }),
    ],
    [
      yamlencode({ apiVersion = "v1", kind = "Namespace", metadata = { name = "hermes" } }),
      yamlencode({
        apiVersion = "v1"
        kind       = "Secret"
        metadata   = { name = "hermes", namespace = "hermes" }
        data = {
          dashboard-username = base64encode("admin")
          dashboard-password = base64encode(random_password.hermes_dashboard_password.result)
          dashboard-secret   = base64encode(random_password.hermes_dashboard_secret.result)
          api-server-key     = base64encode(random_password.hermes_api_server_key.result)
        }
      }),
    ],
  ))
}

# Snippet names and the Proxmox volume IDs they produce, derived once so the
# file resources below and the VMs' user_data_file_id cannot drift apart.
#
# The VMs deliberately consume snippet_file_id rather than the file resource's
# own .id attribute. Those are the same string, but a resource attribute is
# "known after apply" whenever that resource is replaced, and editing a
# cloud-config replaces it, since source_raw.data forces replacement. Because
# user_data_file_id is ForceNew, referencing the attribute made ANY cloud-init
# edit plan as destroying every VM that reads it: verified as
# "6 to add, 6 to destroy" for a one-line change, with cp-1 coming back on
# cluster-init and bootstrapping an empty cluster.
#
# Cloud-init only runs on first boot, so an edit must not disturb running VMs.
# Ordering is preserved by depends_on in vms.tf; the new content applies at the
# next deliberate rebuild, which is the only time it could apply anyway.
locals {
  snippet_file_name = {
    for k in concat(keys(local.cp_vms), keys(local.worker_vms)) :
    k => "k3s-${k}-cloud-config.yml"
  }
  snippet_file_id = {
    for k, name in local.snippet_file_name :
    k => "${var.storage_snippets}:snippets/${name}"
  }
}

#  Control-plane cloud-config
# server_url is empty for cp-1 (it IS the first server), set for cp-2/3.
# The template's own header lists what it takes; templatefile() fails loudly on
# a missing one, so there is no second list to keep in sync here.
resource "proxmox_virtual_environment_file" "cp_cloud_config" {
  for_each = local.cp_vms

  content_type = "snippets"
  datastore_id = var.storage_snippets
  node_name    = each.value.node

  source_raw {
    data = templatefile(
      "${path.module}/files/cp-cloud-config.yml",
      {
        hostname    = each.value.name
        ip          = each.value.ip
        token       = random_password.k3s_token.result
        server_url  = each.value.is_first ? "" : "https://${local.cp_vms["cp-1"].ip}:6443"
        ssh_key     = var.ssh_public_key
        k3s_version = var.k3s_version

        bootstrap_manifests = local.bootstrap_manifests
      }
    )
    file_name = local.snippet_file_name[each.key]
  }
}

#  Worker cloud-config
resource "proxmox_virtual_environment_file" "worker_cloud_config" {
  for_each = local.worker_vms

  content_type = "snippets"
  datastore_id = var.storage_snippets
  node_name    = each.value.node

  source_raw {
    data = templatefile(
      "${path.module}/files/worker-cloud-config.yml",
      {
        hostname    = each.value.name
        ip          = each.value.ip
        token       = random_password.k3s_token.result
        server_url  = "https://${local.cp_vms["cp-1"].ip}:6443"
        ssh_key     = var.ssh_public_key
        k3s_version = var.k3s_version
      }
    )
    file_name = local.snippet_file_name[each.key]
  }
}