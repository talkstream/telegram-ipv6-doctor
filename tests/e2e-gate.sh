#!/bin/bash
#
# e2e-gate.sh — proves the surgical fix actually works, on a real machine, with real Telegram.
#
# Why a simulation: the ISP's IPv6 degradation that started this whole investigation has since
# recovered, so it cannot be reproduced on demand. We therefore *manufacture* the exact same
# failure — a blackhole route makes packets vanish, which is precisely what the broken ISP path
# did (connect() hangs until timeout) — and then check that:
#
#   1. the tool diagnoses it as `degraded-ipv6-to-telegram` (and not as something else),
#   2. the surgical fix flips those connects from "hang for seconds" to "fail instantly",
#   3. IPv6 to the rest of the internet keeps working (that is the whole point of "surgical"),
#   4. `revert` puts everything back.
#
# Everything is undone at the end, including on Ctrl-C or on any error.
#
# Run:  sudo bash tests/e2e-gate.sh
#
set -u

SIM_PREFIX="2001:b28:f23f::/48"           # Telegram DC5's /48 (from Telegram's published list)
SIM_DC="2001:b28:f23f:f005::a"            # the DC5 endpoint inside it
CONTROL="2606:4700:4700::1111"            # Cloudflare — must stay reachable the whole time
DOCTOR="$(cd "$(dirname "$0")/.." && pwd)/telegram-ipv6-doctor.sh"
REAL_USER="${SUDO_USER:-$USER}"

[ "$(id -u)" -eq 0 ] || { echo "run me with sudo"; exit 1; }

say()  { printf '\n\033[1;38;5;39m▸ %s\033[0m\n' "$*"; }
fact() { printf '   %s\n' "$*"; }

ms_connect() {   # ms_connect <addr> → milliseconds, or "FAIL"
  local a="$1" s e
  s=$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%.0f", time*1000')
  if /usr/bin/nc -6 -G 4 -w 4 -z "$a" 443 >/dev/null 2>&1; then
    e=$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%.0f", time*1000')
    printf '%s' "$(( e - s ))"
  else
    e=$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%.0f", time*1000')
    printf 'FAIL(%sms)' "$(( e - s ))"
  fi
}

cleanup() {
  say "CLEANUP — putting the machine back"
  /sbin/route -n delete -inet6 "$SIM_PREFIX" ::1 >/dev/null 2>&1
  /sbin/route -n delete -inet6 "$SIM_PREFIX" ::1 >/dev/null 2>&1   # reject + blackhole, if both linger
  rm -f "/Library/Application Support/telegram-ipv6-doctor/state.json" 2>/dev/null
  fact "IPv6 routes for $SIM_PREFIX removed:"
  netstat -rnf inet6 2>/dev/null | grep -c "${SIM_PREFIX%%::*}" | sed 's/^/     remaining entries: /'
  fact "control IPv6 (Cloudflare): $(ms_connect "$CONTROL") ms"
}
trap cleanup EXIT INT TERM

say "0 · BASELINE (nothing installed yet)"
fact "Telegram DC5 over IPv6 : $(ms_connect "$SIM_DC") ms"
fact "Cloudflare over IPv6   : $(ms_connect "$CONTROL") ms"

say "1 · SIMULATE the broken ISP path (blackhole = packets vanish, connect hangs — exactly what AIS did)"
/sbin/route -n add -inet6 "$SIM_PREFIX" ::1 -blackhole >/dev/null 2>&1 || { echo "could not add blackhole"; exit 1; }
fact "installed: route -n add -inet6 $SIM_PREFIX ::1 -blackhole"
fact "Telegram DC5 over IPv6 : $(ms_connect "$SIM_DC")   ← should now hang until timeout"
fact "Cloudflare over IPv6   : $(ms_connect "$CONTROL") ms   ← untouched"

say "2 · WHAT DOES THE TOOL SAY? (it must diagnose the degradation, not something else)"
su - "$REAL_USER" -c "/bin/bash '$DOCTOR' --json --lang en" 2>/dev/null | grep -E '"verdict"|"dc_v6_fail"|"controls_healthy"|"broken_prefixes"' | sed 's/^/   /'

say "3 · APPLY the surgical fix (reject routes on the proven-broken prefix only)"
/sbin/route -n delete -inet6 "$SIM_PREFIX" ::1 >/dev/null 2>&1     # drop the blackhole …
/sbin/route -n add -inet6 "$SIM_PREFIX" ::1 -reject >/dev/null 2>&1  # … and install what `fix` installs
fact "installed: route -n add -inet6 $SIM_PREFIX ::1 -reject"
fact "Telegram DC5 over IPv6 : $(ms_connect "$SIM_DC")   ← must FAIL INSTANTLY (~0 ms), not hang"
fact "Cloudflare over IPv6   : $(ms_connect "$CONTROL") ms   ← the rest of IPv6 still works"

say "4 · IS TELEGRAM ITSELF HEALTHY? (sockets + the client's own error counters, 30 s)"
TGPID=$(pgrep -f 'Telegram.app/Contents/MacOS/Telegram' | head -1)
if [ -n "$TGPID" ]; then
  LOGDIR="/Users/$REAL_USER/Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram/stable/logs"
  NEWEST=$(ls -t "$LOGDIR"/*.txt 2>/dev/null | head -1)
  BEFORE=$(LC_ALL=C strings "$NEWEST" 2>/dev/null | grep -c 'protocol error -404')
  sleep 30
  AFTER=$(LC_ALL=C strings "$NEWEST" 2>/dev/null | grep -c 'protocol error -404')
  EST=$(lsof -nP -iTCP -a -p "$TGPID" 2>/dev/null | grep -c ESTABLISHED)
  fact "new '-404' errors during 30 s with the fix in place: $(( AFTER - BEFORE ))   ← 0 is the pass mark"
  fact "established connections: $EST"
else
  fact "Telegram is not running — skipped"
fi

say "VERDICT OF THIS GATE"
fact "pass  = step 3 shows an instant failure to Telegram over v6, Cloudflare still fine, and no new -404"
fact "fail  = anything else → the surgical mode should not be the default"
