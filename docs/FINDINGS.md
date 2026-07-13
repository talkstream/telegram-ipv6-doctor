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

## Act II — the same Mac stalled again, and IPv6 was innocent this time (same night)

Hours later, with IPv6 still off and `-404` still at zero, Telegram began stalling again.

The network was **clean**: TCP connect probes from a *different process* to the very same data centres
completed in 60–300 ms with no loss, sampled every 6 s for minutes. Yet the client’s sockets were churning
(20+ in `CLOSED` at any moment).

The culprit was local. A **nightly build of Little Snitch** (6.5 nightly, build 7300 — the only build that
supports macOS 27) was tearing Telegram’s sockets down inside its own deep-packet-inspection stage:

```
Socket closed during DPI without data: LSSocketFlow /Applications/Telegram.app/…
  → 149.154.175.58:443 status=DPI connectName=<nil>
```

Event counts, same machine, same day:

| window | “Socket closed during DPI without data” (Telegram) | state |
|---|---|---|
| 21:45–21:55 | 7 | healthy |
| 22:30–22:40 | **0** | healthy |
| 23:15–23:25 | 2 | healthy |
| **23:37–23:47** | **1735** | **stalling** |
| 23:52–23:55 | 1 | **filter disabled** |

**A‑B‑A test** (filter off → on), sampling the client’s sockets every 5 s:

| phase | avg CLOSED sockets |
|---|---|
| filter ON (during stall) | **20.7** |
| filter OFF | **0.2** |
| filter ON again | 0.2 — the storms are episodic and did not recur inside the 2.5‑minute window; the DPI-close events, however, returned at once (84 in 3 min) |

There were **zero** deny/block events: Telegram’s rules were `allow any outgoing`. The sockets were not
being blocked — they were dying at the inspection stage.

This has been [reported to the vendor](https://www.obdev.at/products/littlesnitch/) with the full data.

---

## What this means (and what it does not)

- **Both causes were real, and they are distinguishable.** During the Act I storm, the filter’s
  teardown events were at background level (31 / 10 min); during the Act II storm, the client’s `-404`
  counter was **zero**. Different signatures, different culprits.
- **Honest caveat.** The buggy filter build was installed during Act I too, and the Act I intervention was
  compound (IPv6 off *and* a restart). The IPv6 conclusion rests on the log evidence (v6 connect timeouts,
  `-404` semantics) and on `-404` staying at zero for hours afterwards — but a single, perfectly isolated
  experiment it was not. We say so rather than pretend otherwise.
- **This is why the tool discriminates.** A tool that only knows how to blame IPv6 would have “fixed” a
  machine whose problem was a firewall — and told its owner to go argue with their ISP. `local-filter-interference`
  is a first-class verdict, evaluated *before* any network verdict, precisely because of this night.

---

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
