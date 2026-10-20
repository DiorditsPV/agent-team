#!/bin/bash
# Стенд пустот и прыжков ленты чата: scripts/gap-bench.sh. Итог по сценариям — в stdout.
#
# Порядок запуска:
#   1. Один прогон за раз: пока идёт другой стенд или снимки (того же приложения), не запускать. Окно приложения открывается на
#      столе, но ввод не нужен и не отправляется: все действия делает само приложение по флагу AGENT_TEAM_GAP_BENCH.
#   2. Собрать Dev-сборку: scripts/bundle.sh --dev. После правок кода пересобирать вручную: скрипт берёт build/AgentTeamDev.app как есть.
#   3. scripts/gap-bench.sh — около двух минут; окно закроется само, приложение останавливается по своему pid.
#      GAP_OUT=<файл> — куда писать итог (рядом лягут <файл>.trace — положение опорной строки по кадрам — и кадры худших просветов <файл>.gap<цикл>.png); в консоль итог выходит всегда.
#      GAP_BREAK=1 — после обычных сценариев четыре намеренно сломанных; все четыре обязаны быть «ПЛОХО».
#   4. Строка «ок» — пустот и прыжков нет; «ПЛОХО» — просвет больше допуска, сдвиг опорной, обратный рывок сверх усадки ленты,
#      кадры «черновик и блок вместе» или повтор id. Устройство замеров — комментарий к runGapBench в ChatPanel+GapBench.swift.
#
set -eu
# Переменные запускающей сессии (роль, проект, tmux, Claude) в демо не нужны: иначе team работает с чужим проектом.
for v in $(env | sed -n 's/^\(TEAM_[A-Za-z0-9_]*\|CLAUDE[A-Za-z0-9_]*\|TMUX[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$v"; done
APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$APP_DIR/.." && pwd)"
APP_BUNDLE="$APP_DIR/build/AgentTeamDev.app"
BIN="$APP_BUNDLE/Contents/MacOS/AgentTeamDev"
SHOT_BIN=""
DATA="$APP_DIR/scripts/readme-shots-data.py"
[ -x "$BIN" ] || "$APP_DIR/scripts/bundle.sh" --dev >/dev/null

WORK="$(mktemp -d /tmp/gap-bench.XXXXXX)"
SOCK="gapb$$"
OUT="$WORK/shots"
cleanup() {
    # Приложение кадра останавливается по своему pid (readme-shots-launch.sh пишет его в SHOT_PIDFILE), не по имени:
    # у других ролей в это время идут свои запуски того же приложения.
    if [ -s "$WORK/app.pid" ]; then kill "$(cat "$WORK/app.pid")" 2>/dev/null || true; fi
    tmux -L "$SOCK" kill-server 2>/dev/null || true
    if [ -n "${SHOT_BUNDLE_ID:-}" ]; then
        rm -rf "$HOME/Library/Saved Application State/${SHOT_BUNDLE_ID:?}.savedState"
        rm -f "$HOME/Library/Preferences/${SHOT_BUNDLE_ID:?}.plist"
    fi
    rm -rf "${WORK:?}"
}
trap cleanup EXIT INT TERM

SHOP="$WORK/shop"
HOME_DIR="$WORK/home"
SOCKS="$WORK/socks"
SCREENS="$WORK/screens"
mkdir -p "$OUT" "$SHOP/agents/roles" "$SHOP/agents/shared" "$WORK/bin" "$WORK/sessions" "$HOME_DIR" "$SOCKS" "$SCREENS" "$OUT"

# --- демо-репозиторий ---
cat > "$SHOP/agents/team.yaml" <<YAML
project: shop
repo: $SHOP
layout: panes
worktree_root: ../shop-wt
test_command: ""
manager: manager
roles:
  - role: manager
    start: manual
  - role: developer
    start: on_demand
  - role: reviewer
    start: on_demand
  - role: tester
    start: on_demand
YAML
cat > "$SHOP/agents/roles/manager.md" <<'MD'
---
role: manager
title: Manager
kind: manager
status: active
description: "Runs the queue, hands out tasks, accepts work by evidence and merges only on the owner's word"
model: opus
worktree: null
zone: []
includes: []
---

You are the manager of the shop project and the lead session of the team. The owner talks to you only. The other roles work in neighbouring tmux panes and get their tasks from you. You do not edit code or documents.
MD
cat > "$SHOP/agents/roles/developer.md" <<'MD'
---
role: developer
extends: developer
title: Developer
description: "Implements shop features in its own worktree and reports to the manager"
worktree: {dir: developer, branch: developer}
zone: [web/]
---

Your zone is `web/`. Run the tests with `pytest`. Keep commits small and name the cause of the change in the message.
MD
cat > "$SHOP/agents/roles/reviewer.md" <<'MD'
---
role: reviewer
extends: reviewer
title: Reviewer
worktree: null
---

Pay special attention to money arithmetic: rounding, tax and stacked discounts.
MD
cat > "$SHOP/agents/roles/tester.md" <<'MD'
---
role: tester
title: QA
kind: executor
status: active
description: "Runs the regression suites and reports failures by cart type"
model: sonnet
worktree: {dir: tester, branch: tester}
zone: [tests/]
includes: []
---

You are the tester. Run the suites the manager names, group failures by cart type and report the numbers, not the impression.
MD
G="git -C $SHOP -c user.name=demo -c user.email=demo@example.com"
git -C "$SHOP" init -q -b main
echo "# shop" > "$SHOP/README.md"
git -C "$SHOP" add -A
$G commit -q -m "Initial commit"

# --- подставной claude: пишет запись сессии, транскрипт и рисует экран из файлов ---
cat > "$WORK/bin/claude-demo" <<SH
#!/bin/bash
AG="\$TEAM_AGENT"; N="\${AG//#/-}"
exec 2>/dev/null
for i in \$(seq 60); do
  INFO=\$(python3 -I -c "import json,sys;d=json.load(open('$SHOP/.team/state.json')).get('\$AG');print(d['session_id'],d['cwd']) if d else None" 2>/dev/null) && [ -n "\$INFO" ] && [ "\$INFO" != None ] && break
  sleep 0.25
done
SID=\${INFO%% *}
touch "$SOCKS/\$N.sock"
printf '{"sessionId":"%s","messagingSocketPath":"$SOCKS/%s.sock"}' "\$SID" "\$N" > "$WORK/sessions/\$\$.json"
LAST=""
while true; do
  CUR=\$(cksum "$SCREENS/\$N.top" "$SCREENS/\$N.bottom" 2>/dev/null)
  ROWS=\$(tput lines); COLS=\$(tput cols)
  if [ "\$CUR \$ROWS \$COLS" != "\$LAST" ]; then
    LAST="\$CUR \$ROWS \$COLS"
    T=\$(wc -l < "$SCREENS/\$N.top"); B=\$(wc -l < "$SCREENS/\$N.bottom")
    printf '\033[H\033[2J'
    cut -c1-\$COLS "$SCREENS/\$N.top"
    PAD=\$((ROWS - T - B)); [ \$PAD -gt 0 ] && yes '' | head -n \$PAD
    cut -c1-\$COLS "$SCREENS/\$N.bottom"
  fi
  sleep 0.4
done
SH
chmod +x "$WORK/bin/claude-demo"

# --- обёртка team: окружение демо внутри, чтобы приложение вызывало её без чужих переменных ---
cat > "$WORK/bin/team" <<SH
#!/bin/sh
export TEAM_TMUX_SOCKET="$SOCK" TEAM_SESSIONS_DIR="$WORK/sessions" TEAM_CLAUDE_BIN="$WORK/bin/claude-demo"
exec uv run --project "$ROOT" team "\$@"
SH
chmod +x "$WORK/bin/team"
TEAM="$WORK/bin/team"

# --- tmux: свой сервер, окна достаточно широкие для панелей ---
tmux -L "$SOCK" -f /dev/null new-session -d -s keeper -x 220 -y 56 "sleep 86400"
tmux -L "$SOCK" set -g default-size 220x56 >/dev/null

# --- копия проверочной сборки со своим bundle id ---
# Два запуска с одним bundle id (снимки других разработчиков идут из того же AgentTeamDev) мешают друг другу: окно второго
# не открывается. У копии свои настройки и свой идентификатор.
SHOT_APP="$WORK/Shots.app"
cp -R "$APP_BUNDLE" "$SHOT_APP"
plutil -replace CFBundleIdentifier -string "dev.agent-team.app.shots.$$" "$SHOT_APP/Contents/Info.plist"
codesign -s - --force --deep "$SHOT_APP" >/dev/null 2>&1 || true
SHOT_BIN="$SHOT_APP/Contents/MacOS/AgentTeamDev"
export SHOT_BUNDLE_ID="dev.agent-team.app.shots.$$"

# --- данные: транскрипты и экраны по фазе ---
state_get() { python3 -I -c "import json;d=json.load(open('$SHOP/.team/state.json'));print(d['$1']['$2'])"; }
AGENTS="manager#1 developer#1 developer#2 reviewer#1 tester#1"
fill() {  # фаза
    for a in $AGENTS; do
        python3 -I "$DATA" transcript "$a" "$(state_get "$a" session_id)" "$(state_get "$a" cwd)" "$HOME_DIR" "$1" "$SOCKS"
        python3 -I "$DATA" screen "$a" "$SCREENS" "$1"
    done
}

cd "$SHOP"
"$TEAM" up >/dev/null
for r in developer developer reviewer tester; do "$TEAM" spawn "$r" >/dev/null; done
sleep 3
"$TEAM" task developer#1 "Checkout form validation" --id SHOP-14 >/dev/null
"$TEAM" task developer#2 "Order receipt e-mails" --id SHOP-15 >/dev/null
"$TEAM" task reviewer#1 "Review of promo-code change" --id SHOP-16 >/dev/null
"$TEAM" task tester#1 "Cart regression suite" --id SHOP-17 >/dev/null

# --- кадры ---
# Приложение запускается из пустого каталога, не из репозитория демо.
mkdir -p "$WORK/run" && cd "$WORK/run"
shot() {  # имя фаза [аргументы приложения…]
    name="$1"; phase="$2"; shift 2
    fill "$phase"
    sleep 1
    raw="$WORK/$name.raw.png"
    env AGENT_TEAM_WINDOW_SIZE=1600x1000 ${LIVE_INPUT:+AGENT_TEAM_LIVE_INPUT=1} SHOT_PIDFILE="$WORK/app.pid" \
        "$APP_DIR/scripts/readme-shots-launch.sh" "$SHOT_BIN" "$raw" --project shop --socket "$SOCK" --tool "$TEAM" --repo "$SHOP" "$@"
    [ -f "$raw" ] || { echo "нет кадра $name" >&2; return 1; }
    swift "$APP_DIR/scripts/png-shrink.swift" "$raw" "$OUT/app-$name.png" 1600
    echo "app-$name.png"
}

export AGENT_TEAM_CLAUDE_HOME="$HOME_DIR" AGENT_TEAM_FRESH_DEFAULTS=1 TEAM_SESSIONS_DIR="$WORK/sessions"
export AGENT_TEAM_GAP_BENCH="${GAP_OUT:-$WORK/gap.txt}"
rm -f "$AGENT_TEAM_GAP_BENCH"
[ -z "${GAP_BREAK:-}" ] || export AGENT_TEAM_GAP_BENCH_BREAK=1
fill busy
sleep 1
# Приложение живёт, пока стенд не запишет итог (около минуты: 12 с до старта и ~20 циклов по 3–4 с); останавливается по своему pid.
rm -rf "$HOME/Library/Saved Application State/${SHOT_BUNDLE_ID:?}.savedState"
env AGENT_TEAM_WINDOW_SIZE=1600x1000 "$SHOT_BIN" -NSQuitAlwaysKeepsWindows 0 --project shop --socket "$SOCK" --tool "$TEAM" --repo "$SHOP" \
    --columns 2 --agents-width 620 >/dev/null 2>&1 &
echo $! > "$WORK/app.pid"
for _ in $(seq 240); do
    [ -s "$AGENT_TEAM_GAP_BENCH" ] && break
    sleep 1
done
[ -s "$AGENT_TEAM_GAP_BENCH" ] || { echo "стенд не записал итог за 240 с" >&2; exit 1; }
cat "$AGENT_TEAM_GAP_BENCH"
