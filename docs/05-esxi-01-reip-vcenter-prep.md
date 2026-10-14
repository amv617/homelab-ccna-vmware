# 05. ESXI-01 Re-IP, IPMI and vCenter Prep

Supermicro X10SRW-F running ESXi 8. Moves the host's management address from the home LAN to VLAN 10 (10.10.10.21), sets up the IPMI remote console, cables both NICs to the access switches as trunks, builds the port groups vCenter needs, and adds an optional storage VMkernel port. Do this after the three switch guides and **before** deploying vCenter.

## Why re-IP before vCenter

vCenter stores the address and name of every host it manages, and its own identity is fixed at deployment. Moving the host first means vCenter is born at its final address (10.10.10.22) next to a host already at its final address, and makes it safe to use the appliance IP as its system name if DNS isn't solid.

## Target settings

| Setting | Value |
|---|---|
| Hostname / suffix | esxi-01 / lab.local |
| vmk0 (management) | 10.10.10.21/24, VLAN 10, gateway 10.10.10.1 |
| DNS | 192.168.1.1 |
| Uplinks | vmnic0 to ACCESS-SW1 Gi1/0/1, vmnic1 to ACCESS-SW2 Gi1/0/1, both active |
| Port groups | Management Network (10), MGMT-VLAN10 (10), VM-NET (20), Storage (30, optional) |
| vmk1 (optional) | 10.10.30.21/24, VLAN 30, no gateway |
| IPMI (BMC) | 10.10.10.30/24, gateway 10.10.10.1, dedicated port to ACCESS-SW2 Gi1/0/2 |
| NTP | pool.ntp.org |

## Part 1: Before you start

| Check | How |
|---|---|
| CORE-SW1 done | `show ip interface brief \| include Vlan` shows the three .1 SVIs |
| Access switches done | `show etherchannel summary` shows Po(SU) on each |
| ESXi ports ready | `show run int g1/0/1` on each access switch: trunk 10,20,30, native 999 |
| Local console | Monitor and keyboard until the IPMI console works |
| IPMI cabled | Dedicated IPMI port to ACCESS-SW2 Gi1/0/2 (access VLAN 10) |
| No running VMs | Host Client shows 0 powered on |

1. **Add a direct workstation route** for 10.10.0.0/16 via 192.168.1.250, even if the router route works. The vCenter installer holds long HTTPS sessions, and the direct route avoids the asymmetric-path problem described in [03-home-router.md](03-home-router.md#known-issue-asymmetric-path).
2. **Back up the host config** while still on the old address: `vim-cmd hostsvc/firmware/sync_config` then `vim-cmd hostsvc/firmware/backup_config`, and download the bundle.
3. **Remove iSCSI datastores and targets** if the NAS previously served iSCSI LUNs. Move anything you need to the local datastore, delete the iSCSI datastores, remove dynamic and static targets, and rescan. The host side must go before the NAS side to avoid an all-paths-down state.

## Part 1B: IPMI remote console

The BMC is a separate controller with its own port, so once its iKVM works you have a console that survives any host network mistake. Get this working before touching the host network.

- **A. BIOS:** press Delete at POST, open IPMI > BMC Network Configuration, set Update IPMI LAN Configuration to Yes.
- **B. Dedicated port:** set the LAN interface to **Dedicated**, not Shared or Failover. In Failover/Shared mode the BMC can fall back to LAN1, which is a trunk with native VLAN 999, and its untagged frames vanish.
- **C. Address**, pick one:
  - **Option A, static:** Address Source Static, 10.10.10.30/24, gateway 10.10.10.1, VLAN **disabled** (the switch port is an access port, so the BMC sends untagged frames). F4 to save.
  - **Option B, DHCP reservation on CORE-SW1:** Address Source DHCP, then create the `IPMI-ESXI01` pool from [`configs/optional/core-sw1-dhcp-reservations.cfg`](../configs/optional/core-sw1-dhcp-reservations.cfg) with the BMC's MAC (shown in the BIOS as Station MAC Address). ACCESS-SW2 just carries the broadcast up the trunk; CORE-SW1 answers, so no helper address is needed. If no lease appears, use the debug procedure in [02-core-sw1.md](02-core-sw1.md#optional-dhcp-reservation-for-the-nas) to see whether the BMC sends a client identifier.
- **D. Verify:** `show interfaces g1/0/2 status` on ACCESS-SW2 (connected, VLAN 10, often 100 Mbps), a MAC learned on Gi1/0/2, and `ping 10.10.10.30` from CORE-SW1.
- **E. Secure it:** browse to https://10.10.10.30, log in with the factory credentials from the board label, and immediately set a strong ADMIN password. Set DNS 192.168.1.1 and hostname esxi-01-ipmi.
- **F. Test iKVM:** Remote Control > iKVM/HTML5, confirm the DCUI appears and the keyboard works. Older firmware may offer only a Java console; update the BMC firmware or keep the local monitor.

## Part 2: Change the management network (DCUI, via iKVM)

4. F2, log in as root, Configure Management Network.
5. **Network Adapters:** select both vmnic0 and vmnic1. Note each MAC for later.
6. **VLAN:** 10. Without it, untagged frames land in native VLAN 999 and go nowhere.
7. **IPv4:** static 10.10.10.21 / 255.255.255.0, gateway 10.10.10.1.
8. **DNS:** 192.168.1.1 only (a public alternate would answer "no such name" for lab entries), hostname esxi-01, custom suffix lab.local.
9. **Apply** and restart the management network. The old Host Client session drops; iKVM is unaffected.
10. **Move cables:** vmnic0 to ACCESS-SW1 Gi1/0/1, vmnic1 to ACCESS-SW2 Gi1/0/1.

## Part 3: Verify

11. DCUI Test Management Network: OK pinging 10.10.10.1 and 192.168.1.1.
12. On each access switch, `show mac address-table int g1/0/1` shows the host MAC in VLAN 10 (only one switch at first; originating-port teaming uses one uplink per virtual port). On CORE-SW1, `ping 10.10.10.21` and `show ip arp 10.10.10.21`.
13. From the workstation, ping and trace 10.10.10.21; the first hop should be 192.168.1.250. Then open https://10.10.10.21/ui.
14. **Regenerate the host certificate** for the new name: `/sbin/generate-certificates`, then restart `hostd` (and `vpxa`). Disable SSH afterward.

## Part 4: Build vSwitch0 for vCenter

15. Confirm vSwitch0 has both uplinks **active**, load balancing Route based on originating port ID, failover detection Link status only.
16. Add port groups **MGMT-VLAN10** (VLAN 10) and **VM-NET** (VLAN 20). Remove the default untagged **VM Network**. On a standard vSwitch a port group carries VMkernel ports or VMs, not both, so vCenter needs its own VLAN 10 VM port group.
17. *(Optional)* Add **vmk1** on a new **Storage** port group, VLAN 30, static 10.10.30.21/24, no services. Not required while the NAS is only a backup target; useful later for NFS.
18. Verify over SSH:

```
esxcli network ip interface ipv4 get
esxcli network vswitch standard portgroup list
vmkping -I vmk1 10.10.30.1        # only if step 17 was done
```

19. **NTP:** pool.ntp.org, start and stop with host. vCenter and its hosts rely on time-bounded certificates and tokens, so clocks must agree.

## Part 5 (optional): Reconnect iSCSI

Only if you kept iSCSI datastores instead of deleting them. After the NAS moves to 10.10.30.10, remove the old dynamic and static targets, add a dynamic target 10.10.30.10:3260, rescan, and mount, keeping the existing signature.

## Part 6: vCenter installer values

| Field | Value |
|---|---|
| Target host | 10.10.10.21, port 443, root |
| VM name | vcsa |
| Size | Tiny (2 vCPU, 14 GB RAM) |
| Datastore | Local NVMe datastore, thin disk mode |
| Network | MGMT-VLAN10 |
| IP | Static 10.10.10.22/24, gateway 10.10.10.1 |
| System name (FQDN) | 10.10.10.22, unless forward and reverse DNS both work for vcsa.lab.local |
| DNS | 192.168.1.1 |
| NTP | pool.ntp.org |
| SSO domain | vsphere.local |

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| DCUI can't ping 10.10.10.1 | VLAN not 10, wrong cable, trunk down | Recheck VLAN; `show interfaces trunk` on the access switch |
| Pings .1 but not 192.168.1.1 | Wrong host gateway | Gateway 10.10.10.1 |
| Host Client hangs or logs out | Asymmetric path via router | Add the workstation route; first hop must be .250 |
| Only one NIC has link | Second cable, or port err-disabled | `show interfaces status err-disabled`, shut/no shut |
| Certificate name warnings | Cert still for old name | Regenerate (step 14) |
| BMC unreachable | Failover/Shared mode, VLAN tagging on, or wrong port | Dedicated, VLAN disabled, dedicated IPMI port |
| iKVM black window | Pop-up blocked | Allow pop-ups for 10.10.10.30 |
| Locked out after bad change | Wrong VLAN or IP | DCUI Network Restore Options via iKVM, restart from step 4 |
