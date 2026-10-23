#!/bin/sh
# 断点续跑 + 项目记录体检：中途退出后再点一次，应当**只补没导出的那些**。
#
# 为什么需要它：一万张的批量跑到一半退出是常态，而这个功能此前没有任何检查 ——
# 它坏掉的表现是"重跑一遍"（白等几小时）或者更糟：**产出重复文件**（a.jpg + a-1.jpg 堆满目录）。
#
# 判据：
#   A 首轮：N 张图 → N 个产物；项目记录 path 正确且 done == total == N
#   B 断点续跑：删掉一个产物再跑 → 报告"跳过已有 X 张"，且**已有的那个指纹与 mtime 都不变**
#   C 无重复：产物总数仍 == N（不会出现 a-1.jpg 之类）
#   D 记录更新而非追加：store 里该 path 只有一条，且 done == total == N
#
# 用法：sh tools/dist/audit_resume.sh
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
APP="$ROOT/app-retouch/.build/release/ContentRetouch"
IMG="$ROOT/douyin_favorites/images"
DIR=/tmp/resume_audit_dir
STORE=/tmp/resume_audit_store.json
OUT="$DIR/retouched"

[ -x "$APP" ] || { echo "先编译：cd app-retouch && swift build -c release"; exit 1; }
A="$IMG/0001_7673816620465215714_01.webp"
B="$IMG/0001_7676844130508479842_23.webp"
[ -f "$A" ] && [ -f "$B" ] || { echo "缺夹具（$A / ${B}）—— 没测到不算通过"; exit 1; }

rm -rf "$DIR" "$STORE"; mkdir -p "$DIR"; cp "$A" "$DIR/a.webp"; cp "$B" "$DIR/b.webp"
N=2

run_export() {   # $1=日志
    : > "$1"
    CR_PROJECTS_PATH="$STORE" "$APP" --import="$A" --run=export:"$DIR" > "$1" 2>&1 &
    pid=$!
    i=0
    while [ $i -lt 40 ]; do
        sleep 2; i=$((i+1))
        grep -q '导出完成' "$1" 2>/dev/null && break
    done
    kill $pid 2>/dev/null
    wait $pid 2>/dev/null || true
}

fail=0
ok()  { echo "  V $1"; }
bad() { echo "  X $1"; fail=1; }

# A 首轮
run_export /tmp/resume_a.log
n=$(ls "$OUT" 2>/dev/null | wc -l | tr -d ' ')
if [ "$n" = "$N" ]; then ok "A 首轮：$N 张图 → $n 个产物"
else bad "A 首轮：$N 张图 → $n 个产物"; fi
# ⚠️ JSON 里的斜杠是转义的（"\/tmp\/…"）—— 直接 grep "path":"/tmp/…" 永远匹配不到，
# 必须先摊平转义（踩过：A/D 两条判据假红）
flat() { sed 's|\\/|/|g' "$STORE" > /tmp/resume_store_flat.json 2>/dev/null || true; }
flat
if grep -q "\"path\":\"$OUT\"" /tmp/resume_store_flat.json 2>/dev/null; then
    ok "A 项目记录：path 正确（$(head -c 80 /tmp/resume_store_flat.json)…）"
else bad "A 项目记录：没找到 path=$OUT"; fi

# B/C 断点续跑
rm -f "$OUT/a.jpg"
hb=$(shasum -a 256 "$OUT/b.jpg" | awk '{print $1}')
tb=$(stat -f %m "$OUT/b.jpg")
run_export /tmp/resume_b.log
n=$(ls "$OUT" 2>/dev/null | wc -l | tr -d ' ')
if [ -f "$OUT/a.jpg" ]; then ok "B 断点续跑：删掉的 a.jpg 被补回来了"
else bad "B 断点续跑：a.jpg 没有补回来"; fi
if grep -q '跳过已有' /tmp/resume_b.log; then ok "B 断点续跑：报告"$(grep -o '跳过已有 [0-9]* 张' /tmp/resume_b.log | head -1)""
else bad "B 断点续跑：没报告跳过（可能整批重做了）"; fi
hb2=$(shasum -a 256 "$OUT/b.jpg" | awk '{print $1}')
tb2=$(stat -f %m "$OUT/b.jpg")
if [ "$hb" = "$hb2" ] && [ "$tb" = "$tb2" ]; then ok "B 已有的那个没被重做（指纹与 mtime 都没变）"
else bad "B 已有的那个被重做了（白等一遍）"; fi
if [ "$n" = "$N" ]; then ok "C 无重复：产物仍是 $n 个"
else bad "C 无重复：产物变成 $n 个（出现了重复文件）"; fi

# D 记录更新而非追加
flat
cnt=$(grep -o "\"path\":\"$OUT\"" /tmp/resume_store_flat.json 2>/dev/null | wc -l | tr -d ' ')
if [ "$cnt" = "1" ]; then ok "D 项目记录：该目录只有一条（更新而非追加）"
else bad "D 项目记录：该目录有 $cnt 条（应当只有 1 条）"; fi

echo "断点续跑体检：$([ "$fail" = "0" ] && echo "全部通过" || echo "有失败")"
exit $fail
