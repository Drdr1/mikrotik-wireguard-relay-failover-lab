# Runbook: check, restart, troubleshoot

## Is everything working?
On the MikroTik (Winbox → New Terminal):
```
/ip route print where dst-address=0.0.0.0/0      # the active default shows "A"; comment says which ISP
/interface wireguard peers print detail          # last-handshake should be under 2 minutes
/ping 10.99.0.3 count=3                          # exit site reachable through the tunnel
/tool netwatch print                             # status of each ISP check and the US site
/log print where topics~"warning"                # alerts that were sent
```
From a US-routed device: open ipleak.net. The IP should be the cellular ISP/exit site, DNS servers in the US, no IPv6.

## Restart
| What | How |
|---|---|
| Tunnel on the MikroTik | `/interface wireguard disable wg-relay; :delay 2; /interface wireguard enable wg-relay` |
| Stuck after an ISP change | `/ip firewall connection remove [find where dst-address~"RELAY_IP:51820"]` |
| Relay | `ssh root@RELAY` then `systemctl restart wg-quick@wg0` and `wg show` |
| exit site device | `systemctl restart wg-quick@wg0 dnsmasq`, or power-cycle it (it reconnects by itself) |

## Common problems
| Symptom | Likely cause | Fix |
|---|---|---|
| US devices have no internet | Tunnel down, so the kill switch is blocking (working as intended) | Check handshake on MikroTik, relay and exit site; restart the tunnel |
| Streaming shows the home | Device not on the UniFi US route, or using its own DNS-over-HTTPS | Check the UniFi policy route; turn off "secure DNS" in that device or app |
| No failover when an ISP dies | Check host route points to the wrong gateway | `/ip route print where comment~"check"`; for ISP3, renew DHCP |
| ISP3 tile red but internet works | ISP3 gateway changed and the DHCP script didn't run | `/ip dhcp-client renew [find comment="ISP3"]` |
| No alerts | ntfy topic or email not set, or all ISPs were down (alerts queue) | `/system script run alert-flush`; check `:global alertTopic` |

## Adding or changing alerts
- Push topic and email: edit `alertTopic` / `alertEmail` at the top of `failover-alerts.rsc` and re-run
  `/system script run alert-lib`.
- New check: `/tool netwatch add host=X interval=15s down-script=":global sendAlert; \$sendAlert \"X down\""`.

## Before changing anything
`/import safe-change.rsc`, turn on Safe Mode, make the change, then `/system scheduler remove auto-rollback`
once it's confirmed good. If access is lost, the router restores the backup within 10 minutes.
