#!/usr/bin/env bash
# 45-hardening.sh — lock down the shared box against student abuse.
#
# A student with a shell + compilers + network can always run code; these
# controls target what you CAN defend: persistence (no 24/7 servers), inbound
# exposure, student-to-student isolation, and shared-disk fairness. Every block
# is gated by a HARDENING_* / ENABLE_* toggle in config.env.
#
# Fully idempotent + convergent: each block is SYMMETRIC — flipping a toggle off
# (or clearing a value) reverts the artifact its "on" side installed, and config
# files are only rewritten (and services only restarted) when the content really
# changes. So re-running is a no-op, and changing a setting on a live server
# converges the box without a manual undo.
set -euo pipefail
source "${HERE:?run via provision.sh}/config.env"
source "${HERE}/lib/common.sh"

yes() { [[ "${1:-no}" == "yes" ]]; }

# Convert sizes like 4G / 512M to KiB (for setquota). Bare numbers = KiB.
to_kb() {
  local v="${1}" n="${1%[GgMmKk]}" u="${1: -1}"
  case "$u" in
    G|g) echo $(( n * 1024 * 1024 )) ;;
    M|m) echo $(( n * 1024 )) ;;
    K|k) echo "$n" ;;
    *)   echo "$v" ;;
  esac
}

# True only when user quota is actually ACTIVE on mountpoint $1. Having the
# 'usrquota' mount option present is NOT the same thing: on a root filesystem
# the boot-time quotaon frequently doesn't run, leaving the option set while
# quota is off (setquota then fails with 'aquota.user' missing).
#
# Capture-then-grep rather than a pipe: the quota tools print a harmless
# "Cannot stat() mounted device tmpfs" warning and exit non-zero, which under
# 'set -o pipefail' would poison a `quotaon -pu | grep` pipeline and give a
# false negative even when quota is on. `|| true` keeps set -e happy.
quota_active() {
  local status
  status="$(quotaon -pu "$1" 2>/dev/null)" || true
  grep -q 'is on' <<<"${status}"
}

# Make quota active on $1, self-activating if only the mount option is set.
# Try quotaon (works when the ext4 quota feature or an existing quota file is in
# use); if still off, build the old-style quota file with quotacheck (-m: don't
# remount the live root fs read-only) and turn it on. Returns 0 iff now active.
ensure_quota_active() {
  local mp="$1"
  quota_active "$mp" && return 0
  quotaon "$mp" 2>/dev/null || true
  quota_active "$mp" && return 0
  quotacheck -cum "$mp" 2>/dev/null || true
  quotaon "$mp" 2>/dev/null || true
  quota_active "$mp"
}

# Stamp each student's soft/hard limit onto the (already active) quota on $1.
# setquota re-applies every run, so changed QUOTA_SOFT/HARD values converge.
apply_student_quotas() {
  local mp="$1" fstype="$2" soft_kb hard_kb u h n=0
  soft_kb="$(to_kb "${QUOTA_SOFT}")"; hard_kb="$(to_kb "${QUOTA_HARD}")"
  while IFS= read -r h; do
    u="$(user_of_home "$h")"
    [[ -n "$u" ]] || continue
    setquota -u "$u" "${soft_kb}" "${hard_kb}" \
      "${QUOTA_INODES_SOFT}" "${QUOTA_INODES_HARD}" "${mp}" \
      && n=$(( n + 1 )) || warn "  setquota failed for ${u}"
  done < <(student_homes)
  log "  applied to ${n} students on ${mp} (${fstype})"
}

# This filesystem uses EXTERNAL quota files (no ext4 'quota' feature), so the
# kernel mounts it with "Quota mode: none" and quota is OFF after every boot —
# and this box reboots nightly. Install a oneshot that turns quota back on at
# boot so enforcement survives reboots without a manual stage-45 re-run.
QUOTA_BOOT_UNIT=/etc/systemd/system/student-quota.service
install_quota_boot_unit() {
  local mp="$1" qon tmp
  qon="$(command -v quotaon || echo /usr/sbin/quotaon)"
  tmp="$(mktemp)"
  cat >"${tmp}" <<EOF
[Unit]
Description=Enable per-user disk quota on ${mp} (managed by provision.sh)
After=local-fs.target
ConditionPathExists=${mp%/}/aquota.user

[Service]
Type=oneshot
RemainAfterExit=yes
# Turn quota on (tolerate the harmless tmpfs-stat warning and an already-on
# state), then confirm it actually came on so a real failure surfaces.
ExecStart=/bin/sh -c '${qon} -u ${mp} 2>/dev/null || true; ${qon} -pu ${mp} 2>/dev/null | grep -q "is on"'

[Install]
WantedBy=multi-user.target
EOF
  if write_if_changed "${tmp}" "${QUOTA_BOOT_UNIT}" 0644; then
    systemctl daemon-reload || true
  fi
  systemctl enable student-quota.service >/dev/null 2>&1 \
    || warn "  could not enable student-quota.service (quota won't auto-reactivate on reboot)"
}
remove_quota_boot_unit() {
  systemctl disable --now student-quota.service 2>/dev/null || true
  if ensure_absent "${QUOTA_BOOT_UNIT}"; then systemctl daemon-reload || true; fi
}

# List home directories of everyone in the students group.
student_homes() {
  local members u
  members="$(getent group "${STUDENT_GROUP}" | awk -F: '{print $4}')"
  IFS=',' read -ra arr <<< "${members}"
  for u in "${arr[@]}"; do
    [[ -n "$u" ]] || continue
    getent passwd "$u" | cut -d: -f6
  done
}

# Map a home dir back to its username.
user_of_home() { getent passwd | awk -F: -v home="$1" '$6==home {print $1}' | head -1; }

ADMIN_GID="$(getent group "${ADMIN_GROUP}" | cut -d: -f3 || true)"

# --- logind: kill user processes on logout ----------------------------------
if yes "${HARDENING_KILL_USER_PROCESSES}"; then
  log "logind: KillUserProcesses=yes (exclude: ${HARDENING_KILL_EXCLUDE_USERS})"
  install -d -m 0755 /etc/systemd/logind.conf.d
  tmp="$(mktemp)"
  cat >"${tmp}" <<EOF
# Managed by 45-hardening.sh — nothing a student starts survives logout.
[Login]
KillUserProcesses=yes
KillExcludeUsers=${HARDENING_KILL_EXCLUDE_USERS}
EOF
  # Restart logind ONLY when the drop-in actually changed (a restart can drop
  # live sessions — fine during a real change, wasteful on an unchanged re-run).
  if write_if_changed "${tmp}" /etc/systemd/logind.conf.d/50-hardening.conf 0644; then
    systemctl restart systemd-logind || warn "could not restart systemd-logind (applies after reboot)"
  fi
else
  if ensure_absent /etc/systemd/logind.conf.d/50-hardening.conf; then
    log "logind: removed kill-on-logout drop-in"
    systemctl restart systemd-logind || warn "could not restart systemd-logind (applies after reboot)"
  fi
fi

# --- deny non-admins the linger loophole ------------------------------------
if yes "${HARDENING_DISABLE_LINGER}"; then
  log "polkit: only ${ADMIN_GROUP} may enable linger"
  install -d -m 0755 /etc/polkit-1/rules.d
  tmp="$(mktemp)"
  cat >"${tmp}" <<EOF
// Managed by 45-hardening.sh — students can't make processes persist via linger.
polkit.addRule(function(action, subject) {
  if (action.id == "org.freedesktop.login1.set-user-linger" &&
      !subject.isInGroup("${ADMIN_GROUP}")) {
    return polkit.Result.NO;
  }
});
EOF
  write_if_changed "${tmp}" /etc/polkit-1/rules.d/50-no-linger.rules 0644 || true
  # Revoke any linger a student already enabled.
  while IFS= read -r h; do
    u="$(user_of_home "$h")"
    [[ -n "$u" ]] && loginctl disable-linger "$u" 2>/dev/null || true
  done < <(student_homes)
else
  if ensure_absent /etc/polkit-1/rules.d/50-no-linger.rules; then
    log "polkit: removed linger restriction (non-admins may enable linger again)"
  fi
fi

# --- restrict cron + at to admins -------------------------------------------
if yes "${HARDENING_RESTRICT_CRON}"; then
  log "cron/at: allow root + ${ADMIN_GROUP} only"
  tmp="$(mktemp)"
  {
    echo root
    getent group "${ADMIN_GROUP}" | awk -F: '{print $4}' | tr ',' '\n'
  } | sed '/^$/d' | sort -u >"${tmp}"
  # Presence of *.allow means everyone not listed is denied. at.allow mirrors it.
  write_if_changed "${tmp}" /etc/cron.allow 0600 || true
  tmp2="$(mktemp)"; cp -a /etc/cron.allow "${tmp2}"
  write_if_changed "${tmp2}" /etc/at.allow 0600 || true
else
  removed=0
  ensure_absent /etc/cron.allow && removed=1 || true
  ensure_absent /etc/at.allow   && removed=1 || true
  (( removed )) && log "cron/at: removed *.allow — reverted to default (cron.deny / allow-all)" || true
fi

# --- idle-shell auto-logout (bash TMOUT) ------------------------------------
# Kicks a student who's idle at the shell prompt; the logout then trips
# kill-on-logout and frees their slice. Admins are exempt. A foreground program
# (editor / running server / compile) keeps the shell busy, so real work isn't
# cut off.
if [[ -n "${HARDENING_IDLE_TIMEOUT:-}" && "${HARDENING_IDLE_TIMEOUT}" != "0" ]]; then
  log "idle logout: ${HARDENING_IDLE_TIMEOUT}s for non-admins (bash TMOUT)"
  tmp="$(mktemp)"
  cat >"${tmp}" <<EOF
# Managed by 45-hardening.sh — idle-shell auto-logout for students (not admins).
if [ -n "\${PS1-}" ]; then
  if ! id -nG 2>/dev/null | tr ' ' '\n' | grep -qx '${ADMIN_GROUP}'; then
    TMOUT=${HARDENING_IDLE_TIMEOUT}
    readonly TMOUT 2>/dev/null || true
    export TMOUT
  fi
fi
EOF
  write_if_changed "${tmp}" /etc/profile.d/99-idle-timeout.sh 0644 || true
else
  ensure_absent /etc/profile.d/99-idle-timeout.sh || true   # disabled -> remove any prior copy
fi

# --- kernel sysctl hardening ------------------------------------------------
if yes "${HARDENING_SYSCTL}"; then
  log "sysctl: kernel hardening"
  tmp="$(mktemp)"
  cat >"${tmp}" <<'EOF'
# Managed by 45-hardening.sh
kernel.dmesg_restrict=1
kernel.kptr_restrict=2
kernel.unprivileged_bpf_disabled=1
net.core.bpf_jit_harden=2
kernel.perf_event_paranoid=3
kernel.yama.ptrace_scope=1
EOF
  if yes "${HARDENING_RESTRICT_USERNS}"; then
    cat >>"${tmp}" <<'EOF'
# Block rootless containers / reduce kernel attack surface. First key is the
# Ubuntu 24.04+ AppArmor gate; second is the older Debian knob. Unknown keys on
# a given kernel are simply ignored.
kernel.apparmor_restrict_unprivileged_userns=1
kernel.unprivileged_userns_clone=0
EOF
  fi
  if write_if_changed "${tmp}" /etc/sysctl.d/90-hardening.conf 0644; then
    sysctl --system >/dev/null 2>&1 || warn "some sysctl keys not present on this kernel (harmless)"
  fi
  # The unprivileged-userns restriction is AppArmor-mediated on Ubuntu; if
  # AppArmor is off it silently does nothing. Warn rather than fail.
  if yes "${HARDENING_RESTRICT_USERNS}"; then
    if [[ "$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null || echo N)" != "Y" ]]; then
      warn "AppArmor is not enabled — the unprivileged user-namespace restriction won't take effect."
      warn "  (Stock Ubuntu enables it by default; check 'aa-status' if this fires.)"
    fi
  fi
else
  if ensure_absent /etc/sysctl.d/90-hardening.conf; then
    log "sysctl: removed kernel-hardening file"
    sysctl --system >/dev/null 2>&1 || true    # re-assert the distro baseline
    warn "sysctl: persistent hardening removed; any live kernel values fully revert on next reboot."
  fi
fi

# --- hidepid on /proc -------------------------------------------------------
if yes "${HARDENING_HIDEPID}"; then
  if [[ -n "${ADMIN_GID}" ]]; then
    log "hidepid=2 on /proc (trusted gid ${ADMIN_GID} = ${ADMIN_GROUP})"
    # Marker-managed so a changed admin gid rewrites the line instead of leaving
    # a stale one (the old grep-guard only appended when absent).
    set_fstab_mount /proc "proc /proc proc defaults,hidepid=2,gid=${ADMIN_GID} 0 0" \
      && log "  updated /proc entry in /etc/fstab" || true
    mount -o remount,hidepid=2,gid="${ADMIN_GID}" /proc \
      || warn "could not remount /proc now; applies on reboot"
  else
    warn "hidepid: admin group '${ADMIN_GROUP}' has no gid; skipping"
  fi
else
  if unset_fstab_mount /proc; then log "hidepid: removed managed /proc entry from /etc/fstab"; fi
  if findmnt -no OPTIONS /proc 2>/dev/null | grep -qE 'hidepid=[12s]'; then
    mount -o remount,hidepid=0 /proc 2>/dev/null \
      || warn "could not remount /proc to hidepid=0 now; applies on reboot"
  fi
fi

# --- private homes + default umask ------------------------------------------
if [[ -n "${HARDENING_HOME_MODE}" ]]; then
  log "home dirs: mode ${HARDENING_HOME_MODE}, default UMASK ${HARDENING_UMASK}"
  # New accounts:
  if grep -qE '^\s*HOME_MODE' /etc/login.defs; then
    sed -i "s/^\s*HOME_MODE.*/HOME_MODE\t${HARDENING_HOME_MODE}/" /etc/login.defs
  else
    printf 'HOME_MODE\t%s\n' "${HARDENING_HOME_MODE}" >>/etc/login.defs
  fi
  if grep -qE '^\s*UMASK' /etc/login.defs; then
    sed -i "s/^\s*UMASK.*/UMASK\t\t${HARDENING_UMASK}/" /etc/login.defs
  else
    printf 'UMASK\t\t%s\n' "${HARDENING_UMASK}" >>/etc/login.defs
  fi
  grep -q 'pam_umask.so' /etc/pam.d/common-session || \
    echo 'session optional pam_umask.so' >>/etc/pam.d/common-session
  # Existing student homes:
  while IFS= read -r h; do
    [[ -d "$h" ]] && chmod "${HARDENING_HOME_MODE}" "$h" || true
  done < <(student_homes)
else
  # Cleared -> revert login.defs to conventional defaults and drop pam_umask.
  # (Existing student homes are NOT re-opened automatically — loosening privacy
  #  on already-private homes should be a deliberate manual step.)
  log "home dirs: HOME_MODE cleared — reverting login.defs defaults + removing pam_umask"
  grep -qE '^\s*HOME_MODE' /etc/login.defs && sed -i 's/^\s*HOME_MODE.*/HOME_MODE\t0755/' /etc/login.defs || true
  grep -qE '^\s*UMASK'     /etc/login.defs && sed -i 's/^\s*UMASK.*/UMASK\t\t022/'       /etc/login.defs || true
  sed -i '/^session\s\+optional\s\+pam_umask.so/d' /etc/pam.d/common-session
fi

# --- restrict FUSE to admins ------------------------------------------------
FUSE_BINS=(/usr/bin/fusermount3 /usr/bin/fusermount /bin/fusermount3 /bin/fusermount)
if yes "${HARDENING_RESTRICT_FUSE}"; then
  log "FUSE: restrict fusermount to ${ADMIN_GROUP}"
  for fb in "${FUSE_BINS[@]}"; do
    [[ -e "$fb" ]] || continue
    chown "root:${ADMIN_GROUP}" "$fb" && chmod 4750 "$fb" \
      && log "  restricted ${fb}" || warn "  could not restrict ${fb}"
  done
else
  log "FUSE: restoring default fusermount ownership/mode (root:root 4755)"
  for fb in "${FUSE_BINS[@]}"; do
    [[ -e "$fb" ]] || continue
    chown root:root "$fb" && chmod 4755 "$fb" \
      && log "  reset ${fb}" || warn "  could not reset ${fb}"
  done
fi

# --- /tmp + /dev/shm mount hardening ----------------------------------------
if yes "${HARDENING_HARDEN_TMP}"; then
  shm_opts="nosuid,nodev,noexec"
  tmp_opts="nosuid,nodev"
  yes "${HARDENING_TMP_NOEXEC}" && tmp_opts="${tmp_opts},noexec"

  log "mounts: /dev/shm (${shm_opts}), /tmp (${tmp_opts},size=${HARDENING_TMP_SIZE})"
  # Marker-managed: changing TMP_SIZE / TMP_NOEXEC rewrites the line (the old
  # grep-guard left the stale line in place).
  set_fstab_mount /dev/shm "tmpfs /dev/shm tmpfs ${shm_opts} 0 0" \
    && log "  set /dev/shm fstab entry" || true
  mount -o "remount,${shm_opts}" /dev/shm || warn "could not remount /dev/shm now (applies on reboot)"

  if set_fstab_mount /tmp "tmpfs /tmp tmpfs ${tmp_opts},size=${HARDENING_TMP_SIZE} 0 0"; then
    warn "/tmp fstab entry set/updated; size+opts apply on next reboot (not remounted live)."
  fi
else
  if unset_fstab_mount /dev/shm; then log "tmp-hardening: removed managed /dev/shm fstab entry"; fi
  # Drop the one option we add beyond the distro default for /dev/shm (noexec).
  if findmnt -no OPTIONS /dev/shm 2>/dev/null | grep -qw noexec; then
    mount -o remount,exec /dev/shm 2>/dev/null \
      || warn "could not drop noexec on /dev/shm live (applies on reboot)"
  fi
  if unset_fstab_mount /tmp; then warn "tmp-hardening: removed managed /tmp fstab entry (reverts on reboot)"; fi
fi

# --- per-user disk quotas ---------------------------------------------------
if yes "${ENABLE_HOME_QUOTA}"; then
  log "quota: per-user home-dir size limits (${QUOTA_SOFT} soft / ${QUOTA_HARD} hard)"
  apt-get install -y --no-install-recommends quota >/dev/null || warn "quota package install failed"
  mp="$(df --output=target /home 2>/dev/null | tail -1)"      # stock Ubuntu: /home is on '/'
  fstype="$(findmnt -no FSTYPE "$mp" 2>/dev/null || echo '')"

  if mount | grep -E "on ${mp} " | grep -qE 'usrquota|usrjquota'; then
    # The mount carries the usrquota option. Activate quota if the boot didn't
    # (option present != quota on, especially on a root fs), then apply limits.
    if ensure_quota_active "${mp}"; then
      apply_student_quotas "${mp}" "${fstype}"
    else
      warn "  'usrquota' is on ${mp} but quota could not be activated; no limits set."
      warn "  Inspect: quotaon -pu ${mp}  /  quotacheck -vcum ${mp}  /  dmesg | grep -i quota"
    fi
  else
    # usrquota isn't on the live mount. On ext*, add it to fstab, then try to
    # bring it in live with a remount so we can activate without a reboot; if
    # the remount doesn't take (common for '/'), fall back to a reboot.
    case "$fstype" in
      ext2|ext3|ext4)
        set_fstab_opt "$mp" usrquota \
          && log "  added 'usrquota' to ${mp} (${fstype}) in /etc/fstab" \
          || true
        mount -o remount "$mp" 2>/dev/null || true
        if mount | grep -E "on ${mp} " | grep -qE 'usrquota|usrjquota' \
           && ensure_quota_active "${mp}"; then
          apply_student_quotas "${mp}" "${fstype}"
        else
          warn "quota option set but not live on ${mp} yet."
          warn ">> REBOOT, then re-run:  sudo bash provision.sh 45   <<  to apply the limits."
        fi
        ;;
      *)
        warn "quota on ${mp} (${fstype}) isn't auto-configured for that filesystem."
        warn "Enable user quotas for it, reboot, then re-run stage 45."
        ;;
    esac
  fi

  # Whichever path activated quota, make it persist across the nightly reboot.
  if quota_active "${mp}"; then
    install_quota_boot_unit "${mp}"
  else
    remove_quota_boot_unit
  fi
else
  # Disabled -> zero any live limits, quotaoff, and strip usrquota from fstab.
  mp="$(df --output=target /home 2>/dev/null | tail -1)"
  if mount | grep -E "on ${mp} " | grep -qE 'usrquota|usrjquota'; then
    log "quota: disabling — zeroing student limits + quotaoff on ${mp}"
    while IFS= read -r h; do
      u="$(user_of_home "$h")"
      [[ -n "$u" ]] || continue
      setquota -u "$u" 0 0 0 0 "${mp}" 2>/dev/null || true
    done < <(student_homes)
    quotaoff "${mp}" 2>/dev/null || true
  fi
  remove_quota_boot_unit
  if unset_fstab_opt "$mp" usrquota; then
    warn "quota: removed 'usrquota' from ${mp} in /etc/fstab (fully reverts on reboot)."
  fi
fi

log "hardening stage complete"
log "  some controls (/tmp tmpfs, /proc hidepid, sysctl) fully apply/revert after a reboot."
