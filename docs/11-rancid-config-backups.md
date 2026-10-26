# 11. Switch Config Backups with RANCID

RANCID logs in to CORE-SW1, ACCESS-SW1 and ACCESS-SW2 every hour, saves each switch's configuration and hardware details, and keeps every change in a git history. When something changes you can see exactly what, on which switch, and when, and you always have the last good config to restore.

```mermaid
flowchart LR
    T["rancid.timer<br/>hourly"] --> R["rancid-run<br/>reads router.db"]
    R --> C["clogin over SSH<br/>as user rancid"]
    C --> SW["core-sw1 10.10.10.1<br/>access-sw1 10.10.10.11<br/>access-sw2 10.10.10.12"]
    SW --> G[("git history<br/>/var/lib/rancid/lab<br/>commit only if changed")]
```

## What RANCID saves for each switch

| Section | From | Why it's useful |
|---|---|---|
| Model, serial, IOS image, license | show version, inventory, license | What hardware and software each switch had on a given day |
| Flash contents, boot settings | dir, show boot | When an image was added or removed |
| VLANs | show vlan | VTP is transparent, so VLANs live in each switch |
| Full running config | show running-config | The part you'd restore from |

Uptime, counters and clock lines are filtered out, so an unchanged switch doesn't create a new version every hour. RANCID only commits when output changes, so the history is a clean list of real changes.

> The serial numbers RANCID records stay on RANCID-01. Nothing from `/var/lib/rancid` belongs in this repo; `.gitignore` blocks the usual paths.

## Values

| Item | Value |
|---|---|
| Server | RANCID-01, 10.10.10.42, Ubuntu 26.04.1 LTS ([09-ubuntu-vm-build.md](09-ubuntu-vm-build.md)) |
| Placement | On 10.10.10.21 in Lab-Cluster, disk on nfs-vm-shared, HA-protected |
| RANCID group | `lab` (all three switches) |
| Switch login | user `rancid`, privilege 15 (Step 1) |
| History | `/var/lib/rancid/lab` |
| Schedule | Hourly, `rancid.timer` from Ubuntu's package |
| Version | RANCID 3.14 (Ubuntu 26.04, universe) |

## Before you start

- RANCID-01 has passed the build guide checklist, including the time zone: `timedatectl` should say America/New_York. If it says UTC, RANCID's logs and change history are stamped in UTC.
- From RANCID-01, `ping -c 2` 10.10.10.1, .11 and .12 all reply.
- You can SSH to each switch as admin and know the enable secret.
- Pick a new password for the rancid switch account (see below).

### Three passwords, three jobs

| Password | What it is | Where it's used |
|---|---|---|
| Admin account on RANCID-01 | The Ubuntu login created when the VM was built | SSH to RANCID-01 and `sudo`. Never on the switches |
| **rancid** (new) | A brand-new password for a new switch account called `rancid` | Step 1 on all three switches; first password in `.cloginrc` (Step 9) |
| Enable secret | The switches' existing enable secret | Second password in `.cloginrc` (Step 9). Don't change it |

**Choosing the rancid password:** use the **same one on all three switches**, because `.cloginrc` has a single password line for them. Make it different from the admin, enable and Ubuntu passwords so the account can be rotated or removed on its own. Stick to **letters, numbers and hyphens**: IOS treats `?` as a help request and won't store it, and spaces or braces complicate `.cloginrc`. Write it down; Step 9 needs it again.

## Part 1: Prepare the switches

### Step 1: Create a rancid account on each switch

On CORE-SW1, ACCESS-SW1 and ACCESS-SW2:

```
conf t
username rancid privilege 15 secret <rancid-password>
end
copy running-config startup-config
show running-config | include username
```

Replace `<rancid-password>` with the new rancid password (not the Ubuntu password), identically on all three switches. Look for a `username rancid privilege 15 secret ...` line (the hash type, 5, 8 or 9, depends on the IOS). A separate account means switch logs show which logins were RANCID's, and the password stored on RANCID-01 isn't your admin password. Privilege 15 is required for `show running-config`. **No ACL change:** MGMT-SSH already permits 10.10.10.0/24.

## Part 2: Set up RANCID on RANCID-01

`ssh labadmin@10.10.10.42`. Steps 2 to 5 run as your admin account with sudo.

Multi-line command blocks can be pasted at once or run a line at a time (one at a time is easier to read). The exception is a block that starts with `cat > ... <<'EOF'` and ends with `EOF`: it writes a file, so paste everything from `cat` through `EOF` in one go.

### Step 2: Install RANCID and git

```bash
sudo apt update
sudo apt -y install rancid git
dpkg -s rancid | grep -E '^(Status|Version)'
```

Expect `install ok installed` and version 3.14. A `warn:` line about `/var/lib/rancid` already existing is harmless. The install creates a `rancid` user whose home is `/var/lib/rancid`.

### Step 3: File layout

| Path | Holds | Set in |
|---|---|---|
| `/etc/hosts` | Switch names, so files are named core-sw1 etc. | 4 |
| `/etc/rancid/rancid.conf` | `RCSSYS=git`, `LIST_OF_GROUPS="lab"` | 5 |
| `~rancid/.cloginrc` | Switch username and passwords (mode 600) | 9 |
| `~rancid/.ssh/config` | Older SSH algorithms IOS 15 needs | 10 |
| `~rancid/.gitconfig` | Name on RANCID's commits | 6 |
| `~rancid/CVS/lab/` | The git repository itself (don't edit) | 7 |
| `~rancid/lab/` | Working copy; `router.db` and `configs/` | 7, 8, 11 |
| `~rancid/logs/` | One log per run | 11 |
| `rancid.timer` | Hourly run | 12 |

### Step 4: Name the switches

```bash
sudo tee -a /etc/hosts > /dev/null <<'EOF'
10.10.10.1   core-sw1
10.10.10.11  access-sw1
10.10.10.12  access-sw2
EOF
getent hosts core-sw1 access-sw1 access-sw2
```

### Step 5: Point RANCID at git and the lab group

```bash
sudo sed -i 's/^RCSSYS=cvs; export RCSSYS/RCSSYS=git; export RCSSYS/' /etc/rancid/rancid.conf
echo 'LIST_OF_GROUPS="lab"; export LIST_OF_GROUPS' | sudo tee -a /etc/rancid/rancid.conf
grep -E '^(RCSSYS|LIST_OF_GROUPS)' /etc/rancid/rancid.conf
```

Exactly these two lines, once each. Set both **before** Step 7: RANCID can't switch from CVS to git after the repository exists.

### Step 6: Become the rancid user

```bash
sudo -iu rancid          # prompt: rancid@rancid-01, home /var/lib/rancid
git config --global user.name "RANCID"
git config --global user.email "rancid@rancid-01.lab"
git config --global init.defaultBranch main
```

Steps 6 to 11 run as rancid. RANCID refuses to run as root, and its files must belong to rancid.

### Step 7: Create the lab repository

```bash
rancid-cvs
```

Despite the name, it works with git when `RCSSYS=git`. Expect `new branch main` and a `router.db` created; "cloned an empty repository" is normal the first time.

### Step 8: List the switches in router.db

```bash
cat > ~/lab/router.db <<'EOF'
core-sw1;cisco;up
access-sw1;cisco;up
access-sw2;cisco;up
EOF
```

| Field | Meaning |
|---|---|
| `core-sw1` | Device name; must resolve (Step 4) and becomes the file name |
| `cisco` | Device type for IOS and IOS-XE, covering both the 3750-X and the 2960-X |
| `up` | Collect it; `down` skips it (for example during a rebuild) |

### Step 9: Store the switch login in .cloginrc

**Before pasting**, replace the two placeholders on the `add password` line: the first with the rancid password from Step 1, the second with the enable secret. Keep the braces `{ }` and delete only the placeholder text between them. The Ubuntu password doesn't go in this file.

```bash
cat > ~/.cloginrc <<'EOF'
add user *-sw* rancid
add password *-sw* {<rancid-password>} {<enable-secret>}
add autoenable *-sw* 1
add method *-sw* ssh
EOF
chmod 600 ~/.cloginrc
ls -l ~/.cloginrc        # -rw------- rancid rancid
```

| Line | Does |
|---|---|
| `*-sw*` | Matches core-sw1, access-sw1, access-sw2 and nothing else |
| `add user` | Log in as rancid |
| `add password` | Login password, then the enable secret (used only if a login lands below privilege 15) |
| `add autoenable 1` | The account starts at privilege 15, so skip `enable` |
| `add method ssh` | SSH only; the switches don't allow Telnet |

**Pasted it with the placeholders still in?** Fix it before the Step 10 test or clogin fails with *Check your passwd*: as rancid, `nano ~/.cloginrc`, replace the placeholders (keep the braces), save with Ctrl+O, Enter, exit with Ctrl+X. nano keeps the 600 permissions; `ls -l ~/.cloginrc` should still start with `-rw-------`.

> **This file holds switch passwords in plain text.** Mode 600 means only rancid can read it. Never copy `.cloginrc` off RANCID-01 or into this repo.

**Quoting rules.** Braces let a password contain spaces, `$`, `[ ]` and `;` safely. A password containing `{` or `}` can't go in braces (the `}` ends it early and clogin reports *extra characters after close-brace*). For that password only, use double quotes and put a backslash before any `$ [ ] " \` inside it; braces and semicolons need no backslash inside quotes. Made-up examples:

| Password | Write it in `.cloginrc` as |
|---|---|
| `Abc-Lab-123` | `{Abc-Lab-123}` (braces, the normal case) |
| `ab}c;9` | `"ab}c;9"` (quotes, because of the brace) |
| `x{y$1` | `"x{y\$1"` (quotes, backslash before the `$`) |

Simplest of all: letters, numbers and hyphens only, in braces.

### Step 10: Allow IOS 15's SSH algorithms, then test one login

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
cat > ~/.ssh/config <<'EOF'
Host core-sw1 access-sw1 access-sw2 10.10.10.1 10.10.10.11 10.10.10.12
    KexAlgorithms +diffie-hellman-group14-sha1,diffie-hellman-group-exchange-sha1
    HostKeyAlgorithms +ssh-rsa
    PubkeyAcceptedAlgorithms +ssh-rsa
    StrictHostKeyChecking accept-new
EOF
chmod 600 ~/.ssh/config

clogin -c "show clock" core-sw1
```

Look for the `CORE-SW1#` prompt and the time; clogin types the password from `.cloginrc`. Repeat for access-sw1 and access-sw2. A `*` before the time means the switch clock isn't NTP-synced, which doesn't affect RANCID (it uses RANCID-01's clock).

| clogin prints | Cause | Fix |
|---|---|---|
| extra characters after close-brace | A password contains `}` inside braces | Write that password in double quotes (Step 9) |
| no matching key exchange method | Older KEX not allowed | Check KexAlgorithms in `~/.ssh/config` |
| no matching host key type | ssh-rsa not allowed | Check HostKeyAlgorithms |
| Error: Check your passwd | Wrong user or password, or placeholders left in | Fix `.cloginrc` (placeholders replaced, braces kept); test `ssh rancid@core-sw1` by hand |
| Connection timed out | No path, or ACL | `ping core-sw1`; check MGMT-SSH |
| Connection Refused (ssh) | SSH not running on the switch | Check `ip ssh` (switch guide, Step 10) |

### Step 11: Run the first collection

```bash
rancid-run                                   # silent, about a minute
tail -n 12 ~/logs/$(ls -t ~/logs | head -1)  # expect: All routers successfully completed.
ls ~/lab/configs                             # access-sw1  access-sw2  core-sw1
head -12 ~/lab/configs/core-sw1
cd ~/lab && git log --oneline | head -5
exit
```

A `/usr/sbin/sendmail: not found` line only means there's no mail relay for change reports; the history still saves. On later runs with no switch changes, the log ends with *nothing to commit, working tree clean* and *Everything up-to-date* after *All routers successfully completed*: RANCID only saves when something changed, and the sendmail line appears only on runs that try to send a report. If the start and end times say UTC, set RANCID-01's time zone (build guide 6c). Each config file starts with RANCID's `!` header lines (chassis, memory, image), then flash, VLANs and the running config.

### Step 12: Run it every hour

Back as your admin account:

```bash
sudo systemctl enable --now rancid.timer rancid-cleanup.timer
systemctl list-timers 'rancid*'
```

`rancid.timer` runs `rancid-run` at the top of every hour as rancid; `rancid-cleanup.timer` deletes run logs older than two days (the history is never deleted). Don't also enable the commented-out entry in `/etc/cron.d/rancid`. After the next hour, `journalctl -u rancid.service -n 5` should end with *Deactivated successfully*.

## Part 3: Prove it catches a change

### Step 13: Harmless change on ACCESS-SW1

```
ACCESS-SW1(config)# vlan 900
ACCESS-SW1(config-vlan)# name RANCID-TEST
ACCESS-SW1(config-vlan)# end
```

Then on RANCID-01:

```bash
sudo -iu rancid
rancid-run
cd ~/lab && git log -p -1 configs/access-sw1
```

Lines starting with `+` show VLAN 900 being added, in a commit made a moment ago: change, collection, history. Remove it (`no vlan 900`), run `rancid-run` again, and the next commit shows the same lines with `-`.

### Step 14: Read the history

As rancid, in `~/lab`:

| Command | Shows |
|---|---|
| `git log --oneline` | Every change, newest first |
| `git log --stat --since="1 week ago"` | Which switches changed this week |
| `git log -p configs/core-sw1` | Every change ever made to CORE-SW1 |
| `git show HEAD` | The most recent change on any switch |
| `git diff HEAD~5 -- configs/access-sw2` | ACCESS-SW2 now vs five changes ago |
| `git show <commit>:configs/core-sw1` | CORE-SW1's whole file as of that commit |
| `grep -n 'interface GigabitEthernet1/0/22' -A6 configs/*` | That port on every switch, side by side |

### Step 15: Get a config back

```bash
sudo cp /var/lib/rancid/lab/configs/core-sw1 /tmp/core-sw1.txt && sudo chmod 644 /tmp/core-sw1.txt
```

```
scp labadmin@10.10.10.42:/tmp/core-sw1.txt ~/Desktop/          # macOS
scp labadmin@10.10.10.42:/tmp/core-sw1.txt $HOME\Desktop\      # Windows
```

The `!` header lines are comments the switch ignores. RANCID keeps one-way secrets (types 5, 8, 9) as-is, so restored usernames and the enable secret work; reversible passwords (line passwords, type 7) are replaced with `<removed>`, so search for that and retype those lines. Delete `/tmp/core-sw1.txt` afterwards. **Don't commit these files here:** they contain password hashes and serial numbers.

## Optional extras

**Keep a copy of the history off the NAS.** RANCID-01's disk and the Veeam backups both live on NAS-01, so one NAS failure could take both. A git bundle is the whole history in one file:

```bash
sudo -iu rancid
cd ~/lab && git bundle create /tmp/rancid-lab.bundle --all
exit
sudo chmod 644 /tmp/rancid-lab.bundle
```

Copy it to the laptop with `scp`, monthly or after big changes, and delete `/tmp/rancid-lab.bundle` afterwards. To restore, copy it back and run `git clone rancid-lab.bundle lab-restored` as rancid. Adding RANCID-01 to the Veeam job is still worth it for quick whole-VM restores.

**Firewall.** RANCID only makes outgoing connections, so on RANCID-01 (never on TS-ROUTER):

```bash
sudo ufw allow OpenSSH
sudo ufw enable
sudo ufw status      # Status: active, OpenSSH ALLOW Anywhere
```

**Email change reports.** RANCID can mail a diff after each change, but that needs a mail relay on RANCID-01 (for example postfix through an email provider), which is a project of its own. Until then, `git log` is the report.

## Keep it safe

- RANCID-01 holds a full-rights switch login and every switch config. Keep it updated (automatic security updates are on) and protect its admin password.
- Rotate the rancid switch password now and then: new secret on all three switches (Step 1), then in `~/.cloginrc`.
- Retiring a switch: set it to `down` or delete its line in `router.db`; the history stays.
- Reach RANCID-01 from outside through Tailscale ([10-tailscale-remote-access.md](10-tailscale-remote-access.md)), never through a port forward.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| "Do not run ... as root!" | Ran a rancid command with sudo | `sudo -iu rancid` first |
| rancid-cvs creates no lab folder | LIST_OF_GROUPS missing or misspelled | Step 5 grep should show it once |
| Log: clogin error: Check your passwd | Wrong password in `.cloginrc` | Fix it; test with clogin |
| Log: missed cmd(s): all commands | Login failed or timed out | Run clogin by hand for that switch |
| Log: End of run not found | Session cut short, often a slow switch | Rerun; if it persists add `NOPIPE=YES; export NOPIPE` to rancid.conf |
| Files named 10.10.10.x | router.db uses IPs, or `/etc/hosts` missing | Step 4, then rename in router.db |
| git: Please tell me who you are | Step 6 git config skipped | Run the git config lines as rancid |
| No new commits for days | Normal if nothing changed, or the timer stopped | `systemctl list-timers 'rancid*'`; read the newest log |
| Permission denied in ~/lab | Edited files as the admin user with sudo | `sudo chown -R rancid:rancid /var/lib/rancid` |
