#!/usr/bin/env bash
# 40-ssh.sh — SSH access + hardening for the student group (no GUI, no X11).
set -euo pipefail
source "${HERE:?run via provision.sh}/config.env"
source "${HERE}/lib/common.sh"

log "ensuring OpenSSH server is installed"
apt-get install -y --no-install-recommends openssh-server

log "writing /etc/ssh/sshd_config.d/50-students.conf"
dest=/etc/ssh/sshd_config.d/50-students.conf
tmp="$(mktemp)"
sed \
  -e "s|@SSH_PORT@|${SSH_PORT}|g" \
  -e "s|@SSH_ALLOW_GROUPS@|${SSH_ALLOW_GROUPS}|g" \
  -e "s|@SSH_PASSWORD_AUTH@|${SSH_PASSWORD_AUTH}|g" \
  "${HERE}/etc/ssh/sshd_config.d/50-students.conf" > "${tmp}"

# Keep a copy of the current drop-in so we can roll back if the new one won't
# parse. Install + validate + reload only when the rendered content changed, so
# an unchanged re-run neither rewrites the file nor re-signals sshd.
prev=""
[[ -f "${dest}" ]] && { prev="$(mktemp)"; cp -a "${dest}" "${prev}"; }
if write_if_changed "${tmp}" "${dest}" 0644; then
  log "validating sshd config"
  if sshd -t; then
    systemctl reload ssh 2>/dev/null || systemctl reload sshd
    log "  sshd config changed; sshd reloaded"
  else
    # Roll back so a typo can't lock everyone out.
    if [[ -n "${prev}" ]]; then cp -a "${prev}" "${dest}"; rm -f "${prev}"; else rm -f "${dest}"; fi
    die "sshd -t failed; reverted the drop-in and did NOT reload. Fix the template and re-run."
  fi
else
  log "  sshd drop-in unchanged; no reload"
fi
[[ -n "${prev}" ]] && rm -f "${prev}" || true

# --- keep students out of sudo ----------------------------------------------
# Belt-and-suspenders: assert the student group is not granted sudo anywhere.
if grep -RsqE "^%${STUDENT_GROUP}\b" /etc/sudoers /etc/sudoers.d 2>/dev/null; then
  warn "the student group appears in sudoers — students should NOT have sudo."
fi

log "ssh stage complete"
log "  students connect with:  ssh <username>@<vm-host> -p ${SSH_PORT}  (e.g. 28jane.doe)"
