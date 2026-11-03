#!/bin/bash
# 一条命令跑完全部验收：编译 → 单元测试 → 自检 → 四态渲染 → 真实菜单栏端到端截图。
#
#   bash scripts/verify.sh              # 全跑
#   SKIP_E2E=1 bash scripts/verify.sh   # 跳过要截屏的那一步（远程/无录屏权限时）
#
# 每一步都会打印证据，最后汇总「通过 / 失败」。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$ROOT/.state"
FAKE="/tmp/dsh-avatar-fake-sessions"
mkdir -p "$STATE"

pass=0
fail=0
step() { echo; echo "==== $* ===="; }
ok()   { pass=$((pass+1)); echo "  ✓ $*"; }
bad()  { fail=$((fail+1)); echo "  ✗ $*"; }

# 截屏必须真的是内容，而不是黑屏/休眠画面。
# 教训：screencapture 在屏幕休眠时照样返回 0 并写出全黑图，
# 只检查退出码会让「端到端截图」假通过（实测踩到过）。
shot_is_real() {
  python3 - "$1" <<'PY'
import sys
from PIL import Image
try:
    im = Image.open(sys.argv[1]).convert("RGB")
except Exception:
    sys.exit(1)
small = im.resize((80, 50))
px = list(small.getdata())
mean = sum(sum(p) for p in px) / (len(px) * 3)
# 菜单栏区域应该至少有点变化，全黑/全同色都判失败
top = list(im.crop((0, 0, im.width, max(1, im.height // 20))).resize((60, 3)).getdata())
spread = max(sum(p) for p in top) - min(sum(p) for p in top)
sys.exit(0 if mean > 18 and spread > 30 else 1)
PY
}

step "1/5 编译"
if bash "$ROOT/scripts/build.sh" > /tmp/dsh-avatar-build.log 2>&1; then
  ok "编译 + 组装 .app + 签名（日志 /tmp/dsh-avatar-build.log）"
else
  bad "编译失败，见 /tmp/dsh-avatar-build.log"; tail -20 /tmp/dsh-avatar-build.log; exit 1
fi

step "2/5 单元测试（几何 / 状态机 / 文本）"
if "$ROOT/build/dsh-avatar-tests" | tail -3; then
  ok "单元测试全通过"
else
  bad "单元测试失败"
fi

step "3/5 自检：窗口层级、刘海避让、取景"
"$ROOT/build/DSHAvatar" --diag --state-dir "$STATE" > /tmp/dsh-avatar-diag.json 2>/tmp/dsh-avatar-diag.err
diag_status=$?
python3 - "$diag_status" <<'PY'
import json, sys
status = int(sys.argv[1])
try:
    d = json.load(open("/tmp/dsh-avatar-diag.json"))
except Exception as e:
    print("  ✗ 自检输出不是 JSON：", e); sys.exit(1)
print("  ok =", d["ok"], " 窗口 =", d["window"]["frame"], " level =", d["window"]["level"])
print("  渲染实测形象 = %.1f×%.1fpt（窗口 %.0f×%.0f）高度占比 %.2f" % (
    d["character"]["renderedRect"]["w"], d["character"]["renderedRect"]["h"],
    d["character"]["viewW"], d["character"]["viewH"], d["character"]["fillOfWindowHeight"]))
for k, v in d["checks"].items():
    print(("  ✓ " if v else "  ✗ ") + k)
sys.exit(0 if (d["ok"] and status == 0) else 1)
PY
if [ $? -eq 0 ]; then ok "自检全部通过"; else bad "自检失败（/tmp/dsh-avatar-diag.json）"; fi

step "4/5 四种心情的渲染图"
for mood in idle working celebrate sleep; do
  "$ROOT/build/DSHAvatar" --render "$ROOT/build/render-$mood.png" --mood "$mood" --state-dir "$STATE" --exit-after 4 >/dev/null 2>&1 \
    && ok "build/render-$mood.png" || bad "渲染 $mood 失败"
done

if [ "${SKIP_E2E:-0}" = "1" ]; then
  step "5/5 端到端（已跳过）"
  echo "  SKIP_E2E=1，跳过真实菜单栏截图"
else
  step "5/5 端到端：假会话「干活中 → 出结果」"
  rm -rf "$FAKE"; mkdir -p "$FAKE"
  # 屏幕休眠时截出来是全黑，先唤醒一下再截（-u 只唤醒不改变亮度设定）。
  caffeinate -u -t 1 2>/dev/null
  python3 "$ROOT/scripts/make-fake-session.py" "$FAKE" 1 "" 3 >/dev/null
  "$ROOT/build/DSHAvatar" --sessions-dir "$FAKE" --state-dir "$STATE" --exit-after 9 >/tmp/dsh-avatar-e2e.log 2>&1 &
  app_pid=$!
  sleep 3
  if screencapture -x "$ROOT/build/e2e-1-干活中.png" 2>/dev/null && shot_is_real "$ROOT/build/e2e-1-干活中.png"; then
    ok "build/e2e-1-干活中.png（干活态：琥珀眯眼 + 金色光环）"
  else
    bad "截屏无效（全黑 = 屏幕休眠或缺少录屏权限）"
  fi
  python3 "$ROOT/scripts/make-fake-session.py" "$FAKE" 0 "新结果来了：菜单栏奶蛙会捧腹大笑" 4 >/dev/null
  sleep 1.2
  if screencapture -x "$ROOT/build/e2e-2-新结果.png" 2>/dev/null && shot_is_real "$ROOT/build/e2e-2-新结果.png"; then
    ok "build/e2e-2-新结果.png（捧腹大笑 + 放大 + 气泡）"
  else
    bad "截屏无效（全黑 = 屏幕休眠或缺少录屏权限）"
  fi
  wait $app_pid 2>/dev/null
fi

echo
echo "========================================"
echo "通过 $pass 项，失败 $fail 项"
[ "$fail" -eq 0 ] || exit 1
echo "全部通过 ✅"
