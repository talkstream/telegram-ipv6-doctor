#!/bin/bash
#
# telegram-ipv6-doctor — why is Telegram stuck on "Connecting" on your Mac?
#
#   Diagnoses (read-only by default) whether the cause is:
#     · your network   — IPv6 routing to Telegram's data centers is degraded
#     · your filter    — a local content filter / firewall (Little Snitch, LuLu, AV) tearing sockets down
#     · Telegram       — a client-side reconnect loop
#   …and only then, if and only if the evidence supports it, offers a reversible fix.
#
#   Repo:    https://github.com/talkstream/telegram-ipv6-doctor
#   License: MIT
#
# Design rules (do not break):
#   · Bash 3.2 (stock macOS). No associative arrays, no mapfile, no ${var^^}, no EPOCHREALTIME, no wait -n.
#   · Read-only unless the user explicitly runs `fix`. Every privileged command is printed before it runs.
#   · Never mutate on an unproven verdict. Never mutate without a working IPv4 path to Telegram.
#   · The reject-prefix list is a CONSTANT (below). It is never fetched at runtime — a hijacked remote
#     list would mean blackholing arbitrary networks with root. CI diffs it against Telegram's official
#     list weekly and opens a PR instead.
#   · Prompts read from /dev/tty (a `curl | bash` pipeline owns stdin).
#   · Everything lives in functions; the file ends with `main "$@"` + a sentinel, so a truncated
#     download executes nothing.
#
set -u

VERSION="1.0.0"

# ---------------------------------------------------------------------------
# Constants — Telegram infrastructure
# ---------------------------------------------------------------------------
#
# IPv6 prefixes: taken verbatim from Telegram's official published network list
#   https://core.telegram.org/resources/cidr.txt   (verified 2026-07-14, HTTP 200)
# Cross-checked against live BGP announcements by Telegram's ASNs
#   (AS62041, AS62014, AS59930, AS44907, AS211157 — RIPEstat, 2026-07-14).
# Only these prefixes may ever be rejected, and only those individually proven broken.
TG_V6_PREFIXES="2001:b28:f23d::/48 2001:b28:f23f::/48 2001:67c:4e8::/48 2001:b28:f23c::/48 2a0a:f280::/32"

# Data-center bootstrap endpoints. Identical in both official codebases:
#   tdesktop  Telegram/SourceFiles/mtproto/mtproto_dc_options.cpp:32-45
#   tdlib     td/telegram/net/ConnectionCreator.cpp:1267-1277
# (These are seeds; the live DC list arrives via help.getConfig and is not public.)
DC_V4="1:149.154.175.50 2:149.154.167.51 3:149.154.175.100 4:149.154.167.91 5:149.154.171.5"
DC_V6="1:2001:b28:f23d:f001::a 2:2001:67c:4e8:f002::a 3:2001:b28:f23d:f003::a 4:2001:67c:4e8:f004::a 5:2001:b28:f23f:f005::a"

# Independent IPv6 control targets — they tell "IPv6 is broken everywhere" apart from
# "IPv6 is broken specifically towards Telegram" (the case this tool exists for).
CONTROLS_V6="2606:4700:4700::1111 2001:4860:4860::8888 2001:67c:2e8:22::c100:68b"

MTPROTO_PORT=443

# Thresholds (milliseconds)
T_DEGRADED=1000     # a probe slower than this is "degraded"
T_HEALTHY=300       # a control faster than this is "healthy"
PROBE_TIMEOUT=2     # nc connect timeout, seconds
PROBE_SAMPLES=3     # samples per target; we take the median

# Absolute paths: this tool runs next to sudo, so it does not trust a caller's $PATH.
# The one exception is the offline test-suite, which substitutes fakes (TGD_TEST=1).
NC_BIN="/usr/bin/nc"
LOG_BIN="/usr/bin/log"
if [ -n "${TGD_TEST:-}" ]; then NC_BIN="nc"; LOG_BIN="log"; fi

# Paths
STATE_DIR="/Library/Application Support/telegram-ipv6-doctor"
STATE_FILE="$STATE_DIR/state.json"
TG_GROUP="${TGD_TG_GROUP:-$HOME/Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram}"
TDESKTOP_DIR="$HOME/Library/Application Support/Telegram Desktop"

# ---------------------------------------------------------------------------
# Globals populated by the diagnostic pipeline
# ---------------------------------------------------------------------------
VERDICT=""
VERDICT_DETAIL=""
BROKEN_PREFIXES=""      # Telegram /48s proven broken on this machine
V4_OK=0                 # count of DC IPv4 endpoints that answered
V6_OK=0
V6_FAIL=0
CONTROLS_HEALTHY=0
CONTROLS_TOTAL=0
HAS_V6=0
FILTER_ACTIVE=""        # name of a local content filter, if any
FILTER_EVENTS=0         # its socket-teardown events for Telegram, last 10 min
NAT64=0
PROXY_SET=0
VPN_ACTIVE=0
CLIENT_NAME=""
CLIENT_VERSION=""
CLIENT_PID=""
LOG_404=0
LOG_RESET=0
LOG_GETCONFIG=0
OUR_ROUTES=0
V6_SERVICE_STATE=""
NET_SERVICE=""

# CLI state
CMD="diagnose"
MODE=""
LANG_SET=""
JSON=0
ASSUME_YES=0
DRY_RUN=0
USE_COLOR=1

# ---------------------------------------------------------------------------
# i18n
# ---------------------------------------------------------------------------
detect_lang() {
  if [ -n "$LANG_SET" ]; then printf '%s' "$LANG_SET"; return; fi
  local loc
  loc=$(defaults read -g AppleLocale 2>/dev/null || printf '%s' "${LANG:-en_US}")
  case "$loc" in ru*|*_RU*) printf 'ru' ;; *) printf 'en' ;; esac
}

# t <key> — one place for every user-visible string.
t() {
  local k="$1"
  if [ "$(detect_lang)" = "ru" ]; then
    case "$k" in
      tagline)        printf 'Почему Telegram висит в «Connecting» — виновата сеть, локальный фильтр или сам клиент?' ;;
      phase_host)     printf 'Хост и клиент' ;;
      phase_net)      printf 'Форма сети' ;;
      phase_filter)   printf 'Локальные фильтры' ;;
      phase_probe)    printf 'Пробы дата-центров' ;;
      phase_logs)     printf 'Логи клиента' ;;
      probing)        printf 'проверяю' ;;
      verdict)        printf 'ВЕРДИКТ' ;;
      rec)            printf 'Что делать' ;;
      v_degraded)     printf 'IPv6-маршрутизация к Telegram сломана' ;;
      v_global)       printf 'IPv6 сломан целиком' ;;
      v_filter)       printf 'Мешает локальный сетевой фильтр' ;;
      v_blocked)      printf 'Похоже на блокировку/DPI провайдера' ;;
      v_proxy)        printf 'Клиент работает через прокси' ;;
      v_loop)         printf 'Петля на стороне клиента' ;;
      v_healthy)      printf 'Сеть в порядке' ;;
      v_mitigated)    printf 'Фикс уже применён' ;;
      v_nolonger)     printf 'Фикс больше не нужен' ;;
      v_v6off)        printf 'IPv6 отключён на интерфейсе' ;;
      v_only6)        printf 'Сеть только на IPv6 (NAT64)' ;;
      v_incon)        printf 'Однозначного вывода нет' ;;
      r_surgical)     printf 'Точечный фикс: отклонять только IPv6-адреса Telegram — весь остальной IPv6 продолжит работать.' ;;
      r_v6off)        printf 'IPv6 не работает нигде. Можно отключить его на интерфейсе целиком.' ;;
      r_filter)       printf 'Сеть чистая. Отключите сетевой фильтр на пару минут и проверьте — если отпустило, дело в нём, а не в провайдере. Сеть трогать не нужно.' ;;
      r_blocked)      printf 'Соединения устанавливаются и сразу рвутся — похоже на DPI-блокировку. Наш фикс не поможет: используйте MTProxy.' ;;
      r_proxy)        printf 'Клиент ходит через прокси. Сначала отключите его в настройках Telegram и повторите диагностику.' ;;
      r_loop)         printf 'Сеть в порядке, но клиент циклится. Помогает перезапуск; если нет — обратитесь в поддержку Telegram.' ;;
      r_healthy)      printf 'Проблем с сетью не видно. Если Telegram всё равно висит — соберите отчёт: report' ;;
      r_mitigated)    printf 'Фикс активен, Telegram ходит по IPv4. Откатить: revert' ;;
      r_nolonger)     printf 'IPv6 к Telegram снова работает — фикс можно снять: revert' ;;
      r_v6disabled)   printf 'IPv6 выключен на этом сетевом сервисе. Если Telegram работает — делать ничего не нужно. Вернуть IPv6: sudo networksetup -setv6automatic "<сервис>"' ;;
      r_only6)        printf 'В вашей сети нет IPv4. Отключать IPv6 нельзя — Telegram (и интернет) отвалятся полностью.' ;;
      r_incon)        printf 'Данные противоречивы, поэтому ничего менять не буду. Уберите VPN/прокси и повторите.' ;;
      gate_no_v4)     printf 'ОТКАЗ: нет рабочего IPv4-пути к Telegram. Фикс отрезал бы вас полностью.' ;;
      gate_verdict)   printf 'ОТКАЗ: фикс применяется только при доказанной деградации IPv6 к Telegram.' ;;
      gate_dirty)     printf 'ОТКАЗ: активны VPN/прокси — данные недостоверны.' ;;
      gate_filter)    printf 'ВНИМАНИЕ: активен локальный сетевой фильтр — он способен давать такую же картину. Сначала проверьте его.' ;;
      will_run)       printf 'Будут выполнены команды (с правами root):' ;;
      confirm)        printf 'Применить? [y/N] ' ;;
      aborted)        printf 'Отменено. Ничего не изменено.' ;;
      applied)        printf 'Применено.' ;;
      verifying)      printf 'Проверяю результат' ;;
      fix_failed)     printf 'Фикс не помог — откатываю обратно.' ;;
      fix_ok)         printf 'Готово. Перезапустите Telegram.' ;;
      reverted)       printf 'Откат выполнен, исходное состояние восстановлено.' ;;
      nothing_revert) printf 'Нечего откатывать: изменений этого инструмента не найдено.' ;;
      no_client)      printf 'клиент Telegram не найден' ;;
      dc)             printf 'ДЦ' ;;
      dc_note)        printf 'мс до дата-центров Telegram (медиана из 3 проб)' ;;
      timeout)        printf 'тайм-аут' ;;
      *)              printf '%s' "$k" ;;
    esac
  else
    case "$k" in
      tagline)        printf 'Why is Telegram stuck on “Connecting” — your network, a local filter, or the client?' ;;
      phase_host)     printf 'Host & client' ;;
      phase_net)      printf 'Network shape' ;;
      phase_filter)   printf 'Local filters' ;;
      phase_probe)    printf 'Data-center probes' ;;
      phase_logs)     printf 'Client logs' ;;
      probing)        printf 'probing' ;;
      verdict)        printf 'VERDICT' ;;
      rec)            printf 'What to do' ;;
      v_degraded)     printf 'IPv6 routing to Telegram is broken' ;;
      v_global)       printf 'IPv6 is broken everywhere' ;;
      v_filter)       printf 'A local network filter is interfering' ;;
      v_blocked)      printf 'Looks like ISP blocking / DPI' ;;
      v_proxy)        printf 'The client is running through a proxy' ;;
      v_loop)         printf 'Client-side reconnect loop' ;;
      v_healthy)      printf 'Network looks fine' ;;
      v_mitigated)    printf 'Fix already applied' ;;
      v_nolonger)     printf 'Fix is no longer needed' ;;
      v_v6off)        printf 'IPv6 is disabled on the interface' ;;
      v_only6)        printf 'IPv6-only network (NAT64)' ;;
      v_incon)        printf 'Inconclusive' ;;
      r_surgical)     printf 'Surgical fix: reject only the IPv6 addresses of Telegram — the rest of your IPv6 keeps working.' ;;
      r_v6off)        printf 'IPv6 is broken everywhere. Disabling it on the interface is an option.' ;;
      r_filter)       printf 'The network is clean. Turn your network filter off for two minutes and re-test — if the stalls stop, it is the filter, not your ISP. Do not touch the network.' ;;
      r_blocked)      printf 'Connections open and are immediately reset — this looks like DPI blocking. Our fix will not help: use MTProxy.' ;;
      r_proxy)        printf 'The client is going through a proxy. Turn it off in the Telegram settings and run the diagnosis again.' ;;
      r_loop)         printf 'The network is fine but the client is looping. A restart usually helps; if not, contact Telegram support.' ;;
      r_healthy)      printf 'No network problem visible. If Telegram still stalls, collect a report: report' ;;
      r_mitigated)    printf 'The fix is active and Telegram is on IPv4. Undo with: revert' ;;
      r_nolonger)     printf 'IPv6 to Telegram works again — you can remove the fix: revert' ;;
      r_v6disabled)   printf 'IPv6 is switched off on this network service. If Telegram works, there is nothing to do. To restore IPv6: sudo networksetup -setv6automatic "<service>"' ;;
      r_only6)        printf 'Your network has no IPv4. Disabling IPv6 would cut you off entirely.' ;;
      r_incon)        printf 'The evidence is contradictory, so nothing will be changed. Remove VPN/proxy and retry.' ;;
      gate_no_v4)     printf 'REFUSED: no working IPv4 path to Telegram. The fix would cut you off completely.' ;;
      gate_verdict)   printf 'REFUSED: the fix only applies when degraded IPv6-to-Telegram is proven.' ;;
      gate_dirty)     printf 'REFUSED: a VPN/proxy is active — the evidence cannot be trusted.' ;;
      gate_filter)    printf 'WARNING: a local network filter is active — it can produce exactly this picture. Check it first.' ;;
      will_run)       printf 'The following commands will run as root:' ;;
      confirm)        printf 'Apply? [y/N] ' ;;
      aborted)        printf 'Aborted. Nothing was changed.' ;;
      applied)        printf 'Applied.' ;;
      verifying)      printf 'Verifying' ;;
      fix_failed)     printf 'The fix did not help — rolling back.' ;;
      fix_ok)         printf 'Done. Restart Telegram.' ;;
      reverted)       printf 'Reverted. Original state restored.' ;;
      nothing_revert) printf 'Nothing to revert: no changes made by this tool were found.' ;;
      no_client)      printf 'no Telegram client found' ;;
      dc)             printf 'DC' ;;
      dc_note)        printf 'ms to the Telegram data centers (median of 3 probes)' ;;
      timeout)        printf 'timeout' ;;
      *)              printf '%s' "$k" ;;
    esac
  fi
}

# ---------------------------------------------------------------------------
# TUI
# ---------------------------------------------------------------------------
setup_colors() {
  if [ "$USE_COLOR" -eq 0 ] || [ ! -t 1 ] || [ -n "${NO_COLOR:-}" ]; then
    C_RESET=""; C_DIM=""; C_BOLD=""; C_BLUE=""; C_GREEN=""; C_AMBER=""; C_RED=""
    S_OK="[ok]"; S_BAD="[!!]"; S_WARN="[..]"; S_DOT="*"
  else
    C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
    C_BLUE=$'\033[38;5;39m'      # Telegram blue
    C_GREEN=$'\033[38;5;42m'; C_AMBER=$'\033[38;5;214m'; C_RED=$'\033[38;5;203m'
    S_OK="✓"; S_BAD="✗"; S_WARN="!"; S_DOT="·"
  fi
}

hr() { printf '%s%s%s\n' "$C_DIM" "────────────────────────────────────────────────────────────────" "$C_RESET"; }

banner() {
  printf '\n'
  printf '  %s%s telegram-ipv6-doctor%s %sv%s%s\n' "$C_BLUE" "$C_BOLD" "$C_RESET" "$C_DIM" "$VERSION" "$C_RESET"
  printf '  %s%s%s\n\n' "$C_DIM" "$(t tagline)" "$C_RESET"
}

phase() { printf '  %s%s%s %s\n' "$C_BLUE" "$S_DOT" "$C_RESET" "$1"; }
item()  { printf '     %s%s%s %s\n' "$2" "$3" "$C_RESET" "$1"; }
ok()    { item "$1" "$C_GREEN" "$S_OK"; }
bad()   { item "$1" "$C_RED" "$S_BAD"; }
warn()  { item "$1" "$C_AMBER" "$S_WARN"; }
note()  { printf '     %s%s%s\n' "$C_DIM" "$1" "$C_RESET"; }

# sparkline <ms> <ms> … — a tiny latency trace built from the real measurements
sparkline() {
  local vals="$1" chars=" ▁▂▃▄▅▆▇█" out="" v idx max=1
  for v in $vals; do [ "$v" -gt "$max" ] 2>/dev/null && max=$v; done
  for v in $vals; do
    if [ "$v" -lt 0 ] 2>/dev/null; then out="${out}█"; continue; fi
    idx=$(( v * 8 / max )); [ "$idx" -lt 1 ] && idx=1; [ "$idx" -gt 8 ] && idx=8
    out="${out}$(printf '%s' "$chars" | cut -c$((idx + 1)))"
  done
  printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# Probe layer — nc with a watchdog (macOS has no timeout(1)); millisecond timing via perl
# ---------------------------------------------------------------------------
now_ms() { /usr/bin/perl -MTime::HiRes=time -e 'printf "%.0f", time*1000' 2>/dev/null || printf '0'; }

# connect_ms <host> <port> <family:4|6> → milliseconds, or -1 on failure/timeout
connect_ms() {
  local host="$1" port="$2" fam="$3" flag="" start end pid rc
  [ "$fam" = "6" ] && flag="-6" || flag="-4"
  start=$(now_ms)
  # shellcheck disable=SC2086
  "$NC_BIN" $flag -G "$PROBE_TIMEOUT" -w "$PROBE_TIMEOUT" -z "$host" "$port" >/dev/null 2>&1 &
  pid=$!
  ( sleep $((PROBE_TIMEOUT + 1)); kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  local guard=$!
  wait "$pid" 2>/dev/null; rc=$?
  kill "$guard" 2>/dev/null
  end=$(now_ms)
  if [ "$rc" -eq 0 ]; then printf '%s' "$(( end - start ))"; else printf '%s' "-1"; fi
}

# median_ms <host> <port> <family> — median of PROBE_SAMPLES probes
median_ms() {
  local host="$1" port="$2" fam="$3" i r results=""
  i=0
  while [ "$i" -lt "$PROBE_SAMPLES" ]; do
    r=$(connect_ms "$host" "$port" "$fam")
    results="$results $r"
    i=$((i + 1))
  done
  printf '%s' "$results" | tr ' ' '\n' | grep -v '^$' | sort -n | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}'
}

# ---------------------------------------------------------------------------
# Phase 1 — host & client
# ---------------------------------------------------------------------------
scan_host() {
  phase "$(t phase_host)"
  local os arch
  os=$(sw_vers -productVersion 2>/dev/null)
  arch=$(uname -m)
  note "macOS $os · $arch"

  if [ -d "$TG_GROUP" ] && [ -d "/Applications/Telegram.app" ]; then
    CLIENT_NAME="Telegram for macOS (native)"
    CLIENT_VERSION=$(defaults read /Applications/Telegram.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null)
    CLIENT_PID=$(pgrep -f 'Telegram.app/Contents/MacOS/Telegram' 2>/dev/null | head -1)
  elif [ -d "$TDESKTOP_DIR" ]; then
    CLIENT_NAME="Telegram Desktop"
    CLIENT_PID=$(pgrep -f 'Telegram Desktop' 2>/dev/null | head -1)
  fi

  if [ -n "$CLIENT_NAME" ]; then
    ok "$CLIENT_NAME ${CLIENT_VERSION:-} ${CLIENT_PID:+(pid $CLIENT_PID)}"
  else
    warn "$(t no_client)"
  fi
}

# ---------------------------------------------------------------------------
# Phase 2 — network shape (dual-stack? proxy? VPN? NAT64? our own routes?)
# ---------------------------------------------------------------------------
scan_network() {
  phase "$(t phase_net)"

  # Which network service carries the default route (never assume "Wi-Fi")
  local dev
  dev=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
  if [ -n "$dev" ]; then
    NET_SERVICE=$(networksetup -listnetworkserviceorder 2>/dev/null \
      | awk -v d="$dev" '/^\(Hardware Port/ { line=$0 } $0 ~ "Device: " d "\\)" { sub(/^\(Hardware Port: /,"",line); sub(/,.*/,"",line); print line; exit }')
  fi
  [ -n "$NET_SERVICE" ] && note "$(t dc): ${dev} → \"$NET_SERVICE\""

  # dual-stack?
  if scutil --nwi 2>/dev/null | grep -q 'IPv6 network interface information' \
     && ! scutil --nwi 2>/dev/null | grep -q 'No IPv6 states found'; then
    HAS_V6=1; ok "IPv6: up"
  else
    HAS_V6=0; note "IPv6: down / disabled"
  fi

  # NAT64 / DNS64 → an IPv6-only network. Mutating anything here would cut the user off.
  if dig +short +time=2 +tries=1 ipv4only.arpa AAAA 2>/dev/null | grep -q ':' \
     || netstat -rnf inet6 2>/dev/null | grep -q '64:ff9b::'; then
    NAT64=1; warn "NAT64/DNS64 detected"
  fi

  # system proxy
  if scutil --proxy 2>/dev/null | grep -qE '(HTTPEnable|SOCKSEnable) *: *1'; then
    PROXY_SET=1; warn "system proxy configured"
  fi

  # VPN carrying traffic (a utun holding a default route), not just an idle interface
  if netstat -rnf inet 2>/dev/null | awk '/^default/{print $NF}' | grep -q '^utun'; then
    VPN_ACTIVE=1; warn "VPN default route active"
  fi

  # our own reject routes — must be recognised before we accuse the network
  OUR_ROUTES=$(netstat -rnf inet6 2>/dev/null | grep -c 'R.*lo0' || true)
  [ -f "$STATE_FILE" ] && note "state file present: $STATE_FILE"

  # IPv6 mode of the service, verbatim
  if [ -n "$NET_SERVICE" ]; then
    V6_SERVICE_STATE=$(networksetup -getinfo "$NET_SERVICE" 2>/dev/null | awk -F': ' '/^IPv6:/{print $2}')
  fi
}

# ---------------------------------------------------------------------------
# Phase 3 — local content filters (Little Snitch, LuLu, AV…)
#
# This runs BEFORE we are allowed to blame anybody's ISP. A local filter can produce a
# picture indistinguishable from broken IPv6 — we learned that the hard way.
# ---------------------------------------------------------------------------
scan_filters() {
  phase "$(t phase_filter)"
  local ext
  ext=$(systemextensionsctl list 2>/dev/null | grep 'activated enabled' | grep -oE '[a-z0-9.]+\.(networkextension|network-extension|systemextension)' | head -1)
  case "$ext" in
    *littlesnitch*) FILTER_ACTIVE="Little Snitch" ;;
    *lulu*)         FILTER_ACTIVE="LuLu" ;;
    "")             FILTER_ACTIVE="" ;;
    *)              FILTER_ACTIVE="$ext" ;;
  esac

  if [ -z "$FILTER_ACTIVE" ]; then
    ok "no third-party network filter"
    return
  fi

  warn "$FILTER_ACTIVE is filtering traffic"

  # Does it tear down Telegram's sockets? Count its own teardown events.
  # (Cheap and bounded; log(1) can be slow, so this is kept out of the probe budget.)
  FILTER_EVENTS=$("$LOG_BIN" show --last 10m --style compact \
      --predicate 'eventMessage CONTAINS "Socket closed" AND eventMessage CONTAINS "Telegram"' 2>/dev/null \
      | grep -c . || true)
  FILTER_EVENTS=${FILTER_EVENTS:-0}

  if [ "$FILTER_EVENTS" -gt 50 ]; then
    bad "$FILTER_EVENTS socket teardowns of Telegram in the last 10 min"
  elif [ "$FILTER_EVENTS" -gt 0 ]; then
    note "$FILTER_EVENTS socket teardowns of Telegram in the last 10 min"
  fi
}

# ---------------------------------------------------------------------------
# Phase 4 — probe the data centers over both families, plus controls
# ---------------------------------------------------------------------------
probe_dcs() {
  phase "$(t phase_probe)"
  local entry id ip ms line v4_trace="" v6_trace="" pfx

  printf '     %s%-4s %-9s %-9s%s\n' "$C_DIM" "$(t dc)" "IPv4" "IPv6" "$C_RESET"
  for entry in $DC_V4; do
    id=${entry%%:*}; ip=${entry#*:}
    ms=$(median_ms "$ip" "$MTPROTO_PORT" 4)
    if [ "$ms" -ge 0 ] 2>/dev/null; then V4_OK=$((V4_OK + 1)); v4_trace="$v4_trace $ms"; else v4_trace="$v4_trace -1"; fi
    local cell
    if [ "$ms" -ge 0 ] 2>/dev/null; then cell="$ms ms"; else cell="$(t timeout)"; fi
    line=$(printf '%-4s %-9s' "$id" "$cell")

    # matching IPv6 endpoint for the same DC
    local v6ip="" e
    for e in $DC_V6; do [ "${e%%:*}" = "$id" ] && v6ip=${e#*:}; done
    if [ "$HAS_V6" -eq 1 ] && [ -n "$v6ip" ]; then
      ms=$(median_ms "$v6ip" "$MTPROTO_PORT" 6)
      if [ "$ms" -ge 0 ] 2>/dev/null && [ "$ms" -lt "$T_DEGRADED" ]; then
        V6_OK=$((V6_OK + 1)); v6_trace="$v6_trace $ms"
        printf '     %s %s%s ms%s\n' "$line" "$C_GREEN" "$ms" "$C_RESET"
      else
        V6_FAIL=$((V6_FAIL + 1)); v6_trace="$v6_trace -1"
        # remember which /48 this broken endpoint belongs to — only these may ever be rejected
        pfx=$(prefix_of "$v6ip")
        [ -n "$pfx" ] && BROKEN_PREFIXES="$BROKEN_PREFIXES $pfx"
        printf '     %s %s%s%s\n' "$line" "$C_RED" "$(t timeout)" "$C_RESET"
      fi
    else
      printf '     %s %s—%s\n' "$line" "$C_DIM" "$C_RESET"
    fi
  done

  # IPv6 controls: is IPv6 broken everywhere, or only towards Telegram?
  if [ "$HAS_V6" -eq 1 ]; then
    local c
    for c in $CONTROLS_V6; do
      CONTROLS_TOTAL=$((CONTROLS_TOTAL + 1))
      ms=$(median_ms "$c" 443 6)
      [ "$ms" -ge 0 ] 2>/dev/null && [ "$ms" -lt "$T_HEALTHY" ] && CONTROLS_HEALTHY=$((CONTROLS_HEALTHY + 1))
    done
    note "IPv6 controls healthy: $CONTROLS_HEALTHY/$CONTROLS_TOTAL"
    note "$(t dc_note): IPv4 $(sparkline "$v4_trace")  IPv6 $(sparkline "$v6_trace")"
  fi

  BROKEN_PREFIXES=$(printf '%s' "$BROKEN_PREFIXES" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')
}

# prefix_of <v6addr> → the Telegram /48 (from the constant list) that contains it, or empty.
# Anything outside the constant list is rejected by design: we never blackhole a network
# that is not provably Telegram's.
prefix_of() {
  local addr="$1" pfx head
  for pfx in $TG_V6_PREFIXES; do
    head=$(printf '%s' "$pfx" | sed 's/::.*//')
    case "$addr" in
      "$head":*) printf '%s' "$pfx"; return ;;
    esac
  done
  printf ''
}

# ---------------------------------------------------------------------------
# Phase 5 — the client's own logs (counts only; never contents)
# ---------------------------------------------------------------------------
scan_logs() {
  [ -d "$TG_GROUP" ] || return 0
  phase "$(t phase_logs)"
  local newest
  # shellcheck disable=SC2012  # log filenames are tool-generated and safe; ls -t is the simplest "newest"
  newest=$(ls -t "$TG_GROUP"/stable/logs/*.txt 2>/dev/null | head -1)
  if [ -z "$newest" ] || [ ! -r "$newest" ]; then
    note "client logs unreadable (grant Full Disk Access to read them)"
    return 0
  fi
  local counts
  counts=$(LC_ALL=C strings "$newest" 2>/dev/null | awk '
    /protocol error -404/ {a++}
    /resetting session/   {b++}
    /getConfig/           {c++}
    END {printf "%d %d %d", a, b, c}')
  LOG_404=$(printf '%s' "$counts" | awk '{print $1}')
  LOG_RESET=$(printf '%s' "$counts" | awk '{print $2}')
  LOG_GETCONFIG=$(printf '%s' "$counts" | awk '{print $3}')
  if [ "${LOG_404:-0}" -gt 5 ]; then
    bad "reconnect storm: -404 ×$LOG_404, resets ×$LOG_RESET, getConfig ×$LOG_GETCONFIG"
  else
    ok "no reconnect storm (-404 ×${LOG_404:-0})"
  fi
}

# ---------------------------------------------------------------------------
# Verdict engine — numeric rules, evaluated in precedence order
# ---------------------------------------------------------------------------
decide() {
  # 0. Our own fix already in place?
  if [ "$OUR_ROUTES" -gt 0 ] || [ -f "$STATE_FILE" ]; then
    if [ "$HAS_V6" -eq 1 ] && [ "$CONTROLS_HEALTHY" -gt 0 ] && [ "$V6_FAIL" -eq 0 ]; then
      VERDICT="fix-active-but-no-longer-needed"; VERDICT_DETAIL="$(t v_nolonger)|$(t r_nolonger)"; return
    fi
    VERDICT="mitigated-by-doctor"; VERDICT_DETAIL="$(t v_mitigated)|$(t r_mitigated)"; return
  fi

  # 1. IPv6-only / NAT64 — nothing may be mutated here, ever.
  if [ "$NAT64" -eq 1 ] || { [ "$V4_OK" -eq 0 ] && [ "$HAS_V6" -eq 1 ] && [ "$V6_OK" -gt 0 ]; }; then
    VERDICT="ipv6-only-network"; VERDICT_DETAIL="$(t v_only6)|$(t r_only6)"; return
  fi

  # 2. Contaminated evidence → refuse to conclude.
  if [ "$VPN_ACTIVE" -eq 1 ] || [ "$PROXY_SET" -eq 1 ]; then
    VERDICT="inconclusive"; VERDICT_DETAIL="$(t v_incon)|$(t r_incon)"; return
  fi

  # 3. A local filter tearing sockets down beats any network story.
  if [ -n "$FILTER_ACTIVE" ] && [ "${FILTER_EVENTS:-0}" -gt 50 ]; then
    VERDICT="local-filter-interference"
    VERDICT_DETAIL="$(t v_filter) ($FILTER_ACTIVE)|$(t r_filter)"; return
  fi

  # 4. IPv6 disabled on the service.
  if [ "$HAS_V6" -eq 0 ]; then
    if [ "$V4_OK" -gt 0 ] && [ "${LOG_404:-0}" -gt 5 ]; then
      VERDICT="client-side-loop"; VERDICT_DETAIL="$(t v_loop)|$(t r_loop)"; return
    fi
    if [ "$V4_OK" -eq 0 ]; then
      VERDICT="blocked"; VERDICT_DETAIL="$(t v_blocked)|$(t r_blocked)"; return
    fi
    VERDICT="ipv6-disabled"; VERDICT_DETAIL="$(t v_v6off)|$(t r_v6disabled)"; return
  fi

  # 5. The case this tool was built for:
  #    IPv6 to ≥2 Telegram DCs broken, IPv4 to the same DCs fine, and IPv6 healthy elsewhere.
  if [ "$V6_FAIL" -ge 2 ] && [ "$V4_OK" -ge 2 ] \
     && [ "$CONTROLS_HEALTHY" -ge $(( (CONTROLS_TOTAL + 1) / 2 )) ] && [ -n "$BROKEN_PREFIXES" ]; then
    VERDICT="degraded-ipv6-to-telegram"; VERDICT_DETAIL="$(t v_degraded)|$(t r_surgical)"; return
  fi

  # 6. IPv6 broken towards everything.
  if [ "$V6_FAIL" -ge 2 ] && [ "$CONTROLS_HEALTHY" -eq 0 ] && [ "$V4_OK" -ge 2 ]; then
    VERDICT="ipv6-broken-globally"; VERDICT_DETAIL="$(t v_global)|$(t r_v6off)"; return
  fi

  # 7. Nothing reaches Telegram at all → censorship/DPI, not our business.
  if [ "$V4_OK" -eq 0 ]; then
    VERDICT="blocked"; VERDICT_DETAIL="$(t v_blocked)|$(t r_blocked)"; return
  fi

  # 8. Network fine, client looping.
  if [ "${LOG_404:-0}" -gt 5 ]; then
    VERDICT="client-side-loop"; VERDICT_DETAIL="$(t v_loop)|$(t r_loop)"; return
  fi

  VERDICT="healthy"; VERDICT_DETAIL="$(t v_healthy)|$(t r_healthy)"
}

show_verdict() {
  local title="${VERDICT_DETAIL%%|*}" rec="${VERDICT_DETAIL#*|}" col="$C_GREEN"
  case "$VERDICT" in
    degraded-ipv6-to-telegram|ipv6-broken-globally|local-filter-interference|blocked) col="$C_RED" ;;
    inconclusive|ipv6-only-network|client-side-loop|ipv6-disabled|proxy-in-app)       col="$C_AMBER" ;;
  esac
  printf '\n'; hr
  printf '  %s%s%s  %s%s%s\n' "$C_DIM" "$(t verdict)" "$C_RESET" "$col$C_BOLD" "$title" "$C_RESET"
  printf '  %s%s%s\n' "$C_DIM" "$rec" "$C_RESET"
  # A filter is running: never let the user walk away thinking their ISP is guilty.
  if [ -n "$FILTER_ACTIVE" ] && [ "$VERDICT" = "degraded-ipv6-to-telegram" ]; then
    printf '\n  %s%s%s\n' "$C_AMBER" "$(t gate_filter) ($FILTER_ACTIVE)" "$C_RESET"
  fi
  hr
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
run_diagnose() {
  # --json must emit nothing but JSON: machines parse it, humans do not read it.
  if [ "$JSON" -eq 1 ]; then
    scan_host >/dev/null 2>&1; scan_network >/dev/null 2>&1; scan_filters >/dev/null 2>&1
    probe_dcs >/dev/null 2>&1; scan_logs >/dev/null 2>&1
    decide
    emit_json
    return
  fi
  banner
  scan_host
  scan_network
  scan_filters
  probe_dcs
  scan_logs
  decide
  show_verdict
  local self="$0"
  # shellcheck disable=SC2016  # the $(curl …) below is literal text we show the user
  case "$self" in /bin/bash|bash|-bash|/bin/sh|sh) self='/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/talkstream/telegram-ipv6-doctor/v1.0.0/telegram-ipv6-doctor.sh)" _' ;; esac
  printf '  %sreport: %s report   ·   fix: %s fix%s\n\n' "$C_DIM" "$self" "$self" "$C_RESET"
}

emit_json() {
  printf '{\n'
  printf '  "tool": "telegram-ipv6-doctor", "version": "%s",\n' "$VERSION"
  printf '  "verdict": "%s",\n' "$VERDICT"
  printf '  "dc_v4_ok": %s, "dc_v6_ok": %s, "dc_v6_fail": %s,\n' "$V4_OK" "$V6_OK" "$V6_FAIL"
  printf '  "controls_healthy": %s, "controls_total": %s,\n' "$CONTROLS_HEALTHY" "$CONTROLS_TOTAL"
  printf '  "ipv6_up": %s, "nat64": %s, "proxy": %s, "vpn": %s,\n' "$HAS_V6" "$NAT64" "$PROXY_SET" "$VPN_ACTIVE"
  printf '  "filter": "%s", "filter_teardowns_10m": %s,\n' "$FILTER_ACTIVE" "${FILTER_EVENTS:-0}"
  printf '  "client_log": {"error_404": %s, "resets": %s, "getconfig": %s},\n' "${LOG_404:-0}" "${LOG_RESET:-0}" "${LOG_GETCONFIG:-0}"
  printf '  "broken_prefixes": "%s"\n' "$(printf '%s' "$BROKEN_PREFIXES" | sed 's/ *$//')"
  printf '}\n'
}

# ---------------------------------------------------------------------------
# fix — guarded, transactional, reversible
# ---------------------------------------------------------------------------
run_fix() {
  banner
  scan_host; scan_network; scan_filters; probe_dcs; scan_logs; decide
  show_verdict

  # --- gates. --yes skips the prompt, never the gates. ---
  case "$VERDICT" in
    degraded-ipv6-to-telegram) : ;;
    ipv6-broken-globally)
      [ "$MODE" = "ipv6-off" ] || { printf '  %s%s%s\n\n' "$C_AMBER" "$(t r_v6off)" "$C_RESET"; exit 3; } ;;
    *)
      printf '  %s%s%s\n\n' "$C_RED" "$(t gate_verdict)" "$C_RESET"; exit 3 ;;
  esac

  if [ "$V4_OK" -lt 1 ] || [ "$NAT64" -eq 1 ]; then
    printf '  %s%s%s\n\n' "$C_RED" "$(t gate_no_v4)" "$C_RESET"; exit 4
  fi
  if [ "$VPN_ACTIVE" -eq 1 ] || [ "$PROXY_SET" -eq 1 ]; then
    printf '  %s%s%s\n\n' "$C_RED" "$(t gate_dirty)" "$C_RESET"; exit 5
  fi
  if [ -n "$FILTER_ACTIVE" ] && [ "${FILTER_EVENTS:-0}" -gt 50 ]; then
    printf '  %s%s%s\n\n' "$C_RED" "$(t gate_filter) ($FILTER_ACTIVE)" "$C_RESET"; exit 6
  fi

  [ -z "$MODE" ] && MODE="surgical"

  # --- build the exact privileged commands, then show them before running anything ---
  local cmds="" pfx
  if [ "$MODE" = "surgical" ]; then
    [ -n "$BROKEN_PREFIXES" ] || { printf '  nothing to reject\n'; exit 3; }
    for pfx in $BROKEN_PREFIXES; do
      cmds="${cmds}/sbin/route -n add -inet6 $pfx ::1 -reject; "
    done
  else
    [ -n "$NET_SERVICE" ] || { printf '  cannot determine the network service\n' >&2; exit 1; }
    cmds="/usr/sbin/networksetup -setv6off \"$NET_SERVICE\"; "
  fi

  printf '  %s%s%s\n' "$C_BOLD" "$(t will_run)" "$C_RESET"
  printf '     %ssudo /bin/sh -c "%s"%s\n\n' "$C_DIM" "$cmds" "$C_RESET"
  [ "$DRY_RUN" -eq 1 ] && { printf '  (--dry-run: nothing executed)\n\n'; exit 0; }

  if [ "$ASSUME_YES" -ne 1 ]; then
    local ans=""
    printf '  %s' "$(t confirm)"
    read -r ans < /dev/tty || true
    case "$ans" in y|Y|yes|Yes) : ;; *) printf '  %s\n\n' "$(t aborted)"; exit 0 ;; esac
  fi

  save_state          # BEFORE mutating; revert depends on it
  # one privileged call → no half-applied state if sudo's timestamp expires mid-way
  if ! sudo /bin/sh -c "$cmds"; then
    printf '  %sfailed — rolling back%s\n' "$C_RED" "$C_RESET"
    run_revert_quiet
    exit 1
  fi
  printf '  %s%s%s\n' "$C_GREEN" "$(t applied)" "$C_RESET"

  # --- post-fix verification: prove it helped, or undo it ---
  printf '  %s%s…%s\n' "$C_DIM" "$(t verifying)" "$C_RESET"
  V4_OK=0; V6_FAIL=0; V6_OK=0
  probe_dcs >/dev/null 2>&1
  if [ "$V4_OK" -lt 1 ]; then
    printf '  %s%s%s\n' "$C_RED" "$(t fix_failed)" "$C_RESET"
    run_revert_quiet
    exit 1
  fi
  printf '  %s%s%s\n\n' "$C_GREEN" "$(t fix_ok)" "$C_RESET"
}

# save_state — verbatim, root-owned. $HOME is useless here: people run this under sudo.
save_state() {
  local svc info routes esc
  sudo /bin/mkdir -p "$STATE_DIR" 2>/dev/null || true
  info=""
  for svc in $(networksetup -listallnetworkservices 2>/dev/null | tail -n +2 | tr ' ' '~'); do
    svc=$(printf '%s' "$svc" | tr '~' ' ')
    esc=$(networksetup -getinfo "$svc" 2>/dev/null | tr '\n' ';' | sed 's/"/\\"/g')
    info="${info}    {\"service\": \"$svc\", \"getinfo\": \"$esc\"},\n"
  done
  info=$(printf '%b' "$info" | sed '$ s/,$//')
  routes=$(netstat -rnf inet6 2>/dev/null | grep 'lo0' | tr '\n' ';' | sed 's/"/\\"/g')
  sudo /usr/bin/tee "$STATE_FILE" >/dev/null <<EOF
{
  "tool": "telegram-ipv6-doctor",
  "version": "$VERSION",
  "mode": "$MODE",
  "rejected_prefixes": "$(printf '%s' "$BROKEN_PREFIXES" | sed 's/ *$//')",
  "network_service": "$NET_SERVICE",
  "ipv6_service_state_before": "$V6_SERVICE_STATE",
  "routes_before": "$routes",
  "services_before": [
$info
  ]
}
EOF
  sudo /bin/chmod 644 "$STATE_FILE" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# revert — idempotent and verified
# ---------------------------------------------------------------------------
run_revert() { banner; run_revert_quiet; }

run_revert_quiet() {
  local pfx mode svc before cmds="" left
  if [ ! -f "$STATE_FILE" ]; then
    # No state (lost? run under a different user?). Fall back to removing anything that
    # looks like ours, and say so plainly rather than pretending we restored a config.
    left=$(netstat -rnf inet6 2>/dev/null | awk '$0 ~ /lo0/ && $2 ~ /::1|lo0/ {print $1}' | grep -c . || true)
    if [ "${left:-0}" -eq 0 ]; then
      printf '  %s\n\n' "$(t nothing_revert)"; return 0
    fi
  fi

  mode=$(json_get "mode")
  svc=$(json_get "network_service")
  before=$(json_get "ipv6_service_state_before")

  if [ "$mode" = "ipv6-off" ] && [ -n "$svc" ]; then
    case "$before" in
      Automatic|"") cmds="/usr/sbin/networksetup -setv6automatic \"$svc\"; " ;;
      Off)          cmds="" ;;   # it was already off before us — leave it
      *)            cmds="/usr/sbin/networksetup -setv6automatic \"$svc\"; " ;;
    esac
  else
    for pfx in $(json_get "rejected_prefixes"); do
      cmds="${cmds}/sbin/route -n delete -inet6 $pfx ::1 2>/dev/null; "
    done
  fi

  if [ -n "$cmds" ]; then
    printf '  %s%s%s\n     %ssudo /bin/sh -c "%s"%s\n' "$C_BOLD" "$(t will_run)" "$C_RESET" "$C_DIM" "$cmds" "$C_RESET"
    [ "$DRY_RUN" -eq 1 ] && { printf '  (--dry-run)\n'; return 0; }
    sudo /bin/sh -c "$cmds" || true
  fi

  sudo /bin/rm -f "$STATE_FILE" 2>/dev/null || true

  # verify: no reject routes of ours may remain
  left=$(netstat -rnf inet6 2>/dev/null | grep -c 'lo0.*R' || true)
  if [ "${left:-0}" -gt 0 ]; then
    printf '  %sreject routes still present — remove manually: sudo route -n delete -inet6 <prefix> ::1%s\n\n' "$C_RED" "$C_RESET"
    return 1
  fi
  printf '  %s%s%s\n\n' "$C_GREEN" "$(t reverted)" "$C_RESET"
}

# json_get <key> — tiny reader for our own state file (no jq on a stock Mac)
json_get() {
  [ -f "$STATE_FILE" ] || { printf ''; return; }
  sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$STATE_FILE" | head -1
}

run_status() {
  banner
  if [ -f "$STATE_FILE" ]; then
    ok "fix active — mode: $(json_get mode)"
    note "prefixes: $(json_get rejected_prefixes)"
    note "state: $STATE_FILE"
    printf '  %s%s%s\n\n' "$C_DIM" "$(t r_mitigated)" "$C_RESET"
  else
    note "no fix applied by this tool"
    printf '\n'
  fi
}

# ---------------------------------------------------------------------------
# report — allowlist only. Nothing that identifies the machine or its owner.
# ---------------------------------------------------------------------------
run_report() {
  USE_COLOR=0; setup_colors
  scan_host >/dev/null 2>&1; scan_network >/dev/null 2>&1; scan_filters >/dev/null 2>&1
  probe_dcs >/dev/null 2>&1; scan_logs >/dev/null 2>&1; decide
  cat <<EOF
### telegram-ipv6-doctor report

| | |
|---|---|
| tool | v$VERSION |
| macOS | $(sw_vers -productVersion 2>/dev/null) ($(uname -m)) |
| client | ${CLIENT_NAME:-none} ${CLIENT_VERSION:-} |
| verdict | **$VERDICT** |

**Data centers** — IPv4 reachable: $V4_OK/5 · IPv6 reachable: $V6_OK · IPv6 failing: $V6_FAIL
**IPv6 controls** healthy: $CONTROLS_HEALTHY/$CONTROLS_TOTAL
**IPv6 on interface:** $HAS_V6 · **NAT64:** $NAT64 · **proxy:** $PROXY_SET · **VPN:** $VPN_ACTIVE
**Local network filter:** ${FILTER_ACTIVE:-none} · socket teardowns of Telegram (10 min): ${FILTER_EVENTS:-0}
**Client log counters:** protocol error -404 ×${LOG_404:-0} · resetting session ×${LOG_RESET:-0} · getConfig ×${LOG_GETCONFIG:-0}
**Telegram IPv6 prefixes proven broken:** ${BROKEN_PREFIXES:-none}

_No hostnames, addresses, SSIDs, account names or user paths are included in this report._
EOF
}

usage() {
  banner
  cat <<EOF
  Usage:
    telegram-ipv6-doctor.sh [diagnose|fix|revert|status|report] [options]

  Commands:
    diagnose   (default)  read-only diagnosis; changes nothing
    fix                   apply a reversible fix — only if the diagnosis proves it is warranted
    revert                undo everything this tool did, restoring the saved state
    status                is a fix currently active?
    report                privacy-safe Markdown report you can paste into a bug report

  Options:
    --mode surgical|ipv6-off   fix strategy (default: surgical — keeps the rest of your IPv6 working)
    --lang en|ru               force language          --json        machine-readable output
    --dry-run                  print privileged commands without running them
    --yes                      skip the confirmation prompt (does NOT skip the safety gates)
    --no-color                 plain output            --version     print version

  Run via curl — note the "_" placeholder, without it bash eats the first argument:
    /bin/bash -c "\$(curl -fsSL <url>)" _ fix --mode surgical
EOF
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
  # `bash -c "$(curl …)" fix` puts "fix" in \$0, not \$1 — catch that instead of silently
  # running the wrong command (a user who thinks they ran `revert` and did not is a real hazard).
  case "$0" in
    diagnose|fix|revert|status|report|--*)
      printf 'telegram-ipv6-doctor: you forgot the "_" placeholder.\n' >&2
      # shellcheck disable=SC2016  # the $(curl …) here is literal text shown to the user
      printf '  correct: /bin/bash -c "$(curl -fsSL <url>)" _ %s\n' "$0" >&2
      exit 64 ;;
  esac

  while [ $# -gt 0 ]; do
    case "$1" in
      diagnose|fix|revert|status|report) CMD="$1" ;;
      --mode)      MODE="${2:-}"; shift ;;
      --mode=*)    MODE="${1#*=}" ;;
      --lang)      LANG_SET="${2:-}"; shift ;;
      --lang=*)    LANG_SET="${1#*=}" ;;
      --json)      JSON=1; USE_COLOR=0 ;;
      --yes|-y)    ASSUME_YES=1 ;;
      --dry-run)   DRY_RUN=1 ;;
      --no-color)  USE_COLOR=0 ;;
      --version|-V) printf 'telegram-ipv6-doctor %s\n' "$VERSION"; exit 0 ;;
      --help|-h)   USE_COLOR=1; setup_colors; usage; exit 0 ;;
      *)           printf 'unknown argument: %s\n' "$1" >&2; exit 64 ;;
    esac
    shift
  done

  setup_colors

  case "$CMD" in
    diagnose) run_diagnose ;;
    fix)      run_fix ;;
    revert)   run_revert ;;
    status)   run_status ;;
    report)   run_report ;;
  esac
}

main "$@"

# ---- END OF SCRIPT ----
