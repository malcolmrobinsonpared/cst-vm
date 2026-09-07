## Verify after running

```bash
# accounts + group membership (managed set = the students group)
getent group students
getent passwd 28jane.doe         # a roster username
sudo chage -l 28jane.doe         # confirm password-expiry (first-login change)

# swap (stage 00)
swapon --show                                  # exactly ONE file: /swapfile, 4G
free -h                                        # Swap: total ~4G, not 8G
grep swap /etc/fstab                           # managed /swapfile entry, no /swap.img
ls -l /swap.img 2>&1                           # "No such file" - installer's copy taken over

# cgroup caps on a live student session (log one in first)
loginctl list-users
systemctl show user-<UID>.slice -p MemoryMax,MemorySwapMax,CPUQuotaPerSecUSec,TasksMax
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
sudo quotaon -pu /              # "user quota on / ... is on"  (ignore the tmpfs-stat warning)
systemctl is-enabled student-quota.service   # "enabled" — reactivates quota on the nightly reboot

# firewall (stage 46)
sudo ufw status verbose          # active; deny in / allow out; rules in order
#   expect, in this order:  22/tcp ALLOW IN | 3000:3999/tcp ALLOW IN
#                           10.90.196.1 ALLOW OUT | 10.90.196.0/24 REJECT OUT
sudo cat /var/lib/cst-vm/firewall.spec         # the rule set stage 46 last applied
curl -sSI --max-time 5 https://ubuntu.com | head -1   # wider network still reachable
ping -c1 -W2 10.90.196.1                       # the router: allowed
ping -c1 -W2 10.90.196.50                      # a neighbour on the segment: refused
getent hosts github.com                        # DNS still resolves (check FW_SUBNET_ALLOW_HOSTS if not)

# ipv6 is off (stage 46)
ip -6 addr                                     # no addresses at all, not even ::1
sysctl net.ipv6.conf.all.disable_ipv6          # = 1
sudo ip6tables -S ufw6-user-output              # -A ufw6-user-output -j DROP
sudo sshd -T | grep -i addressfamily            # inet — sshd isn't trying to bind ::
ping -6 -c1 -W2 ::1 2>&1 | tail -1              # fails: the stack is down
python3 -m http.server 3000 --bind 0.0.0.0 &    # a student's dev server, then:
curl -sS --max-time 5 -o /dev/null -w 'localhost over v4: %{http_code}\n' http://localhost:3000
kill %1                                         # ^ ::1 is gone but localhost still works
# from another machine ON 10.90.196.0/24 — inbound is unaffected by the egress rules:
#   ssh <user>@<vm-ip>            still works
#   curl http://<vm-ip>:3000      still reaches a student's dev server

# maintenance, welcome, endpoint
timedatectl | grep 'Time zone'                             # local timezone set
systemctl list-timers nightly-reboot.timer --no-pager      # next 04:00 reboot
cat /etc/motd                                              # student welcome text
systemctl is-active sophos-spl 2>/dev/null || echo "sophos not installed yet"
```