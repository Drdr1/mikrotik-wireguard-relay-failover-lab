#!/usr/bin/env bash
# One-time relay setup on a fresh cloud VPS Debian/Ubuntu box. Run as root.
set -euo pipefail

apt-get update -qq && apt-get install -y -qq wireguard nftables unattended-upgrades

cat > /etc/sysctl.d/90-relay.conf <<'EOF'
net.ipv4.ip_forward = 1
EOF
sysctl -q --system

# Firewall: SSH and WireGuard in, forwarding only inside the tunnel
cat > /etc/nftables.conf <<'EOF'
#!/usr/sbin/nft -f
flush ruleset
table inet filter {
  chain input {
    type filter hook input priority 0; policy drop;
    ct state established,related accept
    iif lo accept
    icmp type echo-request accept
    udp dport 51820 accept comment "WireGuard"
    tcp dport 22 accept comment "SSH (keys only)"
    iifname "wg0" ip saddr 10.99.0.0/24 accept comment "status page etc. over the tunnel"
  }
  chain forward {
    type filter hook forward priority 0; policy drop;
    iifname "wg0" oifname "wg0" accept comment "peer to peer only"
  }
}
EOF
systemctl enable --now nftables

# SSH: keys only
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl reload ssh || systemctl reload sshd

umask 077
[ -f /etc/wireguard/relay.key ] || wg genkey | tee /etc/wireguard/relay.key | wg pubkey > /etc/wireguard/relay.pub
echo "relay public key: $(cat /etc/wireguard/relay.pub)"
echo "put the private key into /etc/wireguard/wg0.conf, add the peer keys, then: systemctl enable --now wg-quick@wg0"
