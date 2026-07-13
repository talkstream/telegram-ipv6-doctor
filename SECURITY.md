# Security Policy

## Reporting

Please report vulnerabilities privately: open a
[security advisory](https://github.com/talkstream/telegram-ipv6-doctor/security/advisories/new)
or write to [t.me/nafigator](https://t.me/nafigator). Do not open a public issue.

## Threat model

This tool asks for `sudo` and modifies network routing. Its security properties are documented in
[`docs/SAFETY.md`](docs/SAFETY.md); the essentials:

- **Read-only by default.** `diagnose` never mutates. A test with fake `sudo`/`route`/`networksetup`
  binaries fails the suite if it ever tries.
- **No runtime fetches.** Telegram's IPv6 prefixes are a compile-time constant. A remote list would be a
  channel for steering root-level route changes; a test with a fake `curl` enforces this.
- **Pin your install.** The one-liner in the README points at an immutable tag, and the SHA-256 of exactly
  that blob is published in the release notes. The `main` branch is a moving target: treat it as
  trust-on-first-use.
- **Truncation-safe.** All logic is in functions; the file ends with `main "$@"` and a sentinel comment, so
  a partially downloaded script executes nothing.
- **Reversible.** State is saved before any change; `revert` restores it and verifies the result. Reject
  routes also disappear on reboot. There is no daemon and no login item.
