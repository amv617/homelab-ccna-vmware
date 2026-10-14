# 03. Home Router

Two required changes and one optional change on the ISP home router so workstations on the home LAN (Wi-Fi or wired) can reach the lab subnets behind CORE-SW1, and the lab can reach the internet.

Menu names differ between router models and firmware. Look for these settings in the router's advanced network settings. No router credentials, serials, or Wi-Fi details are recorded here.

## Prerequisites

- CORE-SW1 is configured and Gi1/0/1 is cabled to a router LAN port.
- `ping 192.168.1.250` from a workstation gets replies. The router must reach CORE-SW1 before the static route will become active.
- Use a workstation on the main LAN, not a guest network.

## Changes

| # | Setting | Value | Why |
|---|---|---|---|
| 1 | DHCP range | 192.168.1.2 to 192.168.1.199 | Keeps .200 to .254 free for static lab gear; CORE-SW1 is static at .250 |
| 2 | Static route (LAN side) | Destination 10.10.0.0, mask 255.255.0.0, gateway 192.168.1.250 | Return path for every lab VLAN |
| 3 | Local DNS entries (optional) | See table below | Lets you use names like `ssh access-sw1`, helps vCenter |

Leave the LAN address, port forwarding, DMZ, and firewall level at their defaults. None are needed for the lab.

### Static route notes

- Bind the route to the **LAN** interface, not the WAN/broadband side.
- Use a /16 mask (255.255.0.0) so one route covers VLANs 10, 20, and 30.
- If the route shows as failed, the router couldn't reach 192.168.1.250 when it was added. Bring up Gi1/0/1, delete the route, and add it again.
- After shrinking the DHCP range, confirm no other device already holds .250.

### Optional DNS entries

| Host name | IP address | Device |
|---|---|---|
| core-sw1 | 192.168.1.250 | CORE-SW1 |
| access-sw1 | 10.10.10.11 | ACCESS-SW1 |
| access-sw2 | 10.10.10.12 | ACCESS-SW2 |
| esxi-01 | 10.10.10.21 | ESXi host |
| vcsa | 10.10.10.22 | vCenter appliance |
| nas-01 | 10.10.30.10 | NAS |

If names don't resolve, the router's DNS rebind protection may be blocking answers that point to private addresses.

## Verify

From a workstation:

```
ping 10.10.10.1
traceroute -n 10.10.10.11      # macOS
tracert -d 10.10.10.11         # Windows
```

Expected path: 192.168.1.1, then 192.168.1.250, then the switch. Then from CORE-SW1:

```
CORE-SW1# ping 8.8.8.8 source Vlan10
```

`!!!!!` with source 10.10.10.1 proves the router routes back to the lab and NATs it.

## Known issue: asymmetric path

With only the router route, a workstation's packets go workstation, router, CORE-SW1, but replies come straight back from CORE-SW1 (it's on the same subnet). The router sees half of each TCP session and its firewall can drop long sessions such as SSH, the Host Client, or the vCenter installer. Fix: keep the router route for lab internet access, and also add a direct workstation route for 10.10.0.0/16 via 192.168.1.250 on the machines you manage the lab from.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Trace stops at hop 1 | Route missing or wrong mask | Route must read 10.10.0.0 / 255.255.0.0 / 192.168.1.250 |
| Trace stops at hop 2 | Lab side not ready | Finish that switch's guide or check its trunk |
| Ping works, SSH hangs | Asymmetric path | Add a workstation route |
| `ping 8.8.8.8 source Vlan10` fails | Router doesn't NAT the lab | Lab VMs won't reach the internet; workstation access still works |
