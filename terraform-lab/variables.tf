variable "vsphere_server" {
  type    = string
  default = "10.10.10.22"
}

variable "vsphere_user" {
  type = string
}

variable "vsphere_password" {
  type      = string
  sensitive = true # never printed in plan or apply output
}

variable "vms" {
  description = "VMs to build: name => size. Add a line to add a VM, change a number to resize, remove a line to delete."
  type = map(object({
    cpus      = number
    memory_mb = number
  }))
  default = {
    "lab-web01" = { cpus = 1, memory_mb = 1024 }
    "lab-web02" = { cpus = 1, memory_mb = 1024 }
  }
}
