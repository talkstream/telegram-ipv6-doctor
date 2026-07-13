# Findings — why this tool exists, and why it discriminates instead of blaming

This is the field evidence behind `telegram-ipv6-doctor`. It is also, deliberately, the story of how the
first diagnosis was **incomplete** — because that is exactly the mistake the tool is built to stop you from
making.

*Vantage point: a residential AIS line in Chiang Mai, Thailand. Machine: MacBook Pro (Apple silicon),
macOS 27.0. Client: Telegram for macOS (native, `ru.keepcoder.Telegram` 12.8/282011), two accounts.*

---

## Act I — the network really was broken (2026‑07‑13, daytime)

Telegram sat on “Connecting” for hours, with brief connected windows. Media occasionally trickled in.
Reinstalling the app (beta → stable) changed nothing.

**What the evidence showed.** IPv6 was up, but its *routing was broken per destination*:

| target | result |
|---|---|
| IPv4 → 8.8.8.8 | 22 ms |
| IPv6 → Cloudflare `2606:4700:4700::1111` | 46 ms — **healthy: the local v6 stack is fine** |
| IPv6 → Google `2001:4860:4860::8888` | **2046 ms** |
| IPv6 → Telegram’s own endpoints | **connect timeouts** |

The client’s own logs showed the consequence — a re-authentication storm:

```
[MTTcpConnection disconnected from 2001:b28:f23f:f005::a
   (GCDAsyncSocketErrorDomain Code=3 "Attempt to connect to host timed out")]
[MTProto protocol error -404]        ← “auth key not found” on the DC
[MTProto resetting session]
[MTProto preparing auth.bindTempAuthKey …]
```

Counts in a single 1 MB log window: `protocol error -404` ×12 (×62 in the verbose beta logs),
`resetting session` ×4, `bindTempAuthKey` ×32, `getConfig` ×301. The process held **8 established vs 40
CLOSED** sockets and burned 40–94 % CPU.

**The intervention.** Disabling IPv6 on the interface and restarting the client:

| signal | before | after |
|---|---|---|
| `protocol error -404` | 12 (62 in beta logs) | **0–2** |
| `resetting session` | 4 | **0** |
| `getConfig` | 301 | **3–7** |
| log churn | ~130 KB / 9 s | **~94 B / 9 s** |
| sockets | 8 EST / 40 CLOSED | **16 EST / 0 CLOSED** |

The `-404` storm stopped and has not returned since — including through everything in Act II.

---

## Act II — the same Mac stalled again, and my second diagnosis was wrong too

Hours later, with IPv6 still off and `-404` still at zero, Telegram began stalling again. The network measured
**clean**: TCP connect probes from a *different process* to the very same data centres completed in 60–300 ms
with no loss. Yet the client's sockets churned (20+ in `CLOSED` at any moment).

A nightly build of a DPI firewall (Little Snitch 6.5 nightly, build 7300 — the only build supporting macOS 27)
was logging, at the same time:

```
Socket closed during DPI without data: LSSocketFlow /Applications/Telegram.app/… → 149.154.175.58:443
  status=DPI connectName=<nil>
```

1735 of them in the 10 minutes of the stall, versus 0–7 in quiet windows. I ran an A-B-A test on the filter,
saw the churn vanish when it was off, and **concluded the filter was tearing the sockets down**. I sent that
to the vendor.

**That conclusion was wrong, and here is how it died.**

- The A-B-A phases were **2.5–3 minutes long** — on a phenomenon that is episodic (quiet for an hour, then a
  burst). When the filter went back on, the storm did *not* return inside the window. I noticed, and concluded
  anyway.
- Later, with the filter showing **“Disabled”**, the same log line fired at **~160/min while Telegram was
  perfectly healthy** (18 established, 0 closed, CPU 5–16 %) — essentially the rate seen during the stall
  (~174/min).

A signal that cannot distinguish health from failure is not evidence. And the “events dropped to zero when I
disabled the filter” observation was **circular**: a disabled filter stops *logging*.

**What those lines almost certainly are:** MTProtoKit races candidate connections — IPv4 and IPv6, ports
443/80/5222 — and closes the losers **without ever sending data**. That is exactly what the message describes.
The count is a proxy for how many candidates the client opens, nothing more.

The vendor ticket has been corrected. And the tool's `local-filter-interference` verdict, which originally
fired on this count alone, now requires the client to be **observably struggling** as well (see
[CHANGELOG](../CHANGELOG.md), v1.0.1) — the false positive is the reason that release exists.

## What is still unexplained

The late-night episode — the client churning connections while the network measures clean, plus system-wide
slowness (the browser stalls too) — has **no established cause**. The open hypotheses:

- **Our own fix.** With IPv6 disabled at the interface, the client keeps attempting its hardcoded IPv6 DC
  endpoints (they appear in the logs); each fails instantly, which could drive a hot retry loop.
- **A beta OS.** macOS 27 is a developer beta; its network stack is in the path of everything.
- **The filter, still.** A nightly network extension stays in the datapath even when “disabled” (it keeps
  logging), so the GUI toggle was never a clean A/B in the first place.
- **The ISP.** Residential CGNAT can silently drop long-lived NAT state while fresh connections keep working.

That last line matters, because it names the thing every one of my probes was blind to: **every probe was a
*fresh* connect, and fresh connects were always clean.** The signature that fits all the observations is
*long-lived connections dying while new ones succeed* — Telegram's MTProto sessions are long-lived, and so is
a browser's HTTP/2 connection. A long-lived-connection canary (several TCP connections held open with
different idle intervals, recording when each dies) is now running, alongside hours of continuous telemetry
joined to the user's own "it's lagging now" marks.

**The methodological lesson, stated plainly because it cost two retractions:** both wrong conclusions died the
same death — an intervention coincided with an episode ending on its own. Minutes cannot characterise an
episodic fault. Hours can, and only if the ground truth comes from the person using the machine.

## What Telegram’s client does, precisely (verified in source)

Worth stating carefully, because it is easy to overclaim:

- MTProtoKit **does** race IPv4 and IPv6 candidates
  ([`MTDiscoverConnectionSignals.m:222‑224`](https://github.com/TelegramMessenger/Telegram-iOS/blob/master/submodules/MtProtoKit/Sources/MTDiscoverConnectionSignals.m):
  `mergeSignals` + `take:1`), with a **5 s** timeout per attempt, and also tries ports 80 and 5222.
- But there is **no RFC 8305 semantics**: 5 s per attempt versus the RFC’s 250 ms connection-attempt delay,
  and a failing address family is **not durably demoted** — every reconnect re-races the dead endpoints.
- In Telegram Desktop, “prefer IPv6” is an **experimental, off-by-default** option
  ([`session_private.cpp:200`](https://github.com/telegramdesktop/tdesktop/blob/dev/Telegram/SourceFiles/mtproto/session_private.cpp);
  see PR [#28773](https://github.com/telegramdesktop/tdesktop/pull/28773),
  issues [#2198](https://github.com/telegramdesktop/tdesktop/issues/2198),
  [#29244](https://github.com/telegramdesktop/tdesktop/issues/29244)).
- Neither official repository contains the strings “happy eyeballs” or “8305”.

Suggestions to the client team: [`UPSTREAM.md`](UPSTREAM.md).

---

*Full field report (EN/RU), with the complete node registry and reproduction commands:*
<https://887609816.xyz/docs/telegram-ipv6/1cab563bbe1f6379bb36dca7a6da1f07/index.html>
