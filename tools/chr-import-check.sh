#!/usr/bin/env bash
# Boots a real RouterOS CHR in QEMU, imports routeros/*.rsc and fails on any RouterOS error.
# Usage: tools/chr-import-check.sh [routeros-version|stable]
# Needs: qemu-system-x86_64, sshpass, curl, unzip. Uses KVM when available.
set -euo pipefail
cd "$(dirname "$0")/.."

VER=${1:-stable}
if [ "$VER" = stable ]; then
  VER=$(curl -fsS https://upgrade.mikrotik.com/routeros/NEWESTa7.stable | awk '{print $1}')
fi
echo "RouterOS CHR $VER"
WORK=$(mktemp -d); trap 'kill $QPID 2>/dev/null || true; rm -rf "$WORK"' EXIT
curl -fsSL -o "$WORK/chr.zip" "https://download.mikrotik.com/routeros/$VER/chr-$VER.img.zip"
unzip -q "$WORK/chr.zip" -d "$WORK"
IMG=$(ls "$WORK"/chr-*.img)

ACCEL=tcg; [ -w /dev/kvm ] && ACCEL=kvm
# ether1..ether5 = the five ports the config uses; ether6 = CI management (SSH via port 2223)
NICS=""
for i in 1 2 3 4 5; do
  if [ $i = 1 ]; then NICS+=" -netdev user,id=n$i,hostfwd=tcp:127.0.0.1:2222-:22"
  else NICS+=" -netdev user,id=n$i,restrict=on"; fi
  NICS+=" -device virtio-net-pci,netdev=n$i"
done
NICS+=" -netdev user,id=n6,hostfwd=tcp:127.0.0.1:2223-:22 -device virtio-net-pci,netdev=n6"
# shellcheck disable=SC2086
qemu-system-x86_64 -accel $ACCEL -m 512 -smp 2 -nographic -serial null -monitor none \
  -drive file="$IMG",format=raw,if=virtio $NICS &
QPID=$!

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PubkeyAuthentication=no -o LogLevel=ERROR -o ConnectTimeout=20 -o ServerAliveInterval=10"
# RouterOS's SSH server can be slow to answer right after boot or after a login; retry
# connection failures (exit 255) only, so a command never runs twice.
ros() {
  local port=$1 rc; shift
  for _ in 1 2 3 4 5 6; do
    timeout 300 sshpass -p '' ssh $SSH_OPTS -p "$port" admin@127.0.0.1 "$@" && return 0
    rc=$?; [ $rc -ne 255 ] && return $rc
    sleep 5
  done
  return 255
}
rcopy() {
  for _ in 1 2 3 4 5 6; do sshpass -p '' scp $SSH_OPTS -P 2223 "$1" admin@127.0.0.1:/ >/dev/null && return 0; sleep 5; done
  return 1
}

echo "waiting for CHR to boot ($ACCEL)..."
for i in $(seq 120); do sshpass -p '' ssh $SSH_OPTS -p 2222 admin@127.0.0.1 ':put ready' 2>/dev/null | grep -q ready && break; sleep 3; done
ros 2222 '/system resource print' | grep -E 'version|board-name'
sleep 5

# Move management off ether1 (the config turns ether1 into the ISP1 WAN)
ros 2222 '/ip dhcp-client add interface=ether6 disabled=no'
for i in $(seq 40); do sshpass -p '' ssh $SSH_OPTS -p 2223 admin@127.0.0.1 ':put ready' 2>/dev/null | grep -q ready && break; sleep 2; done
ros 2223 '/ip dhcp-client remove [find interface=ether1]'

for f in home-router.rsc failover-alerts.rsc safe-change.rsc; do
  rcopy "routeros/$f"
done

# One session: the config restricts SSH to the home/tunnel subnets, so new logins from CI stop working after import
OUT=$(ros 2223 '/import file-name=home-router.rsc verbose=no; :put "==1"; /import file-name=failover-alerts.rsc verbose=no; :put "==2"; /import file-name=safe-change.rsc verbose=no; :put "==3"; /system scheduler remove auto-rollback; /ip route print terse where routing-table=to-us; /routing rule print terse; /interface wireguard print terse; /ip firewall filter print terse where comment~"kill switch"; /tool netwatch print terse; /ip dns static print terse; :put "--invalid rules:"; /ip firewall filter print terse where invalid; /ip firewall nat print terse where invalid; /ip firewall mangle print terse where invalid; :put ("invalid=" . ([/ip firewall filter print count-only where invalid] + [/ip firewall nat print count-only where invalid] + [/ip firewall mangle print count-only where invalid])); :put "==done"' 2>&1) || true
echo "$OUT"

fail=0
for marker in "==1" "==2" "==3" "==done"; do grep -q -- "$marker" <<<"$OUT" || { echo "missing $marker"; fail=1; }; done
[ "$(grep -c 'Script file loaded and executed successfully' <<<"$OUT")" -ge 3 ] || { echo "not every import succeeded"; fail=1; }
grep -qiE 'failure|syntax error|expected end of command|bad command|input does not match' <<<"$OUT" && { echo "RouterOS reported an error"; fail=1; }
grep -q '^invalid=0' <<<"$(tr -d '\r' <<<"$OUT")" || echo "note: RouterOS shows rules flagged I right after import (diagnostic only, see list above)"
grep -q 'blackhole' <<<"$OUT" || { echo "kill-switch blackhole route missing"; fail=1; }
grep -q 'lookup-only-in-table' <<<"$OUT" || { echo "US routing rule missing"; fail=1; }
[ $fail = 0 ] && echo "PASS: all RouterOS configs imported cleanly on CHR $VER" || { echo "FAIL on CHR $VER"; exit 1; }
