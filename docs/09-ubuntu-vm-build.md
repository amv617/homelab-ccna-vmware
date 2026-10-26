# 09. Ubuntu Server 26.04.1 LTS VM Build

Builds the two small Linux VMs in Lab-Cluster: **TS-ROUTER** for Tailscale remote access ([10-tailscale-remote-access.md](10-tailscale-remote-access.md)) and **RANCID-01** for switch config backups ([11-rancid-config-backups.md](11-rancid-config-backups.md)). Their disks go on the shared nfs-vm-shared datastore so vSphere HA can restart them on another host. Follow this guide once per VM using that VM's column.

## Build sheet

| Setting | TS-ROUTER | RANCID-01 |
|---|---|---|
| Job | Tailscale subnet router | RANCID switch config backups |
| Hostname | ts-router | rancid-01 |
| IP / mask | 10.10.10.41/24 | 10.10.10.42/24 |
| Gateway | 10.10.10.1 (CORE-SW1) | 10.10.10.1 (CORE-SW1) |
| DNS | 192.168.1.1, 1.1.1.1 | 192.168.1.1, 1.1.1.1 |
| Port group | MGMT-VLAN10 | MGMT-VLAN10 |
| vCPU / RAM / disk | 1 / 2 GB / 20 GB thin | 1 / 2 GB / 20 GB thin |
| Datastore | nfs-vm-shared | nfs-vm-shared |
| Compute | 10.10.10.21 (ESXI-01) | 10.10.10.21 (ESXI-01) |
| HA restart priority | High | Medium (default) |
| Next | Tailscale guide, Step 3 | RANCID guide, Part 1 |

10.10.10.40 is reserved for veeam01 ([06-nas-backup.md](06-nas-backup.md)), which is why these use .41 and .42.

## Why these choices

- **26.04.1 LTS** gets security updates until 2031, and the .1 point release includes the early fixes.
- **MGMT-VLAN10** puts both VMs next to vCenter and the switch management addresses; the switches' MGMT-SSH ACL already permits 10.10.10.0/24.
- **nfs-vm-shared** is reachable by every host, so HA can restart the VMs elsewhere. The trade-off is that both depend on NAS-01: if the NAS is down, so are they, including remote access. The VMs are easy to rebuild; RANCID's history is the one thing worth a second copy (RANCID guide, Optional extras).
- **20 GB thin** uses only what's written, about 4 to 5 GB after install.

## Step 1: Download and verify the ISO

Download `ubuntu-26.04.1-live-server-amd64.iso` from ubuntu.com/download/server (once for both VMs) and compare its SHA-256 with the `SHA256SUMS` file at releases.ubuntu.com/26.04.1/:

```
shasum -a 256 ~/Downloads/ubuntu-26.04.1-live-server-amd64.iso                     # macOS
Get-FileHash $HOME\Downloads\ubuntu-26.04.1-live-server-amd64.iso -Algorithm SHA256  # Windows
```

## Step 2: Upload it to vmstore

Skip this if vmstore > ISO already holds `ubuntu-26.04.1-live-server-amd64.iso`.

1. Use the service port (10.10.10.50) or a workstation with the 10.10.0.0/16 route.
2. Open https://10.10.10.21 and accept its certificate first. vmstore is ESXI-01's local datastore, so the upload goes straight to that host and fails quietly if the browser hasn't accepted its certificate.
3. In vCenter, vmstore > Files > ISO folder (create it if needed) > Upload Files.

Only 10.10.10.21 can read vmstore, which is one reason Step 3 builds the VM on that host. The ISO is only needed for the install: Step 5 disconnects it, and after that the VM can run on or move to either host. **Until then, don't migrate the VM to 10.10.10.24.**

**Before you build:** nfs-vm-shared is mounted on every host, MGMT-VLAN10 exists on every host with exactly that name, and pings to 10.10.10.41 and .42 time out (nothing else has the address).

## Step 3: Create the VM on 10.10.10.21

Right-click **10.10.10.21** (the host, not the cluster, so DRS doesn't place it) > New Virtual Machine:

| Page | Setting |
|---|---|
| Name and folder | TS-ROUTER or RANCID-01, location Lab-DC itself |
| Compute resource | 10.10.10.21 |
| Storage | **nfs-vm-shared**, not vmstore |
| Compatibility | ESXi 8.0 and later (VM version 20) |
| Guest OS | Linux > Ubuntu Linux (64-bit) |
| CPU / Memory | 1 / 2 GB |
| Hard disk | 20 GB, Thin Provision |
| SCSI controller | VMware Paravirtual (default) |
| Network | MGMT-VLAN10, VMXNET 3, Connect At Power On |
| CD/DVD | Datastore ISO File > **vmstore** > ISO > the Ubuntu ISO, Connect At Power On (only 10.10.10.21 sees vmstore) |

Finish **without** powering on.

**3b. Per-VM EVC first.** VM > Configure > VMware EVC > Edit > Enable EVC for Intel hosts, **Intel Haswell Generation**. Cluster EVC is off ([08-vsphere-ha-cluster.md](08-vsphere-ha-cluster.md), Step 6), and per-VM EVC can only be changed while the VM is off.

**3c. Quick checks.** MGMT-VLAN10 is VLAN 10 on both hosts, and the ESXI-N1 VM has Expose hardware assisted virtualization ticked (otherwise this VM can't run on 10.10.10.24). Then Power On and Launch Web Console.

## Step 4: Install Ubuntu

The installer is text-based (arrows/Tab to move, Space to tick, Enter to choose). Wording can shift slightly between installer versions; keep defaults for anything not listed.

| # | Screen | Choose |
|---|---|---|
| 1 | Boot menu | Try or Install Ubuntu Server |
| 2 | Language | English |
| 3 | Installer update (if offered) | Continue without updating (updating is also safe) |
| 4 | Keyboard | English (US) |
| 5 | Type of installation | Ubuntu Server (not minimized); no third-party drivers |
| 6 | Network | ens192 > Edit IPv4 ("autoconfiguration failed" is normal: VLAN 10 has no DHCP) |
| 7 | IPv4 | Manual; subnet 10.10.10.0/24; address .41 or .42; gateway 10.10.10.1; name servers `192.168.1.1,1.1.1.1`; search domains blank |
| 8 | Network check | ens192 shows static address; Done |
| 9 | Proxy | Blank |
| 10 | Mirror | Wait for "This mirror location passed tests" (proves address, gateway, DNS and the router route) |
| 11 | Storage | Use an entire disk, LVM on, **no** LUKS encryption (an encrypted VM can't boot unattended) |
| 12 | Storage summary | `/` gets about 10 GB; the rest stays free in the VG (fixed in 6b) |
| 13 | Confirm | Continue (it's the VM's new empty disk) |
| 14 | Profile | Server name ts-router / rancid-01; your own admin username and password (this guide uses `labadmin`) |
| 15 | Ubuntu Pro | Skip for now |
| 16 | SSH | Install OpenSSH server, allow password authentication |
| 17 | Snaps | None |
| 18 | Complete | Reboot Now after security updates finish (5 to 15 minutes) |

## Step 5: First boot

1. In vCenter, change CD/DVD drive 1 to **Client Device** so the ISO is fully disconnected. The ISO is on ESXI-01's local vmstore, so until this is done the VM can't move to or restart on 10.10.10.24.
2. Log in once on the web console and run `ip -br a`: ens192 should be UP with the VM's address.
3. From now on, work over SSH from the laptop: `ssh labadmin@10.10.10.41` (or .42). Type `yes` the first time.

## Step 6: Baseline setup

Same on both VMs. Ubuntu 26.04 ships sudo-rs, which behaves the same for everything here.

```bash
# 6a. Updates, reboot only if needed
sudo apt update && sudo apt -y full-upgrade
[ -f /var/run/reboot-required ] && sudo reboot

# 6b. Give / the rest of the disk (about 17 GB afterwards)
df -h /
sudo lvextend -r -l +100%FREE /dev/ubuntu-vg/ubuntu-lv
df -h /

# 6c. Time zone and clock (chrony; RANCID stamps changes with this clock)
sudo timedatectl set-timezone America/New_York
timedatectl
chronyc sources | head -4

# 6d. VMware Tools, automatic security updates, hostname
systemctl is-active open-vm-tools
systemctl is-enabled unattended-upgrades
hostnamectl --static

# 6e. Where the network settings live
ls /etc/netplan
sudo cat /etc/netplan/*.yaml
```

Look for: `successfully resized`, `System clock synchronized: yes` with a source marked `^*`, `active` / `enabled` / the right hostname, and a netplan file (`00-installer-config.yaml` on 26.04) with the address, `via: 10.10.10.1`, and both name servers. To change the address later, edit that file and run `sudo netplan apply`.

**6f. Firewall.** Leave ufw **off on TS-ROUTER**: its default rules drop forwarded traffic, which subnet routing needs. On RANCID-01 it's optional (RANCID guide). Neither VM accepts anything from the internet.

## Step 7: Finish in vCenter

**7a. HA restart priority.** Lab-Cluster > Configure > VM Overrides > Add, select **TS-ROUTER**, override VM Restart Priority to **High** so remote access comes back first. Leave every other override unchecked. RANCID-01 needs no override (cluster default Medium). Lab-Cluster > Monitor > vSphere HA should count the VM as protected.

> While the second host is the nested ESXI-N1, an ESXI-01 failure takes both hosts down, so HA can't restart these VMs until ESXI-01 returns. The settings still cost nothing and fully protect them once a physical ESXI-03 joins. After a full power cut, NAS-01 must finish booting first: power on vcsa, then these VMs once nfs-vm-shared shows accessible.

If DRS (Partially Automated) recommends moving these VMs to 10.10.10.24, simply don't apply it to keep them on 10.10.10.21.

**7b. VMware Tools.** VM Summary shows host 10.10.10.21, VMware Tools Running, and the VM's IP.

**7c. Baseline snapshot.** Snapshots > Take Snapshot `clean-baseline`. Delete it once the follow-on guide is working; snapshots grow and slow the disk.

**7d. Prove it can move.** With a continuous ping and an SSH session open, Migrate > Change compute resource only > 10.10.10.24 (MGMT-VLAN10 to MGMT-VLAN10), then back to 10.10.10.21:

| # | Where | Expect |
|---|---|---|
| 1 | Recent Tasks | Relocate virtual machine completes in under a minute |
| 2 | VM > Summary | Host changes, still Powered On |
| 3 | Ping and SSH | At most one or two lost pings; SSH stays connected |
| 4 | `uptime` | Keeps counting (live move, not a reboot) |
| 5 | Monitor > Events | Migration ... completed |

Then repeat Steps 3 to 7 for the other VM (the ISO is already uploaded).

## Checklist

| Check | TS-ROUTER | RANCID-01 |
|---|---|---|
| On 10.10.10.21, disk on nfs-vm-shared | 3 | 3 |
| Per-VM EVC Haswell | 3b | 3b |
| SSH from the laptop | .41 | .42 |
| Updates installed, rebooted if needed | 6a | 6a |
| `/` about 17 GB | 6b | 6b |
| Eastern time, clock synchronized | 6c | 6c |
| open-vm-tools active, auto updates enabled | 6d | 6d |
| CD/DVD set to Client Device | 5 | 5 |
| HA protected, restart priority | 7a (High) | 7a (default) |
| Migrates to .24 and back with ping running | 7d | 7d |
| clean-baseline snapshot | 7c | 7c |

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Mirror test fails | Typo in address, gateway or DNS | Back to screen 6 and recheck |
| Mirror test fails, values right | Wrong port group, or router route missing | Check the adapter is MGMT-VLAN10; ping 10.10.10.1 from another lab device |
| VM boots into the installer again | ISO still connected | CD/DVD to Client Device, restart |
| `ssh: connection timed out` | Laptop has no path to 10.10.10.0/24 | Service port, or add the 10.10.0.0/16 route |
| REMOTE HOST IDENTIFICATION HAS CHANGED | Reinstalled at the same address | `ssh-keygen -R 10.10.10.41`, connect again |
| lvextend: insufficient free space | `/` already has the whole disk | Nothing to do |
| `synchronized: no` | chrony can't reach the internet yet | Wait 2 minutes; check `ping 1.1.1.1` |
| Built TS-ROUTER at .40 | Clashes with veeam01 | `sudo sed -i 's#10.10.10.40/24#10.10.10.41/24#' /etc/netplan/*.yaml`, `sudo netplan apply`, reconnect to .41 |
| VMware Tools: Not running | open-vm-tools missing | `sudo apt -y install open-vm-tools` |
| nfs-vm-shared not offered | Not mounted on 10.10.10.21 | Mount it on every host (HA guide Step 8) |
| Migrate: MGMT-VLAN10 not accessible | Port group missing or misnamed on the destination | Create it with the identical name and VLAN 10 |
| Moved to .24, no network | Wrong VLAN there, or NESTED-TRUNK not Accept | VLAN 10; NESTED-TRUNK security all Accept |
| Migrate fails: CPU incompatible | No per-VM EVC | Power off, set Haswell (3b), power on |
| VT-x / VHV disabled error | ESXI-N1 VM lacks hardware-assisted virtualization | Maintenance mode on .24, shut down ESXI-N1, tick it, power on |
| Migration fails on the CD/DVD | CD still points at the ISO on vmstore, which 10.10.10.24 can't see | Client Device (Step 5) |
| VM listed as unprotected | Not on nfs-vm-shared, or HA not configured on a host | Check Storage on the Summary; check Monitor > vSphere HA |
| Both VMs off after a power cut | Hosts booted before NAS-01 | Wait for the datastore, then power them on |
