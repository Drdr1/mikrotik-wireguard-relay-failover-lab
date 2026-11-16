#!/usr/bin/env bash
# WAN failover loop for the simulated MikroTik. Runs inside the "home" namespace.
# RouterOS does the same with recursive routes + check-gateway=ping (distance 1/2/3)
# and a Netwatch script that clears stale connections and sends alerts.
#
# Health check: ping through each WAN, sourced from that WAN's address.
# A WAN is down after 2 failed checks in a row, up again after 2 good ones.

NAMES=(ISP1 ISP2 ISP3); DEVS=(wan1 wan2 wan3)
SRCS=(203.0.113.2 192.0.2.2 100.64.0.2); GWS=(203.0.113.1 192.0.2.1 100.64.0.1)
TARGET=198.51.100.6   # RouterOS config uses public anycast resolvers as check hosts
RELAY=198.51.100.2
ALERTS=/tmp/mtlab/alerts.log
state=(1 1 1); fails=(0 0 0); oks=(2 2 2); active=0

log() { echo "$(date +%T) $*" | tee -a "$ALERTS"; }

pick() { for i in 0 1 2; do [ "${state[$i]}" = 1 ] && { echo $i; return; }; done; echo -1; }

while true; do
  for i in 0 1 2; do
    if ping -c1 -W1 -I "${SRCS[$i]}" "$TARGET" >/dev/null 2>&1; then
      fails[$i]=0; oks[$i]=$((oks[$i]+1))
      [ "${state[$i]}" = 0 ] && [ "${oks[$i]}" -ge 2 ] && { state[$i]=1; up_event=$i; }
    else
      oks[$i]=0; fails[$i]=$((fails[$i]+1))
      [ "${state[$i]}" = 1 ] && [ "${fails[$i]}" -ge 2 ] && { state[$i]=0; down_event=$i; }
    fi
  done
  new=$(pick)
  if [ "$new" != "$active" ]; then
    old=$active
    if [ "$new" = -1 ]; then
      log "ALERT all WANs down (alerts queue until a line returns)"
    else
      ip route replace default via "${GWS[$new]}" dev "${DEVS[$new]}"
      # Stale NAT entries keep tunnel packets on the dead ISP's address; clear them
      conntrack -D -p udp -d "$RELAY" >/dev/null 2>&1 || true
      if [ "$old" = -1 ]; then log "ALERT ${NAMES[$new]} up, internet restored"
      elif [ "$new" -gt "$old" ]; then log "ALERT ${NAMES[$old]} down, switched to ${NAMES[$new]}"
      else log "ALERT ${NAMES[$new]} back up, switched from ${NAMES[$old]} to ${NAMES[$new]}"; fi
    fi
    active=$new
  else
    if [ -n "${down_event:-}" ]; then log "ALERT ${NAMES[$down_event]} down (backup line, no switch)"; fi
    if [ -n "${up_event:-}" ];   then log "ALERT ${NAMES[$up_event]} up"; fi
  fi
  unset down_event up_event
  sleep 1
done
