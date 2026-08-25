#!/usr/bin/env bash
# 00-base.sh — base packages, updates, hardening scaffolding.
set -euo pipefail
source "${HERE:?run via provision.sh}/config.env"

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
cat >/etc/fail2ban/jail.d/sshd.local <<EOF
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
systemctl enable --now fail2ban

# --- timezone (so "nightly reboot" and logs are in local time) --------------
if [[ -n "${TIMEZONE:-}" ]]; then
  log "setting timezone to ${TIMEZONE}"
  timedatectl set-timezone "${TIMEZONE}" || warn "could not set timezone ${TIMEZONE}"
fi

# --- nightly maintenance reboot ---------------------------------------------
# Applies pending kernel/security updates and resets shared state. A systemd
# timer (OnCalendar honours the timezone above) rather than user cron.
if [[ -n "${AUTO_REBOOT_TIME:-}" ]]; then
  log "scheduling nightly reboot at ${AUTO_REBOOT_TIME} (${TIMEZONE:-system tz})"
  cat >/etc/systemd/system/nightly-reboot.service <<'EOF'
[Unit]
Description=Nightly maintenance reboot (managed by provision.sh)
[Service]
Type=oneshot
ExecStart=/usr/sbin/shutdown -r now "Nightly maintenance reboot"
EOF
  cat >/etc/systemd/system/nightly-reboot.timer <<EOF
[Unit]
Description=Nightly maintenance reboot at ${AUTO_REBOOT_TIME}
[Timer]
OnCalendar=*-*-* ${AUTO_REBOOT_TIME}:00
Persistent=false
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now nightly-reboot.timer
else
  systemctl disable --now nightly-reboot.timer 2>/dev/null || true
  rm -f /etc/systemd/system/nightly-reboot.timer /etc/systemd/system/nightly-reboot.service
fi

# --- make sure cgroups v2 unified hierarchy + memory accounting are on -------
# Ubuntu 22.04+ already boots cgroup v2 by default; verify and enable
# per-user accounting so the slice limits in 20-cgroups.sh take effect.
if [[ ! -f /sys/fs/cgroup/cgroup.controllers ]]; then
  warn "cgroup v2 unified hierarchy not detected — check GRUB cmdline."
fi

log "base stage complete"
