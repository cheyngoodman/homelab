#  Locals: VM inventory 

locals {
  cp_vms = {
    "cp-1" = { name = "k3s-cp-1", node = "pve1", ip = "10.0.0.16", cpu = var.cp_spec.cores, memory = var.cp_spec.memory, disk = var.cp_spec.disk, is_first = true }
    "cp-2" = { name = "k3s-cp-2", node = "pve2", ip = "10.0.0.17", cpu = var.cp_spec.cores, memory = var.cp_spec.memory, disk = var.cp_spec.disk, is_first = false }
    "cp-3" = { name = "k3s-cp-3", node = "pve3", ip = "10.0.0.18", cpu = var.cp_spec.cores, memory = var.cp_spec.memory, disk = var.cp_spec.disk, is_first = false }
  }

  worker_vms = {
    "wkr-1" = { name = "k3s-wkr-1", node = "pve1", ip = "10.0.0.32", cpu = var.worker_spec.cores, memory = var.worker_spec.memory, disk = var.worker_spec.disk }
    "wkr-2" = { name = "k3s-wkr-2", node = "pve2", ip = "10.0.0.33", cpu = var.worker_spec.cores, memory = var.worker_spec.memory, disk = var.worker_spec.disk }
    "wkr-3" = { name = "k3s-wkr-3", node = "pve3", ip = "10.0.0.34", cpu = var.worker_spec.cores, memory = var.worker_spec.memory, disk = var.worker_spec.disk }
  }

  # Derived from ubuntu_codename unless explicitly overridden. The image file
  # name carries the codename too, so switching releases fetches a distinctly
  # named file rather than silently reusing whatever is already cached on the
  # NAS under a generic name.
  ubuntu_image_url  = var.ubuntu_cloud_image_url != "" ? var.ubuntu_cloud_image_url : "https://cloud-images.ubuntu.com/${var.ubuntu_codename}/current/${var.ubuntu_codename}-server-cloudimg-amd64.img"
  ubuntu_image_file = "k3s-${var.ubuntu_codename}-server-cloudimg-amd64.img"

  # Template IDs computed here, NOT read from the template resource's
  # attributes. The clone blocks consume this local; if they referenced
  # base[...].vm_id instead, any change that replaces a template would mark the
  # ID "known after apply", and clone is ForceNew, so a templates-only change
  # (e.g. an Ubuntu release bump) would plan as replacing all six VMs too.
  # Same defect and same fix as snippet_file_id in cloud-init.tf.
  #
  # 9100+, not the conventional 9000: this cluster has an unrelated template at
  # 9000. Indexed off proxmox_nodes; append, never reorder.
  template_vm_id = {
    for n in var.proxmox_nodes : n => 9100 + index(var.proxmox_nodes, n)
  }
}

#  Ubuntu cloud image
# Downloaded once, to the first node. storage_iso is shared, so every node
# reads the same file at template-build time.

resource "proxmox_download_file" "ubuntu_cloud_image" {
  content_type = "iso"
  datastore_id = var.storage_iso
  node_name    = var.proxmox_nodes[0]

  url       = local.ubuntu_image_url
  file_name = local.ubuntu_image_file # namespaced; avoids colliding with any pre-existing file of the generic name

  # Optional checksum verification
  checksum           = var.ubuntu_cloud_image_checksum != "" ? var.ubuntu_cloud_image_checksum : null
  checksum_algorithm = var.ubuntu_cloud_image_checksum != "" ? "sha256" : null
}

#  Base templates: one per node (clone sources)
# One per node because the clone check is on the target storage, not the
# source, so a shared template does not help. Node-local too, since only their
# own node ever clones them.

resource "proxmox_virtual_environment_vm" "base" {
  for_each = toset(var.proxmox_nodes)

  name      = "ubuntu-${var.ubuntu_version_slug}-base-${each.value}"
  node_name = each.value

  # Pinned via the shared local rather than auto-assigned; an ID that shifts
  # on rebuild would strand the clones' record of their source. Proxmox VM IDs
  # are cluster-wide, so claiming an occupied ID fails at the convert step with
  # the confusing "you can't convert a template to a template". Check with
  # `pvesh get /cluster/resources --type vm` before changing the base number.
  vm_id = local.template_vm_id[each.value]

  # A real template, not just a stopped VM: immutable, can't be booted by
  # accident, and is the idiomatic Proxmox clone source.
  template = true
  started  = false
  on_boot  = false

  cpu {
    cores = 1
    type  = "host"
  }

  memory {
    dedicated = 512
  }

  # Changing storage_template on an EXISTING template needs `-replace`, not a
  # plain apply. Converting to a template renames the volume to base-<id>-disk-0
  # and hands ownership to the template, so the provider's move-disk path fails
  # with "it is not owned by this VM!". Rebuilding the template is cheap and
  # safe; the VMs are full clones, and clone.vm_id is unchanged, so nothing
  # cloned from it is replaced.
  disk {
    datastore_id = var.storage_template # this node's local disk; clones never leave the node
    file_id      = proxmox_download_file.ubuntu_cloud_image.id
    interface    = "scsi0"
    size         = 4 # minimal; cloned VMs resize their own disk
  }

  operating_system {
    type = "l26" # Linux 6.x
  }

  # No cloud-init drive on the template; each clone gets its own via the
  # initialization block below.
}

#  Control-plane VMs 

resource "proxmox_virtual_environment_vm" "cp" {
  for_each = local.cp_vms

  name      = each.value.name
  node_name = each.value.node
  started   = true
  on_boot   = true

  # Hard stop rather than a guest shutdown. These are being deleted, so a
  # graceful shutdown buys nothing and its long-running task is what returns
  # HTTP 596 when pveproxy forwards it to another node.
  stop_on_destroy = true

  clone {
    # This node's own template, via the computed local; NOT the template
    # resource's attributes, which would couple template replacement to VM
    # replacement (see template_vm_id in locals). Indexing by each.value.node
    # is what keeps the clone same-node; cloning from another node's template
    # onto local-lvm is rejected by Proxmox (see the base template block).
    vm_id     = local.template_vm_id[each.value.node]
    node_name = each.value.node # source == target node by construction

    # TARGET storage; this node's local disk.
    datastore_id = var.storage_vm

    full    = true
    retries = 3
  }

  cpu {
    cores = each.value.cpu
    type  = "host"
  }

  memory {
    dedicated = each.value.memory
  }

  disk {
    datastore_id = var.storage_vm
    interface    = "scsi0"
    size         = each.value.disk
  }

  initialization {
    datastore_id      = var.storage_vm # where the cloud-init drive lives
    user_data_file_id = local.snippet_file_id[each.key]

    ip_config {
      ipv4 {
        address = "${each.value.ip}/24"
        gateway = var.gateway
      }
    }

    dns {
      servers = var.dns_servers
    }
  }

  network_device {
    bridge   = var.vm_bridge
    firewall = false
  }

  operating_system {
    type = "l26"
  }

  agent {
    enabled = true # qemu-guest-agent
  }

  # Both were implicit while the clone/init blocks referenced the resources'
  # attributes; they are not anymore (deliberately; see template_vm_id and
  # snippet_file_id), so the ordering is stated here: the template must exist
  # before it can be cloned, and the snippet before a VM boots from it.
  depends_on = [
    proxmox_virtual_environment_vm.base,
    proxmox_virtual_environment_file.cp_cloud_config,
  ]
}

#  Worker VMs 

resource "proxmox_virtual_environment_vm" "worker" {
  for_each = local.worker_vms

  name      = each.value.name
  node_name = each.value.node
  started   = true
  on_boot   = true

  # Hard stop rather than a guest shutdown. These are being deleted, so a
  # graceful shutdown buys nothing and its long-running task is what returns
  # HTTP 596 when pveproxy forwards it to another node.
  stop_on_destroy = true

  clone {
    vm_id        = local.template_vm_id[each.value.node] # this node's template, via the local; see cp block
    node_name    = each.value.node                       # source == target node
    datastore_id = var.storage_vm                        # target; this node's local disk
    full         = true
    retries      = 3
  }

  cpu {
    cores = each.value.cpu
    type  = "host"
  }

  memory {
    dedicated = each.value.memory
  }

  disk {
    datastore_id = var.storage_vm
    interface    = "scsi0"
    size         = each.value.disk
  }

  initialization {
    datastore_id      = var.storage_vm
    user_data_file_id = local.snippet_file_id[each.key]

    ip_config {
      ipv4 {
        address = "${each.value.ip}/24"
        gateway = var.gateway
      }
    }

    dns {
      servers = var.dns_servers
    }
  }

  network_device {
    bridge   = var.vm_bridge
    firewall = false
  }

  operating_system {
    type = "l26"
  }

  agent {
    enabled = true
  }

  # Explicit ordering; see the cp block's depends_on for why.
  depends_on = [
    proxmox_virtual_environment_vm.base,
    proxmox_virtual_environment_file.worker_cloud_config,
  ]
}