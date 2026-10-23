#!/bin/sh
# 预设体检：套用 / 再点一次取消 / 切换后再取消 / 撤销后再套。
#
# 为什么需要它：用户报过"再点一次取消仍没实现"，说明这条路上有过 bug；而它的**中间状态**
# （appliedPresetKey / prePresetSnapshot）以前没有任何自动检查。第一轮就抓到两个：
#   ① 套 P → 套 Q → 取消 Q：取消把 **P 也一起丢了**（快照只在"当前没预设"时才重拍）
#   ② 套 P → 撤销 → 再套 P：撤销后 appliedPresetKey 还留着，第二次被当成"取消"→ 没反应
# 另外顺手修掉一处系统性错误：好几处 pushHistory 写在**改动之前**（记的是改前状态，
# 撤销会原地不动）—— 预设、Canvas 单击落点、场景推荐、肩线校平、液化旋转。
#
# 判据（96 宽缩图上的峰值差，全部来自 PRESETAUDIT-SUM 那行 ASCII 汇总）：
#   s1 ≥ 3        套用预设确实改了画面
#   s2 ≤ 1        再点一次 = 取消，回到套用前
#   s4undo ≤ 1    撤销套用回到基线
#   s4re ≥ 3      撤销之后再套同一条，仍然生效（不是被当成"取消"）
#   s3q ≥ 3       切换成另一条预设生效
#   s3cancel ≤ 1  取消 Q 回到"套用 Q 之前"= P 的状态
#   s3base ≥ 3    取消 Q 之后画面仍带着 P（没有把 P 一起丢掉）
#
# 用法：sh tools/dist/audit_preset.sh [照片路径]
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
APP="$ROOT/app-retouch/.build/release/ContentRetouch"
PHOTO="${1:-$ROOT/douyin_favorites/images/0001_7673816620465215714_01.webp}"
LOG=/tmp/presetaudit_run.log

[ -x "$APP" ] || { echo "先编译：cd app-retouch && swift build -c release"; exit 1; }
[ -f "$PHOTO" ] || { echo "缺夹具 $PHOTO —— 没测到不算通过"; exit 1; }

: > "$LOG"
CR_IMPORT="$PHOTO" CR_PRESETAUDIT=1 "$APP" > "$LOG" 2>&1 &
pid=$!
i=0
while [ $i -lt 30 ]; do
    sleep 2; i=$((i+1))
    grep -q 'PRESETAUDIT 完' "$LOG" 2>/dev/null && break
done
kill $pid 2>/dev/null
wait $pid 2>/dev/null || true

echo "夹具：$(basename "$PHOTO")"
grep -E '^PRESETAUDIT ' "$LOG" | grep -vE '完|SUM' | sed 's/^/  /' || true

n=$(grep -cE '^PRESETAUDIT-SUM' "$LOG" || true)
if [ "$n" -ne 1 ]; then echo "!! 体检没跑完（缺汇总行）—— 没测到不算通过"; exit 1; fi

awk '
    function ck(desc, ok) {
        if (ok) printf "  V %s\n", desc
        else { printf "  X %s\n", desc; bad++ }
    }
    /^PRESETAUDIT-SUM / {
        for (i = 1; i <= NF; i++) { split($i, kv, "="); v[kv[1]] = kv[2] + 0 }
    }
    END {
        ck("套用预设改了画面（s1=" v["s1"] " ≥ 3）",              v["s1"] >= 3)
        ck("再点一次 = 取消（s2=" v["s2"] " ≤ 1）",               v["s2"] <= 1)
        ck("撤销套用回到基线（s4undo=" v["s4undo"] " ≤ 1）",      v["s4undo"] <= 1)
        ck("撤销后再套同一条仍生效（s4re=" v["s4re"] " ≥ 3）",    v["s4re"] >= 3)
        ck("切换另一条预设生效（s3q=" v["s3q"] " ≥ 3）",          v["s3q"] >= 3)
        ck("取消 Q 回到 P（s3cancel=" v["s3cancel"] " ≤ 1）",     v["s3cancel"] <= 1)
        ck("取消 Q 没把 P 一起丢（s3base=" v["s3base"] " ≥ 3）",  v["s3base"] >= 3)
        exit (bad > 0)
    }' "$LOG"
# ── 第 8 条：**同步到选中图片**（把当前这套调整批量套出去）──────────────────
# 为什么单列：这是个实打实的功能（界面上叫「同步到选中图片」），但此前**没有任何门覆盖**
#（tools/dist 与 coretest 里都搜不到它）。判据：选中的 N 张都要产出、且画面确实变了 ——
# 不然"同步了个空气"也能算通过。
# 夹具用**临时目录**：这个功能会把产物写到源图同级的 synced/，直接在仓库夹具目录里跑会污染仓库。
SYNCDIR=/tmp/presetaudit_sync
rm -rf "$SYNCDIR"; mkdir -p "$SYNCDIR"
for f in $(ls "$(dirname "$PHOTO")" | grep -E '\.(jpg|jpeg|png|webp)$' | sort | head -3); do
    cp "$(dirname "$PHOTO")/$f" "$SYNCDIR/"
done
SLOG=/tmp/presetaudit_sync.log
: > "$SLOG"
FIRST=$(ls "$SYNCDIR" | head -1)
if [ "$(ls "$SYNCDIR" | wc -l | tr -d ' ')" -lt 3 ]; then
    echo "  X 同步到选中：夹具不足 3 张（$SYNCDIR）—— 没测到不算通过"; fail=1
else
    CR_SYNCAUDIT=1 CR_IMPORT="$SYNCDIR/$FIRST" "$APP" > "$SLOG" 2>&1 &
    pid=$!
    i=0
    while [ $i -lt 40 ]; do
        sleep 2; i=$((i+1))
        grep -q 'SYNCAUDIT 完' "$SLOG" 2>/dev/null && break
    done
    kill $pid 2>/dev/null
    wait $pid 2>/dev/null || true
    sline=$(grep -oE 'SYNCAUDIT-SUM.*' "$SLOG" | head -1)
    if [ -z "$sline" ]; then
        echo "  X 同步到选中：没拿到汇总行（见 $SLOG）—— 没测到不算通过"; fail=1
    else
        echo "  · $sline"
        sp=$(echo "$sline" | grep -oE 'picked=[0-9]+' | head -1 | sed 's/.*=//')
        sc=$(echo "$sline" | grep -oE 'changed=[0-9]+' | head -1 | sed 's/.*=//')
        sm=$(echo "$sline" | grep -oE 'missing=[0-9]+' | head -1 | sed 's/.*=//')
        [ -n "$sp" ] || sp=0
        [ -n "$sc" ] || sc=0
        [ -n "$sm" ] || sm=9
        if [ "$sm" = "0" ] && [ "$sc" -ge 2 ] && [ "$sp" -ge 2 ]; then
            echo "  V 8 同步到选中图片：$sp 张都产出、且画面都变了"
        else
            echo "  X 8 同步到选中图片：picked=$sp changed=$sc missing=$sm（应当 picked>=2、changed>=2、missing=0）"; fail=1
        fi
    fi
fi
rm -rf "$SYNCDIR"

echo "预设体检：8 条判据"
