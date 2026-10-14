# 02. CORE-SW1 (Cisco 3750-X)

Layer 3 core. Routes the lab VLANs, uplinks to the home router, and enables SSH from home workstations. **Build this switch first.**

Full paste-ready config: [`configs/core-sw1.cfg`](../configs/core-sw1.cfg)

## What it configures

| Setting | Value |
|---|---|
| Hostname | CORE-SW1 |
| SSH address | 192.168.1.250 on Gi1/0/1 (routed uplink) |
| Default route | 0.0.0.0/0 via 192.168.1.1 |
| VLAN gateways | Vlan10 10.10.10.1, Vlan20 10.10.20.1, Vlan30 10.10.30.1 |
| DHCP | VLAN 20 pool, 10.10.20.100 to .199 |
| Gi1/0/2 | NAS-01, access VLAN 30 |
| Gi1/0/21-22 (Po1) | LACP trunk to ACCESS-SW1 |
| Gi1/0/23-24 (Po2) | LACP trunk to ACCESS-SW2 |
| Gi1/0/3-20 | Unused, shut down in VLAN 999 |
| SSH allowed from | 192.168.1.0/24 and 10.10.10.0/24 |

## Console access

RJ45 console port, 9600 8N1, no flow control. Use only the RJ45 port; if the mini-USB console is also connected, the switch uses that one.

- **macOS:** `ls /dev/cu.*`, then `screen /dev/cu.usbserial-XXXX 9600`. Exit with Ctrl-A, K, Y.
- **Windows:** note the COM port in Device Manager; in PuTTY choose Serial, 9600, and set Flow control to **None** (XON/XOFF can freeze the console).

## Steps

1. **Check and wipe.** `show running-config | include hostname|interface Vlan|ip address|vtp` and `show vlan brief`. If an old config exists: `write erase`, `delete flash:vlan.dat`, `reload`.
2. **License and image.** `show version`: image must contain `universalk9`; license must be `ipbase` or `ipservices`. On `lanbase`, `ip routing` and `no switchport` are rejected.
3. **Base settings.** Hostname, `no ip domain-lookup`, enable secret, local admin user, password encryption, log timestamps, banner, console `login local`.
4. **VLANs and STP.** `vtp mode transparent`; VLANs 10 MGMT, 20 VM-NET, 30 STORAGE, 999 NATIVE-UNUSED; `spanning-tree mode rapid-pvst`.
5. **Routed uplink.** Clear any leftover Vlan1 address, `no ip default-gateway`, `ip routing`, Gi1/0/1 `no switchport` with 192.168.1.250/24, default route to 192.168.1.1.
6. **SVIs and DHCP.** One SVI per VLAN; VM-NET DHCP pool with .1 to .99 and .200 to .254 excluded.
7. **Ports.** STP root primary for all lab VLANs; Gi1/0/2 access VLAN 30 with portfast and BPDU Guard; Po1/Po2 trunks (the 3750-X needs `switchport trunk encapsulation dot1q` before `switchport mode trunk`); unused ports shut in VLAN 999.
8. **SSH.** `ip domain-name lab.local`, 2048-bit RSA key, SSH v2, `MGMT-SSH` standard ACL, VTY `transport input ssh` and `access-class MGMT-SSH in`.
9. **Save.** `copy running-config startup-config`.

## Optional: DHCP reservation for the NAS

Instead of a static address on the NAS, CORE-SW1 can hand it 10.10.30.10 through a manual binding. Template with placeholders: [`configs/optional/core-sw1-dhcp-reservations.cfg`](../configs/optional/core-sw1-dhcp-reservations.cfg).

- Find the NAS MAC with `show mac address-table interface Gi1/0/2` or on the device label.
- If the device sends a DHCP client identifier, match with `client-identifier 01` + MAC (regrouped into dotted sets of four hex digits). If not, match with `hardware-address` + MAC. Use one, never both.
- To see which the device sends: `debug ip dhcp server packet`, bounce the device's link, read the value after `DHCPDISCOVER received from client`, then `undebug all`. Over SSH, run `terminal monitor` first.
- No `ip helper-address` is needed because CORE-SW1 owns VLAN 30 directly.
- If 10.10.30.10 shows under `show ip dhcp conflict`, run `clear ip dhcp conflict *` and bounce the NAS.
- A static address on the NAS works identically if the reservation won't take.

## Verification

| Check | Not cabled yet | Cabled |
|---|---|---|
| `show ip interface brief` | Gi1/0/1, Gi1/0/2, all Vlan down | Gi1/0/1, Gi1/0/2, Vlan30 up/up |
| `show ip route` | No gateway of last resort | `S* 0.0.0.0/0 via 192.168.1.1` plus connected |
| `show vlan brief` | 10, 20, 30, 999 listed | Same, Gi1/0/2 in VLAN 30 |
| `show etherchannel summary` | Po1(SD), Po2(SD) | Po1(SU)/Po2(SU) once access switches are built |
| `ping 192.168.1.1` | Fails | `.!!!!` or `!!!!!` |
| `show ip ssh` | SSH Enabled, version 2.0 | Same |

The default route only appears once Gi1/0/1 is up, because its next hop is only reachable through that link.

## Reaching the lab from workstations

Either add the static route on the home router ([03-home-router.md](03-home-router.md)), or add a per-workstation route (see [01-network-design.md](01-network-design.md#routing)). Test from CORE-SW1 with `ping 8.8.8.8 source Vlan10`: success means the router routes back to the lab and NATs it.

For SSH, copy the host blocks from [`ssh/config.example`](../ssh/config.example); IOS offers an `ssh-rsa` host key that current OpenSSH refuses by default.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `% Invalid input` at `ip routing` or `no switchport` | LAN Base license | Check `show version` license |
| 192.168.1.0 overlaps with Vlan1 | Leftover VLAN 1 address | Clear Vlan1 first (step 5) |
| Po1/Po2 (SD), members (I) or (s) | Access switch not built or miscabled | Check both ends with `show etherchannel summary` |
| SSH to .250 works, ping 10.10.10.1 fails | No workstation route to the lab | Add router or workstation route |
| `ping 8.8.8.8 source Vlan10` fails | Router has no return route or doesn't NAT the lab | Recheck the router route |
| SSH closes immediately | Source not allowed by MGMT-SSH | `show access-lists`; confirm a 192.168.1.x address |
| "no matching host key type" | Modern OpenSSH defaults | Use `ssh/config.example` |
| Works wired, fails on Wi-Fi | Laptop on a guest network | Join the main Wi-Fi |
