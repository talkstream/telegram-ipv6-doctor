# For the Telegram client team

Field evidence: [`FINDINGS.md`](FINDINGS.md). This page is the part that is actionable inside the client.

None of this is Telegram’s fault in origin — the trigger was an ISP with degraded IPv6 routing to Telegram’s
own endpoints. But the client’s reaction is what turned a slow path into an unusable app, and that part is
fixable in code.

**Stated precisely, because it is easy to overclaim:** MTProtoKit *does* race IPv4 and IPv6 candidates
(`MTDiscoverConnectionSignals.m:222‑224` — `mergeSignals` + `take:1`), with a 5 s timeout per attempt, plus
alternate ports 80/5222. What it does not do is give up on a family that keeps failing.

---

### R1 · Demote a failing address family, and race it the way RFC 8305 says

A 5-second per-attempt timeout is twenty times the RFC 8305 connection-attempt delay (250 ms), and the
failing family is **not** durably demoted: every reconnect re-races the same dead IPv6 endpoints. On a
network where IPv6 to Telegram black-holes, that is a permanent tax on every reconnect.

Track per-family and per-address success/RTT; after N recent connect failures on a family, deprioritise it
for a while and prefer the family that most recently completed a handshake. Cap the number of concurrent
connect attempts per DC.

(In Telegram Desktop, “prefer IPv6” is an experimental, off-by-default flag — `session_private.cpp:200`,
PR [#28773](https://github.com/telegramdesktop/tdesktop/pull/28773). Neither official repo contains the
strings “happy eyeballs” or “8305”.)

### R2 · Back off the `-404` / re-auth loop; separate transport reconnect from key re-binding

Observed in one 1 MB log window during the incident: `getConfig` ×301, `auth.bindTempAuthKey` ×32,
`resetting session` ×4, `protocol error -404` ×12 (×62 in verbose logs). A flapping transport should not
trigger a full session reset + temp-key re-bind + config refetch on every failure.

Exponential backoff with jitter; cache `getConfig` with a sane TTL; do not conflate “re-open TCP” with
“re-establish the auth key”.

### R3 · Bound the busy-retry CPU and log volume

Under churn the process held 40–94 % CPU and wrote ~1 MB of logs every few seconds (rapid `critlog`
rotation). Even on a broken network, the reconnect scheduler should idle between rounds. This alone removes
the battery/thermal symptom and keeps the logs usable for support.

### R4 · Unknown TL constructor `0x232d5905`

The macOS client received a message whose constructor id `0x232d5905` is not in its parser and dropped it
~300× on layer 228 (`Type constructor 232d5905 not found`). Whether it is a genuine layer‑228 type missing
from the parser or garbage from a desynced session, a message that can never be parsed on the **updates**
path can force update-gap recovery and add churn. Please map it against the internal schema.
*(Flagged for identification — not asserted as a cause.)*

### R5 · “Connecting” says nothing, and the logs are unreadable

The global indicator showed “Connecting” while media DCs were actively transferring. Distinguish
“reconnecting updates” from “offline”, and surface — in the connection debug panel — which DC and which
address family is failing. Today the only way to see the address-family story is to run `strings` over a
binary `critlog`.

### R6 · Isolate the connection indicator per account

With two accounts (home DCs inferred as DC2 and DC5), a persistent master-DC failure on one appears to hold
the global indicator in “Connecting”. Per-account state in the UI would tell the user which account is
actually stuck.

---

### Bonus: a client-side check worth having

Sockets that are closed *before any data flows*, repeatedly, are a signature of a local content filter
(DPI firewall, AV) rather than a network fault — we hit exactly that with a nightly build of a firewall on
the same machine (see [`FINDINGS.md`](FINDINGS.md), Act II). A client that notices “my sockets die before
the handshake, on every DC, while DNS and other traffic are fine” could say so, instead of showing
“Connecting…” forever.

Related upstream issues: [#29244](https://github.com/telegramdesktop/tdesktop/issues/29244),
[#2198](https://github.com/telegramdesktop/tdesktop/issues/2198),
[#29245](https://github.com/telegramdesktop/tdesktop/issues/29245),
[#25423](https://github.com/telegramdesktop/tdesktop/issues/25423),
Telegram-iOS [#487](https://github.com/TelegramMessenger/Telegram-iOS/issues/487).
