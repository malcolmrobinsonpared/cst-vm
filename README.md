# Student VM build — Ubuntu Server 26.04 LTS

Provisioning scripts + config for a headless VM that students share over SSH. Accounts are **local users provisioned from a CSV roster** and **reconciled on every run** — new rows are created, removed rows are disabled or deleted. Each student is boxed in by **cgroups v2** resource caps, and **Go / Node.js / Python3 / Neovim** are installed system-wide.

## Layout

```
config.env                         # ← edit this first
students.csv.example               # ← copy to your roster CSV (usernames + passwords)
provision.sh                       # entrypoint; runs the stages in order
scripts/
  00-base.sh                       # apt upgrade, base pkgs, unattended-upgrades, fail2ban
  10-users.sh                      # reconcile student accounts from the CSV roster
  20-cgroups.sh                    # per-user systemd slice caps + PAM ulimits
  30-toolchains.sh                 # Go, Node.js, Python3, Neovim (system-wide)
  35-packages.sh                   # common Python/Node/Go packages + boot.dev tooling
  40-ssh.sh                        # sshd: group-gated access, hardened, no X11
  45-hardening.sh                  # lockdown: kill-on-logout, cron/at, sysctl, idle, ...
  48-motd.sh                       # student welcome message (house rules at login)
  50-sophos.sh                     # install Sophos endpoint protection (if present)
SophosSetup.sh                     # ← you provide this (from Sophos Central); not in repo
etc/                               # config templates (@PLACEHOLDERS@ from config.env)
  ssh/sshd_config.d/50-students.conf
  security/limits.d/90-students.conf
  profile.d/student-toolchains.sh
```

## Use

1. Copy this whole folder to a **fresh Ubuntu Server 26.04 LTS** VM, e.g.
   ```bash
   scp -r wsl-build/ admin@vm-host:/opt/student-vm-build
   ```
2. **Review `config.env`** — roster path, resource caps, tool versions.
3. **Create the roster.** Copy `students.csv.example` to the path in `STUDENT_ROSTER_CSV` (default `/root/students.csv`), fill it in, and keep it private:
   ```bash
   cp students.csv.example /root/students.csv && chmod 600 /root/students.csv
   # edit /root/students.csv — one "username,password,full name" row per student
   ```
   Leave a password blank to have one generated for you.
4. Run it as root:
   ```bash
   cd /opt/student-vm-build
   sudo bash provision.sh
   ```
   Re-run a single stage with its numeric prefix, e.g. `sudo bash provision.sh 10`. Preview account changes without applying them: `sudo bash scripts/10-users.sh --dry-run`.
5. If any rows had blank passwords, collect the generated ones from `/root/student-credentials.txt`, distribute over a secure channel, then delete the file.
6. Reboot after the first full run. Then, to activate disk quotas, run stage 45 once more (`sudo bash provision.sh 45`) — it applies each student's home-dir limit now that the reboot has enabled quotas. Finally, verify (below).

**Updating the roster later:** edit the CSV and re-run stage 10 (`sudo bash provision.sh 10`). New rows are created, rows you removed are **disabled** (home kept) or **deleted** per `REMOVED_ACCOUNT_ACTION`, and a student you add back is re-enabled. Existing passwords are left untouched unless you pass `--reset-passwords`.

> **Line endings:** if you edited files on Windows, normalize before running: `sudo apt-get install -y dos2unix && find . -type f \( -name '*.sh' -o -name '*.conf' -o -name '*.env' \) -exec dos2unix {} +`

## What each requirement maps to

| Requirement        | Where |
|--------------------|-------|
| **cgroups**        | `scripts/20-cgroups.sh` → `/etc/systemd/system/user-.slice.d/10-student-limits.conf` (CPU/mem/tasks/IO per user), plus PAM ulimits in `/etc/security/limits.d/90-students.conf`. Root's slice is exempted. |
| **Student accounts**| `scripts/10-users.sh` **reconciles** local users against the CSV roster (`STUDENT_ROSTER_CSV`): adds new rows, re-enables returning students, and disables/deletes rows you removed (`REMOVED_ACCOUNT_ACTION`). Managed set = members of the `students` group, so admins are untouched. Usernames are `YYfirst.last` (created with `useradd --badnames` for the leading digits). Blank passwords are generated to `/root/student-credentials.txt` (0600); `FORCE_PW_CHANGE=yes` expires new ones for first-login change. |
| **Go**             | `scripts/30-toolchains.sh` → official tarball in `/usr/local/go`, on PATH via `etc/profile.d/student-toolchains.sh`. |
| **Node.js**        | official tarball in `/opt/node`; per-user global npm prefix so students need no sudo. |
| **Python3**        | distro `python3` + `venv` + `pip` + `pipx` + `build-essential`. |
| **nvim**           | official release in `/opt/nvim`, symlinked to `/usr/local/bin/nvim`, set as default `editor`/`vi`. |
| **Common packages**| `scripts/35-packages.sh` pre-installs Python libraries, Node CLIs, dev utils, and Go tools for everyone (see below). |
| **SSH access**     | `scripts/40-ssh.sh` → `AllowGroups`, root login off, X11/forwarding off, session/DoS limits; `sshd -t` gate before reload; fail2ban jail from stage 00. |
| **Lockdown**       | `scripts/45-hardening.sh` — kill-on-logout, idle-shell logout, cron/at lockout, kernel sysctls, `/proc` hidepid, private homes, FUSE + `/tmp` mount hardening, disk quotas. Every control is a `config.env` toggle (see below). |
| **Welcome / rules**| `scripts/48-motd.sh` writes `/etc/motd` telling students the house rules (git backups, no sudo, venv, dev ports, quota). Text driven by `MOTD_*` in `config.env`. |
| **Nightly reboot** | `scripts/00-base.sh` sets `TIMEZONE` and a systemd timer that reboots at `AUTO_REBOOT_TIME` (default 04:00 local) to apply updates + reset state. |
| **Endpoint protection** | `scripts/50-sophos.sh` runs your `SophosSetup.sh` (from Sophos Central) with `--products=mdr,xdr,antivirus` if present — see below. |
| **No GUI**         | Nothing GUI is installed; SSH `X11Forwarding no`. Use the Ubuntu **Server** (not Desktop) ISO. |

## Pre-installed packages & boot.dev coverage

`scripts/35-packages.sh` makes the box work out of the box for common coursework — including **boot.dev**, which is Go/Python/SQL-heavy and uses several extra tools. Everything below is installed **system-wide for all students** (who have no sudo); package lists live in `config.env`.

| Ecosystem | What's supplied | How it's installed |
|-----------|-----------------|--------------------|
| **Python libs** | numpy, pandas, matplotlib, scipy, sympy, scikit-learn, seaborn, requests, flask, pytest, pillow, beautifulsoup4, openpyxl, ipython, flake8, black | **APT** → system site-packages, importable by plain `python3` with no venv |
| **Node CLIs** | typescript, ts-node, eslint, prettier, nodemon, http-server, vite | `npm -g` into `/opt/node` |
| **Dev utils** | sqlite3, valgrind, gdb, cmake, clang, httpie | APT |
| **Go tools** | `bootdev` (boot.dev CLI / local test runner), `goose` (migrations), `sqlc` (SQL→Go) | `go install` → `/usr/local/bin` |

> **No containers.** Podman/Docker are deliberately not installed on this shared box — they're an open door to persistent game/bot servers — and unprivileged user namespaces are restricted so students can't bring their own rootless runtime. boot.dev's Docker course won't run here; that's an accepted tradeoff.

Two ecosystem caveats worth knowing:

- **Node *libraries* aren't pre-installed.** Node resolves `express`/`react`/etc. per-project from a local `node_modules`, so a global install isn't visible to a project's `import`/`require`. Students install libraries with `npm install` in their project dir; only **CLI tools** are global. (Python is the opposite — system-wide libs *are* importable, which is why the Python list is generous.)
- **Students' own Python deps go in a venv.** Ubuntu's system Python is PEP-668 "externally managed", so `pip install` against it is blocked by design. The APT libs above cover the common case; for anything else students do `python3 -m venv .venv && . .venv/bin/activate && pip install …` (or `uv`). No sudo needed, no `--break-system-packages`.

## Lockdown / hardening

A shared box gives ~20 students a shell, compilers, and network — you can't stop them running code, so `scripts/45-hardening.sh` locks down what you *can* defend: **persistence** (no 24/7 servers), **inbound exposure**, **student-to-student isolation**, and **shared-disk fairness**. **Every control is a `config.env` lever** — set it to `no` (or change its value) and re-run `sudo bash provision.sh 45` to loosen.

| Control | Stops | Loosen with | Tradeoff |
|---------|-------|-------------|----------|
| **Kill processes on logout** | The Minecraft/bot server they start and leave running | `HARDENING_KILL_USER_PROCESSES` | Detached `tmux`/`screen` & long jobs die on disconnect. Exempt admins via `HARDENING_KILL_EXCLUDE_USERS`. |
| **No self-linger** | Persisting a service across logout/boot | `HARDENING_DISABLE_LINGER` | none for students |
| **cron/at = admins only** | Scheduling a relaunch of a killed server | `HARDENING_RESTRICT_CRON` | students can't use cron/at |
| **Idle-shell logout** | Sessions left connected (holding a slice / dev server up) | `HARDENING_IDLE_TIMEOUT` | fires only at the prompt — a foreground editor/server/compile is "busy" and isn't cut off; admins exempt |
| **Kernel sysctls** | dmesg/kptr/BPF/perf info-leaks & abuse | `HARDENING_SYSCTL` | negligible |
| **Restrict user namespaces** | Rootless containers they bring themselves | `HARDENING_RESTRICT_USERNS` | a few niche sandbox tools need userns |
| **`/proc` hidepid** | Seeing others' processes / command-line secrets | `HARDENING_HIDEPID` | admins (ADMIN_GROUP) keep full visibility |
| **Private homes + umask** | Reading each other's files (cheating/privacy) | `HARDENING_HOME_MODE`, `HARDENING_UMASK` | none |
| **Restrict FUSE** | `sshfs`/`rclone` mounts for exfil/egress-bypass | `HARDENING_RESTRICT_FUSE` | students can't use FUSE mounts |
| **`/tmp` + `/dev/shm` mounts** | SUID/device tricks; a `/tmp`-fill DoS | `HARDENING_HARDEN_TMP`, `HARDENING_TMP_SIZE`, `HARDENING_TMP_NOEXEC` | `/tmp` noexec is **off** by default (breaks pip/node-gyp builds) |
| **Inbound firewall (ufw)** | Hosting a public server port | `ENABLE_UFW`, `UFW_EXTRA_ALLOW` | **off** here — the VPS has an external/provider firewall; flip to `yes` for a host firewall too |
| **Per-user disk quota** | One student filling the disk for all | `ENABLE_HOME_QUOTA`, `QUOTA_SOFT`/`QUOTA_HARD` | **on**, 3 GB soft / 4 GB hard. Needs one reboot to activate — see below |

**What this deliberately does *not* try to stop:** outbound tunnels. A student can still run `ngrok` / `cloudflared` / userspace `tailscale` / a reverse shell — these dial *out*, so no inbound rule or SSH setting touches them. The only real defense is **egress filtering**, which would break students hitting arbitrary APIs for coursework, so it's intentionally left out. With kill-on-logout + inbound closed + the CPU cgroup (a miner is capped to 2 cores), hosting is pointless anyway; add monitoring (long-lived listeners, sustained CPU) and revisit egress only if abuse actually appears.

> **Reboot once after the first run.** `/tmp` tmpfs, `/proc` hidepid, and some sysctls fully apply on the next boot (the build already recommends a reboot).
>
> **Disk quotas need that reboot + a second stage-45 run.** On a stock Ubuntu install `/home` is on the root filesystem, so quotas can't be switched on live. First `provision.sh` run: stage 45 adds `usrquota` to `/etc/fstab` (backing it up) and tells you to reboot. After the reboot the kernel activates quota automatically; then run `sudo bash provision.sh 45` once more to apply each student's 3 GB/4 GB limit. New students added later get their limit on the next stage-45 run — no reboot needed after the first time.

## Hosting dev servers

Students can run development web servers on the box — `python -m http.server`, a Go/Node server, `vite`, etc. A few facts to hand them:

- **Ports 3000–3999 are open on the SDN**, and the box is only reachable over the SDN — so servers are visible to students/staff on the network, never the public internet. Bind to a port in that range.
- **Bind `0.0.0.0`, not `127.0.0.1`.** Binding loopback only makes the server reachable from the box itself (`curl localhost:PORT`); binding `0.0.0.0` makes it reachable across the SDN at `<vm-ip>:PORT`.
- **Privileged ports (<1024) won't work** — students aren't root, so `:80`/`:443` are out. That's why the dev range is 3000–3999.
- **One box, one IP, one port space.** If several students pick the same port they collide ("address already in use"). For 20 students, hand out per-student blocks inside 3000–3999 (e.g. student *N* → `3000 + N*10 … +9`, so 50 ports each) or just have them coordinate.
- **Servers are ephemeral by design.** Kill-on-logout (and the idle-shell logout) mean a server only runs while that student is actively connected; on logout the port frees and nothing lingers. No inbound host firewall or SSH forwarding is involved — access is purely your SDN.

## Endpoint protection (Sophos) & monitoring (PRTG)

**Sophos** is the reason this box is Ubuntu (its Central-managed agent isn't supported on NixOS). The installer embeds your tenant token and isn't in the repo — download `SophosSetup.sh` from your Sophos Central account, drop it next to `provision.sh`, and stage 50 installs it (`--products=mdr,xdr,antivirus`). It's idempotent: skips if `/opt/sophos-spl` already exists, and skips with a note if the file isn't there. **After install, confirm the box shows healthy in the Sophos Central console** — that's the compliance control the OS choice was made for. Change the products/path via `SOPHOS_PRODUCTS` / `SOPHOS_INSTALLER`.

**PRTG** monitors over SSH from a Windows probe. Two hardening interactions to get right so sensors aren't blinded or blocked:

- **Give the probe an account in `ADMIN_GROUP` (sudo).** It must be in a group listed in `SSH_ALLOW_GROUPS` to connect at all, and — because `/proc` runs with `hidepid=2` — only the admin group sees *other users'* processes. System sensors (load, meminfo, disk) read fine regardless; **per-process** sensors need that group membership.
- **Add the probe's IP to `FAIL2BAN_IGNORE_IPS`** so repeated SSH sensor connections can never trip a ban and lock monitoring out.

Idle-logout and kill-on-logout don't affect PRTG — its SSH sensors run a command and disconnect, they don't sit at an idle interactive prompt.

## Verify after running

```bash
# accounts + group membership (managed set = the students group)
getent group students
getent passwd 28jane.doe         # a roster username
sudo chage -l 28jane.doe         # confirm password-expiry (first-login change)

# cgroup caps on a live student session (log one in first)
loginctl list-users
systemctl show user-<UID>.slice -p MemoryMax,CPUQuotaPerSecUSec,TasksMax
systemd-cgtop            # watch live CPU/mem per slice

# toolchains
go version && node --version && npm --version && python3 --version && nvim --version

# pre-installed packages + boot.dev tooling
python3 -c 'import numpy, pandas, matplotlib; print("py libs ok")'
tsc --version && eslint --version              # node global CLIs
goose --version && sqlc version && bootdev version   # go tools on PATH

# ssh policy
sudo sshd -T | grep -Ei 'allowgroups|permitrootlogin|x11forwarding|passwordauthentication'

# hardening (stage 45)
sudo grep -H . /etc/systemd/logind.conf.d/50-hardening.conf   # KillUserProcesses=yes
sudo sysctl kernel.dmesg_restrict kernel.unprivileged_bpf_disabled kernel.apparmor_restrict_unprivileged_userns
sudo cat /etc/cron.allow                       # root + admins only (students denied)
findmnt /proc | grep -o 'hidepid=[^, ]*'       # hidepid=2
crontab -l 2>&1 || true                         # as a student: "not allowed"
grep TMOUT /etc/profile.d/99-idle-timeout.sh   # idle logout configured

# disk quotas (after the reboot + second stage-45 run)
sudo repquota -s /              # per-user usage vs 3G/4G limits
sudo quota -s -u 28jane.doe     # one student's limit

# maintenance, welcome, endpoint
timedatectl | grep 'Time zone'                             # local timezone set
systemctl list-timers nightly-reboot.timer --no-pager      # next 04:00 reboot
cat /etc/motd                                              # student welcome text
systemctl is-active sophos-spl 2>/dev/null || echo "sophos not installed yet"
```

## Notes & decisions

- **Toolchains from upstream tarballs, not apt.** Gives predictable, current versions identical for every student. Bump them in `config.env` and re-run stage 30.
- **Per-user global installs.** `npm -g`, `go install`, and `pip --user`/`pipx` all land in the student's home — students have **no sudo**, so they can't touch `/opt` or `/usr/local`. This is intentional.
- **cgroup caps apply to every login slice**, including admins. Root is exempted via `user-0.slice.d`. To exempt a specific admin UID, add `/etc/systemd/system/user-<UID>.slice.d/00-exempt.conf` mirroring that file and `systemctl daemon-reload`.
- **`MemoryMax` is a hard OOM cap.** If students hit OOM-kills doing legit work, raise `CG_MEMORY_MAX` / `CG_MEMORY_HIGH` in `config.env`. Budget against total VM RAM: 20 × 3G is 60G of *ceiling* — the caps are per-user maxima, not reservations, so oversubscription is expected, but size the VM so the common case fits.
- **The CSV roster is the source of truth.** Usernames are `YYfirst.last` (e.g. `28jane.doe`); the leading grad-year digits need `useradd --badnames`, which stage 10 uses automatically. Passwords come from the CSV; a **blank** password cell is filled with a crypto-random one (`/dev/urandom`, 16 chars, no ambiguous `0/O/1/l/I`) written to the credentials file. `FORCE_PW_CHANGE=yes` expires *new* passwords so the student picks their own at first login (needs `SSH_PASSWORD_AUTH=yes`).
- **Re-running reconciles; it doesn't clobber.** Stage 10 leaves existing active accounts and their passwords alone. Rows you added are created, rows you removed are **disabled** (default: account expired + `nologin` shell, **home kept**) or **deleted** (`REMOVED_ACCOUNT_ACTION=delete` → `userdel -r`, home erased), and a student added back to the CSV is re-enabled. Preview with `--dry-run`; re-apply CSV passwords to everyone with `--reset-passwords`; force delete for one run with `--delete`.
- **The managed set is the `students` group.** Only accounts in that group are ever disabled/deleted, so admin and system accounts are never at risk from a roster edit.
- **Keep the roster private and delete the credentials file.** The CSV holds plaintext passwords (stage 10 warns if it isn't mode 0600); the generated-password file (`/root/student-credentials.txt`) is the one plaintext copy of auto-generated ones — hand them out, then delete it.
- **SSH stays password-based** while students use these passwords. Once they've added SSH keys, set `SSH_PASSWORD_AUTH=no` in `config.env` and re-run stage 40 for key-only auth.
