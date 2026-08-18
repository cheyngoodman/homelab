# Flux's deploy key, generated and registered rather than pasted by hand.
# The private half never leaves this state and reaches a node through
# cloud-init; the public half is the repository's read-only deploy key.
# A rebuild rotates both, and a destroy removes the key from GitHub.
resource "tls_private_key" "flux" {
  count     = var.github_token != "" ? 1 : 0
  algorithm = "ED25519"
}

resource "github_repository_deploy_key" "flux" {
  count      = var.github_token != "" ? 1 : 0
  repository = var.github_repository
  title      = "flux-homelab"
  key        = tls_private_key.flux[0].public_key_openssh
  read_only  = true # Flux only clones; write access would let the cluster push
}
