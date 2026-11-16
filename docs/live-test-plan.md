# Live failover test (done together, Eastern time)

Needed: someone at the home house who can unplug cables, a US-routed device playing a stream,
and a normal device. The admin watches the router and relay remotely and reports in writing.

| # | Action at the house | Pass when |
|---|---|---|
| 0 | Nothing, all ISPs up | US device: ipleak.net shows the cellular ISP exit site, US DNS, no IPv6. Normal device: ISP1 IP |
| 1 | Unplug ISP1 | Within ~15 s: alert "ISP1 down, now on ISP2"; stream keeps playing or resumes; US device still exit site |
| 2 | Also unplug ISP2 | Alert "ISP2 down, now on ISP3"; US device still exit site; relay shows ISP3 address |
| 3 | Plug both back in | Alerts for each; traffic returns to ISP1; US path still exit site |
| 4 | Admin blocks the tunnel at the relay | US device loses internet (kill switch) and never shows a home IP; normal device fine; "US site unreachable" alert |
| 5 | Admin unblocks | US path returns by itself |
| 6 | Power-cycle the MikroTik | Comes back on ISP1, tunnel up, US path works with no manual steps |

Results are recorded in a table with timestamps and handed over with the config exports.
