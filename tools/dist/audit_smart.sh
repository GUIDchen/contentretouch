#!/bin/sh
# 一键智能体检：智能裁剪 / 肩线校平 / 按人物裁剪。
#
# 这三个是"算出来的结果"，所以能用**真值**卡（比"变了就算过"强）：
#   ① 智能裁剪 3:4 → 裁剪框宽高比必须 = 0.750（±0.01）
#   ② 按人物裁剪    → 同上；且必须检出至少 1 人
#   ③ 肩线校平      → 应用的旋转必须**精确等于**检出倾角的反向（±0.05），且被夹在 ±10° 内
#
# ⚠️ 刻意**不**拿"人造旋转图"做差分判据：实测把夹具旋转 +7°/-7°/+14°，
#    检出倾角的变化量是 -5.9 / -10.9 / +9.6 —— 不成比例、符号也不对称。
#    原因想得通：肩线倾角是叠在**姿态检测器**上的启发式，而姿态模型是在正立人像上训练的，
#    对旋转过的人像本身就不稳定。拿它当判据会做出一个"时红时绿"的门，所以只作为信息行留档。
#
# 用法：sh tools/dist/audit_smart.sh
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
APP="$ROOT/app-retouch/.build/release/ContentRetouch"
PHOTO="${1:-$ROOT/2604_wedding/00_RAW_readonly/wedding_01.jpg}"

[ -x "$APP" ] || { echo "先编译：cd app-retouch && swift build -c release"; exit 1; }
[ -f "$PHOTO" ] || { echo "缺夹具 $PHOTO —— 没测到不算通过"; exit 1; }

run_one() {   # $1=照片 $2=日志
    : > "$2"
    CR_IMPORT="$1" CR_SMARTAUDIT=1 "$APP" > "$2" 2>&1 &
    pid=$!
    i=0
    while [ $i -lt 40 ]; do
        sleep 2; i=$((i+1))
        grep -q 'SMARTAUDIT 完' "$2" 2>/dev/null && break
    done
    kill $pid 2>/dev/null
    wait $pid 2>/dev/null || true
}

echo "夹具：$(basename "$PHOTO")"
run_one "$PHOTO" /tmp/smarta_1.log
grep -E '^SMARTAUDIT ' /tmp/smarta_1.log | grep -vE '完|SUM' | sed 's/^/  /' || true

n=$(grep -cE '^SMARTAUDIT-SUM' /tmp/smarta_1.log || true)
if [ "$n" -ne 1 ]; then echo "!! 体检没跑完（缺汇总行）—— 没测到不算通过"; exit 1; fi

awk '
    function ck(desc, ok) {
        if (ok) printf "  V %s\n", desc
        else { printf "  X %s\n", desc; bad++ }
    }
    function abs(x) { return x < 0 ? -x : x }
    /^SMARTAUDIT-SUM / {
        for (i = 1; i <= NF; i++) { split($i, kv, "="); v[kv[1]] = kv[2] + 0 }
    }
    END {
        ck("智能裁剪 3:4 比例正确（" v["cropAR"] " ≈ 0.750）", abs(v["cropAR"] - 0.750) <= 0.01)
        ck("检出人物 ≥ 1（" v["persons"] " 人）",               v["persons"] >= 1)
        ck("按人物裁剪 3:4 比例正确（" v["personAR"] " ≈ 0.750）", abs(v["personAR"] - 0.750) <= 0.01)
        ck("肩线校平 = 倾角的精确反向（tilt " v["tilt"] " → applied " v["applied"] "）",
           abs(v["applied"] + v["tilt"]) <= 0.05)
        ck("肩线校平被夹在 ±10° 内（|" v["applied"] "| ≤ 10）", abs(v["applied"]) <= 10.0001)
        exit (bad > 0)
    }' /tmp/smarta_1.log

echo "一键智能体检：5 条判据"
