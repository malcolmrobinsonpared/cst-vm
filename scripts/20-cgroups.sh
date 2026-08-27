#!/usr/bin/env bash
# 20-cgroups.sh — per-user resource caps via systemd (cgroups v2) + PAM ulimits.
set -euo pipefail
source "${HERE:?run via provision.sh}/config.env"

# systemd runs every login under user-<UID>.slice. A drop-in on the *template*
# unit "user-.slice" applies the same caps to every user instance. This is the
# clean, cgroup-v2-native way to bound each student.
log "installing per-user slice limits (user-.slice drop-in)"
install -d -m 0755 /etc/systemd/system/user-.slice.d

cat >/etc/systemd/system/user-.slice.d/10-student-limits.conf <<EOF
# Managed by provision.sh — per-user resource caps (cgroups v2).
# Applies to EVERY user's login slice. To exempt an admin UID, add
# /etc/systemd/system/user-<UID>.slice.d/00-exempt.conf overriding these.
[Slice]
CPUAccounting=yes
CPUQuota=${CG_CPU_QUOTA}
CPUWeight=${CG_CPU_WEIGHT}
MemoryAccounting=yes
MemoryHigh=${CG_MEMORY_HIGH}
MemoryMax=${CG_MEMORY_MAX}
# MemoryMax bounds resident memory only; without this a single user could take
# the whole swapfile (see SWAP_SIZE in config.env) and thrash the box.
MemorySwapMax=${CG_MEMORY_SWAP_MAX}
TasksAccounting=yes
TasksMax=${CG_TASKS_MAX}
IOAccounting=yes
IOWeight=${CG_IO_WEIGHT}
EOF

# Optional: exempt UID 0's slice so root management work is never throttled.
install -d -m 0755 /etc/systemd/system/user-0.slice.d
cat >/etc/systemd/system/user-0.slice.d/00-exempt.conf <<'EOF'
# Do not cap root's session.
[Slice]
CPUQuota=
MemoryHigh=infinity
MemoryMax=infinity
MemorySwapMax=infinity
TasksMax=infinity
EOF

log "reloading systemd"
systemctl daemon-reload

# --- PAM ulimits: a second layer the kernel enforces per process/session -----
log "installing PAM limits (/etc/security/limits.d/90-students.conf)"
install -m 0644 "${HERE}/etc/security/limits.d/90-students.conf" \
  /etc/security/limits.d/90-students.conf
sed -i \
  -e "s|@STUDENT_GROUP@|${STUDENT_GROUP}|g" \
  -e "s|@ULIMIT_NOFILE@|${ULIMIT_NOFILE}|g" \
  -e "s|@ULIMIT_NPROC@|${ULIMIT_NPROC}|g" \
  /etc/security/limits.d/90-students.conf

# pam_limits is enabled by default in Ubuntu's common-session; make sure.
if ! grep -q 'pam_limits.so' /etc/pam.d/common-session; then
  echo 'session required pam_limits.so' >>/etc/pam.d/common-session
fi

log "cgroups/limits stage complete"
log "  inspect a live student session with:  systemctl status user-<UID>.slice"
log "  or:  systemd-cgtop"
