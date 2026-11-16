# shellcheck shell=bash disable=SC2034
# Shared helpers for the network-namespace simulation.
# Sourced by lab.sh, failover.sh and test.sh. Needs root.

set -euo pipefail

NSES="inet web relay isp1 isp2 isp3 home laptop tv cell exitsite"
RUN=/tmp/mtlab
KEEPALIVE=${KEEPALIVE:-5}   # 25s in production; shorter here so tests run fast

nsx() { local ns=$1; shift; ip netns exec "$ns" "$@"; }

# veth pair between two namespaces: link NS_A IF_A ADDR_A NS_B IF_B ADDR_B
link() {
  ip link add "$2" netns "$1" type veth peer name "$5" netns "$4"
  nsx "$1" ip addr add "$3" dev "$2"; nsx "$1" ip link set "$2" up
  nsx "$4" ip addr add "$6" dev "$5"; nsx "$4" ip link set "$5" up
}

# Kernel WireGuard when the kernel has it (GitHub runners do),
# userspace wireguard-go otherwise (sandboxes without the module).
mkwg() {
  local ns=$1 name=$2
  if nsx "$ns" ip link add "$name" type wireguard 2>/dev/null; then
    echo kernel > "$RUN/wgmode"
  else
    command -v wireguard-go >/dev/null || { echo "no kernel WireGuard and no wireguard-go" >&2; exit 1; }
    setsid ip netns exec "$ns" wireguard-go -f "$name" >"$RUN/$name.log" 2>&1 < /dev/null &
    echo wireguard-go > "$RUN/wgmode"
    for _ in $(seq 50); do nsx "$ns" ip link show "$name" >/dev/null 2>&1 && break; sleep 0.1; done
  fi
}

wgconf() {  # wgconf NS IFACE FILE
  nsx "$1" wg setconf "$2" "$3"
}

# Public IP as seen by the "web" server (what a streaming service would see)
seen_ip() { nsx "$1" curl -s -m "${2:-4}" http://198.51.100.6:8080/ip || true; }

# Which resolver answered (US resolver in exit site or the local one)
dns_geo() { nsx "$1" dig +short +time=2 +tries=1 TXT geo.test @198.51.100.6 2>/dev/null | tr -d '"' | grep -E '^(US|LOCAL)$' || true; }

isp_fail()    { nsx "$1" nft add table inet outage 2>/dev/null; nsx "$1" nft 'add chain inet outage isp_fw { type filter hook forward priority -10; policy drop; }'; }
isp_restore() { nsx "$1" nft delete table inet outage 2>/dev/null || true; }
