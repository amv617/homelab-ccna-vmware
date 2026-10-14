# 04. Access Switches (Cisco 2960-X)

ACCESS-SW1 and ACCESS-SW2 are Layer 2 access switches. Each manages on VLAN 10, uplinks to CORE-SW1 over a two-port LACP trunk, and carries one ESXi uplink. **Finish CORE-SW1 first.**

Configs: [`configs/access-sw1.cfg`](../configs/access-sw1.cfg), [`configs/access-sw2.cfg`](../configs/access-sw2.cfg)

## Differences between the two

| Setting | ACCESS-SW1 | ACCESS-SW2 |
|---|---|---|
| Vlan10 address | 10.10.10.11 | 10.10.10.12 |
| Uplink bundle | Po1, Gi1/0/23-24 to CORE-SW1 Gi1/0/21-22 | Po2, Gi1/0/23-24 to CORE-SW1 Gi1/0/23-24 |
| Gi1/0/1 | ESXI-01 vmnic0, trunk 10,20,30 | ESXI-01 vmnic1, trunk 10,20,30 |
| Gi1/0/2 | Unused | ESXI-01 IPMI, access VLAN 10 |
| Gi1/0/22 | Service laptop, access VLAN 10 | Service laptop, access VLAN 10 |
| Unused, shut in VLAN 999 | Gi1/0/2-21 | Gi1/0/3-21 |

Everything else (base settings, VLANs, STP mode, SSH) is identical.

## Steps

1. **Check and wipe** as on CORE-SW1. This replaces any earlier VLAN 1 management address.
2. **Image.** `show version | include image|Model`: the image should contain `universalk9`. The ports used exist on 24- and 48-port models.
3. **Base settings.** Same as CORE-SW1.
4. **VLANs and STP.** Create the same VLANs as CORE-SW1. In VTP transparent mode they don't propagate, and a VLAN missing here won't cross the trunk.
5. **Management on VLAN 10.** Shut Vlan1, address Vlan10, `ip default-gateway 10.10.10.1`.
6. **EtherChannel trunk.** `channel-group N mode active`, native VLAN 999, allowed 10,20,30,999, `switchport nonegotiate`. The 2960-X doesn't need (or accept) the encapsulation command.
7. **ESXi port.** Trunk 10,20,30, native 999, `spanning-tree portfast trunk` (or `portfast edge trunk` on newer IOS), BPDU Guard.
8. **Service and IPMI ports.** Access VLAN 10, portfast, BPDU Guard.
9. **Unused ports.** Access VLAN 999, shutdown.
10. **SSH** as on CORE-SW1, then save.

## Verification (cabled, CORE-SW1 built)

| Command | Look for |
|---|---|
| `show etherchannel summary` | Po1(SU) or Po2(SU), both members (P) |
| `show interfaces trunk` | Gi1/0/1 and the Po trunking, native 999, VLANs 10,20,30 forwarding |
| `show cdp neighbors` | CORE-SW1 listed twice, once per uplink, on the expected remote ports |
| `show ip interface brief \| include Vlan` | Vlan10 up/up with the switch's address |
| `ping 10.10.10.1`, `ping 192.168.1.250`, `ping 192.168.1.1` | Replies from all three |
| `show ip ssh` | SSH Enabled, version 2.0 |

The three pings prove the trunk and VLAN 10, the default gateway, and the router's return route, in that order. If .250 answers but .1 doesn't, the router has no route back (expected when using workstation routes only).

Not cabled yet: `show interfaces trunk` prints nothing, Po shows (SD), CDP has no entries. That's expected.

The ESXi host has no untagged management VLAN on its trunk, so set the management network VLAN ID to 10 in the DCUI before expecting to reach 10.10.10.21.

## Service port (Gi1/0/22)

Plug a laptop in here to work on the lab directly. VLAN 10 has no DHCP, so set the wired adapter manually:

| Setting | Value |
|---|---|
| IP | 10.10.10.50 |
| Mask | 255.255.255.0 |
| Gateway | 10.10.10.1 |
| DNS | 192.168.1.1 |

Switch it back to DHCP afterward. VLAN 10 is used instead of VLAN 20 because the switches' SSH ACL only permits 192.168.1.0/24 and 10.10.10.0/24. Optionally keep the port shut until needed.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Po (SD), members (I) or (s) | Core side not built or miscabled | `show etherchannel summary` on both ends |
| `%CDP-4-NATIVE_VLAN_MISMATCH` | Native VLAN differs | Native VLAN 999 on both ends |
| Can't ping 10.10.10.1 | Trunk down or VLAN 10 missing | Check VLANs and `show interfaces trunk` |
| Pings .1 but not .250 | No default gateway | `ip default-gateway 10.10.10.1` |
| Workstation can't reach .11/.12 | No route to 10.10.0.0/16 | Add router or workstation route |
| `portfast trunk` rejected | Newer IOS syntax | `spanning-tree portfast edge trunk` |
| Laptop on Gi1/0/22 reaches nothing | Left on DHCP or wrong gateway | Set 10.10.10.50/24, gateway .1 |
