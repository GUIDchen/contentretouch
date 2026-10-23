#!/bin/sh
# 参考追色体检：solveRef（把参考折算成目标）→ applyRef（走界面同一条路）→ **独立量**"离参考近了没"。
#
# 为什么需要它：追色是主打功能，而它此前没有任何自动检查。第一轮就抓到一个会毁照片的问题：
#   **纯色参考（纯白/中灰/纯黑）** 的影调跨度是 0，measure() 归一化出来的 q5/q50/q95 全是 0，
#   而"白底文档"闸门判的是 q50 > 0.6 —— 对纯白恰好不成立，于是闸门失效、追色朝"全黑"冲
#   （实测画面峰值 170~237）。现在多了一道"有没有影调分布"的闸门（跨度 < 8 级 = 纯色，拒绝）。
#
# 判据：
#   A 正常参考：accepted=1、误差必须**变小**（朝参考靠）、画面确实变了
#   B/C/D 纯白/中灰/纯黑参考：必须被拒（accepted=0）
#   E 参考路径不存在：必须被拒且不崩
#
# 用法：sh tools/dist/audit_ref.sh
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
APP="$ROOT/app-retouch/.build/release/ContentRetouch"
PHOTO="${1:-$ROOT/douyin_favorites/images/0001_7673816620465215714_01.webp}"
REF="${2:-$ROOT/2604_wedding/00_RAW_readonly/wedding_01.jpg}"
MAGICK=${MAGICK:-/opt/homebrew/bin/magick}

[ -x "$APP" ] || { echo "先编译：cd app-retouch && swift build -c release"; exit 1; }
[ -f "$PHOTO" ] || { echo "缺夹具 $PHOTO —— 没测到不算通过"; exit 1; }
[ -f "$REF" ] || { echo "缺参考图 $REF —— 没测到不算通过"; exit 1; }

run_one() {   # $1=标签 $2=参考路径 $3=日志
    : > "$3"
    CR_IMPORT="$PHOTO" CR_REFAUDIT=1 "$APP" --reference="$2" > "$3" 2>&1 &
    pid=$!
    i=0
    while [ $i -lt 40 ]; do
        sleep 1; i=$((i+1))
        grep -q 'REFAUDIT 完' "$3" 2>/dev/null && break
    done
    kill $pid 2>/dev/null
    wait $pid 2>/dev/null || true
}

echo "夹具：$(basename "$PHOTO") ｜ 参考：$(basename "$REF")"
fail=0
ok()  { echo "  V $1"; }
bad() { echo "  X $1"; fail=1; }

# A 正常参考
run_one 正常 "$REF" /tmp/ref_a.log
sum=$(grep -o 'REFAUDIT-SUM.*' /tmp/ref_a.log | head -1)
echo "  · $sum"
if [ -z "$sum" ]; then bad "A 正常参考：没有汇总行"
else
    echo "$sum" | awk '
        # ⚠️ awk 的函数必须写在最外层 —— 写进 END{} 里是语法错误（这一轮第二次踩）
        function ck(d, o) { if (o) printf "  V %s\n", d; else { printf "  X %s\n", d; bad++ } }
        { accept = 0; before = 0; after = 0; peak = 0
          for (i = 1; i <= NF; i++) {
            if (index($i, "accepted=") == 1) { split($i, kv, "="); accept = kv[2] + 0 }
            if (index($i, "before=") == 1)   { split($i, kv, "="); before = kv[2] + 0 }
            if (index($i, "after=") == 1)    { split($i, kv, "="); after = kv[2] + 0 }
            if (index($i, "peak=") == 1)     { split($i, kv, "="); peak = kv[2] + 0 }
          }
          ck("A 参考被接受（accepted=" accept "）", accept == 1)
          ck("A 追色让误差变小（" before " → " after "）", after < before)
          ck("A 画面确实变了（峰值 " peak " ≥ 3）", peak >= 3)
          exit (bad > 0)
        }' || fail=1
fi

# B/C/D 纯色参考必须被拒
if [ -x "$MAGICK" ]; then
    $MAGICK -size 800x600 xc:white -alpha off /tmp/audit_ref_white.png 2>/dev/null || true
    $MAGICK -size 800x600 xc:gray50 /tmp/audit_ref_gray.png 2>/dev/null || true
    $MAGICK -size 800x600 xc:black -alpha off /tmp/audit_ref_black.png 2>/dev/null || true
    check_reject() {   # $1=标签 $2=图片 $3=日志
        [ -f "$2" ] || { echo "  · ${1}：造不出夹具，跳过"; return; }
        run_one "$1" "$2" "$3"
        s=$(grep -o 'REFAUDIT-SUM.*' "$3" | head -1)
        echo "  · $s"
        case "$s" in
            *accepted=0*) ok "$1 被拒（纯色参考没有可追的分布）" ;;
            *) bad "$1 没被拒：追色会朝纯色目标冲，画面会被毁" ;;
        esac
    }
    check_reject "B 纯白参考" /tmp/audit_ref_white.png /tmp/ref_b.log
    check_reject "C 中灰参考" /tmp/audit_ref_gray.png /tmp/ref_c.log
    check_reject "D 纯黑参考" /tmp/audit_ref_black.png /tmp/ref_d.log
else
    echo "  · B/C/D 跳过：没找到 magick，造不出纯色夹具"
fi

# E 参考路径不存在
run_one 缺失 "/tmp/audit_missing_ref_$$.jpg" /tmp/ref_e.log
s=$(grep -o 'REFAUDIT-SUM.*' /tmp/ref_e.log | head -1)
echo "  · $s"
case "$s" in
    *accepted=0*) ok "E 参考读不到：被拒且不崩" ;;
    *) bad "E 参考读不到：没有正确拒绝（${s}）" ;;
esac

echo "参考追色体检：$([ "$fail" = "0" ] && echo "全部通过" || echo "有失败")"
exit $fail
