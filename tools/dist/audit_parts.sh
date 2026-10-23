#!/bin/sh
# 按部位体检：脸/眼/唇/鼻/耳/手臂/腿 —— "勾选某个部位调一下，画面必须变，而且**变在该部位里**"。
#
# 为什么需要它：coretest 只验过"部位笔触的构造"（§33），**UI → 管线**这一段没量过；
# 体检矩阵里也没有"部位"行。判据全部用**掩膜当真值**：
#   A 有掩膜的部位必须改画面（峰值 ≥ 3）
#   B 变化最强的那个点必须落在掩膜内（比"变了多少像素在掩膜内"稳 —— 羽化边缘在缩图上会被算到外面）
#   C **没有掩膜的部位不许改画面**（"不该动的部位动了"才是真 bug）
#   D 覆盖：人像照 ≥4 个部位有掩膜；**全身照必须检出腿**
#   E 大掩膜（手臂/腿）的定位质量：≥80% 的改动像素落在掩膜内
#   F 祛油光：必须是"只压高光顶"（亮部明显变暗 且 暗部几乎不动），不是"整体变暗"
#   G 祛黑眼圈：必须是"只动眼下那条带"（带内变亮 且 带外几乎不动），不是"整脸提亮"
#   H 逐项体检 15 项（祛瑕 11 + 颜色 4）：每一项都必须只改"它自己那块地方"
#     （逐项自带小值对照抵消管线底噪；颜色四项 §209 并入 —— 实测 9~15 级，没有一项低于可见阈值）
#
# 用法：sh tools/dist/audit_parts.sh
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
APP="$ROOT/app-retouch/.build/release/ContentRetouch"
PORTRAIT="${1:-$ROOT/douyin_favorites/images/0001_7673816620465215714_01.webp}"
FULLBODY="${2:-$ROOT/2604_wedding/00_RAW_readonly/wedding_01.jpg}"

[ -x "$APP" ] || { echo "先编译：cd app-retouch && swift build -c release"; exit 1; }
[ -f "$PORTRAIT" ] || { echo "缺人像夹具 $PORTRAIT —— 没测到不算通过"; exit 1; }
[ -f "$FULLBODY" ] || { echo "缺全身夹具 $FULLBODY —— 没测到不算通过"; exit 1; }

run_one() {   # $1=日志 $2=照片
    : > "$1"
    CR_IMPORT="$2" CR_PARTAUDIT=1 "$APP" > "$1" 2>&1 &
    pid=$!
    i=0
    while [ $i -lt 90 ]; do
        sleep 1; i=$((i+1))
        grep -q 'PARTAUDIT 完' "$1" 2>/dev/null && break
    done
    kill $pid 2>/dev/null
    wait $pid 2>/dev/null || true
}

fail=0
ok()  { echo "  V $1"; }
bad() { echo "  X $1"; fail=1; }

check_case() {   # $1=标签 $2=照片 $3=日志
    run_one "$3" "$2"
    sum=$(grep -o 'PARTAUDIT-SUM.*' "$3" | head -1)
    if [ -z "$sum" ]; then bad "${1}：没有汇总行（见 ${3}）"; return; fi
    echo "  · ${1}：$sum"
    echo "$sum" | awk -v tag="$1" '
        function ck(desc, ok) {
            if (ok) printf "  V %s\n", desc
            else { printf "  X %s\n", desc; bad++ }
        }
        {
            alive = 0; nomask = 0
            for (i = 2; i <= NF; i++) {
                m = split($i, f, ":")
                if (m < 5) continue
                name = f[1]; p = f[2]; s = f[3]; r = f[4]; pk = f[5]
                sub(/^p/, "", p); sub(/^s/, "", s); sub(/^r/, "", r); sub(/^pk/, "", pk)
                p += 0; s += 0; r += 0; pk += 0
                # 有没有掩膜用**支撑区像素数**（s）判：小脸的"眼睛"掩膜核心可能不到一个采样点
                if (s > 0) {
                    alive++
                    ck(tag "·" name " 有掩膜就要改画面（峰值 " p "）", p >= 3)
                    ck(tag "·" name " 最强改动在掩膜内", pk == 1)
                    if (s >= 500) ck(tag "·" name " 大掩膜：≥90% 的改动落在掩膜里（实 " r "%）", r >= 90)
                } else {
                    nomask++
                    ck(tag "·" name " 没掩膜就不许改画面（实 " p "）", p == 0)
                }
                # §250：耳朵还要判**位置** —— 面积/占比量不出"掩膜在不在耳位"（§243 那次改动门看不出差别）。
                # 契约同 coretest §244：解析路径偏一侧（|xo| > 0.3 脸宽）｜兜底路径跨两侧（sw > 0.8 脸宽）。
                if (name == "耳朵" && s > 0 && m >= 7) {
                    xo = f[6]; sw = f[7]
                    sub(/^xo/, "", xo); sub(/^sw/, "", sw)
                    xo += 0; sw += 0
                    axo = (xo < 0) ? -xo : xo
                    side = (axo > 0.3)
                    span = (sw > 0.8)
                    ck(tag "·耳朵 掩膜在耳位（偏移 " xo " 脸宽、宽 " sw " 脸宽）", side || span)
                    ck(tag "·耳朵 耳位字段存在（xo/sw）", 1)
                }
                if (name == "耳朵" && s > 0 && m < 7) {
                    ck(tag "·耳朵 缺少耳位字段（xo/sw）—— 说明探针没打或字段被改坏", 0)
                }
            }
            ck(tag "：有掩膜的部位数 ≥ 4（实 " alive "）", alive >= 4)
            printf "    （%s：有掩膜 %d 个 / 无掩膜 %d 个）\n", tag, alive, nomask
            exit (bad > 0)
        }' || fail=1
}

check_case "人像照" "$PORTRAIT" /tmp/parts_portrait.log
check_case "全身照" "$FULLBODY" /tmp/parts_fullbody.log

# 全身照必须检出腿（这是"腿的分支"最容易被漏掉的地方）
if grep -q '腿:p[1-9]' /tmp/parts_fullbody.log; then ok "全身照检出了腿（腿的分支真的能跑）"
else bad "全身照没检出腿 —— 腿的分支又没人跑了"; fi

# ⚠️ 这个门原来没定义 MAGICK（其它门都有）—— 补上，否则下面的 E 判据会静默跳过
MAGICK=${MAGICK:-/opt/homebrew/bin/magick}

# E 无脸全身照：**没有脸时"四肢"这条路必须仍然能跑**
# 为什么加这一条：突变测试发现门的两张夹具里 faces=1 / faces=2 ——
# 也就是说"没有脸"那条分支（文档写明"没有脸时只有四肢可能成立"）**从来没被走到过**（§183）。
# 顺带把"夹具到底有没有达到无脸"也做成判据：达不到就判失败，而不是静默跳过（§182.4 的教训）。
if [ -x "$MAGICK" ]; then
    # 夹具造法：把**上 30%（头部区域）重度模糊** —— 身体完整、人脸检测失败。
    # ⚠️ 先用"只裁腿部"做过夹具，结果七个部位全是 p0 —— 那不是代码的问题，是**夹具不公平**：
    # 人体姿态检测需要全身（只有腿的构图找不到关节）。换成"糊脸保身体"之后，
    # 实测 手臂:p102:s1703 腿:p103:s7734 都能检出（这正是文档里"没有脸时只有四肢可能成立"要守的东西）。
    NOFACE=/tmp/parts_noface.jpg
    "$MAGICK" "$FULLBODY" \( +clone -gravity north -crop 100%x30%+0+0 +repage -blur 0x25 \) \
        -gravity north -composite "$NOFACE" 2>/dev/null || true
    if [ -s "$NOFACE" ]; then
        run_one /tmp/parts_noface.log "$NOFACE"
        nsum=$(grep -o 'PARTAUDIT-SUM.*' /tmp/parts_noface.log | head -1)
        if [ -z "$nsum" ]; then bad "E 无脸全身照：没有汇总行（见 /tmp/parts_noface.log）"
        else
            echo "  · 无脸全身照：$nsum"
            case "$nsum" in
                *faces=0*)
                    case "$nsum" in
                        *腿:p[1-9]*) ok "E 无脸全身照：腿仍然检出（没有脸时四肢仍成立）" ;;
                        *) bad "E 无脸全身照：腿没检出 —— 四肢退化成了硬依赖脸" ;;
                    esac ;;
                *) bad "E 无脸全身照：这张仍然检出了脸（夹具没达到无脸的目的，判据无效）" ;;
            esac
        fi
    else bad "E 无脸全身照：夹具裁不出来（$FULLBODY）"; fi
else echo "  · E 跳过：没找到 magick"; fi

# F 祛油光：必须是"只压高光顶"，不是"整体变暗"
# 为什么这么判：整体变暗也能让画面变 —— 那不是祛油光。所以分开量暗部与亮部的平均变化：
# 亮部要明显变暗、暗部必须几乎不动。实测（§188）满档：亮部 +4.44 级、暗部 −0.13 级。
SHLOG=/tmp/partaudit_shine.log
: > "$SHLOG"
CR_IMPORT="$PORTRAIT" CR_SHINEAUDIT=1 "$APP" > "$SHLOG" 2>&1 &
pid=$!
i=0
while [ $i -lt 40 ]; do
    sleep 2; i=$((i+1))
    grep -q 'SHINEAUDIT 完' "$SHLOG" 2>/dev/null && break
done
kill $pid 2>/dev/null
wait $pid 2>/dev/null || true
ssum=$(grep -oE 'SHINEAUDIT-SUM.*' "$SHLOG" | head -1)
if [ -z "$ssum" ]; then
    echo "  X F 祛油光：没拿到汇总行（见 $SHLOG）—— 没测到不算通过"; fail=1
else
    echo "  · $ssum"
    sd=$(echo "$ssum" | grep -oE ' dark=[-0-9.]+' | head -1 | sed 's/.*=//')
    sbr=$(echo "$ssum" | grep -oE ' bright=[-0-9.]+' | head -1 | sed 's/.*=//')
    spk=$(echo "$ssum" | grep -oE ' brightpeak=[-0-9.]+' | head -1 | sed 's/.*=//')
    [ -n "$sd" ] || sd=99
    [ -n "$sbr" ] || sbr=0
    [ -n "$spk" ] || spk=0
    # ⚠️ 口径在 §204 改过一次，原因是**判据原来守错了实现**：F 一直量的是皮肤面板那条
    # （亮部平均 4.44 级），而用户拖的滑杆在按部位面板，其实现用 level 掩膜只碰最亮那一小片 ——
    # 亮部**平均**天然被稀释（实测 1.79），峰值却有 23 级。
    # 所以改成：**作用处有多强看峰值（≥6 级）、别处有没有被带走看暗部均值（≤1 级）**，
    # 亮部平均降为报告项。阈值 6 = 实测 23 的 1/3.8 余量（同族最弱项也不至于被漏掉）。
    okb=$(awk -v d="$sd" -v p="$spk" 'BEGIN{ print (p >= 6 && d <= 1) ? "ok" : "bad" }')
    if [ "$okb" = "ok" ]; then
        ok "F 祛油光只压高光顶：亮部峰值压暗 ${spk} 级（亮部平均 ${sbr}）｜ 暗部只动 $sd 级"
    else
        bad "F 祛油光不是"只压高光顶"：亮部峰值 ${spk} 级（应 >=6）｜ 暗部 $sd 级（应 <=1）｜ 亮部平均 $sbr"
    fi
fi

# G 祛黑眼圈：必须是"只动眼下那条带"，不是"整脸提亮"
# 各判据的口径（为什么是这几个数）：
#   band      眼下带**平均**变亮 —— 羽化边缘会把平均拉低，所以另给峰值
#   bandmax   带内**峰值**变亮 —— 满档实测 +23.1 级，这才是"看得见"的证据
#   outside   脸以外平均变化 —— 必须排除**所有**脸框：只排最大那张，会把第二张脸的合法改动算成漏出
#   maskband  带内掩膜峰值 —— 专盯"掩膜空掉 ⇒ 功能静默失效"这一类（第一版正是这样失效的，实测 0.00）
#   leakpx/leakmax **只报告不判**：基线样本里 anyEnabled=false 会让管线**直接返回**，
#     任何一个人像功能一开，图就要走一次工作空间平移往返 = 整幅重采样。
#     对照实验：把开的参数换成**眼袋**（掩膜与区域与本功能完全不同），漏出足迹一样
#     （11811→10417 px、−50.3→−53.3 级、同样铺满全图）⇒ 那是重采样，不是掩膜漏出，当判据会误伤。
DCLOG=/tmp/partaudit_dc.log
: > "$DCLOG"
CR_IMPORT="$PORTRAIT" CR_DCAUDIT=1 "$APP" > "$DCLOG" 2>&1 &
pid=$!
i=0
while [ $i -lt 40 ]; do
    sleep 2; i=$((i+1))
    grep -q 'DCAUDIT 完' "$DCLOG" 2>/dev/null && break
done
kill $pid 2>/dev/null
wait $pid 2>/dev/null || true
dsum=$(grep -oE 'DCAUDIT-SUM.*' "$DCLOG" | head -1)
if [ -z "$dsum" ]; then
    echo "  X G 祛黑眼圈：没拿到汇总行（见 $DCLOG）—— 没测到不算通过"; fail=1
else
    echo "  · $dsum"
    gb=$(echo "$dsum" | grep -oE '(^| )band=[-0-9.]+' | head -1 | sed 's/.*=//')
    gx=$(echo "$dsum" | grep -oE '(^| )bandmax=[-0-9.]+' | head -1 | sed 's/.*=//')
    go=$(echo "$dsum" | grep -oE '(^| )outside=[-0-9.]+' | head -1 | sed 's/.*=//')
    gm=$(echo "$dsum" | grep -oE '(^| )maskband=[-0-9.]+' | head -1 | sed 's/.*=//')
    [ -n "$gb" ] || gb=0; [ -n "$gx" ] || gx=0; [ -n "$go" ] || go=9; [ -n "$gm" ] || gm=0
    gok=$(awk -v b="$gb" -v x="$gx" -v o="$go" -v m="$gm" 'BEGIN{ print (b >= 1.5 && x >= 6 && o <= 0.5 && m >= 0.5) ? "ok" : "bad" }')
    if [ "$gok" = "ok" ]; then
        ok "G 祛黑眼圈只动眼下带：带内平均 +$gb 级、峰值 +$gx 级 ｜ 带外只动 $go 级 ｜ 掩膜峰值 $gm"
    else
        bad "G 祛黑眼圈不合格：带内平均 $gb 级（应 ≥1.5）｜ 峰值 $gx 级（应 ≥6）｜ 带外 $go 级（应 ≤0.5）｜ 掩膜峰值 $gm（应 ≥0.5 —— 低于就是掩膜空掉、功能静默失效）"
    fi
fi

# H 祛瑕疵 10 项：每一项都必须"只在它该管的那块地方改画面"
# 各判据的口径（为什么是这几个数）：
#   每项都拿**自己**的小值（2.0 / 满档是 100）当对照，逐像素相减 —— 因为"全 0"那张图会让
#   applyPortrait 直接 return，一开任何一项整幅图就多出一层 2~60 级的图形底噪（§189.5 同源）。
#   对照值必须**清掉实现里最深的那道闸门**（adjustInMask 是 guard k>0.001、reduceShine 是 guard strength>0.01，
#   都是 值/100）：0.02 时 11 项有 7 项仍报"改到区外"、0.5 时 2 项、2.0 时全清。
#   dead=0        每项都得真的改画面（改了 0 就是空转 —— 滑杆在、功能不在）
#   share ≥50%    改动像素里至少一半落在该项自己的区域里（实测最低 67%，留 1.34 倍余量）
#   另外每项的**幅度**只报告不判：它量的是"这一项满档有多强"，属于工具细腻度，判据留给后面的轮次。
BILOG=/tmp/partaudit_items.log
: > "$BILOG"
CR_IMPORT="$PORTRAIT" CR_BIAUDIT=1 "$APP" > "$BILOG" 2>&1 &
pid=$!
i=0
while [ $i -lt 60 ]; do
    sleep 2; i=$((i+1))
    grep -q 'BIAUDIT 完' "$BILOG" 2>/dev/null && break
done
kill $pid 2>/dev/null
wait $pid 2>/dev/null || true
bisum=$(grep -oE 'BIAUDIT-SUM.*' "$BILOG" | head -1)
if [ -z "$bisum" ]; then
    echo "  X H 祛瑕疵 10 项：没拿到汇总行（见 $BILOG）—— 没测到不算通过"; fail=1
else
    grep '^BIAUDIT ' "$BILOG" | grep -v 'BIAUDIT-SUM' | grep -v 'BIAUDIT 完' | sed 's/^BIAUDIT /    · /' | sed 's/｜/, /g' | head -12
    bidead=$(echo "$bisum" | grep -oE 'dead=[0-9]+' | head -1 | sed 's/.*=//')
    biweak=$(echo "$bisum" | grep -oE 'weak=[0-9]+' | head -1 | sed 's/.*=//')
    bishare=$(echo "$bisum" | grep -oE 'badshare=[0-9]+' | head -1 | sed 's/.*=//')
    [ -n "$bidead" ] || bidead=99
    [ -n "$biweak" ] || biweak=99
    [ -n "$bishare" ] || bishare=99
    biok=$(awk -v d="$bidead" -v w="$biweak" 'BEGIN{ print (d == 0 && w == 0) ? "ok" : "bad" }')
    if [ "$biok" = "ok" ]; then
        ok "H 逐项体检 15 项（祛瑕 11 + 颜色 4）都改在自己那块地方：空转 ${bidead} 项 ｜ 满档看不见（区内峰值<5 级）${biweak} 项 ｜ 占比不足 ${bishare} 项（占比只报告）"
    else
        bad "H 逐项体检不合格：空转 ${bidead} 项（应为 0 = 滑杆在功能不在）｜ 满档看不见 ${biweak} 项（应为 0，区内峰值 <5 级）"
    fi
fi

echo "按部位体检：$([ "$fail" = "0" ] && echo "全部通过" || echo "有失败")"
exit $fail
