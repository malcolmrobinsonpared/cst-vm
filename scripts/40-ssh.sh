#!/usr/bin/env bash
# 40-ssh.sh — SSH access + hardening for the student group (no GUI, no X11).
set -euo pipefail
source "${HERE:?run via provision.sh}/config.env"

log "ensuring OpenSSH server is installed"
apt-get install -y --no-install-recommends openssh-server

log "writing /etc/ssh/sshd_config.d/50-students.conf"
tmp="$(mktemp)"
sed \
  -e "s|@SSH_PORT@|${SSH_PORT}|g" \
  -e "s|@SSH_ALLOW_GROUPS@|${SSH_ALLOW_GROUPS}|g" \
  -e "s|@SSH_PASSWORD_AUTH@|${SSH_PASSWORD_AUTH}|g" \
  "${HERE}/etc/ssh/sshd_config.d/50-students.conf" > "${tmp}"
install -m 0644 -o root -g root "${tmp}" /etc/ssh/sshd_config.d/50-students.conf
rm -f "${tmp}"

# Validate before reloading so a typo can't lock everyone out.
log "validating sshd config"
if sshd -t; then
  systemctl reload ssh 2>/dev/null || systemctl reload sshd
  log "  sshd reloaded"
else
  die "sshd -t failed; NOT reloading. Fix 50-students.conf and re-run."
fi

# --- keep students out of sudo ----------------------------------------------
# Belt-and-suspenders: assert the student group is not granted sudo anywhere.
if grep -RsqE "^%${STUDENT_GROUP}\b" /etc/sudoers /etc/sudoers.d 2>/dev/null; then
  warn "the student group appears in sudoers — students should NOT have sudo."
fi

log "ssh stage complete"
log "  students connect with:  ssh <username>@<vm-host> -p ${SSH_PORT}  (e.g. 28jane.doe)"
