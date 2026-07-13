#!/usr/bin/env bats
#
# Tests run entirely offline: every external command the tool touches is replaced by a fake
# in tests/fakes/, so a test run needs no network, no sudo and no Telegram install.
#
# What we assert:
#   · the verdict engine reaches the right conclusion for each network shape
#   · `diagnose` never mutates anything (no sudo/route/networksetup writes)
#   · the fix refuses to run when it would strand the user (IPv6-only / NAT64 / no IPv4)
#   · the fix refuses to run on a verdict it was not built for
#   · the report leaks nothing that identifies the machine or its owner
#   · the reject-prefix list is a compile-time constant, never fetched at runtime

setup() {
  DOCTOR="${BATS_TEST_DIRNAME}/../telegram-ipv6-doctor.sh"
  FAKES="${BATS_TEST_DIRNAME}/fakes"
  export PATH="$FAKES:$PATH"
  export TGD_TEST=1
  # every fake reads its behaviour from these
  export FAKE_V4_OK=1 FAKE_V6_DC=fail FAKE_V6_CONTROL=ok FAKE_HAS_V6=1
  export FAKE_NAT64=0 FAKE_PROXY=0 FAKE_VPN=0 FAKE_FILTER="" FAKE_FILTER_EVENTS=0
  export TGD_TG_GROUP="${BATS_TEST_DIRNAME}/fixtures/quiet"
  export SUDO_CALLED_FILE="${BATS_TEST_TMPDIR}/sudo_calls"
  export NET_CALLED_FILE="${BATS_TEST_TMPDIR}/net_calls"
  : > "$SUDO_CALLED_FILE"
  : > "$NET_CALLED_FILE"
}

run_doctor() { run /bin/bash "$DOCTOR" --no-color --lang en "$@"; }

# --- verdicts ---------------------------------------------------------------

@test "degraded IPv6 to Telegram: v6 to DCs fails, v4 fine, v6 controls healthy" {
  run_doctor --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"verdict": "degraded-ipv6-to-telegram"'* ]]
  [[ "$output" == *'2001:b28:f23d::/48'* ]]   # only proven-broken Telegram prefixes
}

@test "IPv6 broken everywhere: controls fail too -> not our surgical case" {
  export FAKE_V6_CONTROL=fail
  run_doctor --json
  [[ "$output" == *'"verdict": "ipv6-broken-globally"'* ]]
}

@test "healthy network: nothing to fix" {
  export FAKE_V6_DC=ok
  run_doctor --json
  [[ "$output" == *'"verdict": "healthy"'* ]]
}

@test "local filter tearing sockets down beats any network story" {
  export FAKE_FILTER="Little Snitch" FAKE_FILTER_EVENTS=1735
  run_doctor --json
  [[ "$output" == *'"verdict": "local-filter-interference"'* ]]
}

@test "IPv6-only / NAT64 network is recognised" {
  export FAKE_NAT64=1 FAKE_V4_OK=0 FAKE_V6_DC=ok
  run_doctor --json
  [[ "$output" == *'"verdict": "ipv6-only-network"'* ]]
}

@test "VPN/proxy contaminate the evidence -> inconclusive, never a diagnosis" {
  export FAKE_VPN=1
  run_doctor --json
  [[ "$output" == *'"verdict": "inconclusive"'* ]]
}

@test "nothing reaches Telegram at all -> blocked, not 'broken IPv6'" {
  export FAKE_V4_OK=0 FAKE_HAS_V6=0
  run_doctor --json
  [[ "$output" == *'"verdict": "blocked"'* ]]
}

@test "network clean but client looping -> client-side loop" {
  export FAKE_V6_DC=ok
  export TGD_TG_GROUP="${BATS_TEST_DIRNAME}/fixtures/storm"
  run_doctor --json
  [[ "$output" == *'"verdict": "client-side-loop"'* ]]
}

# --- safety -----------------------------------------------------------------

@test "diagnose mutates nothing (no sudo, no route add, no networksetup write)" {
  run_doctor
  [ "$status" -eq 0 ]
  [ ! -s "$SUDO_CALLED_FILE" ]
}

@test "fix refuses on an IPv6-only network even with --yes" {
  export FAKE_NAT64=1 FAKE_V4_OK=0 FAKE_V6_DC=ok
  run_doctor fix --yes
  [ "$status" -ne 0 ]
  [ ! -s "$SUDO_CALLED_FILE" ]
}

@test "fix refuses when no IPv4 path to Telegram exists" {
  export FAKE_V4_OK=0
  run_doctor fix --yes
  [ "$status" -ne 0 ]
  [ ! -s "$SUDO_CALLED_FILE" ]
}

@test "fix refuses on a healthy machine" {
  export FAKE_V6_DC=ok
  run_doctor fix --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"REFUSED"* ]]
  [ ! -s "$SUDO_CALLED_FILE" ]
}

@test "fix refuses while a local filter is tearing sockets down" {
  export FAKE_FILTER="Little Snitch" FAKE_FILTER_EVENTS=1735
  run_doctor fix --yes
  [ "$status" -ne 0 ]
  [ ! -s "$SUDO_CALLED_FILE" ]
}

@test "--dry-run prints the privileged command and runs nothing" {
  run_doctor fix --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"route -n add -inet6"* ]]
  [ ! -s "$SUDO_CALLED_FILE" ]
}

@test "missing _ placeholder is caught instead of silently running the wrong command" {
  run /bin/bash -c "$(cat "$DOCTOR")" revert
  [ "$status" -eq 64 ]
  [[ "$output" == *"placeholder"* ]]
}

# --- privacy ----------------------------------------------------------------

@test "report contains no hostname, username, local IP or SSID" {
  run_doctor report
  [ "$status" -eq 0 ]
  [[ "$output" != *"$USER"* ]]
  [[ "$output" != *"$(hostname)"* ]]
  [[ "$output" != *"192.168."* ]]
  [[ "$output" != *"/Users/"* ]]
}

# --- supply chain -----------------------------------------------------------

@test "the reject-prefix list is a constant: the tool fetches nothing at runtime" {
  # Behavioural, not grep-based: fake curl/wget record any invocation and fail.
  run_doctor
  run_doctor fix --dry-run
  run_doctor report
  [ ! -s "$NET_CALLED_FILE" ]
  grep -q 'TG_V6_PREFIXES="2001:' "$DOCTOR"
}

@test "script ends with the truncation sentinel" {
  run tail -1 "$DOCTOR"
  [[ "$output" == *"END OF SCRIPT"* ]]
}
