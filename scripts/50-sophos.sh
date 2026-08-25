#!/usr/bin/env bash
# 50-sophos.sh — install Sophos Central endpoint protection.
#
# Runs the Sophos installer IF you've placed it next to provision.sh. The file
# is NOT in this repo (it embeds your tenant token): download SophosSetup.sh
# from your Sophos Central account and drop it in the build directory. This
# stage runs last, so the box is fully provisioned before the on-access scanner
# comes up. Runs as root (stages already run as root — no separate sudo needed).
set -euo pipefail
source "${HERE:?run via provision.sh}/config.env"

installer="${HERE}/${SOPHOS_INSTALLER}"

# Idempotent: Sophos SPL installs under /opt/sophos-spl.
if [[ -d /opt/sophos-spl ]]; then
  log "Sophos already installed (/opt/sophos-spl present) — skipping"
  exit 0
fi

if [[ ! -f "${installer}" ]]; then
  warn "Sophos installer not found at ${installer} — skipping."
  warn "  Download SophosSetup.sh from Sophos Central, place it next to provision.sh,"
  warn "  then re-run:  sudo bash provision.sh 50"
  exit 0
fi

log "installing Sophos endpoint protection (--products=${SOPHOS_PRODUCTS})"
chmod +x "${installer}" 2>/dev/null || true
if bash "${installer}" --products="${SOPHOS_PRODUCTS}"; then
  log "Sophos install finished"
  log "  IMPORTANT: confirm the box registered in your Sophos Central console"
  log "  (Devices -> Servers) and shows healthy before go-live — that's the"
  log "  compliance check the Ubuntu-over-NixOS decision was made for."
else
  die "Sophos installer failed (exit $?). Check network + token, then re-run stage 50."
fi
