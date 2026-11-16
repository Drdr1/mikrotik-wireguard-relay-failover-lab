# MikroTik + WireGuard site-to-site through a cloud relay, with 3-WAN failover

[![ci](https://github.com/Drdr1/mikrotik-wireguard-relay-failover-lab/actions/workflows/ci.yml/badge.svg)](https://github.com/Drdr1/mikrotik-wireguard-relay-failover-lab/actions/workflows/ci.yml)

A home network routes chosen traffic out of a site in another country. Neither site has a
dependable static IP: one is a satellite ISP behind CGNAT, the far end is a cellular line.
This lab builds the fix and proves it works:

- Both sites **dial out** to a small cloud relay (static IP). No site needs a static IP or an open port.
- The router **fails over across three ISPs** (two static, one satellite behind CGNAT), and the tunnel follows in seconds.
- Only chosen traffic goes to the far site, chosen either **by device** (a UniFi policy route to a second
  router port) or **by destination** (DNS-built address lists that track CDN changes).
- **No leaks.** US-bound traffic can only leave through the tunnel. If the tunnel is down it is blocked,
  never sent out a local ISP. DNS from those devices is forced to a resolver at the far site.
- **Alerts come from the router itself** ("ISP1 down, now on ISP2"), so they work when the relay is down.

```
 laptop ── UDM WAN1 ─┐                       ┌─ ISP1 (static) ──┐
                     ├── MikroTik ───────────┼─ ISP2 (static) ─────┼── internet ── cloud relay (static IP)
 TV ────── UDM WAN2 ─┘   failover + policy   └─ ISP3 (CGNAT) ──┘                 │
                                                                                     │ WireGuard
                                                   exit site exit device ── the cellular ISP (CGNAT) ┘
```

## What's in here

| Path | What it is |
|---|---|
| `routeros/home-router.rsc` | RouterOS v7 config: interfaces, recursive-route failover, WireGuard, US table + kill switch, DNS forcing, management lock-down, by-destination lists |
| `routeros/failover-alerts.rsc` | Netwatch per ISP, stale-connection flush on failover, push/email alerts with an offline queue |
| `routeros/safe-change.rsc` | Change procedure: backup + export + auto-rollback timer, used alongside Safe Mode |
| `relay/` | cloud relay: `wg0.conf` (peer-to-peer forwarding only) and `setup.sh` (firewall, SSH keys only) |
| `exit/` | Far-end exit device: `wg0.conf`, NAT out, US DNS resolver on the tunnel address |
| `sim/` | The whole design rebuilt in Linux network namespaces, with end-to-end tests |
| `tools/chr-import-check.sh` | Boots a real RouterOS CHR in QEMU and imports every `.rsc`, failing on any RouterOS error |
| `docs/` | How it works, runbook (check/restart/troubleshoot), live failover test plan, sample test output |

## The tests

`sudo sim/test.sh` builds the network (three ISPs with BCP38 filtering, ISP3 and the cellular ISP behind
carrier-grade NAT, the relay, a "streaming service" that reports the address it sees, and two DNS
resolvers), then breaks things on purpose:

1. **Baseline**: laptop exits via ISP1; TV exits via exit site; TV's DNS answered in the US.
2. **ISP1 dies upstream** (link stays up, like a real outage): failover to ISP2, tunnel back in about 4 s, alert sent.
3. **ISP2 dies too**: everything moves to ISP3 behind CGNAT; the relay sees ISP3's shared address and the tunnel still works.
4. **ISP1 returns**: automatic failback.
5. **Relay unreachable**: TV traffic and TV DNS are **blocked**, not leaked; the laptop is unaffected.
6. **Control**: remove the US rule and confirm the TV *does* leak, which proves test 5 is real.

See [`docs/sample-run.txt`](docs/sample-run.txt) for a full run (25/25).

CI runs the simulation on kernel WireGuard and imports the RouterOS configs on real CHR
(a pinned 7.16.2 plus the current stable release).

The simulation stands in for the MikroTik with Linux (`sim/home-policy.sh` and `sim/failover.sh`
map section by section to the `.rsc`). It shows the design works. The CHR job shows the RouterOS config is valid.
Neither replaces the live unplug-the-ISP test on the real network ([`docs/live-test-plan.md`](docs/live-test-plan.md)).

## Run it

```bash
sudo apt-get install -y wireguard-tools nftables conntrack dnsutils dnsmasq-base curl iproute2
sudo sim/test.sh                         # end-to-end simulation
tools/chr-import-check.sh stable         # RouterOS import on CHR (needs qemu-system-x86, sshpass, unzip)
```

All addresses are RFC 5737/6598 documentation ranges and the keys are lab-only. Replace every `CHANGE` value before real use.
