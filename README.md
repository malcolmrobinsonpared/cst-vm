# Student VM build — Ubuntu Server 26.04 LTS

## todo
confirm reachability

Provisioning scripts + config for a headless VM that students share over SSH. Accounts are **local users provisioned from a CSV roster** and **reconciled on every run** - new rows are created, removed rows are disabled or deleted. Each student is boxed in by **cgroups v2** resource caps, and **Go / Node.js / Python3 / Neovim** are installed system-wide. I include neovim because it's muscle memory - nothing can be done about it.

## Layout

```
config.env                         # ← edit this first
students.csv.example               # ← copy to your roster CSV (usernames + passwords)
provision.sh                       # entrypoint; runs the stages in order
scripts/
  00-base.sh                       # apt upgrade, base pkgs, unattended-upgrades, fail2ban, swapfile
  10-users.sh                      # reconcile student accounts from the CSV roster
  20-cgroups.sh                    # per-user systemd slice caps + PAM ulimits
  30-toolchains.sh                 # Go, Node.js, Python3, Neovim (system-wide)
  35-packages.sh                   # common Python/Node/Go packages + boot.dev tooling
  40-ssh.sh                        # sshd: group-gated access, hardened, no X11
  45-hardening.sh                  # lockdown: kill-on-logout, cron/at, sysctl, idle, ...
  46-firewall.sh                   # ufw: closed inbound; no egress to the local subnet
  48-motd.sh                       # student welcome message (house rules at login)
  50-sophos.sh                     # install Sophos endpoint protection (if present)
SophosSetup.sh                     # ← you provide this; git ignores this since it leaks keys
etc/                               # config templates (@PLACEHOLDERS@ from config.env)
  ssh/sshd_config.d/50-students.conf
  security/limits.d/90-students.conf
  profile.d/student-toolchains.sh
```

## Use

1. Copy this whole folder to a **fresh Ubuntu Server 26.04 LTS** VM, e.g.
   ```bash
   scp -r wsl-build/ admin@vm-host:/opt/cst-vm
   ```
2. **Lock down the folder on the server.** It holds `config.env` and your Sophos installer, so make it root-owned and unreadable to students before anything else (the roster and generated-credentials files are protected separately — see steps 4 and 6):
   ```bash
   sudo chown -R root:root /opt/cst-vm
   sudo find /opt/cst-vm -type d -exec chmod 0700 {} +
   sudo find /opt/cst-vm -type f -exec chmod 0600 {} +
   ```
3. **Review `config.env`** - resource caps, tool versions.
4. **Create the roster.** Copy `students.csv.example` to the path in `STUDENT_ROSTER_CSV` (default `/opt/cst-vm/students.csv`), fill it in, and keep it private:
   ```bash
   cp students.csv.example students.csv && chmod 600 students.csv
   # edit /opt/cst-vm/students.csv — one "username,password,full name" row per student
   ```
   Leave a password blank to have one generated for you.
5. Run it as root:
   ```bash
   cd /opt/cst-vm
   sudo bash provision.sh
   ```

6. If any rows had blank passwords, collect the generated ones from `/opt/cst-vm/student-credentials.txt`, distribute, then delete the file.

7. Reboot after the first full run, then re-run stage 45 once (`sudo bash provision.sh 45`) to activate disk quotas. The reboot is only so the root filesystem mounts with the `usrquota` option; stage 45 then runs `quotacheck`/`quotaon` itself and applies each student's home-dir limit. Finally, verify (below).

**Updating the roster later:** edit the CSV and re-run stage 10 (`sudo bash provision.sh 10`). New rows are created, rows you removed are **disabled** (home kept) or **deleted** per `REMOVED_ACCOUNT_ACTION`, and a student you add back is re-enabled. Existing passwords are left untouched unless you pass `--reset-passwords`.

> **Line endings:** if you edited files on Windows, normalize before running: `sudo apt-get install -y dos2unix && find . -type f \( -name '*.sh' -o -name '*.conf' -o -name '*.env' \) -exec dos2unix {} +`

## Pre-installed packages & boot.dev coverage

`scripts/35-packages.sh` makes the system work out of the box for common coursework — including **boot.dev**, which is Go/Python/SQL-heavy and uses several extra tools. Everything below is installed **system-wide for all students** (who have no sudo); package lists live in `config.env`.

| Ecosystem | What's supplied | How it's installed |
|-----------|-----------------|--------------------|
| **Python libs** | numpy, pandas, matplotlib, scipy, sympy, scikit-learn, seaborn, requests, flask, pytest, pillow, beautifulsoup4, openpyxl, ipython, flake8, black | **APT** → system site-packages, importable by plain `python3` with no venv |
| **Node CLIs** | typescript, ts-node, eslint, prettier, nodemon, http-server, vite | `npm -g` into `/opt/node` |
| **Dev utils** | sqlite3, valgrind, gdb, cmake, clang, httpie | APT |
| **Go tools** | `bootdev` (boot.dev CLI / local test runner), `goose` (migrations), `sqlc` (SQL→Go) | `go install` → `/usr/local/bin` |

> **No containers.** Podman/Docker are deliberately not installed on this shared box — they're an open door to persistent servers — and unprivileged user namespaces are restricted so students can't bring their own rootless runtime. boot.dev's Docker course won't run here. That's an accepted tradeoff, but open to discussion.

Two ecosystem caveats worth knowing:

- **Node libraries aren't pre-installed.** Students install libraries with `npm install` in their project dir; only **CLI tools** are global. (Python is the opposite — system-wide libs *are* importable, which is why the Python list is generous.)
- **Students' own Python deps go in a venv.** Ubuntu's system Python is PEP-668 "externally managed", so `pip install` against it is blocked by design. The APT libs above cover the common case; for anything else students do `python3 -m venv .venv && . .venv/bin/activate && pip install …` (or `uv`). No sudo needed, no `--break-system-packages`.

## Lockdown / hardening

A shared box gives ~20 students a shell, compilers, and network — you can't stop them running code, so `scripts/45-hardening.sh` locks down what you *can* defend: **persistence** (no 24/7 servers), **inbound exposure**, **student-to-student isolation**, and **shared-disk fairness**. **Every control is a `config.env` lever** — set it to `no` (or change its value) and re-run `sudo bash provision.sh 45` to loosen.

| Control | Stops | Loosen with | Tradeoff |
|---------|-------|-------------|----------|
| **Kill processes on logout** | The Minecraft server they start and leave running | `HARDENING_KILL_USER_PROCESSES` | Detached `tmux`/`screen` & long jobs die on disconnect. Exempt admins via `HARDENING_KILL_EXCLUDE_USERS`. |
| **No self-linger** | Persisting a service across logout/boot | `HARDENING_DISABLE_LINGER` | none for students |
| **cron/at = admins only** | Scheduling a relaunch of a killed server | `HARDENING_RESTRICT_CRON` | students can't use cron/at |
| **Idle-shell logout** | Sessions left connected (holding a slice / dev server up) | `HARDENING_IDLE_TIMEOUT` | fires only at the prompt — a foreground editor/server/compile is "busy" and isn't cut off; admins exempt |
| **Kernel sysctls** | dmesg/kptr/BPF/perf info-leaks & abuse | `HARDENING_SYSCTL` | negligible |
| **Restrict user namespaces** | Rootless containers they bring themselves | `HARDENING_RESTRICT_USERNS` | a few niche sandbox tools need userns |
| **`/proc` hidepid** | Seeing others' processes / command-line secrets | `HARDENING_HIDEPID` | admins (ADMIN_GROUP) keep full visibility |
| **Private homes + umask** | Reading each other's files (cheating/privacy) | `HARDENING_HOME_MODE`, `HARDENING_UMASK` | none |
| **Restrict FUSE** | `sshfs`/`rclone` mounts for exfil/egress-bypass | `HARDENING_RESTRICT_FUSE` | students can't use FUSE mounts |
| **`/tmp` + `/dev/shm` mounts** | SUID/device tricks; a `/tmp`-fill DoS | `HARDENING_HARDEN_TMP`, `HARDENING_TMP_SIZE`, `HARDENING_TMP_NOEXEC` | `/tmp` noexec is **off** by default (breaks pip/node-gyp builds) |
| **Per-user disk quota** | One student filling the disk for all | `ENABLE_HOME_QUOTA`, `QUOTA_SOFT`/`QUOTA_HARD` | **on**, 3 GB soft / 4 GB hard. Needs one reboot to activate — see below |
| **Host firewall (ufw)** | Inbound on anything but SSH + dev ports; students reaching their LAN neighbours | `ENABLE_FIREWALL`, `FW_*` | stage 46, see below |
| **IPv6 off** | Reaching those same neighbours over v6 link-local, around the IPv4 rules | `FW_BLOCK_IPV6` | `::1` goes too; nothing here needs it |

> **Reboot once after the first run.** `/tmp` tmpfs, `/proc` hidepid, and some sysctls fully apply on the next boot (the build already recommends a reboot).
>
> **Disk quotas need that reboot + a second stage-45 run.** On a stock Ubuntu install `/home` is on the root filesystem, so the `usrquota` mount option can't be added to a live `/`. First `provision.sh` run: stage 45 adds `usrquota` to `/etc/fstab` (backing it up) and tells you to reboot. After the reboot the root filesystem mounts with `usrquota`; run `sudo bash provision.sh 45` once more and it activates quota itself (`quotacheck`/`quotaon` — the boot does **not** do this for the root fs) and applies each student's 3 GB/4 GB limit. Because Ubuntu's root fs uses *external* quota files (it's not built with the ext4 `quota` feature), the kernel mounts it with quota **off** on every boot; stage 45 installs a `student-quota.service` oneshot that turns quota back on at boot so enforcement survives the nightly reboot. New students added later get their limit on the next stage-45 run — no reboot needed after the first time.

## Swap

Ubuntu server/cloud images ship with **no swap**, which on a box with ~20 shells means the kernel's only relief under pressure is dropping page cache and then OOM-killing. Stage 00 creates a **4 GB swapfile** at `/swapfile` (`SWAP_SIZE` / `SWAP_FILE` in `config.env`), `mkswap`s it, swaps it on, and adds a managed `/etc/fstab` entry so it survives the nightly reboot.

- **It isn't extra RAM.** `CG_MEMORY_MAX` (3 GB) is still each student's hard ceiling — swap just gives cold pages somewhere to go so an idle session isn't holding RAM the active ones need.
- **Per-user swap is capped too.** `CG_MEMORY_SWAP_MAX` (1 GB) goes into the `user-.slice` drop-in as `MemorySwapMax`. Without it `MemoryMax` bounds only *resident* memory and one student could occupy the entire swapfile.
- **It replaces the installer's swapfile.** Ubuntu's curtin installer leaves its own `/swap.img` behind; left alone, the two stack and the box has neither the size nor the disk footprint `SWAP_SIZE` claims. Once ours is live, stage 00 swaps `/swap.img` off, drops its fstab line and deletes it (`SWAP_REPLACE_EXISTING="no"` to keep both). Only ever **regular files** — swap partitions, `UUID=`/`LABEL=` entries and zram are never touched. Not reversible: clearing `SWAP_SIZE` later removes ours, not theirs.
- **Convergent, like everything else.** Change `SWAP_SIZE` and re-run stage 00 to resize; set it to `""` and re-run to swap off, drop the fstab entry, and delete the file. Re-running unchanged is a no-op. Needs `SWAP_SIZE` + 1 GB free, and skips (with a warning) on btrfs/zfs, which need a hand-built swap area.
- **Resizing means `swapoff` first** — there's no in-place grow, since the kernel reads the swap header once at `swapon`. `swapoff` has to fault every swapped-out page back into RAM, so it can fail when memory is tight; the stage then keeps the existing file and tells you to retry. Cheapest time to resize is just after the 04:00 reboot, when swap is empty.
- Changing `CG_MEMORY_SWAP_MAX` takes a stage-20 re-run (`sudo bash provision.sh 20`); it applies to sessions started after that.

## Host firewall

`scripts/46-firewall.sh` runs **ufw** and does two separate jobs. All of it is driven by the `FW_*` block in `config.env`; `ENABLE_FIREWALL="no"` + a stage-46 re-run removes the firewall entirely.

**Inbound — default deny.** Only `FW_ALLOW_INBOUND_TCP` is opened: SSH (`SSH_PORT`) and the dev-server range `3000:3999` students are told to bind. `FW_ALLOW_INBOUND_FROM` narrows *who* may reach those ports (empty = anywhere on the SDN).

**Outbound — everything except the box's own subnet.** The box sits on `10.90.196.0/24` alongside everything else on that segment, and ~20 students with a shell, a compiler and `nmap` can reach all of it. So egress stays wide open to the **wider network** (which is reached *through* the gateway) and is blocked to the local segment itself:

| Destination | Result |
|-------------|--------|
| `10.90.196.1` (the router) | **allowed** — and with it the whole wider network / internet behind it |
| anything else in `10.90.196.0/24` | **rejected** — printers, APs, staff laptops, other servers on the segment |
| any address outside `10.90.196.0/24` | allowed, exactly as before |

Two things this deliberately does **not** break:

- **Inbound connections from the local subnet still work, both directions.** ufw accepts established/related traffic ahead of these rules, so the reply packets flow normally. An admin at `10.90.196.x` can still SSH in, and a student's dev server is still reachable from a browser on the segment. The rules only govern connections *this box starts*.
- **Nothing about internet access changes.** Traffic to anywhere off-segment is routed via `10.90.196.1`, which is explicitly allowed — apt, npm, `go install`, GitHub and the Sophos agent are unaffected.

Configure it with:

| Setting | Does |
|---------|------|
| `FW_ISOLATE_SUBNETS` | the subnets the box may not initiate traffic into (space-separated CIDRs) |
| `FW_SUBNET_ALLOW_HOSTS` | the exceptions inside them — the gateway, **plus any on-segment DNS/NTP/proxy/APT-mirror/Sophos-relay the box depends on** |
| `FW_ISOLATE_ACTION` | `reject` (default — a mistyped address fails instantly instead of hanging) or `deny` (silent drop) |
| `FW_LOG_ISOLATED` | log what the isolation rules block. Off by default: the expected steady state here is "student probes the subnet, gets refused", which is noise. ufw rate-limits it (3/min) so it's a sample, not a full record |
| `FW_BLOCK_IPV6` | turn IPv6 off entirely — see below |

### IPv6 is switched off

`FW_BLOCK_IPV6="yes"` (the default) blocks IPv6 in two layers, because either alone is a half-measure:

- **The stack is disabled** — `net.ipv6.conf.{all,default,lo}.disable_ipv6=1` via `/etc/sysctl.d/91-no-ipv6.conf`, so no interface holds a v6 address.
- **ufw drops all outbound v6** — `deny out to ::/0`, which lands only in `ip6tables` (`ufw6-user-output -j DROP`) and so can't affect any IPv4 rule. Inbound needs no rule: `default deny incoming` already covers both families. This is the belt-and-braces half: if anything ever brings the stack back up, the box still can't use it.

This isn't optional tidiness — it's what makes the IPv4 rules above mean anything. **IPv6 link-local addressing needs no router, no DHCP and no configuration**: every host on a segment autoconfigures an `fe80::` address and can talk to every other one. Leave v6 up and a student reaches every neighbour on `10.90.196.0/24` over v6 without touching a single one of the rules above.

Knock-on effects, all handled:

- **sshd no longer tries to bind `::`.** `40-ssh.sh` renders `AddressFamily inet` into the drop-in when `FW_BLOCK_IPV6="yes"` (derived, not a separate knob, so the two can't contradict each other). Without it sshd logs `Bind to port 22 on :: failed` at every start.
- **`::1` goes away with the rest of the stack.** In practice nothing here notices: `curl localhost:3000` fails over to `127.0.0.1` instantly, and Node/Python/vite all fall back to IPv4 when no v6 is available. Failures are immediate rather than hanging, which is the point — a dropped-but-live v6 address gives you two-minute timeouts instead.
- **`FW_BLOCK_IPV6="no"` reverts it**, live: the sysctl file is removed *and* the running values are set back to `0` (removing the file alone would only take effect at the next boot). Interfaces pick their v6 addresses back up on the next network restart.

It's a lever of its own, so it's honoured even with `ENABLE_FIREWALL="no"` — turning the firewall off doesn't quietly turn IPv6 back on, and vice versa.

> **The one way to break this is an on-segment dependency you forgot to list.** If your DNS resolver, NTP server or APT mirror lives at another `10.90.196.x` address, add it to `FW_SUBNET_ALLOW_HOSTS` or it stops working. Stage 46 pre-flights this for you: it **aborts before changing anything** if the default gateway would be blocked (that would take the box off the network entirely) or if SSH isn't in the open-ports list (that would lock everyone out), and it **warns** if a configured resolver falls inside an isolated subnet.

Convergent like the rest of the build: the whole rule set is rendered to `/var/lib/cst-vm/firewall.spec` and only rebuilt when that spec changes — or when ufw has been switched off behind the script's back — so a plain re-run touches nothing. When it does rebuild it resets ufw first, so the live rules are exactly the config and never an accumulation of old ones. (`ufw reset` leaves the firewall *disabled*, i.e. unfiltered, for the moment it takes to re-add the rules, so there's no window where an SSH session can be cut off.)

## Hosting dev servers

Students can run development web servers on the box — `python -m http.server`, a Go/Node server, `vite`, etc. A few facts to hand them:

- **Ports 3000–3999 are open on the SDN**, and the box is only reachable over the SDN — so servers are visible to students/staff on the network, never the public internet. Bind to a port in that range. That range is also the only thing besides SSH that the host firewall lets in (`FW_ALLOW_INBOUND_TCP`); keep it in step with `MOTD_DEV_PORTS`, which is what students are told — stage 46 warns if the two drift.
- **Bind `0.0.0.0`, not `127.0.0.1`.** Binding loopback only makes the server reachable from the box itself (`curl localhost:PORT`); binding `0.0.0.0` makes it reachable across the SDN at `<vm-ip>:PORT`.
- **Privileged ports (<1024) won't work** — students aren't root, so `:80`/`:443` are out. That's why the dev range is 3000–3999.
- **One box, one IP, one port space.** If several students pick the same port they collide ("address already in use"). For 20 students, hand out per-student blocks inside 3000–3999 (e.g. student *N* → `3000 + N*10 … +9`, so 50 ports each) or just have them coordinate.
- **Servers are ephemeral by design.** Kill-on-logout (and the idle-shell logout) mean a server only runs while that student is actively connected; on logout the port frees and nothing lingers. No SSH forwarding is involved — access is over your SDN, through the one port range the host firewall opens.
- **Reaching a server from a machine on the same subnet still works.** The firewall's outbound block stops the *box* from initiating connections to its LAN neighbours; it doesn't stop those neighbours connecting *in* (see [Host firewall](#host-firewall)).

## Endpoint protection (Sophos)

**Sophos** is the reason this box is Ubuntu - its Central-managed agent isn't supported on NixOS :/
The installer embeds your tenant token and isn't in the repo — download `SophosSetup.sh` from your Sophos Central account, drop it next to `provision.sh`, and stage 50 installs it (`--products=mdr,xdr,antivirus`). It's idempotent: skips if `/opt/sophos-spl` already exists, and skips with a note if the file isn't there. **After install, confirm the box shows healthy in the Sophos Central console** — that's the compliance control the OS choice was made for. Change the products/path via `SOPHOS_PRODUCTS` / `SOPHOS_INSTALLER`.
