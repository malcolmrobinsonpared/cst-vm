#!/usr/bin/env bash
# 46-firewall.sh — host firewall (ufw): closed inbound, and an egress policy that
# keeps the box off its own LAN segment.
#
# The box shares a subnet with everything else on that segment, and ~20 students
# with a shell can reach all of it. So outbound stays OPEN to the wider network
# (which is reached through the gateway) but is BLOCKED to the local subnet
# itself, except for the on-subnet hosts the box genuinely needs — the gateway,
# plus anything else listed in FW_SUBNET_ALLOW_HOSTS. Inbound is default-deny
# with SSH and the dev-server range opened.
#
# Note what this does NOT break: inbound connections FROM an isolated subnet
# still work both ways, because ufw accepts established/related traffic in
# before.rules — ahead of these rules. An admin on the same subnet can still SSH
# in, and a peer can still reach a student's dev server.
#
# Idempotent + convergent like the rest of the build: the whole rule set is
# rendered to a spec file and only rebuilt when that spec changes (or when ufw
# has been switched off behind our back), so a plain re-run touches nothing.
# ENABLE_FIREWALL="no" reverts the box to no firewall at all.
set -euo pipefail
source "${HERE:?run via provision.sh}/config.env"
source "${HERE}/lib/common.sh"

yes() { [[ "${1:-no}" == "yes" ]]; }

SPEC_FILE=/var/lib/cst-vm/firewall.spec
IPV6_SYSCTL=/etc/sysctl.d/91-no-ipv6.conf

# ufw's `reset` copies the old rule files aside as <name>.<YYYYMMDD_HHMMSS>, one
# set per reset. Drop them: they'd accumulate, and this file is the source of
# truth for the rules anyway (config.env is the source of truth for the intent).
prune_ufw_backups() {
  find /etc/ufw -maxdepth 1 -type f -regextype posix-extended \
    -regex '.*\.(rules|conf)\.[0-9]{8}_[0-9]{6}' -delete 2>/dev/null || true
}

# --- IPv4 CIDR maths (for the pre-flight checks below) -----------------------
# Deliberately IPv4-only: these checks exist to catch a self-inflicted outage
# (blocking your own gateway or resolver), and on this network both are IPv4.
# An IPv6 entry in the config is passed through to ufw untouched, just unchecked.
_ip4() { [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; }
_ip_to_int() { local IFS=. a b c d; read -r a b c d <<<"$1"; echo $(( (a<<24)|(b<<16)|(c<<8)|d )); }

# ip_in_cidr <ip> <cidr-or-ip> — is <ip> covered by the second argument?
ip_in_cidr() {
  local ip="$1" spec="$2" net bits mask
  _ip4 "$ip" || return 1
  if [[ "$spec" == */* ]]; then net="${spec%/*}"; bits="${spec#*/}"; else net="$spec"; bits=32; fi
  _ip4 "$net" || return 1
  [[ "$bits" =~ ^[0-9]+$ ]] && (( bits <= 32 )) || return 1
  mask=$(( bits == 0 ? 0 : (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
  (( ($(_ip_to_int "$ip") & mask) == ($(_ip_to_int "$net") & mask) ))
}

# Would <ip> be blocked by the isolation rules? (in an isolated subnet, and not
# covered by any allow-host entry).
would_be_blocked() {
  local ip="$1" net host
  for host in ${FW_SUBNET_ALLOW_HOSTS:-}; do if ip_in_cidr "$ip" "$host"; then return 1; fi; done
  for net  in ${FW_ISOLATE_SUBNETS:-};    do if ip_in_cidr "$ip" "$net";  then return 0; fi; done
  return 1
}

# --- the IPv6 stack ----------------------------------------------------------
# set_ipv6_stack <yes|no> — "yes" turns IPv6 OFF (disable_ipv6=1), "no" restores
# it. Independent of the ufw half: FW_BLOCK_IPV6 is its own lever, so it is
# honoured even when ENABLE_FIREWALL is off. sysctl.d makes it survive reboots;
# `sysctl --system` (and the explicit -w on the revert) makes it take effect now.
#
# Why bother, when the rules above are IPv4? Because IPv6 needs neither a router
# nor DHCP to work on a link — every host autoconfigures a link-local address —
# so a student on this segment could reach every neighbour over v6 and never
# touch a single one of the IPv4 rules.
set_ipv6_stack() {
  if yes "${1:-no}"; then
    local tmp; tmp="$(mktemp)"
    cat >"${tmp}" <<'EOF'
# Managed by 46-firewall.sh — IPv6 is not used on this network, and leaving it
# up would give students a second, unfiltered path to their LAN neighbours.
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv6.conf.lo.disable_ipv6=1
EOF
    if write_if_changed "${tmp}" "${IPV6_SYSCTL}" 0644; then
      log "ipv6: disabling the stack (${IPV6_SYSCTL})"
      sysctl --system >/dev/null 2>&1 || warn "  sysctl --system reported an error"
    fi
    # Writing 'all' propagates to interfaces that already exist, so a re-run on a
    # live box converges even if the file was already in place but never applied.
    sysctl -qw net.ipv6.conf.all.disable_ipv6=1 2>/dev/null || true
  else
    if ensure_absent "${IPV6_SYSCTL}"; then
      log "ipv6: re-enabling the stack (removed ${IPV6_SYSCTL})"
      sysctl --system >/dev/null 2>&1 || true
      # Removing the file only stops it being applied at the NEXT boot; clear the
      # live values too so the revert is real rather than pending.
      sysctl -qw net.ipv6.conf.all.disable_ipv6=0 2>/dev/null || true
      sysctl -qw net.ipv6.conf.default.disable_ipv6=0 2>/dev/null || true
      sysctl -qw net.ipv6.conf.lo.disable_ipv6=0 2>/dev/null || true
      warn "  interfaces get their v6 addresses back on the next network restart or reboot."
    fi
  fi
}

# Every IPv4 resolver this box is currently configured to use.
resolvers() {
  { resolvectl dns 2>/dev/null | tr ' ' '\n'
    awk '/^[[:space:]]*nameserver/ {print $2}' /etc/resolv.conf 2>/dev/null
  } | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' | sort -u
}

# --- disabled: tear the firewall back down ----------------------------------
if ! yes "${ENABLE_FIREWALL:-no}"; then
  # The spec file is how we know whether this run is the one turning it off (so
  # the warning below fires once, on the actual transition) or just a re-run of
  # an already-unfirewalled box.
  was_managed=0
  [[ -f "${SPEC_FILE}" ]] && was_managed=1
  if command -v ufw >/dev/null 2>&1; then
    log "firewall: ENABLE_FIREWALL is not 'yes' — clearing rules and disabling ufw"
    # Reset rather than just disable: it also clears rules left behind from an
    # earlier config, which `ufw status` can't even enumerate while inactive.
    ufw --force reset >/dev/null 2>&1 || warn "  ufw reset failed"
    prune_ufw_backups
    ufw --force disable >/dev/null 2>&1 || warn "  ufw disable failed"
  fi
  ensure_absent "${SPEC_FILE}" || true
  (( was_managed )) && warn "  the box is now unfiltered: inbound is open and students can reach the whole subnet." || true
  # The IPv6 half is independent of the ufw half, so it gets torn down here too.
  set_ipv6_stack "${FW_BLOCK_IPV6:-no}"
  log "firewall stage complete (disabled)"
  exit 0
fi

log "firewall: installing ufw"
apt-get install -y --no-install-recommends ufw >/dev/null

# --- build the rule set ------------------------------------------------------
# Order matters: ufw evaluates user rules top-down, first match wins, so the
# on-subnet exceptions have to be added BEFORE the subnet-wide block.
declare -a RULES=()

# Inbound. FW_ALLOW_INBOUND_FROM="" means "from anywhere".
for port in ${FW_ALLOW_INBOUND_TCP:-}; do
  if [[ -n "${FW_ALLOW_INBOUND_FROM:-}" ]]; then
    for src in ${FW_ALLOW_INBOUND_FROM}; do
      RULES+=("allow in from ${src} to any port ${port} proto tcp")
    done
  else
    RULES+=("allow in ${port}/tcp")
  fi
done

# Outbound: exceptions first, then the blanket block per isolated subnet.
isolate_action="${FW_ISOLATE_ACTION:-reject}"
case "${isolate_action}" in
  reject|deny) : ;;
  *) warn "FW_ISOLATE_ACTION='${isolate_action}' is not reject/deny; using reject."
     isolate_action="reject" ;;
esac
log_opt=""; yes "${FW_LOG_ISOLATED:-no}" && log_opt=" log"

for host in ${FW_SUBNET_ALLOW_HOSTS:-}; do RULES+=("allow out to ${host}"); done
for net  in ${FW_ISOLATE_SUBNETS:-};    do RULES+=("${isolate_action} out${log_opt} to ${net}"); done

# IPv6, last so an explicit v6 exception above still wins. This lands only in
# ip6tables (ufw6-user-output -j DROP), so it can't affect any IPv4 rule.
# Inbound v6 needs no rule: `default deny incoming` already covers both families.
if yes "${FW_BLOCK_IPV6:-no}"; then RULES+=("deny out to ::/0"); fi

# --- pre-flight: refuse to lock ourselves out --------------------------------
# Both of these abort the stage BEFORE anything is applied, so a bad config
# leaves the running firewall exactly as it was.

# 1. SSH. Without a rule for it, `default deny incoming` ends remote admin.
ssh_ok=0
for port in ${FW_ALLOW_INBOUND_TCP:-}; do
  if [[ "${port}" == "${SSH_PORT}" ]]; then ssh_ok=1; fi
done
(( ssh_ok )) || die "FW_ALLOW_INBOUND_TCP does not list SSH_PORT (${SSH_PORT}) — that would lock everyone out. Fix config.env and re-run."

# 2. The default gateway. Blocking it doesn't isolate the subnet, it takes the
#    box off the network entirely (no apt, no npm, no Sophos, no anything).
gw="$(ip -4 route show default 2>/dev/null | awk '/via/ {print $3; exit}')"
if [[ -n "${gw}" ]] && would_be_blocked "${gw}"; then
  die "default gateway ${gw} falls in FW_ISOLATE_SUBNETS but isn't in FW_SUBNET_ALLOW_HOSTS — that would cut the box off the network. Add it and re-run."
fi
[[ -n "${gw}" ]] || warn "  no IPv4 default route found; skipping the gateway check."

# 3. DNS. A warning, not a hard stop: a stale resolver entry shouldn't block a
#    build, but a blocked one breaks name resolution for everybody.
for r in $(resolvers); do
  if would_be_blocked "$r"; then
    warn "  resolver ${r} is on an isolated subnet — add it to FW_SUBNET_ALLOW_HOSTS or DNS will stop working."
  fi
done

# --- IPv6 off at the stack ---------------------------------------------------
# Gated on its own file, so it converges independently of the ufw rule set.
set_ipv6_stack "${FW_BLOCK_IPV6:-no}"

# --- apply, but only when something actually changed -------------------------
spec="$(mktemp)"
{
  printf 'default: deny incoming / allow outgoing / deny routed\n'
  printf 'logging: %s\n' "${FW_LOGGING:-low}"
  printf 'ipv6: %s\n' "${FW_BLOCK_IPV6:-no}"
  printf 'rule: %s\n' "${RULES[@]}"
} >"${spec}"

install -d -m 0755 "$(dirname "${SPEC_FILE}")"
spec_changed=0
write_if_changed "${spec}" "${SPEC_FILE}" 0644 && spec_changed=1 || true

# ufw only writes ip6tables rules when IPV6=yes in its own config; with IPV6=no
# it silently skips every v6 rule, which would leave the block above a no-op.
ufw_ipv6_on() { grep -qiE '^IPV6=("?)yes\1$' /etc/ufw/ufw.conf 2>/dev/null; }

if (( spec_changed )) || ! ufw status 2>/dev/null | grep -q '^Status: active' || ! ufw_ipv6_on; then
  log "firewall: applying ${#RULES[@]} rules"
  # Reset first so the live rule set is exactly the spec — no leftovers from an
  # earlier config, and no duplicates. This leaves ufw DISABLED (i.e. traffic
  # unfiltered, never blocked) for the moment it takes to re-add the rules, so
  # there is no window in which an SSH session can be cut off.
  ufw --force reset >/dev/null
  prune_ufw_backups

  # Must be set before the rules are added, or the v6 ones are skipped.
  if ! ufw_ipv6_on; then
    sed -i 's/^IPV6=.*/IPV6=yes/' /etc/ufw/ufw.conf
    ufw_ipv6_on || printf 'IPV6=yes\n' >>/etc/ufw/ufw.conf
    log "  set IPV6=yes in /etc/ufw/ufw.conf (so ufw filters v6 at all)"
  fi

  ufw default deny incoming  >/dev/null
  ufw default allow outgoing >/dev/null
  ufw default deny routed    >/dev/null   # not a router; nothing should transit
  ufw logging "${FW_LOGGING:-low}" >/dev/null

  for rule in "${RULES[@]}"; do
    # Unquoted on purpose: each entry is a pre-built ufw argument list.
    ufw ${rule} >/dev/null || die "ufw rejected rule: ${rule}"
    log "  ${rule}"
  done

  ufw --force enable >/dev/null
  log "  ufw enabled (and enabled at boot)"
else
  log "firewall: rules unchanged and ufw already active; nothing to do"
fi

# The MOTD tells students which ports to bind; if the firewall doesn't open the
# same range they get a mystery "works from the box, not from my browser".
if [[ -n "${MOTD_DEV_PORTS:-}" ]] && [[ " ${FW_ALLOW_INBOUND_TCP} " != *" ${MOTD_DEV_PORTS//-/:} "* ]]; then
  warn "MOTD advertises dev ports ${MOTD_DEV_PORTS} but FW_ALLOW_INBOUND_TCP doesn't open ${MOTD_DEV_PORTS//-/:} — students' dev servers won't be reachable."
fi

log "firewall stage complete"
log "  outbound: open to the wider network; blocked to ${FW_ISOLATE_SUBNETS:-none} except ${FW_SUBNET_ALLOW_HOSTS:-none}"
log "  inbound:  deny by default; open tcp ${FW_ALLOW_INBOUND_TCP:-none} from ${FW_ALLOW_INBOUND_FROM:-anywhere}"
if yes "${FW_BLOCK_IPV6:-no}"; then
  log "  ipv6:     stack disabled + dropped at the firewall"
else
  log "  ipv6:     left enabled — note the subnet rules above are IPv4 only"
fi
