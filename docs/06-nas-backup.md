# 06. NAS-01 Backup Target

WD MyCloud EX2 Ultra as the backup destination for the lab: vCenter file-based backups, ESXi host configuration bundles, and VM backups with Veeam Backup & Replication Community Edition. Do this after the ESXi re-IP and vCenter deployment.

## Why three layers

| Layer | Protects | Tool | Share |
|---|---|---|---|
| vCenter config | Inventory, settings, roles, SSO, database | VAMI file-based backup (built in) | `vcenter-backup` |
| ESXi host config | Networking, vSwitch, port groups, storage settings | `vim-cmd` or PowerCLI (built in) | `esxi-config` |
| Virtual machines | VM disks, settings, guest files | Veeam B&R Community Edition (free) | `vm-backup` |

vSphere has no built-in VM backup, so Veeam covers that layer through the vSphere backup APIs. Restore order after a failure: rebuild the host, restore vCenter, then restore VMs.

The VM datastore spans two NVMe drives with no redundancy, so these backups are the real protection. Keep VMs and their backups on different devices.

## Addresses, shares and accounts

| Item | Value | Notes |
|---|---|---|
| NAS-01 | 10.10.30.10/24, gw 10.10.30.1, DNS 192.168.1.1 + 1.1.1.1 | CORE-SW1 Gi1/0/2, VLAN 30 |
| veeam01 (VM) | 10.10.10.40/24, gw 10.10.10.1 | MGMT-VLAN10 port group |
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

11. **veeam01 VM:** Windows Server (evaluation is fine), 4 vCPU, 16 GB RAM, 100 GB thin, MGMT-VLAN10, static 10.10.10.40. Test the three paths:

```powershell
Test-NetConnection 10.10.10.22 -Port 443   # vCenter
Test-NetConnection 10.10.10.21 -Port 902   # ESXi NBD data transfer
Test-NetConnection 10.10.30.10 -Port 445   # NAS SMB
```

12. **Install** B&R Community Edition (no license file), then add vCenter (not the host) under Managed Servers so Veeam follows VMs between hosts.
13. **Repository:** SMB share `\\10.10.30.10\vm-backup` with `svc-veeam`, automatic gateway, **limit concurrent tasks to 2** (dual-core ARM, single 1 GbE).
14. **Job "Lab VMs daily":** protected VMs (not veeam01 itself), repository NAS-01, 7-day retention, daily 1:00 AM, application-aware processing optional.
15. **Run and prove a restore:** Entire VM restore to a new name with the network **Disconnected**, boot it, then delete it.

## Part 5: Keep it healthy

| Task | How often |
|---|---|
| Check last vCenter backup (VAMI > Backup > Activity) | Weekly |
| Check Veeam job results | Weekly |
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
