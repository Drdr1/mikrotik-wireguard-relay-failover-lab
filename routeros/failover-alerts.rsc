# Failover handling + alerts. Import after home-router.rsc. RouterOS v7.12+.
#
# - Netwatch watches each ISP's check host (pinned to that ISP by the scope=10 routes).
# - On any change it clears stale NAT entries for the tunnel, so WireGuard moves to the
#   new ISP in seconds. Without this, RouterOS can keep sending tunnel packets with the
#   dead ISP's address until the old connection entry times out.
# - Alerts go straight from the router (phone push via ntfy + email), so they still work
#   when the cloud relay is down. If every ISP is down, alerts queue and are sent when a
#   line returns.

# CHANGE: pick a long random topic name; install the ntfy app and subscribe to it.
:global alertTopic "https://ntfy.sh/CHANGE-long-random-topic"
:global alertEmail "CHANGE@example.com"
:global relayIP "198.51.100.2"
:global alertQueue ""

/system script
add name=alert-lib dont-require-permissions=no comment="defines sendAlert / activeWan / wanChanged" source={
  :global alertTopic; :global alertEmail; :global alertQueue; :global relayIP
  :global activeWan do={
    :foreach n in={"ISP1";"ISP2";"ISP3"} do={
      :if ([/ip route get [find comment=("default via " . $n)] active]) do={ :return $n }
    }
    :return "none"
  }
  :global sendAlert do={
    :global alertTopic; :global alertEmail; :global alertQueue
    :local msg ([/system identity get name] . ": " . $1)
    :log warning $msg
    :do {
      /tool fetch url=$alertTopic http-method=post http-data=$msg keep-result=no
      :do { /tool e-mail send to=$alertEmail subject="Router alert" body=$msg } on-error={}
    } on-error={ :set alertQueue ($alertQueue . $msg . "\n") }
  }
  :global wanChanged do={
    :global activeWan; :global sendAlert; :global relayIP
    :delay 3s
    # tunnel: forget connection entries bound to the old ISP
    /ip firewall connection remove [find where dst-address~($relayIP . ":51820")]
    :local now [$activeWan]
    :if ($2 = "down") do={ $sendAlert ($1 . " down, now on " . $now) } else={ $sendAlert ($1 . " up, now on " . $now) }
  }
}
add name=alert-flush comment="retry queued alerts" source={
  :global alertQueue; :global alertTopic
  :if ([:len $alertQueue] > 0) do={
    :do {
      /tool fetch url=$alertTopic http-method=post http-data=("Queued while offline:\n" . $alertQueue) keep-result=no
      :set alertQueue ""
    } on-error={}
  }
}

/system scheduler
add name=alert-lib-boot start-time=startup on-event="/system script run alert-lib" comment="load alert functions at boot"
add name=alert-flush interval=1m on-event="/system script run alert-flush" comment="send queued alerts"

/tool netwatch
add host=9.9.9.9 interval=10s timeout=1s comment="ISP1" \
    down-script=":global wanChanged; \$wanChanged \"ISP1\" \"down\"" \
    up-script=":global wanChanged; \$wanChanged \"ISP1\" \"up\""
add host=1.0.0.1 interval=10s timeout=1s comment="ISP2" \
    down-script=":global wanChanged; \$wanChanged \"ISP2\" \"down\"" \
    up-script=":global wanChanged; \$wanChanged \"ISP2\" \"up\""
add host=8.8.4.4 interval=10s timeout=1s comment="ISP3" \
    down-script=":global wanChanged; \$wanChanged \"ISP3\" \"down\"" \
    up-script=":global wanChanged; \$wanChanged \"ISP3\" \"up\""
add host=10.99.0.3 interval=15s timeout=2s comment="US site over tunnel" \
    down-script=":global sendAlert; \$sendAlert \"US site unreachable: US traffic is blocked (kill switch)\"" \
    up-script=":global sendAlert; \$sendAlert \"US site reachable again\""

/system script run alert-lib
