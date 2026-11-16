#!/usr/bin/env bash
# The home router's policy, written for Linux so it can run in the simulation.
# Each block maps 1:1 to a section of routeros/home-router.rsc.
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh

# Per-WAN tables, used only by the health checks (rules match the check host only,
# so tunnel traffic always follows the main table).
# RouterOS equivalent: recursive routes with check-gateway.
nsx home ip route add default via 203.0.113.1 dev wan1 table 11
nsx home ip route add default via 192.0.2.1   dev wan2 table 12
nsx home ip route add default via 100.64.0.1  dev wan3 table 13
nsx home ip rule add from 203.0.113.2 to 198.51.100.6 lookup 11 pref 50
nsx home ip rule add from 192.0.2.2 to 198.51.100.6 lookup 12 pref 51
nsx home ip rule add from 100.64.0.2 to 198.51.100.6 lookup 13 pref 52

# Main table: start on ISP1; failover.sh moves it
nsx home ip route add default via 203.0.113.1 dev wan1

# US path (RouterOS: routing table to-us + lookup-only-in-table + blackhole)
nsx home ip route add default via 10.99.0.3 dev wg-relay onlink table 200
nsx home ip route add blackhole default metric 250 table 200
nsx home ip rule add iif ether5 lookup 200 pref 100
# Nothing from the US port ever consults the main table, so there is no local fallback.

nsx home nft -f - <<'EOF'
table ip nat {
  chain pre {
    type nat hook prerouting priority -100;
    # US devices: all DNS goes to the US resolver in exit site, whatever server they ask
    iifname "ether5" udp dport 53 dnat to 10.99.0.3
    iifname "ether5" tcp dport 53 dnat to 10.99.0.3
  }
  chain post {
    type nat hook postrouting priority 100;
    oifname { "wan1", "wan2", "wan3" } masquerade
    oifname "wg-relay" masquerade
  }
}
table inet filter {
  chain home_fw {
    type filter hook forward priority 0; policy accept;
    # Kill switch: US traffic may only leave through the tunnel
    iifname "ether5" oifname { "wan1", "wan2", "wan3" } counter drop comment "US kill switch"
    # DNS-over-TLS would bypass the DNS redirect
    iifname "ether5" tcp dport 853 drop
    tcp flags syn oifname "wg-relay" tcp option maxseg size set rt mtu
  }
}
EOF
