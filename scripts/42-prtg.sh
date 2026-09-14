#!/usr/bin/env bash
# 42-prtg.sh — a locked-down, key-only SSH account for a PRTG probe to monitor
# this box with its SSH sensors (SSH Load Average / Meminfo / Disk Free / uptime).
#
# Why SSH and not SNMP/WMI: this is a headless Linux box behind a default-deny
# firewall that only opens SSH + the dev-server range, so the SSH sensors are the
# path that needs nothing new opened at the protocol level. They read /proc and
# run `df` — no privilege required — so this account is unprivileged. It is:
#   * in its OWN group (PRTG_GROUP), never STUDENT_GROUP — so 10-users.sh, which
#     reconciles the student group against the CSV, never disables it;
#   * not in ADMIN_GROUP — no sudo;
#   * key-only: the password is locked, and the key is pinned with from="PROBE"
#     plus `restrict`, so it is unusable from any other host and cannot forward.
#
# The matching network + fail2ban openings live in config.env: FW_ALLOW_INBOUND_
# FROM and FAIL2BAN_IGNORE_IPS both pick up PRTG_PROBE_IP while monitoring is on,
# and SSH_ALLOW_GROUPS picks up PRTG_GROUP (rendered into sshd by 40-ssh). Run a
# full ./provision.sh (or at least stages 00, 40, 42, 46) so those converge too.
#
# Convergent: ENABLE_PRTG_MONITORING="no" + a re-run removes the account and its
# group (and, via config.env, closes the firewall/fail2ban openings).
set -euo pipefail
source "${HERE:?run via provision.sh}/config.env"
source "${HERE}/lib/common.sh"

yes() { [[ "${1:-no}" == "yes" ]]; }

PRTG_USER="${PRTG_USER:-prtg}"
PRTG_GROUP="${PRTG_GROUP:-prtg}"

# --- disabled: tear the account back down ------------------------------------
if ! yes "${ENABLE_PRTG_MONITORING:-no}"; then
  if id "${PRTG_USER}" >/dev/null 2>&1; then
    log "prtg: ENABLE_PRTG_MONITORING is not 'yes' — removing account ${PRTG_USER}"
    userdel -r "${PRTG_USER}" 2>/dev/null || userdel "${PRTG_USER}" || warn "  userdel ${PRTG_USER} failed"
  fi
  if getent group "${PRTG_GROUP}" >/dev/null; then
    groupdel "${PRTG_GROUP}" 2>/dev/null || warn "  groupdel ${PRTG_GROUP} failed (still has members?)"
  fi
  log "prtg stage complete (disabled)"
  exit 0
fi

# --- group -------------------------------------------------------------------
if ! getent group "${PRTG_GROUP}" >/dev/null; then
  log "prtg: creating group ${PRTG_GROUP}"
  groupadd --system "${PRTG_GROUP}"
fi

# --- account -----------------------------------------------------------------
# Needs a home (for ~/.ssh/authorized_keys) and a real shell (PRTG runs each
# sensor over the SSH exec channel, e.g. `sh -c "cat /proc/loadavg"`).
if ! id "${PRTG_USER}" >/dev/null 2>&1; then
  log "prtg: creating account ${PRTG_USER}"
  useradd --create-home --shell /bin/bash --gid "${PRTG_GROUP}" \
          --comment "PRTG monitoring (managed by provision.sh)" "${PRTG_USER}"
else
  # Converge the essentials in case they drifted; never touch the password here.
  usermod --gid "${PRTG_GROUP}" --shell /bin/bash "${PRTG_USER}"
fi
chage -E -1 "${PRTG_USER}" 2>/dev/null || true   # never expire the service account

# Guard: this account must never carry student or admin group membership.
for g in "${STUDENT_GROUP}" "${ADMIN_GROUP}"; do
  if id -nG "${PRTG_USER}" 2>/dev/null | tr ' ' '\n' | grep -qx "${g}"; then
    warn "  ${PRTG_USER} was a member of '${g}' — removing it (must not be)."
    gpasswd -d "${PRTG_USER}" "${g}" >/dev/null 2>&1 || true
  fi
done

# Key-only: lock the password so the pinned key below is the sole way in.
if [[ "$(passwd -S "${PRTG_USER}" 2>/dev/null | awk '{print $2}')" != "L" ]]; then
  passwd -l "${PRTG_USER}" >/dev/null
  log "  locked the password (key-only login)"
fi

# --- authorized key ----------------------------------------------------------
home="$(getent passwd "${PRTG_USER}" | cut -d: -f6)"
[[ -n "${home}" && -d "${home}" ]] || die "home dir for ${PRTG_USER} not found (${home:-unset})"
ssh_dir="${home}/.ssh"
auth="${ssh_dir}/authorized_keys"
install -d -m 0700 -o "${PRTG_USER}" -g "${PRTG_GROUP}" "${ssh_dir}"

if [[ -z "${PRTG_SSH_PUBKEY:-}" ]]; then
  warn "PRTG_SSH_PUBKEY is empty — account created but stays locked out until it's set."
  warn "  Generate a pair (ssh-keygen -t ed25519 -C prtg@probe -f prtg_key), give PRTG the"
  warn "  private key, put the .pub line in PRTG_SSH_PUBKEY, then re-run: sudo ./provision.sh 42"
  # Drop any stale key so removing the pubkey from config.env converges too.
  ensure_absent "${auth}" && log "  removed a stale authorized_keys" || true
  log "prtg stage complete (account ready, awaiting PRTG_SSH_PUBKEY)"
  exit 0
fi

# Validate the key before trusting it (a typo'd key would silently lock PRTG out).
keytmp="$(mktemp)"; printf '%s\n' "${PRTG_SSH_PUBKEY}" >"${keytmp}"
if ! ssh-keygen -l -f "${keytmp}" >/dev/null 2>&1; then
  rm -f "${keytmp}"
  die "PRTG_SSH_PUBKEY is not a valid OpenSSH public key. Fix config.env and re-run."
fi
rm -f "${keytmp}"

# Pin the key to the probe and lock it down; sensors run over exec (+ maybe pty),
# never a forward. from="" restricts it to the probe's IP even if the key leaks.
key_opts="from=\"${PRTG_PROBE_IP}\",${PRTG_SSH_KEY_OPTIONS:-restrict,pty}"
tmp="$(mktemp)"
{
  printf '# Managed by scripts/42-prtg.sh — do not edit by hand.\n'
  printf '%s %s\n' "${key_opts}" "${PRTG_SSH_PUBKEY}"
} >"${tmp}"

# Not write_if_changed: that installs root:root, but sshd StrictModes wants the
# file owned by the login user. Same compare-then-install idea, user-owned.
if [[ -f "${auth}" ]] && cmp -s "${tmp}" "${auth}"; then
  rm -f "${tmp}"
  log "  authorized_keys unchanged"
else
  install -m 0600 -o "${PRTG_USER}" -g "${PRTG_GROUP}" "${tmp}" "${auth}"
  rm -f "${tmp}"
  log "  installed authorized_keys (key pinned to ${PRTG_PROBE_IP})"
fi

log "prtg stage complete"
log "  account:  ${PRTG_USER} — group ${PRTG_GROUP}, no sudo, key-only, key pinned to ${PRTG_PROBE_IP}"
log "  in PRTG:  add this box as a device; set its Linux (SSH) credentials to user"
log "            '${PRTG_USER}' with the matching PRIVATE key; add the SSH sensors."
log "  test from the probe:  ssh -i <privkey> ${PRTG_USER}@<vm-ip> 'cat /proc/loadavg'"
