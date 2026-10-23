#!/bin/sh
# 场景推荐体检：classifyScene 认出来的类别 + suggestParams 是否真的落到参数上。
#
# 为什么需要它："场景推荐"是智能功能，此前没有任何检查 —— 分类器退化成"永远返回同一个类别"、
# 或者建议没落到参数上，都不会有人发现。判据用**内容已知的夹具**当真值：
#   人像照 → 人像 ｜ 宠物照 → 宠物 ｜ 婚礼照 → 婚礼/宴席 ｜ 合成风景（无脸无人无动物）→ 风光/场景
# 另加两条不变量：① 类别必须与该图的检出信号自洽；② 四次里至少出现 3 个不同类别（真的在分辨）。
#
# 用法：sh tools/dist/audit_scene.sh
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
APP="$ROOT/app-retouch/.build/release/ContentRetouch"
IMG="$ROOT/douyin_favorites/images"
MAGICK=${MAGICK:-/opt/homebrew/bin/magick}
LAND=/tmp/scene_audit_landscape.jpg

[ -x "$APP" ] || { echo "先编译：cd app-retouch && swift build -c release"; exit 1; }

# 合成风景（真值：没有脸/人/动物 → 必须落到"风光/场景"）
if [ -x "$MAGICK" ]; then
    $MAGICK -size 1200x800 gradient:'#87CEEB-#FFFFFF' \
        -fill '#2F4F4F' -draw 'polygon 0,800 300,420 620,800' \
        -draw 'polygon 500,800 820,360 1200,800' \
        -fill '#FFD700' -draw 'circle 950,150 950,110' "$LAND" 2>/dev/null || true
fi

# ⚠️ 有界重试：机器负载高时（实测 load 21/69），"启动 + 导入 + Vision 分类"会超过预算 →
# 门假红。假红比没有门更糟（会训练人忽略红灯），所以这里**最多试 2 次**、每次 60 秒，
# 并且把"等超时"和"真失败"分开报。
run_once() {   # $1=日志 $2=照片 $3=等待秒数
    : > "$1"
    CR_IMPORT="$2" CR_SCENEAUDIT=1 "$APP" > "$1" 2>&1 &
    pid=$!
    i=0
    while [ $i -lt "$3" ]; do
        sleep 1; i=$((i+1))
        grep -q 'SCENEAUDIT 完' "$1" 2>/dev/null && break
    done
    kill $pid 2>/dev/null
    wait $pid 2>/dev/null || true
}
run_one() {   # $1=日志 $2=照片
    run_once "$1" "$2" 60
    grep -q 'SCENEAUDIT 完' "$1" 2>/dev/null && return 0
    echo "    （等超时，重试一次）"
    run_once "$1" "$2" 60
}

fail=0
ok()  { echo "  V $1"; }
bad() { echo "  X $1"; fail=1; }
cats=""

check_case() {   # $1=标签 $2=照片 $3=期望类别（子串）$4=日志
    if [ ! -f "$2" ]; then echo "  · ${1}：夹具不存在，跳过"; return; fi
    run_one "$4" "$2"
    sum=$(grep -o 'SCENEAUDIT-SUM.*' "$4" | head -1)
    if [ -z "$sum" ]; then
        # 把"等超时"和"跑完了但没数据"分开报：前者是环境问题（负载），后者才是产品问题
        if grep -q 'SCENEAUDIT 完' "$4" 2>/dev/null; then bad "${1}：跑完了但没有汇总行（产品问题）"
        else bad "${1}：两次都等超时（很可能只是机器负载高，见 ${4}）"; fi
        return
    fi
    echo "  · ${1}：$sum"
    cat=$(echo "$sum" | sed 's/.*cat=//; s/ faces=.*//')
    cats="$cats|$cat"
    case "$cat" in
        *"$3"*) ok "$1 类别「${cat}」符合真值「${3}」" ;;
        *) bad "$1 类别「${cat}」与真值「${3}」不符" ;;
    esac
    # 自洽：宠物 ⇒ 有动物；风光 ⇒ 无脸无动物；其余 ⇒ 有脸
    faces=$(echo "$sum" | sed 's/.*faces=//; s/ people=.*//')
    animals=$(echo "$sum" | sed 's/.*animals=//; s/ peak=.*//')
    peak=$(echo "$sum" | sed 's/.*peak=//')
    case "$cat" in
        宠物) [ "$animals" -ge 1 ] || bad "$1 判成宠物但动物数为 0（不自洽）" ;;
        风光*) [ "$faces" = "0" ] && [ "$animals" = "0" ] || bad "$1 判成风光但有脸/动物（不自洽）" ;;
        *) [ "$faces" -ge 1 ] || bad "$1 判成「${cat}」但脸数为 0（不自洽）" ;;
    esac
    [ "$(echo "$peak" | cut -d. -f1)" -ge 3 ] || bad "$1 建议没落到参数上（画面变化峰值 ${peak}）"
}

check_case "人像照" "$IMG/0001_7673816620465215714_01.webp" "人像" /tmp/sc_1.log
check_case "宠物照" "$IMG/0001_7676844130508479842_23.webp" "宠物" /tmp/sc_2.log
check_case "婚礼照" "$ROOT/2604_wedding/00_RAW_readonly/wedding_01.jpg" "婚礼/宴席" /tmp/sc_3.log
check_case "合成风景" "$LAND" "风光/场景" /tmp/sc_4.log

# 反退化：类别不能永远是同一个
n=$(echo "$cats" | tr '|' '\n' | grep -c . || true)
uniq=$(echo "$cats" | tr '|' '\n' | grep . | sort -u | wc -l | tr -d ' ')
if [ "$uniq" -ge 3 ]; then ok "分类器在分辨：$n 张图里出现 $uniq 个不同类别"
else bad "分类器可疑：$n 张图只有 $uniq 个不同类别（${cats}）"; fi

echo "场景推荐体检：$([ "$fail" = "0" ] && echo "全部通过" || echo "有失败")"
exit $fail
