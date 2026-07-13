# Safety

This tool asks for `sudo` and changes network routing on other people’s machines. That deserves an explicit
account of what it does, what it refuses to do, and how you get your machine back.

## Read-only by default

`diagnose` (the default, and what the one-liner runs) never mutates anything. It runs `nc`, `ping`, `scutil`,
`netstat`, `lsof`, `log show` and reads counters from Telegram’s own log files. No `sudo`, no writes.

A test enforces this: fake `sudo`, `route` and `networksetup` binaries record any invocation, and the test
fails if a `diagnose` run touches them. Same for `curl`/`wget` — see below.

## What `fix` actually runs

Surgical mode (the default), for **each Telegram IPv6 prefix it has just proven broken on your machine**:

```
sudo /bin/sh -c '/sbin/route -n add -inet6 2001:b28:f23d::/48 ::1 -reject; …'
```

`-reject` makes the kernel answer `connect()` with an immediate ICMP-unreachable instead of letting it hang.
Telegram therefore fails over to IPv4 at once, and **every other IPv6 destination is untouched**.

Blunt mode (`--mode ipv6-off`), only for the “IPv6 is broken everywhere” verdict:

```
sudo /usr/sbin/networksetup -setv6off "<the service that carries your default route>"
```

Both are printed in full **before** they run. `--dry-run` prints and exits.

## Refusals (they are not warnings — the tool exits)

| Situation | Why it refuses |
|---|---|
| No working **IPv4** path to Telegram | The fix would leave you with no path at all. |
| **IPv6-only / NAT64** network (`ipv4only.arpa` returns AAAA, or a `64:ff9b::/96` route exists) | There is no IPv4 to fall back to. Disabling IPv6 would take your whole internet — including your ability to download this tool again. |
| The verdict is anything other than the one the fix was built for | We do not “fix” machines that are not broken this way. |
| A **VPN or system proxy** is active | The measurements cannot be trusted; a wrong verdict here would be a wrong root-level change. |
| A **local filter** is tearing sockets down | Then your network is not the problem. Fix the filter. |

`--yes` skips the confirmation prompt. It does **not** skip any of the above.

## Getting your machine back

State is written **before** any change, to `/Library/Application Support/telegram-ipv6-doctor/state.json`
(root-owned, world-readable). It records, verbatim, the `networksetup -getinfo` output of *every* network
service — including a manual IPv6 configuration if you had one — and the IPv6 routing table.

```bash
telegram-ipv6-doctor.sh revert
```

`revert` is idempotent, tolerates already-removed routes, and **verifies the result** (`netstat -rnf inet6`
must show none of our reject routes left). If it cannot verify, it says so and prints the manual command
instead of claiming success.

Reject routes also die on reboot. There is no daemon, no login item, nothing that reinstalls them behind
your back — persistence was deliberately left out of v1, because a network change that silently outlives its
cause is worse than the bug.

## Supply chain

- The one-liner is pinned to an **immutable tag**, and the SHA-256 of exactly that blob is published in the
  release notes — so `shasum -a 256` is a real check, not a ritual.
- The script is one file, all logic in functions, ending with `main "$@"` and a sentinel comment. A truncated
  download **executes nothing**.
- Telegram’s IPv6 prefixes are a **compile-time constant**. The tool fetches nothing at runtime — enforced by
  a test with a fake `curl` that fails the suite if it is ever invoked. A hijacked remote list would otherwise
  mean blackholing arbitrary networks with root privileges. Freshness is handled by a weekly CI job that diffs
  Telegram’s published list and opens a pull request for a human to review.
- Only prefixes **proven broken on your machine** are rejected — never the whole list “just in case”.

## Privacy

No telemetry. The only outbound traffic is the probes. `report` is built from an allowlist — macOS version,
architecture, client version, per-DC latencies, control latencies, log counters, verdict — and contains no
hostnames, no IP addresses of yours, no SSID, no account names and no paths containing your username.

## Reporting a vulnerability

Open a private security advisory on GitHub, or write to [t.me/nafigator](https://t.me/nafigator).
