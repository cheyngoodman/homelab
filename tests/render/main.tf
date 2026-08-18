# Offline render test for the cloud-init templates.
#
# Renders all three shapes a template can take; cp-1 (cluster-init), a
# joining control plane, and a worker; with dummy values, so template syntax
# errors surface here instead of mid-apply against live Proxmox. This is gate
# 1 from AGENTS.md, and it has already caught a real one: a bare
# %{ inside a comment parses as a templatefile directive and fails four lines
# away from its cause.
#
# No providers, no credentials, no network:
#
#   tofu init && tofu apply -auto-approve
#
# then feed the rendered_* outputs to `cloud-init schema` (CI does both).

locals {
  base_vars = {
    ip          = "10.0.0.17"
    token       = "dummy-token-for-render-test"
    ssh_key     = "ssh-ed25519 AAAAdummykey render-test"
    k3s_version = "v0.0.0+render-test"
  }

  # Multi-line and indented, because that is the shape that breaks: the block
  # is nested inside cloud-init's own block scalar, so a line that loses its
  # indentation produces valid YAML meaning something else entirely.
  dummy_manifests = <<-EOT
    apiVersion: v1
    kind: Namespace
    metadata:
      name: render-test
    ---
    apiVersion: v1
    kind: Secret
    metadata:
      name: render-test
      namespace: render-test
    data:
      a: ZHVtbXk=
      b: ZHVtbXk=
    ---
    apiVersion: v1
    kind: Secret
    metadata:
      name: render-test-two
      namespace: render-test
    data:
      c: ZHVtbXk=
  EOT
}

# Both cp shapes are rendered twice, with and without bootstrap manifests. The
# empty case is a real deployment shape (a cluster seeded before its credentials
# exist), not just a default, so it has to parse too.
output "rendered_cp_first" {
  value = templatefile("${path.module}/../../files/cp-cloud-config.yml",
    merge(local.base_vars, { hostname = "k3s-cp-1", server_url = "", bootstrap_manifests = local.dummy_manifests })
  )
}

output "rendered_cp_first_no_secrets" {
  value = templatefile("${path.module}/../../files/cp-cloud-config.yml",
    merge(local.base_vars, { hostname = "k3s-cp-1", server_url = "", bootstrap_manifests = "" })
  )
}

output "rendered_cp_join" {
  value = templatefile("${path.module}/../../files/cp-cloud-config.yml",
    merge(local.base_vars, { hostname = "k3s-cp-2", server_url = "https://10.0.0.16:6443", bootstrap_manifests = local.dummy_manifests })
  )
}

output "rendered_worker" {
  value = templatefile("${path.module}/../../files/worker-cloud-config.yml",
    merge(local.base_vars, { hostname = "k3s-wkr-1", server_url = "https://10.0.0.16:6443" })
  )
}
