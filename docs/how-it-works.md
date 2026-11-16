# How it works

## The problem with the old setup
The US device connected *in* to one ISP's static IP. When that ISP dropped, the tunnel dropped,
and ISP3 (no static IP, behind CGNAT) could never be used for it at all.

## The new setup
1. **Both sites dial out.** The MikroTik and the exit site device each keep a WireGuard tunnel open
   to the cloud relay. Outbound connections work from any ISP, including ISP3's CGNAT and
   the cellular ISP's cellular network. No inbound port is open anywhere at home.
2. **The relay just forwards.** Traffic from the MikroTik is passed to the exit site device and back.
   The relay never sends home traffic out its own address.
3. **Failover.** The MikroTik checks each ISP by pinging a public host reachable only through that
   ISP. Order: ISP1, then ISP2, then ISP3. When the active ISP fails, the default route moves to
   the next one, old connection entries for the tunnel are cleared, and the tunnel re-forms out of the
   new ISP within seconds. The relay learns the new address from the first packet.
4. **What goes to the US.** The Dream Machine hides every device behind one address, so the
   choice is made in UniFi: a policy route sends chosen devices (or a "US" network) out the Dream
   Machine's WAN2, which is cabled to MikroTik ether5. Everything arriving on ether5 goes to the
   US. Optionally, specific services (e.g. a streaming service) can go to the US from any device, using address
   lists the router builds from DNS answers.
5. **No leaks.** Traffic from ether5 can only use a routing table that holds the tunnel and a
   blackhole. If the tunnel is down, that traffic is dropped, never sent out a local ISP. A firewall
   rule backs this up. DNS from ether5 is forced to a resolver on the exit site device, DNS-over-TLS is
   blocked, and IPv6 is blocked on that path.
6. **Alerts.** The router sends a push notification and an email itself when an ISP goes down or
   comes back ("ISP1 down, now on ISP2"), and when the US site is unreachable. If all ISPs are
   down, alerts queue and are sent when a line returns.

## Addresses
| | |
|---|---|
| Tunnel | relay 10.99.0.1, MikroTik 10.99.0.2, exit site 10.99.0.3, admin laptop 10.99.0.10 (temporary) |
| MikroTik to UDM | WAN1 link 10.10.4.0/30, WAN2 (US) link 10.10.5.0/30 |
| ISP check hosts | ISP1 9.9.9.9, ISP2 1.0.0.1, ISP3 8.8.4.4 |
