#!/usr/bin/env bash
# 48-motd.sh — student welcome message shown at every login (/etc/motd).
#
# States the house rules up front so students (and their teachers) aren't
# surprised by them: sessions end on logout/idle, no sudo, venv for pip, the
# dev-server port range, the disk quota, and "back up with git".
set -euo pipefail
source "${HERE:?run via provision.sh}/config.env"

# Idle-logout note, in minutes, only if the timeout is enabled.
idle_note=""
if [[ -n "${HARDENING_IDLE_TIMEOUT:-}" && "${HARDENING_IDLE_TIMEOUT}" != "0" ]]; then
  idle_note=" or after $(( HARDENING_IDLE_TIMEOUT / 60 )) min idle"
fi

log "writing /etc/motd (student welcome)"
cat >/etc/motd <<EOF

  =================================================================
    Welcome to the PARED student dev server.
  =================================================================

  - Back up your work with GIT. Home directories are NOT backed up
    for you: commit and push to GitHub regularly.

  - Your session ends when you log out${idle_note}, and background
    programs stop when you disconnect.

  - Disk space is limited to about ${QUOTA_HARD} per person.  Check yours:
        quota -s

  - No sudo. Python, Node, Go and many common libraries are already installed. 
    Need a system package? Ask ${MOTD_IT_CONTACT}.

  - Python packages: use a virtual environment for your own packages:
        python3 -m venv .venv 
        source .venv/bin/activate
        pip install ...

  - Dev web servers: listen on a port in ${MOTD_DEV_PORTS} and bind
    0.0.0.0 (not 127.0.0.1) to reach it from your browser on the network.

  Need help? Contact ${MOTD_IT_CONTACT}.

EOF

# Ubuntu's dynamic MOTD fetches "news" over the network at login; turn that off
# (privacy + a little login latency) while leaving the rest of the MOTD alone.
if [[ -f /etc/default/motd-news ]]; then
  sed -i 's/^ENABLED=.*/ENABLED=0/' /etc/default/motd-news || true
fi

log "motd stage complete"
