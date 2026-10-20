"""Хук Claude Code на AskUserQuestion: кладёт открытый вопрос роли в .team/asks/<агент>/<tool_use_id>.json.

Claude Code рисует форму вопроса в альтернативном экране, а в транскрипт вызов попадает только вместе с ответом,
поэтому пока роль ждёт, вопрос берётся из этой записи. Запуск: `python -I -S askhook.py <каталог записей>`,
вход хука — JSON на stdin.
- PreToolUse пишет запись и убирает записи прежних вопросов агента: прежний вызов закрыт, раз модель задаёт новый.
- PostToolUse удаляет запись своего вызова.

Скрипт самостоятельный, только стандартная библиотека: он запускается в каталоге роли с флагами -I -S, и ни
пакет, ни site-packages ему не нужны. Хук ничего не печатает и всегда выходит с кодом 0: вывод или иной код
Claude Code принял бы за решение о вызове, а хук только наблюдает. Любая ошибка — молча пропустить.
"""
import json
import os
import re
import sys
import time

TOOL = "AskUserQuestion"
SAFE_ID = re.compile(r"[A-Za-z0-9_-]{1,128}")


def _remove(path: str) -> None:
    try:
        os.unlink(path)
    except OSError:
        pass


def handle(store: str, data) -> None:
    if not isinstance(data, dict) or data.get("tool_name") != TOOL:
        return
    tid = data.get("tool_use_id")
    if not isinstance(tid, str) or not SAFE_ID.fullmatch(tid):
        return
    own = os.path.join(store, tid + ".json")
    event = data.get("hook_event_name")
    if event == "PostToolUse":
        _remove(own)
        return
    if event != "PreToolUse" or not isinstance(data.get("tool_input"), dict):
        return
    os.makedirs(store, exist_ok=True)
    for name in os.listdir(store):
        if name.endswith(".json") and name != tid + ".json":
            _remove(os.path.join(store, name))
    transcript = data.get("transcript_path") if isinstance(data.get("transcript_path"), str) else ""
    try:
        offset = os.path.getsize(transcript) if transcript else 0      # tool_result ищется после этого места
    except OSError:
        offset = 0
    rec = {"id": tid, "ts": int(time.time()), "session_id": data.get("session_id"), "transcript": transcript,
           "offset": offset, "tool_input": data["tool_input"]}
    tmp = os.path.join(store, f".{tid}.{os.getpid()}.tmp")
    try:
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(rec, fh, ensure_ascii=False)
        os.replace(tmp, own)                     # читатель видит запись целиком или не видит вовсе
    finally:
        _remove(tmp)


def main() -> None:
    try:
        if len(sys.argv) == 2:
            handle(sys.argv[1], json.loads(sys.stdin.read()))
    except BaseException:                         # noqa: BLE001 — хук не должен мешать вызову ни при какой ошибке
        pass
    os._exit(0)


if __name__ == "__main__":
    main()
