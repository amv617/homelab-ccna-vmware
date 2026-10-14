# 08. Nested HA Member (ESXI-N1)

Builds a second ESXi host as a VM on ESXI-01, called ESXI-N1, and joins it to **Lab-Cluster** to practice vSphere HA, vMotion and DRS before buying a second server. It connects straight into the lab VLANs through a trunk port group, shares an NFS datastore with ESXI-01, and is removed cleanly when real hardware arrives.

## What it's good for

| You can practice | You can't |
|---|---|
| Cluster creation, EVC, HA and DRS settings | Survive a real ESXI-01 failure (everything runs on it) |
| Primary election, heartbeats, HA events and alarms | Fail ESXI-01 as a test |
| Automatic VM restart when ESXI-N1 fails | Realistic performance |
| vMotion, Storage vMotion, maintenance mode | Protect anything important |

The HA mechanics are identical to a physical cluster, so everything configured here carries over when a second server arrives. This guide works alongside [07-vsphere-ha-cluster.md](07-vsphere-ha-cluster.md): it replaces that guide's Parts 1 and 2 (the physical ESXI-03) and reuses its Parts 3 to 6.

## Values

| Item | Value |
|---|---|
| VM name / hostname | ESXI-N1 / esxi-n1 |
| vmk0 (management, vMotion) | 10.10.10.24/24, VLAN 10, gateway 10.10.10.1 |
| vmk1 (NFS) | 10.10.30.24/24, VLAN 30, no gateway |
| Resources | 4 vCPU, 12 GB RAM, 40 GB thin on the local datastore |
| Port group on ESXI-01 | NESTED-TRUNK, VLAN 4095, security Accept x3 |
| Shared datastore | nfs-vm-shared (NFS export on NAS-01) |
| ESXi build | Same as ESXI-01 |

## Part 1: Prepare ESXI-01

1. **Capacity.** ESXi ~4 GB + vcsa 14 GB + veeam01 16 GB (can be off) + ESXI-N1 12 GB, about 46 of 64 GB.
2. **Upload the ESXi ISO** (same build as ESXI-01) to an `ISO` folder on the local datastore.
3. **Create NESTED-TRUNK** on vSwitch0: VM port group, VLAN ID **All (4095)**. Under Security, override and set **Promiscuous mode, MAC address changes, Forged transmits** to Accept. VLAN 4095 passes tags through so the nested host can tag its own VLANs; the Accept settings let nested VMs' MACs through. Scoping them to this one port group keeps the relaxed security away from other VMs. Expect occasional duplicate pings, harmless at lab scale.

## Part 2: Create the VM

| Setting | Value |
|---|---|
| Guest OS | Other > VMware ESXi 8.0 or later |
| Compatibility | ESXi 8.0 and later |
| CPU | 4, **Expose hardware assisted virtualization to the guest OS** |
| Memory | 12 GB |
| Disk | 40 GB thin; NVMe or VMware Paravirtual controller |
| NIC 1 and NIC 2 | NESTED-TRUNK, VMXNET3 |
| CD/DVD | ESXi ISO from datastore, connect at power on |
| Firmware | EFI, Secure Boot off |

## Part 3: Install ESXi

At the installer boot screen press Shift+O and append `systemMediaSize=min` so a 40 GB disk is enough. Install, disconnect the ISO, reboot. A warning about hardware virtualization means the CPU option above wasn't set.

## Part 4: Configure like a real host

### Step 7: Management network in the DCUI

F2, log in as root, Configure Management Network:

| DCUI item | Value |
|---|---|
| Network Adapters | vmnic0 and vmnic1 both selected |
| VLAN | 10 |
| IPv4 | Static 10.10.10.24 / 255.255.255.0, gateway 10.10.10.1 |
| DNS | 192.168.1.1; hostname **esxi-n1** (short name only) |
| Custom DNS Suffixes | lab.local |

> **Hostname field.** Type only `esxi-n1` there; the domain goes in Custom DNS Suffixes. If you type `lab.local` or `esxi-n1.lab.local` in the Hostname field, ESXi splits it at the first dot ("lab.local" becomes host `lab` in domain `local`) and the SSH prompt reads `[root@lab:~]`. Step 8b fixes it.

Apply and restart the management network, then run Test Management Network: OK pinging 10.10.10.1 and 192.168.1.1. From the workstation, ping 10.10.10.24 and open https://10.10.10.24/ui. NESTED-TRUNK carries the VLAN 10 tag out through ESXI-01's uplinks, so this works exactly as on a physical host.

### Step 8: Finish the host settings

Do these in order, all on ESXI-N1, before adding it to vCenter. Most of it is in ESXI-N1's own Host Client; check the address bar says **10.10.10.24**, not ESXI-01's 10.10.10.21, because the two look identical.

**8a. Enable SSH.** Host > Actions > Services > Enable Secure Shell (SSH). The yellow banner while SSH is on is expected; it gets turned off in 8g.

**8b. Fix the name, then regenerate the certificate.** `ssh root@10.10.10.24`, then:

```
[root@esxi-n1:~] hostname -f
esxi-n1.lab.local
```

If it prints anything else (`lab.local`, `localhost`), set the full name and check again:

```
esxcli system hostname set --fqdn=esxi-n1.lab.local
hostname -f
```

`--fqdn` sets host and domain together. Setting them separately also works, but both options need two dashes (`--host=esxi-n1 --domain=lab.local`); without them esxcli returns "Invalid option". The prompt shows the old name until you log out and back in.

With the name correct:

```
/sbin/generate-certificates
/etc/init.d/hostd restart
/etc/init.d/vpxa restart
```

The certificate is issued for whatever name the host has at that moment, so always fix the name first, and rerun these if the name ever changes. The Host Client drops when hostd restarts; reload after about 30 seconds. `vpxa` may say it isn't running yet, which is fine before the host joins vCenter. If ESXI-N1 is already in vCenter, it will show disconnected afterward: right-click > Connect and accept the new certificate.

**8c. NTP.** Host > Manage > System > Time & date > Edit NTP settings: enable the NTP client, startup policy Start and stop with host, server pool.ntp.org, Save. Then Manage > Services, select **ntpd**, and Start it; saving the settings alone doesn't start the service. Until it runs, `esxcli system ntp get` shows `PID: 0`; once running, `Time Synchronized` stays false for the first few minutes. Wait about 5 minutes before treating that as a problem.

**8d. MGMT-VLAN10 port group.** Networking > Port groups > Add port group: name `MGMT-VLAN10` (same capitalization as ESXI-01), VLAN 10, vSwitch0, security left on Inherit. Leave the Management Network port group (vmk0) alone; a VMkernel port group can't hold VMs.

**8e. VM-NET port group.** Same as 8d with name `VM-NET`, VLAN 20.

**8f. Storage VMkernel port (vmk1).** VMkernel NICs > Add VMkernel NIC: new port group `Storage`, vSwitch0, VLAN 30, MTU 1500, IPv4 static 10.10.30.24 / 255.255.255.0, default TCP/IP stack, **no** services checked. NFS uses vmk1 automatically because NAS-01 is on vmk1's own subnet; vMotion goes on vmk0 later.

**8g. Remove VM Network and verify.** Confirm VM Network has 0 VMs, then Actions > Remove (an untagged port group would drop VMs into native VLAN 999). Then over SSH:

```
[root@esxi-n1:~] esxcli network vswitch standard portgroup list
Name                Virtual Switch  Active Clients  VLAN ID
MGMT-VLAN10         vSwitch0        0               10
Management Network  vSwitch0        1               10
Storage             vSwitch0        1               30
VM-NET              vSwitch0        0               20
[root@esxi-n1:~] esxcli network ip interface ipv4 get
vmk0  10.10.10.24  255.255.255.0  10.10.10.255  STATIC  10.10.10.1
vmk1  10.10.30.24  255.255.255.0  10.10.30.255  STATIC  10.10.10.1
[root@esxi-n1:~] vmkping -I vmk1 10.10.30.10
[root@esxi-n1:~] esxcli system ntp get
```

Look for four port groups (VLANs 10, 10, 30, 20), both vmk addresses, a reply from NAS-01 out vmk1 (proves VLAN 30 crosses NESTED-TRUNK), and NTP with a non-zero PID and `Time Synchronized: true`. vmk1 showing gateway 10.10.10.1 is normal: ESXi 8 displays the host default gateway on any VMkernel port without its own, and NFS still leaves on vmk1. Then disable SSH.

| If this fails | Likely cause | Fix |
|---|---|---|
| `vmkping -I vmk1 10.10.30.10` no reply | Storage VLAN not 30, NAS not yet at 10.10.30.10, or NESTED-TRUNK not 4095 | Check 8f, NAS address, NESTED-TRUNK VLAN |
| Fails out vmk1 but works with `-I vmk0` | ESXI-01 drops vmk1's own MAC | NESTED-TRUNK security: all three set to Accept with Override, not Inherit |
| `hostname -f` shows the wrong name | Domain typed into the DCUI Hostname field | `esxcli system hostname set --fqdn=esxi-n1.lab.local`, then rerun 8b |
| esxcli "Invalid option" | Single dash before an option | Use `--fqdn=`, `--host=`, `--domain=` |
| NTP `PID: 0` | ntpd never started | Start ntpd in Manage > Services, or `/etc/init.d/ntpd start` |
| `Time Synchronized: false` | Normal right after start | Wait about 5 minutes |
| Port group name already exists | Created earlier | Edit the existing one's VLAN instead |
| Remove greyed out for VM Network | Something still uses it | Move that VM to MGMT-VLAN10 first |

## Part 5: Join the cluster

9. Do these steps from [07-vsphere-ha-cluster.md](07-vsphere-ha-cluster.md), using ESXI-N1 wherever it says ESXI-03:

| HA guide step | With ESXI-N1 |
|---|---|
| 3 and 4: datacenter and cluster | Lab-DC and Lab-Cluster, HA and DRS off for now |
| 5: add hosts | ESXI-01 (10.10.10.21) and ESXI-N1 (10.10.10.24) |
| 6: EVC | Intel Broadwell; both report the same E5-2690 v4, so no reboots |
| 7: NFS share | Include 10.10.30.24 in the host list (or 10.10.30.0/24) |
| 8: mount nfs-vm-shared | Select both ESXI-01 and ESXI-N1 |
| 9: vMotion on vmk0 | On both hosts |

ESXI-01 needs its own vmk1 (10.10.30.21, VLAN 30) to mount the NFS datastore.
10. **VM overrides:** ESXI-N1 VM with HA restart priority Disabled and DRS Disabled; vcsa DRS Disabled. Keeps DRS from moving the infrastructure under test.
11. **Startup order on ESXI-01:** vcsa first, then ESXI-N1 after ~300 seconds; shutdown action Guest shutdown.

## Part 6: Enable HA and test

12. **HA settings for the lab.** Follow HA guide Steps 11 and 12 with these adjustments:

| Setting | Value | Why |
|---|---|---|
| Admission control | Disabled | ESXI-N1 can't hold half of ESXI-01's load |
| Host isolation response | Power off and restart VMs | ESXI-N1 is wired through ESXI-01 |
| Heartbeat datastores | nfs-vm-shared + `das.ignoreInsufficientHbDatastore = true` | Clears the two-datastore warning |
| VM Monitoring | Disabled | Focus on host failure |

13. **Test VM** TEST-HA01 on ESXI-N1, datastore nfs-vm-shared, 1 vCPU / 1 GB / 8 GB thin, on a shared-name VLAN port group. Start a continuous ping to it.
14. **vMotion** it to ESXI-01 and back. At most one dropped ping proves storage, networking and EVC.
15. **Fail ESXI-N1:** hard power-off its VM. ESXI-N1 goes Not Responding; TEST-HA01 restarts on ESXI-01 within one to three minutes and Events shows the HA restart. Power ESXI-N1 back on; it rejoins.
    - **Isolation test:** disconnect both of ESXI-N1's vNICs while it runs; HA's isolation response restarts TEST-HA01 on ESXI-01.
    - **Never** test by powering off ESXI-01.

## Part 7: When a real second host arrives

1. Build the physical host as ESXI-03 with Parts 1 and 2 of [07-vsphere-ha-cluster.md](07-vsphere-ha-cluster.md), and add it to Lab-Cluster.
2. Put ESXI-N1 in maintenance mode, migrate its VMs off.
3. Remove ESXI-N1 from inventory, then delete the VM, its override and startup entry.
4. Remove 10.10.30.24 from the NFS allow list and delete NESTED-TRUNK.
5. Re-enable admission control (50%).

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Installer finds no disk | Unsupported controller | NVMe or VMware Paravirtual |
| ESXI-N1 can't power on VMs | Virtualization not exposed | Tick hardware-assisted virtualization |
| Test Management Network fails | VLAN not 10, or vNICs not on NESTED-TRUNK | Recheck DCUI and VM adapters |
| ESXI-N1 VMs have no network | NESTED-TRUNK security not Accept | Override all three to Accept |
| vmkping to NAS fails | Storage PG not VLAN 30, or trunk not 4095 | Fix VLAN IDs |
| EVC validation fails | Nested CPU missing a feature | Recheck CPU exposure; try Haswell or skip EVC |
| Insufficient failover resources | Admission control on | Disable it |
| Restarted VM has no network | Port group names differ | Make names identical |
| DUP! ping replies | Promiscuous mode with two vNICs | Harmless |
