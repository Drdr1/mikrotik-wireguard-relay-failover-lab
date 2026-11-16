#!/usr/bin/env bash
# One-time setup on the exit site device. Run as root. LAN_IF = the interface toward the the cellular ISP router.
set -euo pipefail
LAN_IF=${LAN_IF:-eth0}

apt-get update -qq && apt-get install -y -qq wireguard nftables dnsmasq

echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/90-us-exit.conf
sysctl -q --system

# NAT tunnel traffic out through the cellular ISP; nothing from the tunnel may reach the local LAN
cat > /etc/wireguard/us-exit.nft <<EOF
table ip us_exit {
  chain forward {
    type filter hook forward priority 0; policy drop;
    ct state established,related accept
    iifname "wg0" ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } drop comment "no access to the exit site home LAN"
    iifname "wg0" oifname "$LAN_IF" accept
  }
  chain post {
    type nat hook postrouting priority 100;
    ip saddr 10.99.0.0/24 oifname "$LAN_IF" masquerade
  }
}
EOF
# US resolver on the tunnel address: the home router sends all US-path DNS here
cat > /etc/dnsmasq.d/us-resolver.conf <<'EOF'
listen-address=10.99.0.3
bind-dynamic
no-resolv
server=1.1.1.1
server=9.9.9.9
cache-size=2000
EOF
systemctl enable --now dnsmasq
systemctl restart dnsmasq

umask 077
[ -f /etc/wireguard/exitsite.key ] || wg genkey | tee /etc/wireguard/exitsite.key | wg pubkey > /etc/wireguard/exitsite.pub
echo "exitsite public key: $(cat /etc/wireguard/exitsite.pub)"
echo "put the private key into /etc/wireguard/wg0.conf, then: systemctl enable --now wg-quick@wg0"
