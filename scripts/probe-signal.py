#!/usr/bin/env python3
"""信号探针：盯着 DSH 的会话投影缓存，看「一轮跑完」在字段上长什么样。

DSH 每一步事件都会把会话状态投影写到
`~/.dsh/storages/session_projcache/sessions/<id>.json`（纯 JSON，无需权限、无需解压）。
这个脚本每 2 秒扫一遍，只记录**发生变化**的会话，用来确认：
  - 「正在干活」对应哪个字段（openStep？turnBoundary？）
  - 「出了新结果」对应哪个字段（turnOutline.turns[].response 从空变非空？turns 变多？）
日志：/tmp/dsh-signal-sample.log
"""
import json, os, time, glob

ROOT = os.path.expanduser("~/.dsh/storages/session_projcache/sessions")
LOG = "/tmp/dsh-signal-sample.log"
seen = {}

def snapshot(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            d = json.load(f)
    except Exception as e:
        return {"error": str(e)}
    r = d.get("record", {})
    rows = r.get("rows", {})
    def val(k, default=None):
        v = rows.get(k)
        return v.get("val", default) if isinstance(v, dict) else default
    to = val("turnOutline") or {}
    turns = to.get("turns") or []
    stats = val("sessionStats") or {}
    tb = val("turnBoundary") or {}
    return {
        "title": (val("title") or "")[:24],
        "cwd": (r.get("identity", {}) or {}).get("cwd", ""),
        "turns": len(turns),
        "resp_lens": [len((t.get("response") or "")) for t in turns],
        "draft_len": len(to.get("draft") or ""),
        "steps": stats.get("steps"),
        "openStep": (stats.get("openStep") or {}).get("step") if stats.get("openStep") else None,
        "lastStepBoundary": (tb.get("lastStepBoundary") or {}).get("kind"),
        "lastTurn": tb.get("lastTurn"),
    }

def main():
    with open(LOG, "a", encoding="utf-8") as log:
        log.write(f"\n=== 探针启动 {time.strftime('%H:%M:%S')} ===\n")
        while True:
            files = glob.glob(os.path.join(ROOT, "*.json"))
            files.sort(key=lambda p: os.path.getmtime(p), reverse=True)
            for p in files[:3]:                       # 只看最活跃的三个会话
                sid = os.path.basename(p)[:-5]
                snap = snapshot(p)
                key = json.dumps(snap, sort_keys=True, ensure_ascii=False)
                if seen.get(sid) != key:
                    seen[sid] = key
                    log.write(f"{time.strftime('%H:%M:%S')} {sid[-12:]} {json.dumps(snap, ensure_ascii=False)}\n")
                    log.flush()
            time.sleep(2)

if __name__ == "__main__":
    main()
