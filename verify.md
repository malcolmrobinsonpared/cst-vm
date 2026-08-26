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
sudo quotaon -pu /              # "user quota on / ... is on"  (ignore the tmpfs-stat warning)
systemctl is-enabled student-quota.service   # "enabled" — reactivates quota on the nightly reboot

# maintenance, welcome, endpoint
timedatectl | grep 'Time zone'                             # local timezone set
systemctl list-timers nightly-reboot.timer --no-pager      # next 04:00 reboot
cat /etc/motd                                              # student welcome text
systemctl is-active sophos-spl 2>/dev/null || echo "sophos not installed yet"
```