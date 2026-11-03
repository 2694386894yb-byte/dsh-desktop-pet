#!/usr/bin/env python3
"""造一份假的 DSH 会话投影，用来在不打扰真实会话的情况下验证挂件。

用法：
    python3 scripts/make-fake-session.py <目录> <working 0|1> <回复文本> <步数> [会话id]

字段名与 `~/.dsh/storages/session_projcache/sessions/<id>.json` 保持一致。
"""
import json
import os
import sys
import time

def main() -> int:
    if len(sys.argv) < 5:
        print(__doc__)
        return 2
    directory, working, response, step = sys.argv[1], sys.argv[2] == "1", sys.argv[3], int(sys.argv[4])
    session_id = sys.argv[5] if len(sys.argv) > 5 else "session-00000000-1111-2222-3333-444444444444"
    os.makedirs(directory, exist_ok=True)
    now = int(time.time() * 1000)
    doc = {
        "version": 7,
        "record": {
            "identity": {"formatVersion": 4, "cwd": "/Users/example/projects"},
            "rows": {
                "title": {"ver": 1, "seq": 9, "val": "端到端验证用的假会话"},
                "turnOutline": {"ver": 2, "seq": 9, "val": {
                    "turns": [{"turn": 1, "seq": 4, "prompt": "模拟提示词", "response": response}],
                    "draft": "..." if working else "",
                }},
                "sessionStats": {"ver": 1, "seq": 9, "val": {
                    "turns": 1, "steps": step,
                    "openStep": ({"turn": 1, "step": step, "startTime": now} if working else None),
                }},
                "turnBoundary": {"ver": 2, "seq": 9, "val": {
                    "lastTurn": 1,
                    "lastStepBoundary": {"kind": "start" if working else "end", "seq": 9},
                }},
                "timeContext": {"ver": 2, "seq": 9, "val": {"lastMessageTime": now}},
            },
        },
    }
    path = os.path.join(directory, session_id + ".json")
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(doc, handle, ensure_ascii=False)
    print(path)
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
