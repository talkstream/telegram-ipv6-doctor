# Changelog

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
