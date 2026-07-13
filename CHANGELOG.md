# Changelog

## v1.0.1 — 2026-07-14

**Fixes a false positive that could have made the tool lie to people.**

- `local-filter-interference` used to fire on the *count* of a filter's socket-teardown log lines alone
  (e.g. Little Snitch's `Socket closed during DPI without data`). That rule was wrong. Those lines are also
  what a filter logs when MTProtoKit **races candidate connections** (IPv4/IPv6 × ports 443/80/5222) and
  closes the losers without sending data — measured on a live machine at **~160 events/min while the client
  was perfectly healthy** (18 established, 0 closed). The same rate appeared during an actual stall
  (~174/min), so the signal cannot tell health from failure.
- The verdict now requires **observed client distress** (sockets churning: ≥ 8 in `CLOSED`) *in addition to*
  the filter being active and noisy. A quiet-but-noisy-logging filter no longer gets blamed.
- `--json` and `report` now carry `client_sockets` (live / churning), so the evidence behind the verdict is
  visible rather than implied.
- Reports now state plainly that a filter's teardown count is not, on its own, evidence.

If you ran **v1.0.0** and got `local-filter-interference`, re-run: the verdict may change.

## v1.0.0 — 2026-07-14

First release.

- One-command, read-only diagnosis of Telegram's "Connecting" state on macOS.
- Discriminates between three causes: degraded IPv6 routing to Telegram, a local network filter tearing
  sockets down, and a client-side reconnect loop — plus blocked/DPI, proxy, NAT64 and healthy states.
- Surgical fix: reject-routes for only those Telegram IPv6 prefixes proven broken on the machine, leaving
  the rest of IPv6 working. Blunt fallback (`--mode ipv6-off`) for globally broken IPv6.
- Hard refusals: no IPv4 path, IPv6-only/NAT64 networks, unproven verdict, active VPN/proxy, active filter.
- `revert` restores the saved state and verifies the result.
- 18 offline tests (bats + fake binaries); shellcheck clean; no telemetry; no runtime fetches.
