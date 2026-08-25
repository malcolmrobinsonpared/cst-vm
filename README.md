# Student VM build — Ubuntu Server 26.04 LTS

## todo
confirm reachability
confirm prtg probe

Provisioning scripts + config for a headless VM that students share over SSH. Accounts are **local users provisioned from a CSV roster** and **reconciled on every run** - new rows are created, removed rows are disabled or deleted. Each student is boxed in by **cgroups v2** resource caps, and **Go / Node.js / Python3 / Neovim** are installed system-wide. I include neovim because it's muscle memory - nothing can be done about it.

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
2. **Lock down the folder on the server.** It holds the roster CSV, generated credentials, and your Sophos installer — make it root-owned and unreadable to students before anything else:
   ```bash
   sudo chown -R root:root /opt/cst-vm
   sudo chmod -R 0600 /opt/cst-vm
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

7. Reboot after the first full run. Then, to activate disk quotas, run stage 45 once more (`sudo bash provision.sh 45`) — it applies each student's home-dir limit now that the reboot has enabled quotas. Finally, verify (below).

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

**Sophos** is the reason this box is Ubuntu - its Central-managed agent isn't supported on NixOS :/
The installer embeds your tenant token and isn't in the repo — download `SophosSetup.sh` from your Sophos Central account, drop it next to `provision.sh`, and stage 50 installs it (`--products=mdr,xdr,antivirus`). It's idempotent: skips if `/opt/sophos-spl` already exists, and skips with a note if the file isn't there. **After install, confirm the box shows healthy in the Sophos Central console** — that's the compliance control the OS choice was made for. Change the products/path via `SOPHOS_PRODUCTS` / `SOPHOS_INSTALLER`.

**PRTG** monitors over SSH from a probe. Two hardening interactions to get right so sensors aren't blinded or blocked:

- **Give the probe an account in `ADMIN_GROUP` (sudo).** It must be in a group listed in `SSH_ALLOW_GROUPS` to connect at all, and — because `/proc` runs with `hidepid=2` — only the admin group sees *other users'* processes. System sensors (load, meminfo, disk) read fine regardless; **per-process** sensors need that group membership.
- **Add the probe's IP to `FAIL2BAN_IGNORE_IPS`** so repeated SSH sensor connections can never trip a ban and lock monitoring out.

Idle-logout and kill-on-logout don't affect PRTG — its SSH sensors run a command and disconnect, they don't sit at an idle interactive prompt.
