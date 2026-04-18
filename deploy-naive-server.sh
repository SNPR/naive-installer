#!/usr/bin/env bash
# deploy-naive-server.sh — turnkey NaiveProxy server deployment.
#
# Builds Caddy with the klzgrad/forwardproxy plugin (naive branch), writes a
# locked-down Caddyfile with basic_auth + probe_resistance + masking site,
# installs a systemd unit, opens UFW, enables BBR, and prints the client URL.
#
# Target OS: Ubuntu 22.04/24.04, Debian 12. Run as root on a fresh box whose
# A-record already resolves to this server's public IP.
#
# Usage (interactive — will ask for domain / email / html path):
#   bash deploy-naive-server.sh
#
# Usage (non-interactive — any env var provided up-front skips its prompt):
#   DOMAIN=proxy.example.com EMAIL=you@example.com bash deploy-naive-server.sh
#
# Optional env:
#   DOMAIN       your domain (asked if missing)
#   EMAIL        Let's Encrypt email (asked if missing)
#   HTML_PATH    local path to a single .html file OR a directory with index.html
#                that should be used as the masking site. Asked if missing.
#                Empty answer -> built-in stub page is used.
#   NAIVE_USER   basic_auth username       (default: random hex)
#   NAIVE_PASS   basic_auth password       (default: random base64)
#   MASK_SITE    URL for reverse_proxy (alternative to HTML_PATH — hides a remote site)
#   GO_VERSION   Go to install             (default: latest from go.dev)
#   SWAP_SIZE    swap to create if <1.5GB  (default: 2G)
#   SKIP_UFW=1   skip firewall setup
#   SKIP_BBR=1   skip BBR tuning
#   REBUILD=1    force rebuild of caddy even if binary exists
#   ENABLE_WARP=1  route outbound via Cloudflare WARP (wgcf + kernel WireGuard
#                  + policy routing). Hides VPS IP for outbound while keeping
#                  inbound :443/:80 on the VPS IP. Asked interactively if unset.
#   NODE_ROLE    standalone|entry|exit (default: standalone). In a two-node
#                chain the client connects to the "entry" node, which transparently
#                forwards CONNECT to the "exit" node via HTTPS upstream. The
#                "exit" role is behaviorally identical to "standalone" — the
#                label just marks the node in the summary output. Asked interactively.
#   UPSTREAM_DOMAIN / UPSTREAM_USER / UPSTREAM_PASS
#                required when NODE_ROLE=entry — they identify the exit node
#                and are taken from /root/naive-credentials.txt on that node.
#   NONINTERACTIVE=1  never prompt, fail if something required is missing

set -euo pipefail

# When the script is executed via a pipe (`curl ... | bash` or `bash <(curl ...)`
# in some shells), stdin is not the terminal and `read -rp` would hang or
# consume the piped script. Reopen stdin from /dev/tty so interactive prompts
# still work. If there's no tty at all (cron, docker without -it) we leave
# stdin alone — the script will then run in non-interactive mode and require
# env vars for everything required.
if [[ ! -t 0 && -r /dev/tty ]]; then
  exec </dev/tty
fi

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# Prompt helper: ask VAR with optional DEFAULT and validator regex.
# Skips prompt if VAR already non-empty in env. Dies in non-interactive mode
# if VAR is empty and no default.
ask() {
  local var="$1" prompt="$2" default="${3:-}" pattern="${4:-}"
  local current="${!var:-}"
  [[ -n "$current" ]] && { [[ -z "$pattern" || "$current" =~ $pattern ]] || die "$var invalid: $current"; return 0; }
  if [[ "${NONINTERACTIVE:-0}" == "1" || ! -t 0 ]]; then
    [[ -n "$default" ]] && { printf -v "$var" '%s' "$default"; return 0; }
    die "$var required (non-interactive mode)"
  fi
  local reply suffix=''
  [[ -n "$default" ]] && suffix=" [$default]"
  while :; do
    read -rp "$(printf '\033[1;36m?\033[0m %s%s: ' "$prompt" "$suffix")" reply
    reply="${reply:-$default}"
    if [[ -z "$reply" ]]; then
      printf '  (answer required)\n'
      continue
    fi
    if [[ -n "$pattern" && ! "$reply" =~ $pattern ]]; then
      printf '  invalid format, try again\n'
      continue
    fi
    printf -v "$var" '%s' "$reply"
    return 0
  done
}

# Like ask but allows empty answer (for optional inputs).
ask_optional() {
  local var="$1" prompt="$2"
  local current="${!var:-}"
  [[ -n "$current" ]] && return 0
  if [[ "${NONINTERACTIVE:-0}" == "1" || ! -t 0 ]]; then return 0; fi
  local reply
  read -rp "$(printf '\033[1;36m?\033[0m %s (Enter to skip): ' "$prompt")" reply
  printf -v "$var" '%s' "$reply"
}

# yes/no prompt with a default; writes 1 or 0 into VAR.
ask_yn() {
  local var="$1" prompt="$2" default="${3:-n}"
  local current="${!var:-}"
  if [[ -n "$current" ]]; then
    case "$current" in 1|y|Y|yes|true) printf -v "$var" '%s' 1;; *) printf -v "$var" '%s' 0;; esac
    return 0
  fi
  if [[ "${NONINTERACTIVE:-0}" == "1" || ! -t 0 ]]; then
    [[ "$default" == "y" ]] && printf -v "$var" '%s' 1 || printf -v "$var" '%s' 0
    return 0
  fi
  local reply suffix='[y/N]'
  [[ "$default" == "y" ]] && suffix='[Y/n]'
  read -rp "$(printf '\033[1;36m?\033[0m %s %s: ' "$prompt" "$suffix")" reply
  reply="${reply:-$default}"
  case "$reply" in y|Y|yes) printf -v "$var" '%s' 1;; *) printf -v "$var" '%s' 0;; esac
}

# ------------------------------------------------------------ preflight

[[ $EUID -eq 0 ]] || die "must run as root"
[[ -r /etc/os-release ]] || die "/etc/os-release missing"
. /etc/os-release
case "${ID:-}:${VERSION_ID:-}" in
  ubuntu:22.04|ubuntu:24.04|ubuntu:25.*|debian:12|debian:13) ;;
  *) warn "untested OS ${ID} ${VERSION_ID}; continuing anyway" ;;
esac

printf '\n\033[1;34m=== NaiveProxy server setup ===\033[0m\n'
ask DOMAIN    "Domain (A-record already pointing to this server)" "" '^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'
ask EMAIL     "Email for Let's Encrypt"                          "" '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
# Ask for HTML_PATH with re-prompt on invalid input (interactive mode only).
# Empty answer -> skip (built-in stub will be used).
validate_html_path() {
  local p="$1"
  [[ -z "$p" ]] && return 0
  [[ -e "$p" ]] || { printf '  path does not exist: %s\n' "$p" >&2; return 1; }
  if [[ -f "$p" ]]; then
    [[ "$p" =~ \.html?$ ]] || warn "not *.html — using as index.html anyway"
    return 0
  fi
  if [[ -d "$p" ]]; then
    [[ -f "$p/index.html" ]] || { printf '  directory has no index.html: %s\n' "$p" >&2; return 1; }
    return 0
  fi
  printf '  not a regular file or directory: %s\n' "$p" >&2
  return 1
}

if [[ -z "${MASK_SITE:-}" ]]; then
  if [[ -n "${HTML_PATH:-}" ]]; then
    # Supplied via env — fail fast, no retry.
    HTML_PATH="${HTML_PATH/#\~/$HOME}"
    validate_html_path "$HTML_PATH" || die "HTML_PATH invalid: $HTML_PATH"
  elif [[ "${NONINTERACTIVE:-0}" != "1" && -t 0 ]]; then
    while :; do
      read -rp "$(printf '\033[1;36m?\033[0m Path on THIS server to your HTML file or directory (Enter to skip): ')" HTML_PATH
      HTML_PATH="${HTML_PATH/#\~/$HOME}"
      [[ -z "$HTML_PATH" ]] && break
      validate_html_path "$HTML_PATH" && break
      printf '  try again, or press Enter to skip and use the built-in stub\n'
    done
  fi
fi

ask_yn ENABLE_WARP "Route outbound traffic through Cloudflare WARP (hides VPS IP)?" n

# Node role: standalone | entry | exit. Only "entry" has extra config.
NODE_ROLE="${NODE_ROLE:-}"
case "$NODE_ROLE" in
  standalone|entry|exit) ;;
  "")
    if [[ "${NONINTERACTIVE:-0}" != "1" && -t 0 ]]; then
      printf '\n\033[1;34m=== Node role ===\033[0m\n'
      printf '  1) standalone — single naive server (most common)\n'
      printf '  2) entry      — forwards client CONNECTs to another naive (exit) node\n'
      printf '  3) exit       — like standalone, but will receive chained traffic from an entry node\n'
      role_reply=""
      read -rp "$(printf '\033[1;36m?\033[0m Choose [1]: ')" role_reply
      case "${role_reply:-1}" in
        2|entry) NODE_ROLE=entry ;;
        3|exit)  NODE_ROLE=exit ;;
        *)       NODE_ROLE=standalone ;;
      esac
    else
      NODE_ROLE=standalone
    fi
    ;;
  *) die "NODE_ROLE must be one of: standalone, entry, exit (got: $NODE_ROLE)" ;;
esac

# Entry role needs the exit node's credentials.
if [[ "$NODE_ROLE" == "entry" ]]; then
  ask UPSTREAM_DOMAIN "Exit node domain (from exit's /root/naive-credentials.txt)" "" '^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'
  ask UPSTREAM_USER   "Exit node username" ""
  ask UPSTREAM_PASS   "Exit node password" ""
  # Enforce safe URL chars so embedded creds in `upstream https://u:p@host` parse cleanly.
  [[ "$UPSTREAM_USER" =~ ^[A-Za-z0-9._~-]+$ ]] || die "UPSTREAM_USER has URL-unsafe chars (only A-Z a-z 0-9 . _ ~ - allowed)"
  [[ "$UPSTREAM_PASS" =~ ^[A-Za-z0-9._~-]+$ ]] || die "UPSTREAM_PASS has URL-unsafe chars (only A-Z a-z 0-9 . _ ~ - allowed)"
fi

if [[ "$NODE_ROLE" == "entry" && "${ENABLE_WARP:-0}" == "1" ]]; then
  warn "WARP on an entry node is unusual — entry's outbound already goes to the exit node,"
  warn "so WARP just adds a redundant hop. Continuing because you asked for it."
fi

ARCH_RAW=$(uname -m)
case "$ARCH_RAW" in
  x86_64)  GOARCH=amd64 ;;
  aarch64) GOARCH=arm64 ;;
  armv7l)  GOARCH=armv6l ;;
  *) die "unsupported arch: $ARCH_RAW" ;;
esac

# DNS sanity — non-fatal, just a warning.
if command -v getent >/dev/null; then
  RESOLVED=$(getent hosts "$DOMAIN" | awk '{print $1}' | head -n1 || true)
  MYIP=$(curl -s4 --max-time 5 https://ifconfig.me || true)
  if [[ -n "$RESOLVED" && -n "$MYIP" && "$RESOLVED" != "$MYIP" ]]; then
    warn "DNS: $DOMAIN -> $RESOLVED, but this host is $MYIP. ACME may fail."
  fi
fi

NAIVE_USER="${NAIVE_USER:-$(openssl rand -hex 6)}"
NAIVE_PASS="${NAIVE_PASS:-$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)}"

# Save creds early so they survive a mid-script failure.
CREDS_FILE=/root/naive-credentials.txt
umask 077
cat > "$CREDS_FILE" <<EOF
Domain:   ${DOMAIN}
Username: ${NAIVE_USER}
Password: ${NAIVE_PASS}
Client URL: naive+https://${NAIVE_USER}:${NAIVE_PASS}@${DOMAIN}:443
EOF
umask 022

# ------------------------------------------------------------ system prep

log "apt update + base packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends \
  curl wget ca-certificates gnupg lsb-release openssl xz-utils \
  libcap2-bin tar jq sudo

# Swap: xcaddy needs ~1GB RAM; build OOMs on 1GB VPS without swap.
MEM_KB=$(awk '/MemTotal/{print $2}' /proc/meminfo)
if (( MEM_KB < 1500000 )) && [[ ! -f /swapfile ]]; then
  log "low RAM ($((MEM_KB/1024)) MB) — creating ${SWAP_SIZE:-2G} swap"
  fallocate -l "${SWAP_SIZE:-2G}" /swapfile
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# BBR — doubles throughput on long-haul TCP; safe on all modern kernels.
if [[ "${SKIP_BBR:-0}" != "1" ]]; then
  log "enabling BBR + fq"
  cat > /etc/sysctl.d/99-naive-bbr.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=16777216
net.core.wmem_max=16777216
EOF
  sysctl -q --system
fi

# ------------------------------------------------------------ go toolchain

GO_VERSION="${GO_VERSION:-$(curl -sS https://go.dev/VERSION?m=text | head -n1)}"
GO_VERSION="${GO_VERSION#go}"
[[ "$GO_VERSION" =~ ^[0-9]+\.[0-9]+ ]] || die "could not resolve Go version"

NEED_GO=1
if [[ -x /usr/local/go/bin/go ]] && /usr/local/go/bin/go version | grep -q "go${GO_VERSION} "; then
  NEED_GO=0
fi
if (( NEED_GO )); then
  log "installing Go ${GO_VERSION} (${GOARCH})"
  TARBALL="go${GO_VERSION}.linux-${GOARCH}.tar.gz"
  DL="/root/${TARBALL}"
  wget -qO "$DL" "https://go.dev/dl/${TARBALL}"
  rm -rf /usr/local/go
  tar -C /usr/local -xzf "$DL"
  rm -f "$DL"
fi
export PATH=/usr/local/go/bin:/root/go/bin:$PATH
go version

# ------------------------------------------------------------ build caddy

CADDY_BIN=/usr/bin/caddy
if [[ ! -x "$CADDY_BIN" || "${REBUILD:-0}" == "1" ]]; then
  log "installing xcaddy"
  GOBIN=/root/go/bin go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest

  BUILD_DIR=/root/caddy-build
  mkdir -p "$BUILD_DIR"
  cd "$BUILD_DIR"

  log "building caddy + klzgrad/forwardproxy@naive (2-5 min)"
  /root/go/bin/xcaddy build \
    --with github.com/caddyserver/forwardproxy@caddy2=github.com/klzgrad/forwardproxy@naive

  install -m 0755 caddy "$CADDY_BIN"
  cd - >/dev/null

  "$CADDY_BIN" list-modules | grep -q '^http.handlers.forward_proxy' \
    || die "forward_proxy module missing from build"
fi

log "setcap CAP_NET_BIND_SERVICE"
setcap 'cap_net_bind_service=+ep' "$CADDY_BIN"

# ------------------------------------------------------------ caddy user + dirs

if ! getent group caddy >/dev/null; then groupadd --system caddy; fi
if ! id caddy >/dev/null 2>&1; then
  useradd --system --gid caddy --create-home --home-dir /var/lib/caddy \
          --shell /usr/sbin/nologin --comment "Caddy" caddy
fi

install -d -o caddy -g caddy -m 0750 /etc/caddy /var/lib/caddy /var/log/caddy
install -d -o caddy -g caddy -m 0755 /var/www/html

# ------------------------------------------------------------ cloudflare warp (wgcf + kernel WireGuard)
#
# Policy-routing model (see header of this block for rationale):
#   - inbound on WAN gets CONNMARK=1; replies get fwmark=1 -> table main (eth0)
#   - wgcf's own UDP-to-endpoint packets are auto-marked with FwMark=51820 by
#     the kernel WG module -> table main (eth0), so the tunnel doesn't loop
#   - everything else (NEW outbound from userspace, incl. Caddy) -> table warp
#     -> default via wgcf -> encrypted UDP to Cloudflare -> egress via CF

WARP_TABLE=51820   # used as the routing table id AND the wg FwMark value
WARP_CONNMARK=1    # connmark for inbound WAN connections

# Clean up the previous cloudflare-warp (SOCKS5) setup from older script versions.
# It conflicts with wgcf (both try to be "the WARP") and we don't need it anymore.
if command -v warp-cli >/dev/null 2>&1; then
  warn "found cloudflare-warp daemon from older setup — removing"
  warp-cli --accept-tos disconnect >/dev/null 2>&1 || true
  systemctl disable --now warp-svc.service >/dev/null 2>&1 || true
  DEBIAN_FRONTEND=noninteractive apt-get purge -y cloudflare-warp >/dev/null 2>&1 || true
  rm -f /etc/apt/sources.list.d/cloudflare-client.list \
        /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg \
        /etc/systemd/system/warp-svc.service.d/override.conf 2>/dev/null || true
fi

# If user is disabling WARP now, bring down any previous wgcf setup.
if [[ "${ENABLE_WARP:-0}" != "1" ]]; then
  if systemctl is-enabled wg-quick@wgcf >/dev/null 2>&1 || \
     systemctl is-active  wg-quick@wgcf >/dev/null 2>&1; then
    warn "disabling previously-enabled wgcf WARP"
    systemctl disable --now wg-quick@wgcf >/dev/null 2>&1 || true
  fi
fi

WARP_EGRESS_IP=""  # filled in if WARP comes up successfully

if [[ "${ENABLE_WARP:-0}" == "1" ]]; then
  log "setting up WARP via wgcf + kernel WireGuard"

  apt-get install -y --no-install-recommends wireguard-tools iptables iproute2

  # Detect WAN interface (the one with the default route).
  WAN_IF=$(ip -4 route show default | awk '/default/ {print $5; exit}')
  [[ -n "$WAN_IF" ]] || die "cannot determine WAN interface (no default route?)"
  log "WAN interface: ${WAN_IF}"

  # Pick correct wgcf release binary for this arch.
  case "$GOARCH" in
    amd64)  WGCF_ARCH=amd64 ;;
    arm64)  WGCF_ARCH=arm64 ;;
    armv6l) WGCF_ARCH=armv7 ;;
    *) die "no wgcf build for arch $GOARCH" ;;
  esac

  if [[ ! -x /usr/local/bin/wgcf ]]; then
    WGCF_URL=$(curl -sS https://api.github.com/repos/ViRb3/wgcf/releases/latest \
      | jq -r ".assets[] | select(.name | test(\"linux_${WGCF_ARCH}$\")) | .browser_download_url" | head -n1)
    [[ -n "$WGCF_URL" ]] || die "could not resolve wgcf download URL"
    log "downloading wgcf: ${WGCF_URL##*/}"
    curl -fsSL -o /usr/local/bin/wgcf "$WGCF_URL"
    chmod +x /usr/local/bin/wgcf
  fi

  # Register a WARP account (idempotent — reuse existing account file if any).
  mkdir -p /etc/wireguard
  pushd /etc/wireguard >/dev/null
  [[ -f wgcf-account.toml ]] || wgcf register --accept-tos
  [[ -f wgcf-profile.conf ]] || wgcf generate

  # Register custom routing table name so `ip route add ... table warp` works.
  grep -q "^${WARP_TABLE}[[:space:]]\+warp\b" /etc/iproute2/rt_tables 2>/dev/null \
    || echo "${WARP_TABLE} warp" >> /etc/iproute2/rt_tables

  # PostUp / PostDown helper scripts — keep wgcf.conf clean and atomic-ish.
  cat > /etc/wireguard/wgcf-postup.sh <<EOF
#!/bin/sh
set -e
IFACE="\$1"
WAN="${WAN_IF}"
FWMARK=${WARP_TABLE}
CONNMARK=${WARP_CONNMARK}

# Idempotency: delete any leftovers from a prior failed PostDown.
ip rule del priority 100 fwmark \$CONNMARK table main         2>/dev/null || true
ip rule del priority 200 fwmark \$FWMARK   table main         2>/dev/null || true
ip rule del priority 300                    table warp         2>/dev/null || true
ip route flush table warp                                      2>/dev/null || true
iptables -t mangle -D PREROUTING -i "\$WAN" -j CONNMARK --set-mark \$CONNMARK 2>/dev/null || true
iptables -t mangle -D OUTPUT -m conntrack --ctstate RELATED,ESTABLISHED -j CONNMARK --restore-mark 2>/dev/null || true

# Mark inbound connections arriving on WAN; restore on reply OUTPUT packets
# so they route back via main (eth0), not via wgcf.
iptables -t mangle -A PREROUTING -i "\$WAN" -j CONNMARK --set-mark \$CONNMARK
iptables -t mangle -A OUTPUT -m conntrack --ctstate RELATED,ESTABLISHED -j CONNMARK --restore-mark

# Reply traffic -> main; WG's own UDP -> main; everything else -> warp.
ip rule add priority 100 fwmark \$CONNMARK table main
ip rule add priority 200 fwmark \$FWMARK   table main
ip rule add priority 300                    table warp
ip route add default dev "\$IFACE" table warp
EOF
  cat > /etc/wireguard/wgcf-postdown.sh <<EOF
#!/bin/sh
WAN="${WAN_IF}"
FWMARK=${WARP_TABLE}
CONNMARK=${WARP_CONNMARK}

iptables -t mangle -D OUTPUT -m conntrack --ctstate RELATED,ESTABLISHED -j CONNMARK --restore-mark 2>/dev/null || true
iptables -t mangle -D PREROUTING -i "\$WAN" -j CONNMARK --set-mark \$CONNMARK                        2>/dev/null || true
ip route flush table warp                                                                            2>/dev/null || true
ip rule del priority 300                    table warp                                               2>/dev/null || true
ip rule del priority 200 fwmark \$FWMARK   table main                                               2>/dev/null || true
ip rule del priority 100 fwmark \$CONNMARK table main                                               2>/dev/null || true
exit 0
EOF
  chmod +x /etc/wireguard/wgcf-postup.sh /etc/wireguard/wgcf-postdown.sh

  # Rewrite wgcf.conf from the generated profile on each run:
  #   - drop DNS (we want system resolver; WARP DNS is OK but not required)
  #   - drop IPv6 (simplify routing; egress is IPv4-only)
  #   - Table = off (we manage routes via PostUp)
  #   - FwMark = $WARP_TABLE (kernel marks wg's own UDP for main-table routing)
  cp wgcf-profile.conf wgcf.conf
  sed -i -E '
    /^DNS = /d
    s/, *[0-9a-fA-F:]+\/128//g
    s/, *::\/0//g
    /^Address = [0-9a-fA-F:]+\/128/d
    /^AllowedIPs = ::\/0/d
    /^Table = /d
    /^FwMark = /d
    /^PostUp = /d
    /^PostDown = /d
  ' wgcf.conf
  # Insert our own knobs right after [Interface]:
  sed -i "/^\[Interface\]/a\\
Table = off\\
FwMark = ${WARP_TABLE}\\
PostUp = /etc/wireguard/wgcf-postup.sh %i\\
PostDown = /etc/wireguard/wgcf-postdown.sh %i" wgcf.conf
  chmod 0600 wgcf.conf wgcf-account.toml wgcf-profile.conf
  popd >/dev/null

  # Record VPS IP BEFORE bringing WARP up so we can diff after.
  VPS_IP=$(curl -s4 --max-time 5 https://ifconfig.me || true)

  # Restart the tunnel (stop+start to ensure PostDown/PostUp run cleanly).
  systemctl daemon-reload
  systemctl enable wg-quick@wgcf >/dev/null 2>&1 || true
  systemctl restart wg-quick@wgcf

  # Give the tunnel a moment to handshake.
  sleep 3

  # Verify egress via the tunnel interface directly.
  WARP_EGRESS_IP=$(curl -s4 --max-time 10 --interface wgcf https://ifconfig.me || true)
  if [[ -z "$WARP_EGRESS_IP" || "$WARP_EGRESS_IP" == "$VPS_IP" ]]; then
    warn "WARP tunnel did not come up (or no route via wgcf)."
    warn "  check: wg show wgcf; journalctl -u wg-quick@wgcf -n 50"
    warn "rolling back WARP so the proxy keeps working"
    systemctl disable --now wg-quick@wgcf >/dev/null 2>&1 || true
    WARP_EGRESS_IP=""
    ENABLE_WARP=0
  else
    # Verify SYSTEM egress (no --interface) now exits via WARP thanks to policy routing.
    SYS_EGRESS=$(curl -s4 --max-time 10 https://ifconfig.me || true)
    if [[ -z "$SYS_EGRESS" ]]; then
      warn "tunnel up but system has no outbound route — check policy rules"
    elif [[ "$SYS_EGRESS" == "$VPS_IP" ]]; then
      warn "tunnel up but system is still exiting via VPS IP (policy routing not applied?)"
      warn "  check: ip rule show ; ip route show table warp"
    else
      log "WARP active. System egress IP: ${SYS_EGRESS} (was VPS ${VPS_IP})"
    fi
  fi
fi

# ------------------------------------------------------------ caddyfile

# Chain: if this is an entry node, add an HTTPS upstream pointing at the exit.
# HTTPS upstream is handled by a dedicated HTTP-CONNECT dialer in the plugin
# (not by proxy.FromURL), so it works reliably with h2 CONNECT — unlike the
# SOCKS5 upstream path that got dropped in an earlier revision of this script.
if [[ "$NODE_ROLE" == "entry" ]]; then
  UPSTREAM_LINE="            upstream https://${UPSTREAM_USER}:${UPSTREAM_PASS}@${UPSTREAM_DOMAIN}:443"
else
  UPSTREAM_LINE=""
fi

# Mask site: reverse_proxy if MASK_SITE set, else serve a static site.
if [[ -n "${MASK_SITE:-}" ]]; then
  MASK_BLOCK=$(cat <<EOF
        reverse_proxy ${MASK_SITE} {
            header_up Host {upstream_hostport}
            header_up X-Forwarded-Host {host}
        }
EOF
)
else
  # Wipe previous contents so re-running the script doesn't mix old + new files.
  find /var/www/html -mindepth 1 -delete 2>/dev/null || true

  if [[ -n "${HTML_PATH:-}" ]]; then
    if [[ -f "$HTML_PATH" ]]; then
      log "installing custom HTML file: $HTML_PATH -> /var/www/html/index.html"
      install -m 0644 -o caddy -g caddy "$HTML_PATH" /var/www/html/index.html
    else
      log "installing custom HTML directory: $HTML_PATH -> /var/www/html/"
      cp -aT "$HTML_PATH" /var/www/html
      chown -R caddy:caddy /var/www/html
      chmod -R a+rX /var/www/html
    fi
  else
    log "no custom HTML provided — using built-in stub"
    cat > /var/www/html/index.html <<'EOF'
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Welcome</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>body{font-family:system-ui,sans-serif;max-width:40rem;margin:4rem auto;padding:0 1rem;color:#222}h1{font-weight:400}</style>
</head><body><h1>Welcome</h1>
<p>This site is under construction. Please check back later.</p>
</body></html>
EOF
    chown caddy:caddy /var/www/html/index.html
  fi

  MASK_BLOCK='        file_server {
            root /var/www/html
        }'
fi

cat > /etc/caddy/Caddyfile <<EOF
{
    order forward_proxy before file_server
    admin off
    log {
        output file /var/log/caddy/access.log {
            roll_size 50mb
            roll_keep 5
        }
        format json
        level INFO
    }
    servers :443 {
        protocols h1 h2 h3
    }
}

:80 {
    redir https://{host}{uri} permanent
}

:443, ${DOMAIN} {
    tls ${EMAIL}
    route {
        forward_proxy {
            basic_auth ${NAIVE_USER} ${NAIVE_PASS}
            hide_ip
            hide_via
            probe_resistance
${UPSTREAM_LINE}
        }
${MASK_BLOCK}
    }
}
EOF
chown caddy:caddy /etc/caddy/Caddyfile
chmod 0640 /etc/caddy/Caddyfile

# Validate as the caddy user so we don't create root-owned log files
# that block the service from starting.
sudo -u caddy "$CADDY_BIN" validate --config /etc/caddy/Caddyfile

# Belt-and-suspenders: make sure everything under log/state dirs is caddy-owned.
chown -R caddy:caddy /var/log/caddy /var/lib/caddy

# ------------------------------------------------------------ systemd

cat > /etc/systemd/system/caddy.service <<EOF
[Unit]
Description=Caddy with klzgrad/forwardproxy (NaiveProxy server)
Documentation=https://caddyserver.com/docs/
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify
User=caddy
Group=caddy
ExecStart=${CADDY_BIN} run --environ --config /etc/caddy/Caddyfile
ExecReload=${CADDY_BIN} reload --config /etc/caddy/Caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable caddy >/dev/null
systemctl restart caddy

# ------------------------------------------------------------ firewall

if [[ "${SKIP_UFW:-0}" != "1" ]] && command -v ufw >/dev/null; then
  log "configuring ufw"
  ufw allow OpenSSH       >/dev/null || true
  ufw allow 80/tcp        >/dev/null
  ufw allow 443/tcp       >/dev/null
  ufw allow 443/udp       >/dev/null   # QUIC / HTTP/3
  yes | ufw enable        >/dev/null || true
fi

# ------------------------------------------------------------ smoke test

log "waiting for Let's Encrypt cert (up to 120s)"
for i in $(seq 1 24); do
  if curl -sk --max-time 5 "https://${DOMAIN}/" -o /dev/null -w '%{http_code}' | grep -qE '^(200|301|302|403)$'; then
    break
  fi
  sleep 5
done

HTTP_STATUS=$(curl -sI --max-time 10 "https://${DOMAIN}/" -o /dev/null -w '%{http_code}' || echo 000)
TLS_ISSUER=$(echo | openssl s_client -connect "${DOMAIN}:443" -servername "${DOMAIN}" 2>/dev/null \
             | openssl x509 -noout -issuer 2>/dev/null | sed 's/issuer= *//')

# Entry-node end-to-end chain check: curl through our own proxy and see what
# public IP comes out. Should NOT be this VDS's IP; should be the exit's
# egress (exit VDS IP, or Cloudflare if the exit has WARP on).
CHAIN_EGRESS_IP=""
if [[ "$NODE_ROLE" == "entry" ]]; then
  CHAIN_EGRESS_IP=$(curl -s4 --max-time 20 \
    --proxy "https://${NAIVE_USER}:${NAIVE_PASS}@${DOMAIN}:443" \
    https://ifconfig.me 2>/dev/null || true)
  THIS_VPS_IP=$(curl -s4 --max-time 5 https://ifconfig.me 2>/dev/null || true)
  if [[ -z "$CHAIN_EGRESS_IP" ]]; then
    warn "chain test failed — entry could not reach exit. Check:"
    warn "  - exit node is reachable:   curl -I https://${UPSTREAM_DOMAIN}/"
    warn "  - upstream creds are right: UPSTREAM_USER / UPSTREAM_PASS"
    warn "  - exit's 443 is open in its firewall"
  elif [[ "$CHAIN_EGRESS_IP" == "$THIS_VPS_IP" ]]; then
    warn "chain egress equals entry VPS IP — upstream seems inactive"
  else
    log "chain OK — client traffic exits with IP ${CHAIN_EGRESS_IP}"
  fi
fi

# ------------------------------------------------------------ summary

umask 077
{
  echo "NaiveProxy node deployed: $(date -u +%FT%TZ)"
  echo "Role:     ${NODE_ROLE}"
  echo "Domain:   ${DOMAIN}"
  echo "Username: ${NAIVE_USER}"
  echo "Password: ${NAIVE_PASS}"
  if [[ "$NODE_ROLE" == "entry" ]]; then
    echo ""
    echo "Upstream (exit) node:"
    echo "  Domain:   ${UPSTREAM_DOMAIN}"
    echo "  Username: ${UPSTREAM_USER}"
    echo "  (password not re-printed for safety)"
  fi
  if [[ "$NODE_ROLE" != "entry" ]]; then
    # exit/standalone: these are the creds a downstream entry (or a direct
    # client) will use.
    echo ""
    echo "For a downstream ENTRY node, pass these values:"
    echo "  UPSTREAM_DOMAIN=${DOMAIN}"
    echo "  UPSTREAM_USER=${NAIVE_USER}"
    echo "  UPSTREAM_PASS=${NAIVE_PASS}"
  fi
  echo ""
  echo "Client config (config.json):"
  echo "{"
  echo "  \"listen\": \"socks://127.0.0.1:1080\","
  echo "  \"proxy\":  \"https://${NAIVE_USER}:${NAIVE_PASS}@${DOMAIN}\""
  echo "}"
  echo ""
  echo "Client URL (Nekobox/Karing/Hiddify import):"
  echo "naive+https://${NAIVE_USER}:${NAIVE_PASS}@${DOMAIN}:443"
  echo ""
  echo "HTTP/3 variant:"
  echo "  \"proxy\": \"quic://${NAIVE_USER}:${NAIVE_PASS}@${DOMAIN}\""
} > "$CREDS_FILE"
umask 022

if [[ "${ENABLE_WARP:-0}" == "1" && -n "${WARP_EGRESS_IP:-}" ]]; then
  WARP_LINE=" WARP      : enabled (wgcf, egress IP ${WARP_EGRESS_IP})"
else
  WARP_LINE=" WARP      : disabled (egress IP = VPS IP)"
fi

if [[ "$NODE_ROLE" == "entry" ]]; then
  CHAIN_LINE=" Upstream  : https://${UPSTREAM_DOMAIN} (exit node)"
  [[ -n "$CHAIN_EGRESS_IP" ]] && CHAIN_LINE+=$'\n'" Chain exit: ${CHAIN_EGRESS_IP}"
else
  CHAIN_LINE=""
fi

cat <<EOF

============================================================
 NaiveProxy node ready — role: ${NODE_ROLE}
============================================================
 Domain    : ${DOMAIN}
 User      : ${NAIVE_USER}
 Pass      : ${NAIVE_PASS}
 HTTP 443  : ${HTTP_STATUS}
 TLS cert  : ${TLS_ISSUER:-<cert not issued yet>}
${WARP_LINE}${CHAIN_LINE:+
$CHAIN_LINE}
 Creds     : ${CREDS_FILE}
 Logs      : journalctl -u caddy -f   |   /var/log/caddy/access.log
============================================================

Client config.json:
{
  "listen": "socks://127.0.0.1:1080",
  "proxy":  "https://${NAIVE_USER}:${NAIVE_PASS}@${DOMAIN}"
}

Smoke test from a machine running naive client:
  curl -x socks5h://127.0.0.1:1080 https://ifconfig.me
EOF

if [[ -z "$TLS_ISSUER" ]]; then
  warn "certificate not issued yet — check: journalctl -u caddy -n 100"
  warn "common causes: port 80/443 blocked, DNS not propagated, rate-limited"
fi
