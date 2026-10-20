#!/bin/bash
# Один запуск приложения для снимка (вызывается из readme-shots.sh): readme-shots-launch.sh <исполняемый файл> <файл кадра> <аргументы…>
# Отдельным файлом: запуск тем же кодом внутри основного скрипта окна не открывал.
B=$1; raw=$2; shift 2
# Окна не восстанавливаются из сохранённого состояния прошлого запуска: на нём запуск иногда оставался без окна.
[ -z "${SHOT_BUNDLE_ID:-}" ] || rm -rf "$HOME/Library/Saved Application State/${SHOT_BUNDLE_ID:?}.savedState"
"$B" -NSQuitAlwaysKeepsWindows 0 "$@" --snapshot "$raw" --snapshot-delay 9 --quit >/dev/null 2>&1 &
p=$!
# pid запуска — вызывающему (SHOT_PIDFILE): прерванный сценарий останавливает своё приложение по pid, а не по имени.
[ -z "${SHOT_PIDFILE:-}" ] || echo "$p" > "$SHOT_PIDFILE"
for _ in $(seq 60); do
    sleep 1
    [ -f "$raw" ] && break
done
# Приложение выходит само (--quit). Убитый раньше срока запуск ломает следующий: окно у него не открывается.
for _ in $(seq 30); do
    kill -0 "$p" 2>/dev/null || break
    sleep 1
done
kill -9 "$p" 2>/dev/null
sleep 2
exit 0
