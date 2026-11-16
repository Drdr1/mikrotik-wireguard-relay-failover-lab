#!/usr/bin/env bash
# End-to-end tests against the simulated network. Run as root after `lab.sh up`
# (or just run this; it builds the lab itself and tears it down at the end).
set -uo pipefail
cd "$(dirname "$0")" || exit 1
source ./lib.sh
set +e

ISP1=203.0.113.2 ISP2=192.0.2.2 ISP3_CGNAT=198.18.3.2 EXITSITE=198.18.9.2
pass=0; fail=0
ok()  { echo "  PASS  $*"; pass=$((pass+1)); }
bad() { echo "  FAIL  $*"; fail=$((fail+1)); }
expect() { local what=$1 want=$2 got=$3; [ "$got" = "$want" ] && ok "$what = $got" || bad "$what: want '$want', got '${got:-<nothing>}'"; }

# Wait until a command's output equals the expected value; prints seconds taken
wait_for() {
  local want=$1 limit=$2; shift 2; local t0=$SECONDS got
  while [ $((SECONDS - t0)) -lt "$limit" ]; do
    got=$("$@"); [ "$got" = "$want" ] && { echo $((SECONDS - t0)); return 0; }
    sleep 1
  done; return 1
}

relay_endpoint() { nsx relay wg show wg-hub endpoints | grep -F "$(cat $RUN/home.pub)" | awk '{print $2}' | cut -d: -f1; }

./lab.sh up
trap './lab.sh down >/dev/null 2>&1' EXIT
echo "waiting for the tunnel..."
wait_for "$EXITSITE" 30 seen_ip tv >/dev/null || true

echo "== 1. Baseline: all three ISPs up"
expect "laptop exits via" "$ISP1" "$(seen_ip laptop)"
expect "US device exits via" "$EXITSITE" "$(seen_ip tv)"
expect "relay sees home at" "$ISP1" "$(relay_endpoint)"
expect "US device DNS answered by" "US" "$(dns_geo tv)"
expect "laptop DNS answered by" "LOCAL" "$(dns_geo laptop)"

echo "== 2. ISP1 fails (line stays up, traffic dies upstream)"
isp_fail isp1
if s=$(wait_for "$EXITSITE" 30 seen_ip tv 2); then ok "US path recovered in ${s}s"; else bad "US path did not recover within 30s"; fi
expect "laptop exits via" "$ISP2" "$(seen_ip laptop)"
expect "US device exits via" "$EXITSITE" "$(seen_ip tv)"
expect "relay sees home at" "$ISP2" "$(relay_endpoint)"
expect "US device DNS answered by" "US" "$(dns_geo tv)"
grep -q "ISP1 down, switched to ISP2" "$RUN/alerts.log" && ok "alert: ISP1 down, switched to ISP2" || bad "missing failover alert"

echo "== 3. ISP2 fails too: only ISP3 (CGNAT, no static IP) left"
isp_fail isp2
if s=$(wait_for "$EXITSITE" 30 seen_ip tv 2); then ok "US path recovered over ISP3 in ${s}s"; else bad "US path did not recover over ISP3"; fi
expect "laptop exits via (ISP3 CGNAT address)" "$ISP3_CGNAT" "$(seen_ip laptop)"
expect "relay sees home at (ISP3 CGNAT address)" "$ISP3_CGNAT" "$(relay_endpoint)"
grep -q "ISP2 down, switched to ISP3" "$RUN/alerts.log" && ok "alert: ISP2 down, switched to ISP3" || bad "missing ISP3 alert"

echo "== 4. ISP1 comes back: traffic returns to the primary"
isp_restore isp1; isp_restore isp2
if s=$(wait_for "$ISP1" 30 seen_ip laptop); then ok "back on ISP1 in ${s}s"; else bad "did not fail back"; fi
if s=$(wait_for "$EXITSITE" 30 seen_ip tv 2); then ok "US path fine after failback (${s}s)"; else bad "US path broken after failback"; fi
grep -q "ISP1 back up, switched from ISP3 to ISP1" "$RUN/alerts.log" && ok "alert: ISP1 back up" || bad "missing recovery alert"

echo "== 5. Kill switch: relay unreachable must not leak US traffic to a local ISP"
nsx relay nft -f - <<'EOF2'
table inet outage {
  chain in {
    type filter hook input priority -10
    udp dport 51820 drop
  }
}
EOF2
sleep 2
got=$(seen_ip tv 3)
[ -z "$got" ] && ok "US device blocked while the tunnel is down" || bad "US device reached the web via $got (LEAK)"
expect "laptop unaffected" "$ISP1" "$(seen_ip laptop)"
nsx home ip route del default via 10.99.0.3 dev wg-relay table 200   # RouterOS: tunnel route goes inactive
got=$(seen_ip tv 3)
[ -z "$got" ] && ok "blackhole route holds with the tunnel route gone" || bad "US device reached the web via $got (LEAK)"
dnsgot=$(dns_geo tv)
[ -z "$dnsgot" ] && ok "US device DNS blocked too (no local fallback)" || bad "US device DNS answered by $dnsgot (LEAK)"
nsx home ip route add default via 10.99.0.3 dev wg-relay onlink table 200
nsx relay nft delete table inet outage
if s=$(wait_for "$EXITSITE" 30 seen_ip tv 2); then ok "tunnel back, US path restored in ${s}s"; else bad "US path not restored"; fi

echo "== 6. Control: without the US routing rule, traffic WOULD leak (proves test 5 is real)"
nsx home ip rule del iif ether5 lookup 200 pref 100
nsx home nft delete rule inet filter home_fw handle "$(nsx home nft -a list chain inet filter home_fw | awk '/US kill switch/{print $NF}')"
got=$(seen_ip tv 3)
[ "$got" = "$ISP1" ] && ok "with protection removed, US device leaks via ISP1 ($got): the rule is what stops it" || bad "control did not leak (got '${got:-nothing}'), test 5 proves nothing"
nsx home ip rule add iif ether5 lookup 200 pref 100
nsx home nft insert rule inet filter home_fw iifname "ether5" oifname '{ "wan1", "wan2", "wan3" }' counter drop comment '"US kill switch"'
expect "protection restored, US device exits via" "$EXITSITE" "$(seen_ip tv)"

echo
echo "alerts sent during the run:"; sed 's/^/  /' "$RUN/alerts.log"
echo
echo "WireGuard: $(cat $RUN/wgmode)   passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
