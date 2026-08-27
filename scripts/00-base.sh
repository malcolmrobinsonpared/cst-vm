#!/usr/bin/env bash
# 00-base.sh — base packages, updates, hardening scaffolding.
set -euo pipefail
source "${HERE:?run via provision.sh}/config.env"
source "${HERE}/lib/common.sh"

log "updating apt and installing base packages"
apt-get update -y
apt-get -y full-upgrade

# Core utilities + build toolchain (needed by pip wheels, node-gyp, cgo).
apt-get install -y --no-install-recommends \
  ca-certificates curl wget gnupg lsb-release \
  build-essential pkg-config git \
  htop tmux rsync unzip zip jq ripgrep fd-find tree \
  bash-completion man-db less \
  software-properties-common \
  unattended-upgrades fail2ban \
  acl

# --- automatic security updates ---------------------------------------------
log "enabling unattended security upgrades"
cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

# --- fail2ban: protect the public SSH port ----------------------------------
log "configuring fail2ban for sshd"
f2b_tmp="$(mktemp)"
cat >"${f2b_tmp}" <<EOF
[sshd]
enabled  = true
port     = ${SSH_PORT}
backend  = systemd
maxretry = 5
findtime = 10m
bantime  = 1h
# Never ban these (e.g. admin jump hosts). loopback is implicit.
ignoreip = 127.0.0.1/8 ::1 ${FAIL2BAN_IGNORE_IPS:-}
EOF
f2b_changed=0
write_if_changed "${f2b_tmp}" /etc/fail2ban/jail.d/sshd.local 0644 && f2b_changed=1 || true
systemctl enable fail2ban >/dev/null 2>&1 || true
# fail2ban is already running after apt-install, so `enable --now` never re-reads
# the jail. Reload only when it changed (or isn't running) so a changed SSH_PORT
# / ignore-list actually converges on the live daemon, but a plain re-run is a
# no-op. A fail2ban reload does not drop established SSH sessions.
if (( f2b_changed )) || ! systemctl is-active --quiet fail2ban; then
  systemctl reload-or-restart fail2ban || warn "fail2ban reload failed"
fi

# --- timezone (so "nightly reboot" and logs are in local time) --------------
if [[ -n "${TIMEZONE:-}" ]]; then
  log "setting timezone to ${TIMEZONE}"
  timedatectl set-timezone "${TIMEZONE}" || warn "could not set timezone ${TIMEZONE}"
fi

# --- swap file ---------------------------------------------------------------
# Ubuntu server/cloud images have no swap at all. Symmetric like the rest of the
# build: SWAP_SIZE="" swaps off, drops the fstab entry and deletes the file.
# Only the size is convergent — a changed SWAP_SIZE recreates the file, an
# unchanged one is a no-op (never a re-mkswap, which would churn the disk).

# Sizes like 4G / 512M / 1048576 (bare = bytes) -> bytes.
size_to_bytes() {
  local v="$1" n="${1%[GgMmKk]}" u="${1: -1}"
  case "$u" in
    G|g) echo $(( n * 1024 * 1024 * 1024 )) ;;
    M|m) echo $(( n * 1024 * 1024 )) ;;
    K|k) echo $(( n * 1024 )) ;;
    *)   echo "$v" ;;
  esac
}
swap_is_on() { swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$1"; }

SWAP_FILE="${SWAP_FILE:-/swapfile}"
if [[ -n "${SWAP_SIZE:-}" ]]; then
  swap_want="$(size_to_bytes "${SWAP_SIZE}")"
  swap_have=0
  [[ -f "${SWAP_FILE}" ]] && swap_have="$(stat -c %s "${SWAP_FILE}")"
  swap_fstype="$(findmnt -no FSTYPE -T "${SWAP_FILE}" 2>/dev/null || echo '')"

  if [[ "${swap_fstype}" == "btrfs" || "${swap_fstype}" == "zfs" ]]; then
    # Both need a specially-created (nocow / zvol) swap area; a plain file here
    # either fails to swapon or corrupts. Left to the admin deliberately.
    warn "swap: ${SWAP_FILE} lives on ${swap_fstype}, which needs a hand-built swap area; skipping."
  elif (( swap_have != swap_want )); then
    log "swap: creating ${SWAP_SIZE} swapfile at ${SWAP_FILE}"
    # Room for the new file, counting the space the old one gives back. Keep a
    # 1 GiB cushion so we never fill the disk the student homes share.
    swap_avail=$(( $(df --output=avail -B1 "$(dirname "${SWAP_FILE}")" | tail -1) + swap_have ))
    if (( swap_avail < swap_want + 1024 * 1024 * 1024 )); then
      warn "  only $(( swap_avail / 1024 / 1024 ))M free where ${SWAP_FILE} would go; skipping."
    else
      swapoff "${SWAP_FILE}" 2>/dev/null || true
      rm -f "${SWAP_FILE}"
      # fallocate is instant on ext4; dd is the portable fallback.
      fallocate -l "${swap_want}" "${SWAP_FILE}" 2>/dev/null \
        || dd if=/dev/zero of="${SWAP_FILE}" bs=1M count=$(( swap_want / 1024 / 1024 )) status=none
      chmod 0600 "${SWAP_FILE}"
      mkswap "${SWAP_FILE}" >/dev/null
      swapon "${SWAP_FILE}" || warn "  swapon ${SWAP_FILE} failed"
    fi
  elif ! swap_is_on "${SWAP_FILE}"; then
    # Right size but not active (e.g. fstab entry added but never mounted).
    swapon "${SWAP_FILE}" || warn "  swapon ${SWAP_FILE} failed"
  fi

  if [[ -f "${SWAP_FILE}" ]]; then
    set_fstab_swap "${SWAP_FILE}" && log "  set ${SWAP_FILE} entry in /etc/fstab" || true
  fi
else
  if swap_is_on "${SWAP_FILE}"; then
    log "swap: SWAP_SIZE cleared — disabling ${SWAP_FILE}"
    # Needs free RAM to page everything back in; if it can't, leave the file be.
    swapoff "${SWAP_FILE}" || warn "  swapoff ${SWAP_FILE} failed (still in use); leaving it in place"
  fi
  if ! swap_is_on "${SWAP_FILE}"; then
    unset_fstab_swap "${SWAP_FILE}" && log "swap: removed ${SWAP_FILE} entry from /etc/fstab" || true
    ensure_absent "${SWAP_FILE}" && log "swap: removed ${SWAP_FILE}" || true
  fi
fi

# --- nightly maintenance reboot ---------------------------------------------
# Applies pending kernel/security updates and resets shared state. A systemd
# timer (OnCalendar honours the timezone above) rather than user cron.
if [[ -n "${AUTO_REBOOT_TIME:-}" ]]; then
  log "scheduling nightly reboot at ${AUTO_REBOOT_TIME} (${TIMEZONE:-system tz})"
  nr_changed=0
  nr_svc="$(mktemp)"
  cat >"${nr_svc}" <<'EOF'
[Unit]
Description=Nightly maintenance reboot (managed by provision.sh)
[Service]
Type=oneshot
ExecStart=/usr/sbin/shutdown -r now "Nightly maintenance reboot"
EOF
  write_if_changed "${nr_svc}" /etc/systemd/system/nightly-reboot.service 0644 && nr_changed=1 || true
  nr_tmr="$(mktemp)"
  cat >"${nr_tmr}" <<EOF
[Unit]
Description=Nightly maintenance reboot at ${AUTO_REBOOT_TIME}
[Timer]
OnCalendar=*-*-* ${AUTO_REBOOT_TIME}:00
Persistent=false
[Install]
WantedBy=timers.target
EOF
  write_if_changed "${nr_tmr}" /etc/systemd/system/nightly-reboot.timer 0644 && nr_changed=1 || true
  (( nr_changed )) && systemctl daemon-reload || true
  systemctl enable --now nightly-reboot.timer >/dev/null
else
  systemctl disable --now nightly-reboot.timer 2>/dev/null || true
  nr_removed=0
  ensure_absent /etc/systemd/system/nightly-reboot.timer   && nr_removed=1 || true
  ensure_absent /etc/systemd/system/nightly-reboot.service && nr_removed=1 || true
  (( nr_removed )) && systemctl daemon-reload || true
fi

# --- make sure cgroups v2 unified hierarchy + memory accounting are on -------
# Ubuntu 22.04+ already boots cgroup v2 by default; verify and enable
# per-user accounting so the slice limits in 20-cgroups.sh take effect.
if [[ ! -f /sys/fs/cgroup/cgroup.controllers ]]; then
  warn "cgroup v2 unified hierarchy not detected — check GRUB cmdline."
fi

log "base stage complete"
