# Look up objects that already exist. Terraform never changes these.
data "vsphere_datacenter" "dc" {
  name = "Lab-DC"
}

data "vsphere_compute_cluster" "cluster" {
  name          = "Lab-Cluster"
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_datastore" "shared" {
  name          = "nfs-vm-shared"
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_network" "vm_net" {
  name          = "VM-NET"
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_virtual_machine" "template" {
  name          = "ubuntu-2604-tmpl"
  datacenter_id = data.vsphere_datacenter.dc.id
}

# One VM per entry in var.vms, cloned from the template.
resource "vsphere_virtual_machine" "vm" {
  for_each = var.vms

  name             = each.key
  resource_pool_id = data.vsphere_compute_cluster.cluster.resource_pool_id # DRS picks the host
  datastore_id     = data.vsphere_datastore.shared.id

  num_cpus = each.value.cpus
  memory   = each.value.memory_mb

  # Hardware copied from the template, so the clone matches what Ubuntu was installed on.
  guest_id  = data.vsphere_virtual_machine.template.guest_id
  firmware  = data.vsphere_virtual_machine.template.firmware
  scsi_type = data.vsphere_virtual_machine.template.scsi_type

  network_interface {
    network_id   = data.vsphere_network.vm_net.id
    adapter_type = data.vsphere_virtual_machine.template.network_interface_types[0]
  }

  disk {
    label            = "disk0"
    size             = data.vsphere_virtual_machine.template.disks[0].size
    thin_provisioned = data.vsphere_virtual_machine.template.disks[0].thin_provisioned
  }

  clone {
    template_uuid = data.vsphere_virtual_machine.template.id

    customize {
      linux_options {
        host_name = each.key
        domain    = "lab.local"
      }
      network_interface {} # empty = DHCP from CORE-SW1's VLAN 20 pool
    }
  }
}
