#!/usr/bin/env bash
# 45-hardening.sh — lock down the shared box against student abuse.
#
# A student with a shell + compilers + network can always run code; these
# controls target what you CAN defend: persistence (no 24/7 servers), inbound
# exposure, student-to-student isolation, and shared-disk fairness. Every block
# is gated by a HARDENING_* / ENABLE_* toggle in config.env, so loosening any
# single restriction is a one-line change + re-run of this stage.
set -euo pipefail
source "${HERE:?run via provision.sh}/config.env"

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

ADMIN_GID="$(getent group "${ADMIN_GROUP}" | cut -d: -f3 || true)"

# Add 'usrquota' to the fstab options of a mountpoint (ext* only), preserving all
# other lines verbatim. Backs up fstab and validates before replacing. Returns 0
# if the option is present afterwards, non-zero on failure.
add_usrquota_to_fstab() {
  local mp="$1" tmp bak
  # already present in that mount's options (field 4)?
  awk -v mp="$mp" '!/^[[:space:]]*#/ && $2==mp && $4 ~ /(^|,)usrquota(,|$)/ {f=1} END{exit f?0:1}' \
    /etc/fstab && return 0
  tmp="$(mktemp)"; bak="/etc/fstab.bak-$(date +%s)"
  awk -v mp="$mp" '
    /^[[:space:]]*#/ { print; next }
    NF>=4 && $2==mp {
      if ($4 !~ /(^|,)usrquota(,|$)/) $4=$4",usrquota"
      printf "%s %s %s %s %s %s\n", $1,$2,$3,$4,($5==""?"0":$5),($6==""?"0":$6)
      found=1; next
    }
    { print }
    END { if(!found) exit 3 }
  ' /etc/fstab > "$tmp" || { rm -f "$tmp"; return 1; }
  # sanity: the target mount line still exists in the rewritten file
  grep -qE "^[^#]*[[:space:]]${mp}[[:space:]]" "$tmp" || { rm -f "$tmp"; return 1; }
  cp -a /etc/fstab "$bak" && cat "$tmp" > /etc/fstab && rm -f "$tmp" \
    && { log "  backed up /etc/fstab -> ${bak}"; return 0; }
  rm -f "$tmp"; return 1
}

# --- logind: kill user processes on logout ----------------------------------
if yes "${HARDENING_KILL_USER_PROCESSES}"; then
  log "logind: KillUserProcesses=yes (exclude: ${HARDENING_KILL_EXCLUDE_USERS})"
  install -d -m 0755 /etc/systemd/logind.conf.d
  cat >/etc/systemd/logind.conf.d/50-hardening.conf <<EOF
# Managed by 45-hardening.sh — nothing a student starts survives logout.
[Login]
KillUserProcesses=yes
KillExcludeUsers=${HARDENING_KILL_EXCLUDE_USERS}
EOF
  # Reloading logind can drop live sessions; fine during provisioning.
  systemctl restart systemd-logind || warn "could not restart systemd-logind (applies after reboot)"
fi

# --- deny non-admins the linger loophole ------------------------------------
if yes "${HARDENING_DISABLE_LINGER}"; then
  log "polkit: only ${ADMIN_GROUP} may enable linger"
  install -d -m 0755 /etc/polkit-1/rules.d
  cat >/etc/polkit-1/rules.d/50-no-linger.rules <<EOF
// Managed by 45-hardening.sh — students can't make processes persist via linger.
polkit.addRule(function(action, subject) {
  if (action.id == "org.freedesktop.login1.set-user-linger" &&
      !subject.isInGroup("${ADMIN_GROUP}")) {
    return polkit.Result.NO;
  }
});
EOF
  # Revoke any linger a student already enabled.
  while IFS= read -r h; do
    u="$(getent passwd | awk -F: -v home="$h" '$6==home {print $1}' | head -1)"
    [[ -n "$u" ]] && loginctl disable-linger "$u" 2>/dev/null || true
  done < <(student_homes)
fi

# --- restrict cron + at to admins -------------------------------------------
if yes "${HARDENING_RESTRICT_CRON}"; then
  log "cron/at: allow root + ${ADMIN_GROUP} only"
  {
    echo root
    getent group "${ADMIN_GROUP}" | awk -F: '{print $4}' | tr ',' '\n'
  } | sed '/^$/d' | sort -u >/etc/cron.allow
  install -m 0600 /etc/cron.allow /etc/at.allow
  chmod 0600 /etc/cron.allow
  # Presence of *.allow means everyone not listed is denied.
fi

# --- idle-shell auto-logout (bash TMOUT) ------------------------------------
# Kicks a student who's idle at the shell prompt; the logout then trips
# kill-on-logout and frees their slice. Admins are exempt. A foreground program
# (editor / running server / compile) keeps the shell busy, so real work isn't
# cut off.
if [[ -n "${HARDENING_IDLE_TIMEOUT:-}" && "${HARDENING_IDLE_TIMEOUT}" != "0" ]]; then
  log "idle logout: ${HARDENING_IDLE_TIMEOUT}s for non-admins (bash TMOUT)"
  cat >/etc/profile.d/99-idle-timeout.sh <<EOF
# Managed by 45-hardening.sh — idle-shell auto-logout for students (not admins).
if [ -n "\${PS1-}" ]; then
  if ! id -nG 2>/dev/null | tr ' ' '\n' | grep -qx '${ADMIN_GROUP}'; then
    TMOUT=${HARDENING_IDLE_TIMEOUT}
    readonly TMOUT 2>/dev/null || true
    export TMOUT
  fi
fi
EOF
  chmod 0644 /etc/profile.d/99-idle-timeout.sh
else
  rm -f /etc/profile.d/99-idle-timeout.sh   # disabled -> remove any prior copy
fi

# --- kernel sysctl hardening ------------------------------------------------
if yes "${HARDENING_SYSCTL}"; then
  log "sysctl: kernel hardening"
  cat >/etc/sysctl.d/90-hardening.conf <<'EOF'
# Managed by 45-hardening.sh
kernel.dmesg_restrict=1
kernel.kptr_restrict=2
kernel.unprivileged_bpf_disabled=1
net.core.bpf_jit_harden=2
kernel.perf_event_paranoid=3
kernel.yama.ptrace_scope=1
EOF
  if yes "${HARDENING_RESTRICT_USERNS}"; then
    cat >>/etc/sysctl.d/90-hardening.conf <<'EOF'
# Block rootless containers / reduce kernel attack surface. First key is the
# Ubuntu 24.04+ AppArmor gate; second is the older Debian knob. Unknown keys on
# a given kernel are simply ignored.
kernel.apparmor_restrict_unprivileged_userns=1
kernel.unprivileged_userns_clone=0
EOF
  fi
  sysctl --system >/dev/null 2>&1 || warn "some sysctl keys not present on this kernel (harmless)"
  # The unprivileged-userns restriction is AppArmor-mediated on Ubuntu; if
  # AppArmor is off it silently does nothing. Warn rather than fail.
  if yes "${HARDENING_RESTRICT_USERNS}"; then
    if [[ "$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null || echo N)" != "Y" ]]; then
      warn "AppArmor is not enabled — the unprivileged user-namespace restriction won't take effect."
      warn "  (Stock Ubuntu enables it by default; check 'aa-status' if this fires.)"
    fi
  fi
fi

# --- hidepid on /proc -------------------------------------------------------
if yes "${HARDENING_HIDEPID}"; then
  if [[ -n "${ADMIN_GID}" ]]; then
    log "hidepid=2 on /proc (trusted gid ${ADMIN_GID} = ${ADMIN_GROUP})"
    if ! grep -qE '^\s*proc\s+/proc\s' /etc/fstab; then
      echo "proc /proc proc defaults,hidepid=2,gid=${ADMIN_GID} 0 0" >>/etc/fstab
    fi
    mount -o remount,hidepid=2,gid="${ADMIN_GID}" /proc \
      || warn "could not remount /proc now; applies on reboot"
  else
    warn "hidepid: admin group '${ADMIN_GROUP}' has no gid; skipping"
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
fi

# --- restrict FUSE to admins ------------------------------------------------
if yes "${HARDENING_RESTRICT_FUSE}"; then
  log "FUSE: restrict fusermount to ${ADMIN_GROUP}"
  for fb in /usr/bin/fusermount3 /usr/bin/fusermount /bin/fusermount3 /bin/fusermount; do
    [[ -e "$fb" ]] || continue
    chown "root:${ADMIN_GROUP}" "$fb" && chmod 4750 "$fb" \
      && log "  restricted ${fb}" || warn "  could not restrict ${fb}"
  done
fi

# --- /tmp + /dev/shm mount hardening ----------------------------------------
if yes "${HARDENING_HARDEN_TMP}"; then
  shm_opts="nosuid,nodev,noexec"
  tmp_opts="nosuid,nodev"
  yes "${HARDENING_TMP_NOEXEC}" && tmp_opts="${tmp_opts},noexec"

  log "mounts: /dev/shm (${shm_opts}), /tmp (${tmp_opts},size=${HARDENING_TMP_SIZE})"
  if ! grep -qE '\s/dev/shm\s' /etc/fstab; then
    echo "tmpfs /dev/shm tmpfs ${shm_opts} 0 0" >>/etc/fstab
  fi
  mount -o "remount,${shm_opts}" /dev/shm || warn "could not remount /dev/shm now (applies on reboot)"

  if ! grep -qE '\s/tmp\s' /etc/fstab; then
    echo "tmpfs /tmp tmpfs ${tmp_opts},size=${HARDENING_TMP_SIZE} 0 0" >>/etc/fstab
    warn "/tmp will become a size-capped tmpfs on next reboot (not remounted live)."
  fi
fi

# --- per-user disk quotas ---------------------------------------------------
if yes "${ENABLE_HOME_QUOTA}"; then
  log "quota: per-user home-dir size limits (${QUOTA_SOFT} soft / ${QUOTA_HARD} hard)"
  apt-get install -y --no-install-recommends quota >/dev/null || warn "quota package install failed"
  mp="$(df --output=target /home 2>/dev/null | tail -1)"      # stock Ubuntu: /home is on '/'
  fstype="$(findmnt -no FSTYPE "$mp" 2>/dev/null || echo '')"

  if mount | grep -E "on ${mp} " | grep -qE 'usrquota|usrjquota'; then
    # Quota is live on the mount — apply per-student limits.
    quotaon "${mp}" 2>/dev/null || true
    soft_kb="$(to_kb "${QUOTA_SOFT}")"; hard_kb="$(to_kb "${QUOTA_HARD}")"
    n=0
    while IFS= read -r h; do
      u="$(getent passwd | awk -F: -v home="$h" '$6==home {print $1}' | head -1)"
      [[ -n "$u" ]] || continue
      setquota -u "$u" "${soft_kb}" "${hard_kb}" \
        "${QUOTA_INODES_SOFT}" "${QUOTA_INODES_HARD}" "${mp}" \
        && n=$(( n + 1 )) || warn "  setquota failed for ${u}"
    done < <(student_homes)
    log "  applied to ${n} students on ${mp} (${fstype})"
  else
    # Not live yet. On ext*, enable it in fstab now; a reboot then activates it.
    case "$fstype" in
      ext2|ext3|ext4)
        if add_usrquota_to_fstab "$mp"; then
          warn "enabled 'usrquota' on ${mp} (${fstype}) in /etc/fstab."
          warn ">> REBOOT, then re-run:  sudo bash provision.sh 45   <<  to apply the limits."
          warn "   (boot auto-runs quotacheck/quotaon; this stage then sets each student's cap.)"
        else
          warn "couldn't edit /etc/fstab automatically. Add 'usrquota' to the ${mp} options,"
          warn "reboot, then re-run stage 45."
        fi
        ;;
      *)
        warn "quota on ${mp} (${fstype}) isn't auto-configured for that filesystem."
        warn "Enable user quotas for it, reboot, then re-run stage 45."
        ;;
    esac
  fi
fi

log "hardening stage complete"
log "  some controls (/tmp tmpfs, /proc hidepid, sysctl) fully apply after a reboot."
