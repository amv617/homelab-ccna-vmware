# 06. NAS-01 Backup Target

WD MyCloud EX2 Ultra as the backup destination for the lab: vCenter file-based backups, ESXi host configuration bundles, and VM backups with Veeam Backup & Replication Community Edition. Do this after the ESXi re-IP and vCenter deployment.

## Why three layers

| Layer | Protects | Tool | Share |
|---|---|---|---|
| vCenter config | Inventory, settings, roles, SSO, database | VAMI file-based backup (built in) | `vcenter-backup` |
| ESXi host config | Networking, vSwitch, port groups, storage settings | `vim-cmd` or PowerCLI (built in) | `esxi-config` |
| Virtual machines | VM disks, settings, guest files | Veeam B&R Community Edition (free) | `vm-backup` |

vSphere has no built-in VM backup, so Veeam covers that layer through the vSphere backup APIs. Restore order after a failure: rebuild the host, restore vCenter, then restore VMs.

vcsa, veeam01 and the ESXI-N1 VM live on **vmstore**, which spans both NVMe drives with no redundancy; if either drive fails, everything on it is lost, so these backups are their real protection. The cluster VMs (TS-ROUTER, RANCID-01) live on **nfs-vm-shared**, on this same NAS, so a NAS failure would take a VM and its backup together: keep a second copy of anything you can't rebuild somewhere else (Part 5).

## Addresses, shares and accounts

| Item | Value | Notes |
|---|---|---|
| NAS-01 | 10.10.30.10/24, gw 10.10.30.1, DNS 192.168.1.1 + 1.1.1.1 | CORE-SW1 Gi1/0/2, VLAN 30 |
| veeam01 (VM) | 10.10.10.40/24, gw 10.10.10.1, DNS 192.168.1.1 and 1.1.1.1 | MGMT-VLAN10, disk on ESXI-01's vmstore |
| `vcenter-backup` | R/W: `svc-vcenter` only | |
| `esxi-config` | R/W: NAS admin only | Recycle bin on |
| `vm-backup` | R/W: `svc-veeam` only | |
| `svc-vcenter`, `svc-veeam` | Standard users, not admins | One account per tool |

The HA cluster later adds a fourth share, `vm-shared`, exported over NFS to the hosts' VLAN 30 addresses only; see [08-vsphere-ha-cluster.md](08-vsphere-ha-cluster.md#part-3-shared-nfs-storage).

All backup traffic originates in VLAN 10 and is routed by CORE-SW1 to VLAN 30. Because the NAS's gateway is also CORE-SW1, replies take the same path back and never cross the home router.

## Part 1: Prepare the NAS

1. **Firmware and disks.** Update firmware; confirm the volume is **RAID 1**, Healthy, both drives Good. (Changing RAID mode erases the volume.)
2. **Remove iSCSI targets** (after the ESXi side is cleaned up) and turn iSCSI off, closing TCP 3260.
3. **Static address** 10.10.30.10/24, gateway 10.10.30.1, DNS 192.168.1.1 and 1.1.1.1. Move the cable to CORE-SW1 Gi1/0/2. Verify with `show interfaces g1/0/2 status` (connected, VLAN 30, 1000) and `ping 10.10.30.10`. The DHCP reservation in [02-core-sw1.md](02-core-sw1.md#optional-dhcp-reservation-for-the-nas) is an equivalent alternative.
4. **Time.** Local time zone, NTP on with pool.ntp.org, so timestamps match vCenter, ESXi and Veeam.
5. **Services.** SMB on, minimum SMB2 if offered. Turn off FTP, WebDAV and anything else unused. No cloud/remote access on the backup shares.
6. **Service accounts.** Create `svc-vcenter` and `svc-veeam` as non-admin users with strong passwords. Avoid `@`, `:` and `/`, which some tools misparse in SMB paths.
7. **Shares.** Public off, media serving off on all three. Recycle bin **off** on `vcenter-backup` and `vm-backup` (retention deletes would otherwise fill the volume), on for the manually managed `esxi-config`.
8. **Test** each share from a workstation (`smb://10.10.30.10/<share>` on macOS, `\\10.10.30.10\<share>` on Windows). Each account should write to its own share and be refused on the other. On Windows, run `net use * /delete` afterward.

## Part 2: vCenter file-based backup

9. VAMI at `https://10.10.10.22:5480` > Backup > Configure:

| Field | Value |
|---|---|
| Location | `smb://10.10.30.10/vcenter-backup/vcsa` |
| Credentials | `svc-vcenter` |
| Schedule | Daily 3:30 AM (after the 1:00 AM Veeam job) |
| Encryption | Optional; store the password safely or the backup is unrecoverable |
| DB health check | On |
| Retain | 7 |
| Stats, Events, Tasks | Unchecked |

10. **Backup Now** and confirm a dated folder with `backup-metadata.json` and archive files. Restore uses the same VCSA ISO with Restore instead of Install.

## Part 3: ESXi host configuration backup

Back up after networking or storage changes and before every ESXi update. A bundle restores only onto the identical build, so put the build and date in the file name.

- **Host shell:** `vim-cmd hostsvc/firmware/sync_config`, `vim-cmd hostsvc/firmware/backup_config`, download from the printed URL (replace `*` with the host IP), copy to `esxi-config`, disable SSH.
- **PowerCLI (all hosts):**

```powershell
Install-Module VMware.PowerCLI -Scope CurrentUser
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false
Connect-VIServer 10.10.10.22 -User administrator@vsphere.local
Get-VMHost | Get-VMHostFirmware -BackupConfiguration -DestinationPath \\10.10.30.10\esxi-config
```

Restore: host in maintenance mode, `Set-VMHostFirmware -VMHost <host> -Restore -SourcePath <bundle> -HostUser root`.

## Part 4: VM backups with Veeam Community Edition

Veeam Backup & Replication Community Edition is free for a small number of workloads (10 at the time of writing), which covers this lab. It runs on a Windows VM, reads VMs through vCenter, and writes backups to the `vm-backup` share.

### Step 12: Build the veeam01 VM

| Setting | Value | Why |
|---|---|---|
| VM name / computer name | veeam01 / VEEAM01 | Matches the address plan |
| Guest OS | Windows Server 2025 (or 2022) Standard Evaluation, **Desktop Experience** | Veeam's server runs on Windows with a GUI; the evaluation is free for 180 days |
| Host / datastore | 10.10.10.21 / **vmstore** | Not nfs-vm-shared: Veeam shouldn't run from the NAS it writes to, and it keeps working while the NAS reboots |
| vCPU / RAM | 4 / 16 GB | ESXI-01 then holds vcsa 14 GB, the ESXI-N1 VM 12 GB, two 2 GB Ubuntu VMs and veeam01: about 46 of 64 GB |
| Disk | 100 GB thin | Windows, Veeam and its config database; backups go to the NAS |
| Network | MGMT-VLAN10, VMXNET 3; static 10.10.10.40/24, gateway 10.10.10.1, DNS 192.168.1.1 and 1.1.1.1 | Same VLAN as vCenter and the hosts; CORE-SW1 routes to the NAS |

**12.1 ISO on vmstore.** Download the Windows Server evaluation ISO from Microsoft's Evaluation Center (64-bit, about 5 to 7 GB) and upload it to vmstore > ISO. If the upload fails at once, open https://10.10.10.21 in the same browser, accept the certificate, and retry. Keeping the ISO next to the VM means the install doesn't depend on the NAS.

**12.2 Create the VM.** Right-click 10.10.10.21 > New Virtual Machine: name veeam01, location Lab-DC itself, compute 10.10.10.21, storage **vmstore**, compatibility ESXi 8.0 and later, guest OS Windows Server 2025 (or 2022), Windows VBS **unticked**. Hardware: 4 CPU, 16 GB, 100 GB thin, network MGMT-VLAN10 with VMXNET 3, CD/DVD from vmstore > ISO with Connect At Power On. **Leave the disk controller at the wizard's default**: Windows Setup has drivers for it, but not for VMware Paravirtual. VM Options at defaults (EFI, Secure Boot on; Server needs no TPM).

**12.3 Install Windows Server.** Power on, open the web console, click inside it, and press a key at *Press any key to boot from CD or DVD* (it only waits a few seconds; Actions > Power > Reset if you miss it). Choose Install Windows Server, edition **Standard Evaluation (Desktop Experience)**, Custom install onto Disk 0. Set the Administrator password and record it. Use the web console's **Send Ctrl+Alt+Del** to sign in; your keyboard's combination goes to your own computer.

**12.4 VMware Tools.** In vCenter, Guest OS > Install VMware Tools > Mount; in Windows run `setup64.exe` from the VMware Tools DVD, Typical, reboot. Then set CD/DVD drive 1 to **Client Device**. Tools supplies the VMXNET 3 driver, so there's no network until this step.

**12.5 Address, name, time zone, updates.** In an elevated PowerShell:

```powershell
Get-NetAdapter                                         # note the Name, usually Ethernet0
New-NetIPAddress -InterfaceAlias "Ethernet0" -IPAddress 10.10.10.40 `
    -PrefixLength 24 -DefaultGateway 10.10.10.1
Set-DnsClientServerAddress -InterfaceAlias "Ethernet0" `
    -ServerAddresses 192.168.1.1,1.1.1.1
Set-TimeZone -Id "Eastern Standard Time"
Rename-Computer -NewName VEEAM01 -Restart
```

Then in Server Manager > Local Server: enable **Remote Desktop** (connect with `mstsc /v:10.10.10.40` on Windows or the Windows App on macOS), install **all Windows updates** before Veeam, and leave the Windows Firewall on (Veeam's installer opens what it needs).

**12.6 Tell the cluster.** veeam01 is on local vmstore, so HA can't restart it and vMotion can't move it without moving its storage. Mark it like vcsa: Lab-Cluster > Configure > VM Overrides > Add > veeam01, override **DRS automation level: Disabled** and **VM Restart Priority: Disabled**. Check its Summary shows VMware Tools Running, IP 10.10.10.40, host 10.10.10.21.

**12.7 Test the paths** from PowerShell on veeam01:

```powershell
Test-NetConnection 10.10.10.22 -Port 443   # vCenter
Test-NetConnection 10.10.10.21 -Port 902   # ESXI-01 data transfer (NBD)
Test-NetConnection 10.10.10.24 -Port 902   # ESXI-N1 data transfer, for VMs running there
Test-NetConnection 10.10.30.10 -Port 445   # NAS SMB
```

All four should show `TcpTestSucceeded : True`. Veeam finds VMs and takes snapshots through vCenter on 443, reads disks from whichever host runs the VM on 902, and writes to the NAS on 445.

> **Evaluation period.** `slmgr /dlv` shows the time left on the 180-day evaluation. `slmgr /rearm` plus a reboot extends it a limited number of times; after that, rebuild veeam01 and import the `vm-backup` repository.

### Step 13: Install Veeam and add vCenter

1. Download Veeam B&R Community Edition from veeam.com (free account), mount the ISO, run Setup with **no license file** (it runs as Community Edition), default components.
2. Open the console, leave **localhost**, and Connect (Use Windows session authentication, or `VEEAM01\Administrator`). Console and backup server are both on veeam01.
3. Backup Infrastructure > Managed Servers > Add Server > VMware vSphere > **vSphere**: 10.10.10.22, `administrator@vsphere.local`, accept the certificate. Adding vCenter rather than the host means Veeam follows VMs between hosts.
4. Also add **ESXI-01 on its own**: Add Server > VMware vSphere > **ESXi**, 10.10.10.21 with root. This lets Veeam restore vcsa straight to the host when vCenter itself is down.

### Step 14: Add the NAS as a repository

Backup Repositories > Add Repository > Network attached storage > SMB share: name `NAS-01 vm-backup`, folder `\\10.10.30.10\vm-backup`, credentials `svc-veeam` (or `10.10.30.10\svc-veeam`), gateway Automatic, **limit concurrent tasks to 2** (dual-core ARM, single 1 GbE). Leave the default repository for Veeam's own configuration backups.

### Step 15: Create the backup job

Home > Backup Job > Virtual machine, name **Lab VMs daily**. Add from Hosts and Clusters > 10.10.10.22 > Lab-DC > Lab-Cluster:

| VM | In this job? | Why |
|---|---|---|
| RANCID-01 | Yes | Its switch-config history is the one thing in the lab you can't rebuild |
| TS-ROUTER | Yes | Restoring is quicker than rebuilding and re-joining Tailscale |
| vcsa | Yes, as a second layer | The VAMI backup (Part 2) stays the main vCenter backup; this is a faster whole-VM restore if that fails |
| veeam01 | No | A backup server backing itself up mid-job gives unreliable copies; reinstall and import the repository instead |
| ESXI-N1 (VM) | No | Quicker to rebuild; its test VMs live on nfs-vm-shared, not inside it |

Alternatively add Lab-Cluster itself with exclusions for veeam01, ESXI-N1 and vCLS, so new VMs are backed up automatically (Community Edition covers up to 10 workloads).

| Storage page | Choose | Why |
|---|---|---|
| Backup proxy | Automatic | veeam01 is the only proxy |
| Repository | **NAS-01 vm-backup** | Not *Default Backup Repository*, which is veeam01's own C: drive on vmstore: it would fill the disk and sit on the same NVMe as vcsa |
| Retention | 7 days | A week of daily restore points |
| GFS (keep fulls longer) | Unticked | Would fill the NAS |
| Secondary destinations | Unticked for now | Where an off-NAS copy goes later |

Guest Processing: application-aware processing **off** (Linux VMs plus vcsa, no Windows databases). Schedule: **daily at 1:00 AM**, which finishes before the 3:30 AM VAMI backup. Finish without running yet.

**Restoring vcsa** when vCenter is down: Entire VM restore straight to the standalone 10.10.10.21 added in Step 13. The VAMI file-based backup remains VMware's preferred way back when available.

### Step 15b: Keep the job running every night

Veeam runs as Windows services, so nobody needs to be signed in, but at 1:00 AM all of these must be up: **veeam01**, **vcsa**, **the host running each VM** (port 902), and **NAS-01**.

1. `services.msc`: the Veeam services (Veeam Backup Server and its database service) are Running and Automatic.
2. Windows Update > Advanced options: set active hours to cover roughly midnight to 5 AM so updates don't restart veeam01 mid-job.
3. After an outage, power on vcsa first, then veeam01, then ESXI-N1 and the other VMs ([08-vsphere-ha-cluster.md](08-vsphere-ha-cluster.md), Step 10); if NAS-01 is still booting, wait for nfs-vm-shared to show accessible.

A missed night isn't caught up: the job just runs at its next scheduled time. Home > Last 24 hours is how you spot a gap.

### Step 16: Run it, then prove a restore works

Start the job (the first full over 1 GbE takes a while; vcsa is the biggest), confirm **Success** and `.vbk` files in `vm-backup`, then do an Entire VM restore of one VM to a new name with the network **Disconnected**, boot it, and delete it. A backup you have never restored is only a hope.

## Part 5: Keep it healthy

| Task | How often |
|---|---|
| Check last vCenter backup (VAMI > Backup > Activity) | Weekly |
| Check Veeam job results (Home > Last 24 hours), including nights the job didn't run | Weekly |
| Add new VMs to the job (unless it targets Lab-Cluster) | When you build a VM |
| Check veeam01's Windows evaluation (`slmgr /dlv`) | Monthly |
| NAS free space, keep 20%+ free | Monthly |
| NAS email alerts for drive/RAID | Once |
| Host config backup | After changes, before updates |
| Restore drill | Monthly |

For anything irreplaceable, add a rotated off-site copy (3-2-1 rule).

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| VAMI invalid credentials or location | Path format, permissions, special characters | `smb://10.10.30.10/vcenter-backup/vcsa`; simplify password |
| VAMI backup stalls | NAS still on the home LAN, replies via router | Finish step 3; gateway 10.10.30.1 |
| Veeam can't add repository | SMB1 only, credential format, 445 blocked | SMB2+; try `10.10.30.10\svc-veeam`; test port 445 |
| Veeam can't reach host | Port 902 or name resolution | Test 902; add host DNS entry or add host by IP |
| 30 to 100 MB/s | 1 GbE + ARM NAS | Normal; keep 2 concurrent tasks |
| Share filling despite retention | Recycle bin on | Turn it off and empty it |
| veeam01 boots to a blank screen or EFI menu | Missed "Press any key" | Actions > Power > Reset, click in and press a key right away |
| Windows Setup can't find a disk | Controller switched to VMware Paravirtual | Set it back to the wizard default (LSI Logic SAS or NVMe) |
| No network in Windows after install | VMXNET 3 needs the VMware Tools driver | Install VMware Tools (12.4) |
| Only a command prompt after install | Edition without Desktop Experience | Reinstall with Desktop Experience |
| Port 902 test fails for one host | Host unreachable from VLAN 10, or a typo | Ping its vmk0; check it's connected in vCenter |
| Console can't connect to localhost | Veeam services stopped | `services.msc`: start Veeam Backup Server and its database service, set Automatic |
| Last night's job didn't run | veeam01, vcsa or the NAS was off, or Windows restarted | Power everything on (15b), set active hours, run the job by hand |
| veeam01's C: drive filling | Job pointed at Default Backup Repository | Job > Storage > NAS-01 vm-backup; delete the old backups |
| Can't restore vcsa: vCenter unavailable | Veeam only knows the hosts through vCenter | Add 10.10.10.21 as a standalone ESXi host (Step 13) and restore to it |
