terraform {
  required_version = ">= 1.6.0"

  required_providers {
    vsphere = {
      # The provider moved from hashicorp/vsphere; VMware by Broadcom maintains it now.
      source  = "vmware/vsphere"
      version = ">= 2.10.0"
    }
  }
}
