#!/usr/bin/env bash
# 10-users.sh — reconcile local student accounts against a CSV roster.
#
# The CSV (STUDENT_ROSTER_CSV) is the source of truth. Each run:
#   * creates accounts that are new in the CSV,
#   * re-enables previously-disabled students who reappear in it,
#   * disables (default) or deletes accounts that were dropped from it,
#   * leaves existing active accounts — and their passwords — alone.
#
# The "managed set" is the members of STUDENT_GROUP, so admin/system accounts
# are never touched. Usernames use the grad-year scheme YYfirst.last, e.g.
# 28jane.doe (class of 2028); the leading digits need useradd --badnames.
#
#   sudo bash scripts/10-users.sh                    # reconcile
#   sudo bash scripts/10-users.sh --dry-run          # show the plan, change nothing
#   sudo bash scripts/10-users.sh --reset-passwords  # also re-apply CSV passwords to existing users
#   sudo bash scripts/10-users.sh --delete           # remove dropped accounts (override the config default)
set -euo pipefail
# Self-locate so `sudo bash scripts/10-users.sh` works standalone too.
: "${HERE:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${HERE}/config.env"

type log  >/dev/null 2>&1 || log()  { printf '[10-users] %s\n' "$*"; }
type warn >/dev/null 2>&1 || warn() { printf '[warn] %s\n' "$*" >&2; }
type die  >/dev/null 2>&1 || die()  { printf '[error] %s\n' "$*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || die "must run as root"

# --- flags -------------------------------------------------------------------
DRY=0; RESET_PW=0
ACTION="${REMOVED_ACCOUNT_ACTION:-disable}"
for arg in "$@"; do
  case "$arg" in
    --dry-run)         DRY=1 ;;
    --reset-passwords) RESET_PW=1 ;;
    --delete)          ACTION="delete" ;;
    --disable)         ACTION="disable" ;;
    *) die "unknown argument: ${arg}" ;;
  esac
done
[[ "$ACTION" == "disable" || "$ACTION" == "delete" ]] \
  || die "REMOVED_ACCOUNT_ACTION must be 'disable' or 'delete' (got '${ACTION}')"

[[ -f "${STUDENT_ROSTER_CSV}" ]] \
  || die "roster CSV not found: ${STUDENT_ROSTER_CSV} (copy students.csv.example and fill it in)"

# Warn if the roster (plaintext passwords) is readable by group/other.
perms="$(stat -c '%a' "${STUDENT_ROSTER_CSV}" 2>/dev/null || echo '')"
if [[ -n "$perms" && "${perms: -2}" != "00" ]]; then
  warn "roster ${STUDENT_ROSTER_CSV} is mode ${perms}; it holds plaintext passwords — 'chmod 600' it."
fi

# --- helpers -----------------------------------------------------------------
# do_cmd: print the action in --dry-run, otherwise execute it (args-safe, no eval).
do_cmd() {
  if (( DRY )); then printf '   [plan] %s\n' "$*"; return 0; fi
  "$@"
}
set_password() { # user plaintext
  if (( DRY )); then printf '   [plan] set password: %s\n' "$1"; return 0; fi
  echo "$1:$2" | chpasswd
}
gen_pw() {
  local charset='ABCDEFGHJKMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789'
  # `head` closes the pipe after PW_LENGTH bytes, which SIGPIPE-kills `tr`
  # (exit 141). Under `set -o pipefail` that would fail the whole pipeline and
  # `set -e` would abort the run on every blank-password row. Feed `tr` via
  # process substitution so the pipeline is just `head` (clean exit 0); `tr`'s
  # SIGPIPE is no longer part of the pipeline status.
  head -c "${PW_LENGTH}" < <(LC_ALL=C tr -dc "${charset}" </dev/urandom)
}
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

# --- students group ----------------------------------------------------------
if ! getent group "${STUDENT_GROUP}" >/dev/null; then
  log "creating group ${STUDENT_GROUP}"
  do_cmd groupadd "${STUDENT_GROUP}"
fi

# --- detect useradd --badnames (permits the YY-prefixed usernames) -----------
BADNAMES_FLAG=""
if useradd --help 2>&1 | grep -oq -- '--badnames\?'; then
  BADNAMES_FLAG="$(useradd --help 2>&1 | grep -o -- '--badnames\?' | head -1)"
else
  warn "useradd has no --badnames flag; digit-leading usernames (e.g. 28jane.doe) may be rejected."
fi

# --- credentials file (created only if we generate any passwords) ------------
CREDS_STARTED=0
record_generated() { # user plaintext
  if (( DRY )); then return 0; fi
  if (( ! CREDS_STARTED )); then
    umask 077
    # Append across runs: write the header only when the file is new/empty, so a
    # later run that adds one student can't truncate and lose the passwords
    # generated for earlier students.
    if [[ ! -s "${CREDENTIALS_FILE}" ]]; then
      { echo "# Generated passwords (blank CSV rows) — $(date -Is)"
        echo "# username : password"; } >"${CREDENTIALS_FILE}"
    fi
    chmod 0600 "${CREDENTIALS_FILE}"
    CREDS_STARTED=1
  fi
  printf '%s : %s\n' "$1" "$2" >>"${CREDENTIALS_FILE}"
}

# --- parse desired set from the CSV ------------------------------------------
declare -A want_pw want_cmt want_seen
firstline=1
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%$'\r'}"                       # strip CR (Windows-edited CSV)
  (( firstline )) && line="${line#$'﻿'}"        # strip UTF-8 BOM on first line
  firstline=0
  [[ -z "${line//[[:space:]]/}" ]] && continue        # blank
  [[ "${line#\#}" != "$line" ]] && continue           # comment
  IFS=',' read -r c_user c_pass c_cmt _ <<< "$line"
  c_user="$(trim "${c_user:-}")"; c_pass="$(trim "${c_pass:-}")"; c_cmt="$(trim "${c_cmt:-}")"
  [[ -z "$c_user" ]] && continue
  c_user="${c_user,,}"                                  # usernames are lowercase
  [[ "$c_user" == "username" ]] && continue            # header row
  if [[ -n "${want_seen[$c_user]:-}" ]]; then
    warn "CSV: duplicate username '${c_user}' (keeping first)"
    continue
  fi
  want_seen[$c_user]=1
  want_pw[$c_user]="$c_pass"
  want_cmt[$c_user]="$c_cmt"
done < "${STUDENT_ROSTER_CSV}"

(( ${#want_seen[@]} > 0 )) || die "no valid students parsed from ${STUDENT_ROSTER_CSV}"

# --- current managed set = members of STUDENT_GROUP --------------------------
declare -A is_current
members="$(getent group "${STUDENT_GROUP}" | awk -F: '{print $4}')"
IFS=',' read -ra marr <<< "${members}"
for u in "${marr[@]}"; do [[ -n "$u" ]] && is_current[$u]=1; done

# --- reconcile ---------------------------------------------------------------
added=0 reenabled=0 kept=0 removed=0 gencount=0

for u in "${!want_pw[@]}"; do
  pw="${want_pw[$u]}"; cmt="${want_cmt[$u]}"

  if id "$u" >/dev/null 2>&1; then
    # ---- existing: ensure group/shell/comment and re-enable if disabled ----
    was_locked=0
    [[ "$(passwd -S "$u" 2>/dev/null | awk '{print $2}')" == "L" ]] && was_locked=1

    do_cmd usermod -a -G "${STUDENT_GROUP}" "$u"
    do_cmd usermod -s "${STUDENT_SHELL}" "$u"
    do_cmd chage -E -1 "$u"                              # clear any account expiry
    [[ -n "$cmt" ]] && do_cmd usermod -c "$cmt" "$u"
    if (( was_locked )); then
      if (( DRY )); then printf '   [plan] unlock %s\n' "$u"; else usermod -U "$u" 2>/dev/null || true; fi
      log "re-enable ${u} (was disabled, back on roster)"
      reenabled=$(( reenabled + 1 ))
    else
      kept=$(( kept + 1 ))
    fi

    if (( RESET_PW )); then
      if [[ -z "$pw" ]]; then pw="$(gen_pw)"; record_generated "$u" "$pw"; gencount=$(( gencount + 1 )); fi
      set_password "$u" "$pw"
      [[ "${FORCE_PW_CHANGE}" == "yes" ]] && do_cmd chage -d 0 "$u"
    fi
    continue
  fi

  # ---- new: create ----------------------------------------------------------
  gen_this=0
  if [[ -z "$pw" ]]; then pw="$(gen_pw)"; gen_this=1; fi
  ua_opts=(--create-home --shell "${STUDENT_SHELL}" --groups "${STUDENT_GROUP}" --comment "${cmt:-Student}")
  [[ -n "$BADNAMES_FLAG" ]] && ua_opts=("$BADNAMES_FLAG" "${ua_opts[@]}")
  if do_cmd useradd "${ua_opts[@]}" "$u"; then
    set_password "$u" "$pw"
    # Record the generated password ONLY after the account actually exists.
    # Otherwise a create that keeps failing (e.g. a name useradd rejects) would
    # mint a fresh password + orphan credentials line on every single re-run.
    if (( gen_this )); then record_generated "$u" "$pw"; gencount=$(( gencount + 1 )); fi
    [[ "${FORCE_PW_CHANGE}" == "yes" ]] && do_cmd chage -d 0 "$u"
    log "create ${u}"
    added=$(( added + 1 ))
  else
    warn "failed to create ${u} (name policy? see useradd --badnames)"
  fi
done

# --- removals: in the group but no longer in the CSV -------------------------
for u in "${!is_current[@]}"; do
  [[ -n "${want_seen[$u]:-}" ]] && continue
  if [[ "$ACTION" == "delete" ]]; then
    log "DELETE ${u} (dropped from roster) — home dir will be erased"
    if (( DRY )); then printf '   [plan] userdel -r %s\n' "$u"; else userdel -r "$u" 2>/dev/null || userdel "$u" || warn "userdel failed for ${u}"; fi
  else
    log "disable ${u} (dropped from roster) — home dir kept"
    do_cmd usermod -L "$u" || true
    do_cmd chage -E 1 "$u"
    do_cmd usermod -s /usr/sbin/nologin "$u"
  fi
  removed=$(( removed + 1 ))
done

log "reconcile: ${added} added, ${reenabled} re-enabled, ${kept} unchanged, ${removed} ${ACTION}d, ${gencount} passwords generated"
(( CREDS_STARTED )) && log "generated passwords in ${CREDENTIALS_FILE} (0600) — distribute securely, then delete."
if (( DRY )); then log "(dry-run: nothing was changed)"; fi
if [[ "${FORCE_PW_CHANGE}" == "yes" && ( ${added} -gt 0 || ${RESET_PW} -eq 1 ) ]]; then
  log "affected students must set a new password at first login (SSH_PASSWORD_AUTH must be 'yes')"
fi