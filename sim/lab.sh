#!/usr/bin/env bash
# Builds (up) or removes (down) the simulated network:
#
#   laptop ─ether4─┐                         ┌─ isp1 (static) ─┐
#                  ├─ home (MikroTik role) ─┼─ isp2    (static) ─┼─ inet ─┬─ relay (cloud, static IP)
#   tv ─────ether5─┘   (failover.sh)         └─ isp3 (CGNAT) ─┘        ├─ web (whoami HTTP + "local" DNS)
#                                                                          └─ cell (CGNAT) ─ exitsite (US exit)
#
# laptop = a device on the normal UniFi network (UDM WAN1)
# tv     = a device the UniFi policy route sends out UDM WAN2 (the US port)
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh

down() {
  pkill -f "$RUN/failover" 2>/dev/null || true
  pkill -f "dnsmasq.*$RUN" 2>/dev/null || true
  pkill -f "$RUN/whoami" 2>/dev/null || true
  pkill -f wireguard-go 2>/dev/null || true
  for ns in $NSES; do ip netns del "$ns" 2>/dev/null || true; done
  rm -rf "$RUN" /var/run/wireguard/wg-*.sock
}

up() {
  down; mkdir -p "$RUN"
  for ns in $NSES; do ip netns add "$ns"; nsx "$ns" ip link set lo up; nsx "$ns" sysctl -qw net.ipv4.ip_forward=1; done

  # ---- internet core
  link inet r0  198.51.100.1/30  relay  eth0 198.51.100.2/30
  link inet w0  198.51.100.5/30  web    eth0 198.51.100.6/30
  link inet d0  198.18.1.1/30    isp1 upl 198.18.1.2/30
  link inet f0  198.18.2.1/30    isp2    upl 198.18.2.2/30
  link inet s0  198.18.3.1/30    isp3 upl 198.18.3.2/30
  link inet a0  198.18.9.1/30    cell     upl 198.18.9.2/30
  nsx inet ip route add 203.0.113.0/30 via 198.18.1.2
  nsx inet ip route add 192.0.2.0/30   via 198.18.2.2
  nsx relay ip route add default via 198.51.100.1
  nsx web   ip route add default via 198.51.100.5

  # ---- home ISPs. Each drops traffic not sourced from its own customer prefix (BCP38),
  # so a packet leaving with the wrong ISP's address dies, like on real networks.
  link isp1 cust 203.0.113.1/30 home wan1 203.0.113.2/30
  link isp2    cust 192.0.2.1/30   home wan2 192.0.2.2/30
  link isp3 cust 100.64.0.1/30 home wan3 100.64.0.2/30
  nsx isp1  ip route add default via 198.18.1.1
  nsx isp2     ip route add default via 198.18.2.1
  nsx isp3 ip route add default via 198.18.3.1
  nsx isp1 nft -f - <<'EOF'
table inet bcp38 {
  chain isp_fw {
    type filter hook forward priority 0
    iifname "cust" ip saddr != 203.0.113.0/30 drop
  }
}
EOF
  nsx isp2 nft -f - <<'EOF'
table inet bcp38 {
  chain isp_fw {
    type filter hook forward priority 0
    iifname "cust" ip saddr != 192.0.2.0/30 drop
  }
}
EOF
  # ISP3: carrier-grade NAT, no inbound reachability, public address shared
  nsx isp3 nft -f - <<'EOF'
table inet bcp38 {
  chain isp_fw {
    type filter hook forward priority 0
    iifname "cust" ip saddr != 100.64.0.0/30 drop
  }
}
table ip cgnat {
  chain post {
    type nat hook postrouting priority 100
    oifname "upl" masquerade
  }
}
EOF

  # ---- exit site behind the cellular ISP CGNAT
  link cell cust 100.64.1.1/30 exitsite eth0 100.64.1.2/30
  nsx cell ip route add default via 198.18.9.1
  nsx cell nft -f - <<'EOF'
table ip cgnat {
  chain post {
    type nat hook postrouting priority 100
    oifname "upl" masquerade
  }
}
EOF
  nsx exitsite ip route add default via 100.64.1.1

  # ---- home side
  link home ether4 10.10.4.1/30 laptop eth0 10.10.4.2/30
  link home ether5 10.10.5.1/30 tv     eth0 10.10.5.2/30
  nsx laptop ip route add default via 10.10.4.1
  nsx tv     ip route add default via 10.10.5.1

  # ---- WireGuard: relay hub, both sites dial out
  for n in relay home exitsite; do nsx $n wg genkey > "$RUN/$n.key"; nsx $n wg pubkey < "$RUN/$n.key" > "$RUN/$n.pub"; done
  mkwg relay wg-hub; mkwg home wg-relay; mkwg exitsite wg-us

  cat > "$RUN/relay.conf" <<EOF
[Interface]
PrivateKey = $(cat $RUN/relay.key)
ListenPort = 51820
[Peer]
# home MikroTik
PublicKey = $(cat $RUN/home.pub)
AllowedIPs = 10.99.0.2/32
[Peer]
# exit site exit: also the peer for every internet destination
PublicKey = $(cat $RUN/exitsite.pub)
AllowedIPs = 10.99.0.3/32, 0.0.0.0/0
EOF
  wgconf relay wg-hub "$RUN/relay.conf"
  nsx relay ip addr add 10.99.0.1/24 dev wg-hub; nsx relay ip link set wg-hub mtu 1420 up
  # Anything that arrives from the tunnel and isn't for 10.99.0.0/24 goes back into the tunnel (to exit site)
  nsx relay ip rule add iif wg-hub lookup 100 pref 100
  nsx relay ip route add 10.99.0.0/24 dev wg-hub table 100
  nsx relay ip route add default dev wg-hub table 100

  for side in home:wg-relay:10.99.0.2 exitsite:wg-us:10.99.0.3; do
    IFS=: read -r ns ifn addr <<<"$side"
    cat > "$RUN/$ns.conf" <<EOF
[Interface]
PrivateKey = $(cat $RUN/$ns.key)
[Peer]
PublicKey = $(cat $RUN/relay.pub)
Endpoint = 198.51.100.2:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = $KEEPALIVE
EOF
    wgconf $ns $ifn "$RUN/$ns.conf"
    nsx $ns ip addr add $addr/24 dev $ifn; nsx $ns ip link set $ifn mtu 1420 up
  done

  # ---- exit site: exit to the internet + US resolver on its tunnel address
  nsx exitsite nft -f - <<'EOF'
table ip nat {
  chain post {
    type nat hook postrouting priority 100
    oifname "eth0" masquerade
  }
}
EOF
  nsx exitsite dnsmasq --conf-file=/dev/null --pid-file="$RUN/dns-exitsite.pid" --listen-address=10.99.0.3 \
      --bind-interfaces --no-resolv --txt-record=geo.test,US --log-facility="$RUN/dns-exitsite.log"

  # ---- web: whoami over HTTP and a "local ISP" DNS resolver
  cat > "$RUN/whoami.py" <<'EOF'
import http.server
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        b = self.client_address[0].encode()
        self.send_response(200); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
        open("/tmp/mtlab/web-access.log", "a").write(self.client_address[0] + "\n")
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("0.0.0.0", 8080), H).serve_forever()
EOF
  nsx web python3 "$RUN/whoami.py" >/dev/null 2>&1 &
  nsx web dnsmasq --conf-file=/dev/null --pid-file="$RUN/dns-web.pid" --listen-address=198.51.100.6 \
      --bind-interfaces --no-resolv --txt-record=geo.test,LOCAL

  # ---- home router (the MikroTik's job, Linux edition)
  ./home-policy.sh
  cp ./failover.sh "$RUN/failover"
  nsx home bash "$RUN/failover" >"$RUN/failover.log" 2>&1 &
  echo "lab up (WireGuard: $(cat $RUN/wgmode))"
}

case "${1:-up}" in up) up ;; down) down ;; *) echo "usage: $0 up|down"; exit 2 ;; esac
