# 01. Network Design

Physical and logical design for the lab: home router, 3750-X Layer 3 core, two 2960-X access switches, a Supermicro ESXi 8 host, and a MyCloud EX2 Ultra NAS.

## Topology

See the diagram in the [README](../README.md#topology) or [`diagrams/topology.mmd`](../diagrams/topology.mmd).

- **Home LAN** 192.168.1.0/24, served by the home router (192.168.1.1). Workstations stay here.
- **Lab** 10.10.0.0/16, routed by CORE-SW1. Each VLAN gets a /24 with its gateway at `.1` on CORE-SW1.

## Routing

- CORE-SW1 runs `ip routing` and sends unknown traffic to the home router: `ip route 0.0.0.0 0.0.0.0 192.168.1.1`.
- The home router has a static route for **10.10.0.0/16 via 192.168.1.250** for return traffic, and NATs the lab to the internet.
- Fallback if the router can't hold a static route: add the route on each workstation instead.
  - macOS: `sudo networksetup -setadditionalroutes "Wi-Fi" 10.10.0.0 255.255.0.0 192.168.1.250`
  - Windows: `route -p add 10.10.0.0 mask 255.255.0.0 192.168.1.250`
  - Lab VMs then reach workstations but not the internet.

## Core and access layer

- CORE-SW1's uplink is a routed port (`no switchport`) at 192.168.1.250, so workstations reach it with no extra routing.
- Each 2960-X uplinks over a two-port LACP EtherChannel trunk: 2 Gbps per switch, survives one cable failure. Spanning tree still runs, but with no loops every link forwards.
- The 2960-X switches manage on VLAN 10 (10.10.10.11 and .12, gateway 10.10.10.1). VLAN 1 is shut down.
- Gi1/0/22 on each access switch is a **service port**: access VLAN 10, so a laptop there can SSH to all three switches and reach ESXi, vCenter and the NAS. VLAN 10 has no DHCP, so the laptop uses 10.10.10.50/24, gateway 10.10.10.1.

## Storage

The NAS sits directly on CORE-SW1 so storage traffic from either ESXi uplink is one hop away. Static 10.10.30.10/24, gateway 10.10.30.1, DNS 192.168.1.1 then 1.1.1.1. Using CORE-SW1 as its gateway keeps every lab conversation symmetric (no half-seen sessions through the home router's firewall).

## ESXi host networking

- The two NICs go to **different** access switches. Because the 2960-X pair is not stacked, there is **no LACP toward the host**.
- Standard vSwitch0, both NICs active, load balancing **Route based on originating virtual port**.
- Port groups on vSwitch0:

| Port group | VLAN | Used by |
|---|---|---|
| Management Network | 10 | vmk0, 10.10.10.21 |
| MGMT-VLAN10 | 10 | vCenter appliance (10.10.10.22) and management VMs |
| VM-NET | 20 | Guest VMs (DHCP from CORE-SW1) |
| Storage | 30 | vmk1, 10.10.30.21 (optional) |

- vCenter installs most cleanly with working forward and reverse DNS. Either run lab DNS or use the appliance IP as its system name.

## Lab service VMs (VLAN 10)

All on the MGMT-VLAN10 port group, gateway 10.10.10.1:

| VM | Address | DNS | Job |
|---|---|---|---|
| veeam01 | 10.10.10.40 | 192.168.1.1 | Veeam backups ([06-nas-backup.md](06-nas-backup.md)) |
| TS-ROUTER | 10.10.10.41 | 192.168.1.1, 1.1.1.1 | Tailscale subnet router ([10-tailscale-remote-access.md](10-tailscale-remote-access.md)) |
| RANCID-01 | 10.10.10.42 | 192.168.1.1, 1.1.1.1 | Switch config backups ([11-rancid-config-backups.md](11-rancid-config-backups.md)) |

## DNS

Lab devices use 192.168.1.1 for DNS, reached through CORE-SW1. The switches run `no ip domain-lookup` and need no DNS server.

## Build order

1. CORE-SW1: VLANs 10, 20, 30, 999; SVIs; `ip routing`; routed Gi1/0/1; default route.
2. Home router: static route 10.10.0.0/16 to 192.168.1.250, then ping 10.10.10.1 from a workstation.
3. ACCESS-SW1 and SW2: VLANs, Vlan10 management IP, Po1/Po2 trunks. Verify with `show etherchannel summary`.
4. NAS: static 10.10.30.10, gateway 10.10.30.1, cable to CORE-SW1 Gi1/0/2.
5. ESXi: set vmk0 to VLAN 10, 10.10.10.21, from the DCUI before cabling both trunk ports.
6. Add vSwitch0 port groups and vmk1, then deploy vCenter at 10.10.10.22.
7. Configure NAS shares and backups.
