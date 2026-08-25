# lib/common.sh — shared idempotency helpers, sourced by the stage scripts.
#
# All mutating helpers report whether they actually CHANGED anything via their
# exit status (0 = changed, 1 = already in the desired state). This lets callers
# gate service reloads/remounts on real changes, so a plain re-run is a no-op but
# a changed config.env value still converges.
#
# IMPORTANT: the stages run under `set -e`. A helper returning 1 ("no change")
# would abort the script if called bare. ALWAYS call these in a condition —
# `if helper ...; then`, `helper ... && x`, or `helper ... || true` — never bare.
#
# Requires the log()/warn() helpers exported by provision.sh.

# write_if_changed <src-tmp> <dest> [mode]
#   Install <src> to <dest> only when the content differs. Always consumes
#   (removes) <src>. Returns 0 if <dest> changed, 1 if it was already identical.
write_if_changed() {
  local src="$1" dest="$2" mode="${3:-0644}"
  if [[ -f "$dest" ]] && cmp -s "$src" "$dest"; then
    rm -f "$src"; return 1
  fi
  install -m "$mode" -o root -g root "$src" "$dest"
  rm -f "$src"
  return 0
}

# ensure_absent <file>
#   Remove <file> if present. Returns 0 if it existed (so the caller can reload a
#   service), 1 if it was already gone.
ensure_absent() {
  [[ -e "$1" ]] || return 1
  rm -f "$1"
  return 0
}

# ---- /etc/fstab: marker-managed, mountpoint-authoritative -------------------
# The managed line for a mountpoint is the single source of truth for it. set_*
# drops EVERY active fstab line for that mountpoint and appends exactly one, so
# value changes (size, gid, opts) and re-runs converge instead of appending
# duplicates, and unset_* fully removes it. A single stable backup is kept (not a
# new timestamped file each run, which would accumulate).
FSTAB="/etc/fstab"
FSTAB_MARK="# managed-by-provision"

_fstab_has_root() { awk '!/^[[:space:]]*#/ && $2=="/" {f=1} END{exit f?0:1}' "$1"; }

_fstab_commit() { # <newfile> — refuse if it would drop the root mount; back up; install
  if ! _fstab_has_root "$1"; then
    warn "fstab: refusing an edit that would drop the root mount; leaving /etc/fstab untouched"
    rm -f "$1"; return 2
  fi
  cp -a "$FSTAB" "${FSTAB}.provision.bak"
  cat "$1" > "$FSTAB"; rm -f "$1"
  return 0
}

# set_fstab_mount <mountpoint> <line-without-marker>
#   Make <line> the one active fstab entry for <mountpoint>. 0 if fstab changed.
set_fstab_mount() {
  local mp="$1" want="$2 ${FSTAB_MARK}" t; t="$(mktemp)"
  awk -v mp="$mp" '!/^[[:space:]]*#/ && $2==mp {next} {print}' "$FSTAB" > "$t"
  printf '%s\n' "$want" >> "$t"
  if cmp -s "$t" "$FSTAB"; then rm -f "$t"; return 1; fi
  _fstab_commit "$t"
}

# unset_fstab_mount <mountpoint>
#   Drop every active fstab entry for <mountpoint>. 0 if fstab changed.
unset_fstab_mount() {
  local mp="$1" t; t="$(mktemp)"
  awk -v mp="$mp" '!/^[[:space:]]*#/ && $2==mp {next} {print}' "$FSTAB" > "$t"
  if cmp -s "$t" "$FSTAB"; then rm -f "$t"; return 1; fi
  _fstab_commit "$t"
}

# set_fstab_opt <mountpoint> <opt> / unset_fstab_opt <mountpoint> <opt>
#   Add/remove ONE option in field 4 of an EXISTING fstab entry (used for
#   usrquota on '/', which modifies the distro's own line rather than adding a
#   new one). 0 if fstab changed, 1 if already in the wanted state.
set_fstab_opt() {
  local mp="$1" opt="$2" t; t="$(mktemp)"
  awk -v mp="$mp" -v opt="$opt" '
    /^[[:space:]]*#/ { print; next }
    NF>=4 && $2==mp {
      n=split($4,a,","); have=0
      for (i=1;i<=n;i++) if (a[i]==opt) have=1
      if (!have) $4=$4","opt
      printf "%s %s %s %s %s %s\n",$1,$2,$3,$4,($5==""?"0":$5),($6==""?"0":$6); next
    }
    { print }
  ' "$FSTAB" > "$t"
  if cmp -s "$t" "$FSTAB"; then rm -f "$t"; return 1; fi
  _fstab_commit "$t"
}
unset_fstab_opt() {
  local mp="$1" opt="$2" t; t="$(mktemp)"
  awk -v mp="$mp" -v opt="$opt" '
    /^[[:space:]]*#/ { print; next }
    NF>=4 && $2==mp {
      n=split($4,a,","); out=""
      for (i=1;i<=n;i++) if (a[i]!=opt) out=(out==""?a[i]:out","a[i])
      if (out=="") out="defaults"
      $4=out
      printf "%s %s %s %s %s %s\n",$1,$2,$3,$4,($5==""?"0":$5),($6==""?"0":$6); next
    }
    { print }
  ' "$FSTAB" > "$t"
  if cmp -s "$t" "$FSTAB"; then rm -f "$t"; return 1; fi
  _fstab_commit "$t"
}
