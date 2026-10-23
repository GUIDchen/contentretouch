#!/bin/sh
# GUI 截图回归：把 App 的各个面板截一遍，和基线比对。
#
# 为什么要它：布局类 bug（工具条压画布那种）用「进程活着 + 窗口存在」的冒烟测试完全测不出来，
# 只有把界面真的画出来看一眼才发现。这个脚本把「看一眼」自动化。
#
# 用法:
#   sh tools/dist/ui_baseline.sh save     # 重建基线（改了界面、确认新样子没问题之后）
#   sh tools/dist/ui_baseline.sh check    # 与基线比对（默认；有差异退出码非 0）
#
# 实现上用 App 的自截图（--screenshot），不需要屏幕录制权限：
#   App 自己把窗口缓存成位图，6 秒后退出。
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

APP="app-retouch/.build/release/ContentRetouch"
[ -x "$APP" ] || { echo "先构建：cd app-retouch && swift build -c release"; exit 2; }

DIR="docs/shots/ui"
BASE="$DIR/baseline"
CUR="$DIR/current"
MODE="${1:-check}"
# 判定用「缩到 256 宽的灰度 RMSE」（0~1）。为什么要缩图：全分辨率比 AE 时，
# 搜索框的闪烁光标 + 鼠标悬停高亮就能造出 0.3~1.3% 的假差异（实测：同一份代码两次截图，
# export 面板 AE 1.34%，差异像素全在控件边框上）。缩图后小元素被平均掉，真正的布局错位仍显著。
# ⚠️ 阈值不是拍的，是量出来的（2026-09-26）：
#   同一份代码、两次截图（一模一样的面板），14 个面板的实测差异是 0.00~5.30%
#   （home 3.88 / portrait 3.99 / image 5.30 / todo 3.71 / export 2.69 …，history 与 pick 是 0）。
#   而原来的阈值是 6.0 —— 离噪声上限只有 0.7 个百分点，所以在忙机器上会假红（清单里 B6 那条）。
#   真回归的形状是"几十个百分点"（§135 实测：窗口没画完时 63%；布局炸掉时 56%），
#   所以阈值取噪声的 ~2 倍：既不误报，也远小于真回归。
#   代价写清楚：**小幅错位（几个像素）这类小回归会漏掉** —— 要查这种，用 save 前后 git diff 基线。
THRESHOLD="${UI_DIFF_PCT:-12.0}"

mkdir -p "$BASE" "$CUR"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# 面板清单：名称:模块:面板号:裁切区（面板号空 = 图库主页；裁切区空 = 整窗比对）
# §253：裁切区是**局部裁切比对** —— 整窗分母太大，关注区单独比灵敏度高得多
#（压力场景实测：整窗 8.45% vs 项目带裁切 15.34%，阈值 12% ⇒ 整窗会漏报）。
SHOTS="home:图库:
portrait:精修:3
preset:精修:0
tone:精修:1
history:精修:2
pick:精修:5
crop:精修:7
clothes:精修:8
image:精修:9
pet:精修:10
export:精修:11
ref:精修:12
search:精修:13
todo:精修:6
stress:图库::2660x260+30+1120
parts:精修:17
help:精修:14
feedback:精修:15
reflib:精修:16
trash:精修:18"
# §248：面板覆盖从 12 个扩到 17 个（新增 parts/help/feedback/reflib/trash）。
# 4 号（人像）与 3 号**渲染同一个 facePanel**、截图逐像素一样，重复截没有信息量，故不列，只在此说明。

capture() {
    name="$1"; module="$2"; panel="$3"
    out="$4/$name.png"
    rm -f "$out"
    # --appearance dark 必须带：宿主系统会在日出/日落自动换肤，不带就会出现
    # 「同一份代码夜里 0%、早上 56%」的假差异（实测踩到）。
    # §252：stress 场景用「20 个超长名字的项目」灌进图库页（走 CR_PROJECTS_PATH，**不污染用户真实项目列表**）。
    # 目的：把「文字被压住 / 卡片冲出边缘」这类问题变成**截图判据** —— 布局再被改坏（换行没了、折叠失效、名字被切），
    # 这个场景的截图必然变化，门就会红。这是 §249 小样否掉无障碍树方案后的替代路子。
    if [ "$name" = "stress" ]; then
        CR_PROJECTS_PATH=/tmp/crfix/layout_stress_projects.json \
            "$APP" --appearance dark --module "$module" --screenshot "$out" >/dev/null 2>&1
    elif [ -n "$panel" ]; then
        "$APP" --appearance dark --module "$module" --panel "$panel" --screenshot "$out" >/dev/null 2>&1
    else
        "$APP" --appearance dark --module "$module" --screenshot "$out" >/dev/null 2>&1
    fi
    [ -f "$out" ] || { echo "  ✗ $name 没截出来"; return 1; }
    return 0
}

echo "模式：${MODE}（差异阈值 $THRESHOLD%；实测同代码噪声上限 5.30%；截图并发 $PAR）"
fail=0
checked=0

# ── 阶段一：截图（**有界并发**）──────────────────────────────────
# 为什么能并发：每个面板的耗时几乎全是"等窗口画出来"的固定等待（--screenshot 内部 6 秒起、最多重试 8 次），
# 不是算力。串行 14 个面板实测 102 秒，其中大部分是纯等待。
# 并发度默认 3：太低省不下时间，太高会让多个 App 抢 CPU，反而可能让某些面板截到"没画完"的窗口
# （那会变成假红 —— 这正是这套门最怕的事）。UI_PARALLEL=1 可退回串行。
PAR=${UI_PARALLEL:-3}
if [ "$MODE" = "save" ]; then target="$BASE"; else target="$CUR"; fi
running=0
for entry in $SHOTS; do
    name=$(echo "$entry" | cut -d: -f1)
    module=$(echo "$entry" | cut -d: -f2)
    panel=$(echo "$entry" | cut -d: -f3)
    capture "$name" "$module" "$panel" "$target" > "$TMP/log_$name.txt" 2>&1 &
    running=$((running + 1))
    if [ "$running" -ge "$PAR" ]; then wait; running=0; fi
done
wait
for entry in $SHOTS; do
    name=$(echo "$entry" | cut -d: -f1)
    if [ ! -f "$target/$name.png" ]; then
        echo "  ✗ $name 没截出来"; cat "$TMP/log_$name.txt" 2>/dev/null; fail=1
    elif [ "$MODE" = "save" ]; then
        echo "  已存基线 $name"
    fi
done

# ── 阶段二：比对（串行；magick 比对很快）───────────────────────
if [ "$MODE" != "save" ]; then
for entry in $SHOTS; do
    name=$(echo "$entry" | cut -d: -f1)
    crop=$(echo "$entry" | cut -d: -f4)
    [ -f "$CUR/$name.png" ] || continue       # 没截出来的上面已经记过失败
        if [ ! -f "$BASE/$name.png" ]; then
            # ⚠️ 这里以前只打印一行提示就 continue，fail 保持 0 —— 基线丢光也会报"界面与基线一致"。
            # 基线是 git 跟踪的（docs/shots/ui/baseline），被删/被清空时必须响亮地失败。
            echo "  ✗ $name 没有基线（$BASE/$name.png）—— 先跑一次 save，别把空基线当通过"
            fail=1
            continue
        fi
        # §253：配了裁切区就只比那块（关注区），否则整窗比
        if [ -n "$crop" ]; then
            # ⚠️ 裁切模式**不缩放到 256**（§253 实测）：缩到 256 宽会把关注区的文字差异彻底抹平 ——
            # 同一对图：不缩放 13.58%、缩到 256 只有 0.00%（压力场景 vs 空项目）。
            # 只裁不缩，比较量仍在 0.7 MP 量级，magick 很快。
            magick "$BASE/$name.png" -crop "$crop" +repage -colorspace gray "$TMP/a.png"
            magick "$CUR/$name.png" -crop "$crop" +repage -colorspace gray "$TMP/b.png"
        else
            magick "$BASE/$name.png" -resize 256x -colorspace gray "$TMP/a.png"
            magick "$CUR/$name.png" -resize 256x -colorspace gray "$TMP/b.png"
        fi
        # RMSE 输出形如 "1234.5 (0.0312)"：括号里是归一化值
        rmse=$(magick compare -metric RMSE "$TMP/a.png" "$TMP/b.png" null: 2>&1 | sed -n 's/.*(\(.*\))/\1/p')
        [ -n "$rmse" ] || rmse=0
        pct=$(awk -v r="$rmse" 'BEGIN{printf "%.2f", r*100}')
        flag=$(awk -v p="$pct" -v th="$THRESHOLD" 'BEGIN{print (p>th ? "X" : "V")}')
        [ "$flag" = "X" ] && fail=1
        scope=$([ -n "$crop" ] && echo "裁切 $crop" || echo "整窗")
        printf "  %s %-10s 差异 RMSE %6s%%（阈值 %s%%，%s）\n" "$flag" "$name" "$pct" "$THRESHOLD" "$scope"
        checked=$((checked+1))
done
fi

if [ "$MODE" = "check" ] && [ "$checked" = "0" ]; then
    # 一个面板都没比对成（截图全失败 / 基线全缺）——空输入不算通过（同第 133 节的教训）
    echo "!! 一个面板都没比对上（截图或基线缺失），这次界面回归没有意义"
    exit 1
fi

if [ "$MODE" = "check" ]; then
    if [ "$fail" = "0" ]; then
        echo "界面与基线一致（或差异在阈值内）｜比对 $checked 个面板"
    else
        echo "界面和基线不一致：看一眼 $CUR/ 与 $BASE/ 的差异；确认是新样子就重跑 save"
        exit 1
    fi
fi
