# home MikroTik: multi-WAN failover + WireGuard to a cloud relay + US policy routing
# RouterOS v7.12 or newer. Import on top of an existing config:  /import home-router.rsc
#
# Values marked CHANGE are lab placeholders (RFC 5737 documentation addresses, a lab-only key).
#
#   ether1  ISP1   static   (primary)
#   ether2  ISP2      static   (second)
#   ether3  ISP3  DHCP, behind CGNAT (last resort)
#   ether4  to UDM Pro Max WAN1  (normal home traffic)
#   ether5  to UDM Pro Max WAN2  (devices UniFi policy-routes to the US)
#
# The UDM NATs every home device, so the MikroTik can't tell devices apart. The device choice
# is made in UniFi (a policy route sends chosen devices/networks out WAN2); anything that
# arrives on ether5 goes to the US. Specific services from other devices can go to the US too,
# via DNS-built address lists (section 7).

# ---------------------------------------------------------------- 1. interfaces
/interface ethernet
set [ find default-name=ether1 ] name=ether1-isp1 comment="WAN1 ISP1 (static)"
set [ find default-name=ether2 ] name=ether2-isp2 comment="WAN2 ISP2 (static)"
set [ find default-name=ether3 ] name=ether3-isp3 comment="WAN3 ISP3 (DHCP, CGNAT)"
set [ find default-name=ether4 ] name=ether4-udm comment="to UDM WAN1: normal traffic"
set [ find default-name=ether5 ] name=ether5-us comment="to UDM WAN2: US-bound devices"

/interface list
add name=WAN comment="internet-facing"
add name=LAN comment="home side"
/interface list member
add list=WAN interface=ether1-isp1
add list=WAN interface=ether2-isp2
add list=WAN interface=ether3-isp3
add list=LAN interface=ether4-udm
add list=LAN interface=ether5-us

/ip address
add address=203.0.113.2/30 interface=ether1-isp1 comment="CHANGE ISP1 static"
add address=192.0.2.2/30 interface=ether2-isp2 comment="CHANGE ISP2 static"
add address=10.10.4.1/30 interface=ether4-udm comment="UDM WAN1 uses 10.10.4.2"
add address=10.10.5.1/30 interface=ether5-us comment="UDM WAN2 uses 10.10.5.2"

# ---------------------------------------------------------------- 2. WAN failover
# Recursive routes: each ISP has a check host reachable only through that ISP (scope=10).
# check-gateway=ping pings the check host, so an ISP that is "link up but dead upstream"
# is detected, not just a pulled cable. Distance sets the order ISP1 > ISP2 > ISP3.
/ip route
add dst-address=9.9.9.9/32 gateway=203.0.113.1 scope=10 comment="check ISP1 - CHANGE gateway"
add dst-address=1.0.0.1/32 gateway=192.0.2.1 scope=10 comment="check ISP2 - CHANGE gateway"
add dst-address=8.8.4.4/32 gateway=100.64.0.1 scope=10 comment="check ISP3"
add dst-address=0.0.0.0/0 gateway=9.9.9.9 target-scope=11 check-gateway=ping distance=1 comment="default via ISP1"
add dst-address=0.0.0.0/0 gateway=1.0.0.1 target-scope=11 check-gateway=ping distance=2 comment="default via ISP2"
add dst-address=0.0.0.0/0 gateway=8.8.4.4 target-scope=11 check-gateway=ping distance=3 comment="default via ISP3"

# ISP3's gateway is handed out by DHCP and can change; the DHCP script keeps
# the ISP3 check route pointed at whatever gateway ISP3 gives us.
/ip dhcp-client
add interface=ether3-isp3 add-default-route=no use-peer-dns=no use-peer-ntp=no comment="ISP3" \
    script=":if (\$bound=1) do={ /ip route set [find comment=\"check ISP3\"] gateway=\$\"gateway-address\" }"

/ip firewall nat
add chain=srcnat out-interface-list=WAN action=masquerade comment="NAT out each ISP"

# ---------------------------------------------------------------- 3. WireGuard to the relay
# The router dials OUT to the relay, so no ISP needs a static IP or an open port, and
# ISP3's CGNAT doesn't matter. Tunnel packets follow the main table, so they move to
# whichever ISP is active; the relay learns the new address from the next packet.
/interface wireguard
add name=wg-relay listen-port=51820 mtu=1420 comment="tunnel to cloud relay (private key auto-generated)"
/interface wireguard peers
add interface=wg-relay public-key="isX9MzrBI99frpoiEQ2exIdhVTFxTGHsuWYtuELl5ww=" \
    endpoint-address=198.51.100.2 endpoint-port=51820 allowed-address=0.0.0.0/0 \
    persistent-keepalive=25s comment="cloud relay - CHANGE key and address"
/ip address
add address=10.99.0.2/24 interface=wg-relay comment="tunnel address"
/ip firewall nat
add chain=srcnat out-interface=wg-relay action=masquerade comment="US traffic leaves as 10.99.0.2"
/ip firewall mangle
add chain=forward out-interface=wg-relay protocol=tcp tcp-flags=syn action=change-mss \
    new-mss=clamp-to-pmtu passthrough=yes comment="avoid MTU stalls in the tunnel"

# ---------------------------------------------------------------- 4. US path + kill switch
# Table to-us has only two routes: exit site through the tunnel, and a blackhole behind it.
# Traffic from ether5 may look ONLY in this table, so if the tunnel is down it hits the
# blackhole. It can never fall back to a local ISP.
/routing table
add name=to-us fib comment="US-bound traffic: tunnel or nothing"
/ip route
add dst-address=0.0.0.0/0 gateway=10.99.0.3%wg-relay routing-table=to-us distance=1 comment="US exit: exit site over the tunnel"
add dst-address=0.0.0.0/0 blackhole routing-table=to-us distance=250 comment="kill switch: never fall back"
/routing rule
add dst-address=10.10.0.0/16 action=lookup table=main comment="router and home subnets stay local"
add interface=ether5-us action=lookup-only-in-table table=to-us comment="US devices: tunnel only"
add routing-mark=to-us action=lookup-only-in-table table=to-us comment="US services by destination: tunnel only"

/ip firewall filter
add chain=forward in-interface=ether5-us out-interface-list=WAN action=drop comment="US kill switch (backup to the routing rule)"
add chain=forward in-interface=ether4-udm dst-address-list=us-services out-interface-list=WAN action=drop comment="US-services kill switch"

# ---------------------------------------------------------------- 5. DNS for the US path
# Every DNS query from US devices goes to the resolver on the exit site device, whatever
# server the device asked for, so services see a US resolver and get US CDN answers.
/ip firewall nat
add chain=dstnat in-interface=ether5-us protocol=udp dst-port=53 action=dst-nat to-addresses=10.99.0.3 comment="US DNS: force exit site resolver"
add chain=dstnat in-interface=ether5-us protocol=tcp dst-port=53 action=dst-nat to-addresses=10.99.0.3 comment="US DNS: force exit site resolver (tcp)"
/ip firewall filter
add chain=forward in-interface=ether5-us protocol=tcp dst-port=853 action=reject reject-with=tcp-reset comment="block DNS-over-TLS bypass"
# ISP3 gives IPv6; v6 from US devices would skip the tunnel entirely.
/ipv6 firewall filter
add chain=forward in-interface=ether5-us action=drop comment="no IPv6 on the US path"

# ---------------------------------------------------------------- 6. management lock-down
/ip firewall filter
add chain=input connection-state=established,related action=accept comment="allow replies"
add chain=input connection-state=invalid action=drop comment="drop invalid"
add chain=input protocol=icmp action=accept comment="allow ping"
add chain=input in-interface=wg-relay src-address=10.99.0.0/24 action=accept comment="management over the tunnel"
add chain=input in-interface-list=LAN action=accept comment="management from home"
add chain=input in-interface-list=WAN action=drop comment="nothing from the internet"
/ip service
set telnet disabled=yes
set ftp disabled=yes
set www disabled=yes
set api disabled=yes
set api-ssl disabled=yes
set ssh address=10.10.4.0/30,10.99.0.0/24
set winbox address=10.10.4.0/30,10.99.0.0/24
/tool mac-server set allowed-interface-list=LAN
/tool mac-server mac-winbox set allowed-interface-list=LAN
/ip neighbor discovery-settings set discover-interface-list=LAN
/ip dns set allow-remote-requests=yes servers=9.9.9.9,1.1.1.1
# (the WAN drop rule above keeps the resolver closed to the internet)

# ---------------------------------------------------------------- 7. optional: US by destination
# For services that should reach the US from ANY device: the router resolves these names
# through the exit site resolver (US answers) and adds each IP to us-services automatically,
# so the list follows CDN changes. UDM must use the MikroTik (10.10.4.1) as its DNS.
/ip dns static
add type=FWD name=service-a.example match-subdomain=yes forward-to=10.99.0.3 address-list=us-services comment="US service"
add type=FWD name=cdn-a.example match-subdomain=yes forward-to=10.99.0.3 address-list=us-services comment="US service"
add type=FWD name=service-b.example match-subdomain=yes forward-to=10.99.0.3 address-list=us-services comment="US service"
/ip firewall mangle
add chain=prerouting in-interface=ether4-udm dst-address-list=us-services action=mark-routing \
    new-routing-mark=to-us passthrough=no comment="US services by destination"
