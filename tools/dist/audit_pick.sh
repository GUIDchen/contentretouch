#!/bin/sh
# 挑图（pick-cli）体检：这是完全没被覆盖过的独立二进制。
#
# 判据（全部可算真值）：
#   A 排序：总分必须**降序**（输出的意义就在这里）
#   B 覆盖：目录里 N 张图，就要有 N 行（少一张都是静默漏挑）
#   C CSV ：行数 == N+1（表头）、列数 == 8
#   D --top 1：只印 1 行（但 CSV 仍是全量）
#   E 语义：把同一张图**人为模糊**一份，清晰那张必须排在前面（真值：分数确实在量清晰度）
#   F 退出码：目录不存在 / 目录为空 → **非零**（与 retouch-cli 同一条规矩，账本第 148 节）
#
# 用法：sh tools/dist/audit_pick.sh
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
PICK="$ROOT/app-retouch/.build/release/pick-cli"
SRC="${1:-$ROOT/douyin_favorites/images/0001_7673816620465215714_01.webp}"
MAGICK=${MAGICK:-/opt/homebrew/bin/magick}

[ -x "$PICK" ] || { echo "先编译：cd app-retouch && swift build -c release"; exit 1; }
[ -f "$SRC" ] || { echo "缺夹具 $SRC —— 没测到不算通过"; exit 1; }

PAIR=/tmp/pick_audit_pair; CSV=/tmp/pick_audit.csv
rm -rf "$PAIR"; mkdir -p "$PAIR"
cp "$SRC" "$PAIR/清晰.webp"
if [ -x "$MAGICK" ]; then
    $MAGICK "$SRC" -blur 0x8 "$PAIR/模糊.webp" 2>/dev/null || cp "$SRC" "$PAIR/模糊.webp"
else
    cp "$SRC" "$PAIR/模糊.webp"        # 没有 magick 时退化成同一张（E 会跳过）
fi
N=$(ls "$PAIR" | wc -l | tr -d ' ')

fail=0
ok()  { echo "  V $1"; }
bad() { echo "  X $1"; fail=1; }

"$PICK" "$PAIR" --csv "$CSV" > /tmp/pick_audit.log 2>/dev/null || true
lines=$(grep -cE '^ *[0-9]+\.' /tmp/pick_audit.log || true)
if [ "$lines" = "$N" ]; then ok "B 覆盖完整：$N 张图 → $lines 行"
else bad "B 覆盖完整：$N 张图 → $lines 行（有静默漏挑）"; fi

# A 排序：解析"总分 X"
awk '
    /^ *[0-9]+\./ {
        if (match($0, /总分 +[-0-9.]+/)) {
            v = substr($0, RSTART, RLENGTH); sub(/总分 +/, "", v); v += 0
            n++
            if (n > 1 && v > prev) { printf "  X A 排序：第 %d 行 %s 大于前一行的 %s（不是降序）\n", n, v, prev; bad++ }
            prev = v
        }
    }
    END { if (bad == 0) printf "  V A 排序：%d 行总分降序正确\n", n; exit (bad > 0) }' /tmp/pick_audit.log || fail=1

# C CSV
if [ -f "$CSV" ]; then
    rows=$(wc -l < "$CSV" | tr -d ' ')
    cols=$(head -1 "$CSV" | awk -F, '{print NF}')
    if [ "$rows" = "$((N + 1))" ] && [ "$cols" = "8" ]; then ok "C CSV：$rows 行（表头 + ${N}）、$cols 列"
    else bad "C CSV：$rows 行（期望 $((N + 1))）、$cols 列（期望 8）"; fi
else bad "C CSV：没写出文件"; fi

# D --top 1
"$PICK" "$PAIR" --top 1 > /tmp/pick_top1.log 2>/dev/null || true
toplines=$(grep -cE '^ *[0-9]+\.' /tmp/pick_top1.log || true)
if [ "$toplines" = "1" ]; then ok "D --top 1：只印 1 行"
else bad "D --top 1：印了 $toplines 行"; fi

# E 清晰排在模糊前（没有 magick 时两张一样，跳过）
if [ -x "$MAGICK" ]; then
    first=$(grep -E '^ *1\.' /tmp/pick_audit.log | head -1)
    case "$first" in
        *清晰*) ok "E 语义：清晰那张排在第一（$(echo "$first" | sed 's/ ｜.*//' | cut -c1-40)）" ;;
        *) bad "E 语义：模糊那张排到了第一（分数没在量清晰度）" ;;
    esac
else echo "  · E 跳过：没找到 magick"; fi

# E2 清晰**分数本身**：模糊那张必须严格低于清晰那张
# 为什么单加这条：E 只看"谁排第一"，而排名会被构图/曝光等其它分项左右 ——
# 突变测试证明过（把清晰度打分钉成 0，§182）：那次排序没翻转、E 照样绿，但分数本身已经全是 0。
# 这条盯的是分数（相对比较，与夹具无关），并用同一个突变验过它会红。
if [ -x "$MAGICK" ]; then
    s_clear=$(grep '清晰' /tmp/pick_audit.log | grep -oE '清晰 [+-]?[0-9.]+' | head -1 | grep -oE '[+-]?[0-9.]+')
    s_blur=$(grep '模糊' /tmp/pick_audit.log | grep -oE '清晰 [+-]?[0-9.]+' | head -1 | grep -oE '[+-]?[0-9.]+')
    [ -n "$s_clear" ] || s_clear=0
    [ -n "$s_blur" ] || s_blur=0
    if awk -v a="$s_clear" -v b="$s_blur" 'BEGIN{exit !(a > b)}'; then
        ok "E2 清晰分数有区分度：清晰 $s_clear > 模糊 $s_blur"
    else
        bad "E2 清晰分数没有区分度：清晰 $s_clear ｜ 模糊 $s_blur（分数没在量清晰度）"
    fi
fi

# F 退出码
if "$PICK" /tmp/pick_audit_missing_$$ > /dev/null 2>&1; then bad "F 目录不存在：退出码 0"; else ok "F 目录不存在：非零退出"; fi
rm -rf /tmp/pick_audit_empty_$$; mkdir -p /tmp/pick_audit_empty_$$
if "$PICK" /tmp/pick_audit_empty_$$ > /dev/null 2>&1; then bad "F 目录为空：退出码 0"; else ok "F 目录为空：非零退出"; fi
rm -rf /tmp/pick_audit_empty_$$

echo "挑图体检：$([ "$fail" = "0" ] && echo "全部通过" || echo "有失败")"
exit $fail
