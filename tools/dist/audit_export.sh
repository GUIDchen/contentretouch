#!/bin/sh
# 导出通路的门：**用户真正拿到的东西**。
#
# 为什么需要它：coretest 验核心函数、体检表验参数、工具体检验交互状态，
# 而"导出的那张图对不对"以前只有人导一张看一眼。账本里恰好记过一次
# 「导出走的是另一条私有链，裁剪/液化/祛痘/换天空/降噪/锐化/暗角/颗粒/镜头校正全都没做」。
#
# 三条判据（每条一次独立导出，互不影响）：
#   A 全分辨率通路：导出图存在，且尺寸 == 原片（不被预览尺寸带偏）
#   B 裁剪进导出：--simulate=crop（0.15~0.65 = 50%）→ 导出图宽高约为原片一半
#   C 手动编辑进导出：--simulate=liquify（3 笔推动，半径 12%）→ 导出图与原片有可测差异
#     （不用 spot：污点修复是把一小块的**附近纹理搬过来**，落在干净皮肤上像素几乎不变 ——
#      工具体检里 spot 峰值只有 8，拿它当判据会把"修好了"误判成"没进导出"）
#
# 用法：sh tools/dist/audit_export.sh
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
APP="$ROOT/app-retouch/.build/release/ContentRetouch"
SRC="${1:-$ROOT/douyin_favorites/images/0001_7673816620465215714_01.webp}"
MAGICK=${MAGICK:-/opt/homebrew/bin/magick}

[ -x "$APP" ] || { echo "先编译：cd app-retouch && swift build -c release"; exit 1; }
[ -f "$SRC" ] || { echo "缺夹具 $SRC —— 没测到不算通过"; exit 1; }
[ -x "$MAGICK" ] || { echo "缺 magick（brew install imagemagick）"; exit 1; }

set -- $($MAGICK identify -format "%w %h" "$SRC")
SW=$1; SH=$2
echo "夹具：$(basename "$SRC")（$SW x ${SH}）"

fail=0
ok()  { echo "  V $1"; }
# ⚠️ bad() 一直**没有定义**（只有 ok）—— 所有失败分支一执行就是 `bad: command not found` + 退出码 127，
# 报出来的既不是判据失败也不是判据通过，而是一句"命令找不到"（§193 第一次走到失败分支才发现）。
bad() { echo "  X $1"; fail=1; }
run_case() {
    name=$1; sim=$2; extra=$3; srcOverride=$4
    d=/tmp/expcheck_$name; log=/tmp/expcheck_$name.log
    rm -rf "$d" "$log"; mkdir -p "$d"
    cp "${srcOverride:-$SRC}" "$d/src.webp"     # 第 4 个参数可以换源图（大图用例要用）
    # ⚠️ 必须 --import：simulateTool 开头就是 `guard srcURL != nil`，
    # 没有工作图时它**静默返回**（日志里连"自检 --simulate"都不会有），
    # 于是"裁剪进导出"这条会假装在测、其实什么都没模拟 —— 踩过一次。
    if [ -n "$sim" ]; then
        ("$APP" --import="$d/src.webp" --simulate="$sim" --run=export:"$d" $extra > "$log" 2>&1 &)
    else
        ("$APP" --import="$d/src.webp" --run=export:"$d" $extra > "$log" 2>&1 &)
    fi
    i=0
    while [ $i -lt 40 ]; do
        sleep 2; i=$((i+1))
        grep -q '导出完成' "$log" 2>/dev/null && break
    done
    pkill -f 'release/ContentRetouch' >/dev/null 2>&1 || true
    sleep 1
}
# 产物可能是 jpg/png/tif —— 别只找 jpg/png（tiff 那条会取不到文件）
out_of() { ls "/tmp/expcheck_$1/retouched/"* 2>/dev/null | head -1; }
# ⚠️ magick 的输出是**科学计数法**（6.21857e+06），用 sed 去掉非数字只会拿到开头的 "6" ——
# 于是"改了 99.96% 的像素"被读成"只有 6 个像素变了"（踩过，差点把好功能判成坏的）。交给 awk 转整数。
ae_between() {
    $MAGICK compare -metric AE -fuzz 2% "$1" "$2" null: 2>&1 | awk 'NR==1{printf "%d", $1+0}'
}

# A 全分辨率通路
run_case plain ""
O=$(out_of plain)
if [ -z "$O" ]; then echo "  X A 全分辨率通路：没导出任何文件"; fail=1
else
    set -- $($MAGICK identify -format "%w %h" "$O")
    OW=$1; OH=$2
    if [ "$OW" = "$SW" ] && [ "$OH" = "$SH" ]; then
        echo "  V A 全分辨率通路：导出 $OW x ${OH}（与原片一致）"
    else
        echo "  X A 全分辨率通路：导出 $OW x ${OH}，原片 $SW x ${SH}（尺寸对不上）"; fail=1
    fi
fi

# B 裁剪进导出
run_case crop crop
O=$(out_of crop)
if [ -z "$O" ]; then echo "  X B 裁剪进导出：没导出任何文件"; fail=1
else
    set -- $($MAGICK identify -format "%w %h" "$O")
    OW=$1; OH=$2
    wantW=$((SW / 2)); wantH=$((SH / 2))
    dw=$((OW - wantW)); dh=$((OH - wantH))
    [ $dw -lt 0 ] && dw=$((0 - dw)); [ $dh -lt 0 ] && dh=$((0 - dh))
    if [ $dw -le 2 ] && [ $dh -le 2 ]; then
        echo "  V B 裁剪进导出：导出 $OW x ${OH}（裁剪框 50% → 期望 $wantW x ${wantH}）"
    else
        echo "  X B 裁剪进导出：导出 $OW x ${OH}，期望约 $wantW x ${wantH}（裁剪没进导出）"; fail=1
    fi
fi

# C 手动编辑（液化形变）进导出
# ⚠️ 对照必须是**另一次导出**，不是原片：导出走的是 JPEG + 本图自适应，
# 与原片本来就全图不同（实测无编辑那版与原片 AE 也是 620 万）—— 拿原片当对照等于恒真。
run_case liquify liquify
O=$(out_of liquify); P=$(out_of plain)
if [ -z "$O" ] || [ -z "$P" ]; then echo "  X C 手动编辑进导出：缺导出文件"; fail=1
else
    ae=$(ae_between "$P" "$O")
    if [ "${ae:-0}" -ge 10000 ]; then
        echo "  V C 手动编辑进导出：与"无编辑"那版有 $ae 个像素不同（3 笔液化确实进了导出）"
    else
        echo "  X C 手动编辑进导出：与"无编辑"那版只有 ${ae:-0} 个像素不同（液化笔没进导出）"; fail=1
    fi
    # 信息行：污点修复是把附近纹理搬过来，落在干净皮肤上本来就几乎不改像素（实测 504），
    # 所以它**不适合当判据**，但数字值得留档。
    run_case spot spot
    S=$(out_of spot)
    if [ -n "$S" ]; then echo "  · 参考：污点修复那版与"无编辑"差 $(ae_between "$P" "$S") 个像素（局部修复本就不该大改）"; fi
fi

# D 批量导出必须带上**只有 LOGO**的水印
# ⚠️ 这条是踩出来的：核心 exportBatch 的判据原来只写 `if !watermarkText.isEmpty`，
# 于是"只设 LOGO、不填文字"时批量导出一个水印都不加（单张导出判的是两者之一）——
# 两条路行为不一致。负向验证过：旧写法下批量导出与"完全没设水印"逐像素相同（差异包围盒 0x0）。
LOGO=/tmp/audit_export_logo.png
if [ -x "$MAGICK" ]; then
    $MAGICK -size 200x80 xc:none -fill red -draw "roundrectangle 4,4 196,76 12,12" "$LOGO" 2>/dev/null || true
fi
if [ -f "$LOGO" ]; then
    run_case watermark "" "--watermark-image=$LOGO"
    O=$(out_of watermark); P=$(out_of plain)
    if [ -z "$O" ] || [ -z "$P" ]; then echo "  X D 批量导出带 LOGO 水印：缺导出文件"; fail=1
    else
        # 只比右下角（水印默认位置 bottom-right，LOGO 宽 = 长边 14%）
        # ⚠️ 别用 ${TMP}：那是 ui_baseline.sh 里的变量，这个脚本没有 —— 路径落到根目录、裁剪静默失败、
        # 两个不存在的文件比出 0 差异（踩过：D 恒报"LOGO 没进导出"，其实是脚本自己写错了）
        $MAGICK "$O" -gravity southeast -crop 30%x30%+0+0 +repage -resize 200x200 /tmp/audit_export_wm_a.png 2>/dev/null || true
        $MAGICK "$P" -gravity southeast -crop 30%x30%+0+0 +repage -resize 200x200 /tmp/audit_export_wm_b.png 2>/dev/null || true
        if [ ! -s /tmp/audit_export_wm_a.png ] || [ ! -s /tmp/audit_export_wm_b.png ]; then
            echo "  X D 批量导出带 LOGO 水印：裁剪失败（脚本问题，不是产品问题）"; fail=1
        else
        ae=$(ae_between /tmp/audit_export_wm_a.png /tmp/audit_export_wm_b.png)
        # ⚠️ 只比"有没有差异"抓不到**黑块**：LOGO 的透明背景要是被当成"不透明的黑"，
        # 差异照样有几万个像素、判据照样通过（实测过：水印区平均亮度 0.013 = 全黑，门却是绿的）。
        # 所以再加一条：水印**不许**把角落压得比原图更暗（透明区应当透出底图）。
        # 判据选"LOGO 框里有没有红光"：夹具 LOGO 是**红圆角块 + 透明背景**，所以
        #   修好的导出：R−G 明显为正（实测 20% 裁剪处 0.084）
        #   透明被压成黑块：整框变黑 → R−G ≈ 0（实测无水印那版是 −0.003）
        # 为什么不用"最暗像素"当判据：照片角落本来就有纯黑像素，两边都是 0，那条判据**没有牙齿**
        #（第一版就是这么写的，实测打印出 "最暗 0 vs 原图 0" —— 门是绿的，但什么也没守住）。
        red=$($MAGICK /tmp/audit_export_wm_a.png -gravity southeast -crop 20%x20%+0+0 +repage \
              -format '%[fx:mean.r-mean.g]' info: 2>/dev/null)
        redok=$(awk -v r="$red" 'BEGIN{ if (r == "") print "?"; else print (r + 0 >= 0.02) ? "ok" : "bad" }')
        if [ "${ae:-0}" -ge 500 ] && [ "$redok" = "ok" ]; then
            echo "  V D 批量导出带 LOGO 水印：右下角与无水肿那版有 $ae 个像素不同，且 LOGO 透明区没被压黑（红光成分 $red ≥ 0.02）"
        elif [ "${ae:-0}" -lt 500 ]; then
            echo "  X D 批量导出带 LOGO 水印：右下角只有 ${ae:-0} 个像素不同（LOGO 没进批量导出）"; fail=1
        else
            echo "  X D 批量导出带 LOGO 水印：LOGO 框里没有红光（R−G=$red）—— 透明 PNG 的 alpha 丢了，透明区变成了黑块"; fail=1
        fi
        fi
    fi
else
    echo "  · D 跳过：没找到 magick，造不出测试 LOGO"
fi

# D2 水印配了但用不了 → 必须**说出来**，不许静默不打
# 为什么要有这条：LOGO 路径写错/文件被移走时，导出会照常报"导出完成"，
# 产物与"完全没设水印"逐像素一致 —— 对"交付带水印的成片"来说这是最坏的一种失败（§177）。
run_case wmmiss "" "--watermark-image=/tmp/definitely_no_such_logo.png"
if grep -aq '没有' /tmp/expcheck_wmmiss.log 2>/dev/null && grep -aq '水印' /tmp/expcheck_wmmiss.log 2>/dev/null; then
    ok "D2 水印 LOGO 不存在时如实报告（$(grep -a '水印' /tmp/expcheck_wmmiss.log | head -1 | cut -c1-44)）"
else
    bad "D2 水印 LOGO 不存在时**没有任何提示** —— 用户会以为成片打了水印（看了 /tmp/expcheck_wmmiss.log）"
fi

# E 导出设置矩阵：每一项都有**可算的真值**（长边/格式/位深/命名模板/色彩空间/质量）
# 为什么值得单列：这些设置全都在 exportImage 里用，但"设置到底有没有生效"以前没人验过。
# 其中质量那条还对应一个历史 bug（账本记过："95/75/50 三档产出的字节数一模一样"）。
set_check() {   # $1=标签 $2=期望说明 $3=实际值 $4=期望值
    if [ "$3" = "$4" ]; then echo "  V E ${1}：$2 = $3"
    else echo "  X E ${1}：$2 期望 ${4}，实际 $3"; fail=1; fi
}

run_case le1600 "" "--export-long-edge=1600"
O=$(out_of le1600)
if [ -n "$O" ]; then
    set_check "长边 1600" "长边" "$($MAGICK identify -format '%[fx:max(w,h)]' "$O" 2>/dev/null)" "1600"
else echo "  X E 长边 1600：没导出文件"; fail=1; fi

run_case pngout "" "--export-format=png"
O=$(out_of pngout)
if [ -n "$O" ]; then
    set_check "格式 PNG" "扩展名" "${O##*.}" "png"
    set_check "格式 PNG" "格式" "$($MAGICK identify -format '%m' "$O" 2>/dev/null)" "PNG"
else echo "  X E 格式 PNG：没导出文件"; fail=1; fi

run_case tiff16 "" "--export-format=tiff --export-bit-depth=16"
O=$(out_of tiff16)
if [ -n "$O" ]; then
    set_check "TIFF 16 位" "位深" "$($MAGICK identify -format '%z' "$O" 2>/dev/null)" "16"
else echo "  X E TIFF 16 位：没导出文件"; fail=1; fi

run_case tpl "" "--export-name-template=作品_{index}"
O=$(out_of tpl)
if [ -n "$O" ]; then
    set_check "命名模板 {index}" "文件名" "$(basename "$O")" "作品_1.jpg"
else echo "  X E 命名模板：没导出文件"; fail=1; fi

run_case p3 "" "--export-color-space=DisplayP3"
O=$(out_of p3)
P=$(out_of plain)
if [ -n "$O" ] && [ -n "$P" ]; then
    # 这个版本的 identify 里 %[profile:icc] 输出的是**配置文件描述**（P3 版是 "Display P3"，sRGB 版空）
    p3desc=$($MAGICK identify -format '%[profile:icc]' "$O" 2>/dev/null || true)
    srgbdesc=$($MAGICK identify -format '%[profile:icc]' "$P" 2>/dev/null || true)
    case "$p3desc" in
        *P3*) ok_p3=1 ;;
        *) ok_p3=0 ;;
    esac
    if [ "$ok_p3" = "1" ] && [ -z "$srgbdesc" ]; then
        echo "  V E 色彩空间 DisplayP3：P3 版带 ICC 配置文件（描述「${p3desc}」），sRGB 版不带"
    else
        echo "  X E 色彩空间 DisplayP3：P3 版描述「${p3desc}」、sRGB 版描述「${srgbdesc}」"; fail=1
    fi
else echo "  X E 色彩空间：缺导出文件"; fail=1; fi

run_case q60 "" "--export-quality=60"
O=$(out_of q60)
if [ -n "$O" ] && [ -n "$P" ]; then
    # 质量必须真的影响输出（历史 bug：三档字节数一模一样）
    if [ "$(wc -c < "$O")" -lt "$(wc -c < "$P")" ]; then
        echo "  V E 质量 60：$(wc -c < "$O" | tr -d ' ') 字节 < 默认质量 95 的 $(wc -c < "$P" | tr -d ' ') 字节"
    else
        echo "  X E 质量 60：字节数没有变小（质量设置没生效）"; fail=1
    fi
else echo "  X E 质量：缺导出文件"; fail=1; fi

# F 大图全分辨率：40MP 的片子必须**原尺寸**导出，且要能跑完（这条比账本里手工验过的 24MP 更大）
BIG="$ROOT/douyin_favorites/images/0049_7658970207381179702_04.webp"
if [ ! -f "$BIG" ]; then
    BIG=$(ls -S "$ROOT"/douyin_favorites/images/*.webp 2>/dev/null | head -1)
fi
if [ -f "$BIG" ]; then
    read -r BW BH <<EOF
0 0
EOF
    set -- $($MAGICK identify -format "%w %h" "$BIG" 2>/dev/null)
    BW=$1; BH=$2
    mp=$(awk -v a="$BW" -v b="$BH" 'BEGIN{printf "%.0f", a*b/1e6}')
    if [ "${mp:-0}" -lt 8 ]; then
        echo "  · F 跳过：库里最大的夹具只有 ${mp}MP（大图用例需要 ≥8MP）"
    else
        t0=$(date +%s)
        run_case big "" "" "$BIG"
        t1=$(date +%s)
        O=$(out_of big)
        if [ -z "$O" ]; then bad "F 大图（${mp}MP）：没导出文件（超时或失败）"
        else
            set -- $($MAGICK identify -format "%w %h" "$O" 2>/dev/null)
            OW=$1; OH=$2
            if [ "$OW" = "$BW" ] && [ "$OH" = "$BH" ]; then
                ok "F 大图全分辨率：${BW}x${BH}（${mp}MP）→ 导出同尺寸，用时 $((t1 - t0)) 秒"
            else
                bad "F 大图：导出 ${OW}x${OH}，原片 ${BW}x${BH}（大图被偷偷缩了？）"
            fi
        fi
    fi
else
    echo "  · F 跳过：找不到大图夹具"
fi

# J 原图无损：**没有做任何编辑**、又选了无损格式时，导出的像素必须与源逐点一致
# 为什么单列：前面每条都在验"参数有没有生效"（尺寸/格式/位深/命名/色彩空间/质量），
# 而"用户什么都没改、只想另存一张无损图"这条路上会不会偷偷掉精度，从来没人验过 ——
# 这是"原图无损"承诺的最后一环（前几环：16 位导入、RAW 路径、EXIF 方向都已验过）。
# 夹具**当场造**：把门夹具转成 16 位 sRGB PNG（源是 JPEG 的话源本身就有损，判据没有意义）。
d=/tmp/expcheck_lossless
rm -rf "$d"; mkdir -p "$d"
# ⚠️ 真 16 位要写 -define png:bit-depth=16：只写 -depth 16 时 magick 出来的仍是 8 位（实测），
# 那样"16 位往返"这条判据就是空的。
"$MAGICK" "$SRC" -colorspace sRGB -define png:bit-depth=16 -depth 16 "$d/src.png" 2>/dev/null
LBD0=$($MAGICK identify -format '%z' "$d/src.png" 2>/dev/null)
if [ ! -f "$d/src.png" ]; then
    bad "J 原图无损：造不出 16 位 PNG 夹具（magick 失败）"
elif [ "$LBD0" != "16" ]; then
    bad "J 原图无损：夹具不是 16 位（实际 $LBD0）—— 这条判据会落空，先修夹具"
else
    for lfmt in png tiff; do
        LLOG="/tmp/expcheck_lossless_$lfmt.log"
        : > "$LLOG"
        # ⚠️ `--run=export:<dir>` 的语义是"**导出这个目录里的图**"，所以这里必须传**源所在目录**。
        # 传一个空目录时它一声不响地什么都不做（界面状态栏有字、stderr 没有）——
        # 这属于"没测到 = 通过"，本轮已让它在 stderr 如实报告（见 Export.swift 的 exportFolderAt）。
        rm -rf "$d/retouched"
        ("$APP" --import="$d/src.png" --run=export:"$d" --export-format="$lfmt" --export-bit-depth=16 > "$LLOG" 2>&1 &)
        i=0
        while [ $i -lt 40 ]; do
            sleep 2; i=$((i+1))
            grep -q '导出完成' "$LLOG" 2>/dev/null && break
        done
        pkill -f 'release/ContentRetouch' >/dev/null 2>&1 || true
        sleep 1
        LO=$(ls "$d/retouched/"* 2>/dev/null | head -1)
        if [ -z "$LO" ]; then
            bad "J 原图无损($lfmt)：没有导出文件（见 $LLOG）"
        else
            # magick 的输出可能是科学计数法，交给 awk 转整数（这个坑踩过，见本文件开头的 ae_between）
            LAE=$($MAGICK compare -metric AE "$d/src.png" "$LO" null: 2>&1 | awk 'NR==1{printf "%d", $1+0}')
            # ⚠️ compare 的输出是 "2749.9 (0.04196)"：**绝对值在前、归一值在括号里**，
            # 取 $1 会拿到 2749.9 那种绝对值（判据阈值是按 0~1 定的，直接判会永远红）。
            LRM=$($MAGICK compare -metric RMSE "$d/src.png" "$LO" null: 2>&1 | awk -F'[()]' 'NR==1{print $2}')
            [ -n "$LAE" ] || LAE=999999
            LBD=$($MAGICK identify -format '%z' "$LO" 2>/dev/null)
            # 判据分两档（§194 定的口径）：
            #   · 逐点一致（AE=0）当然是理想，但**导出会做一次"本图自适应曝光"**（实测 +4 级左右），
            #     所以逐点一致在本设计下不成立 —— 硬要求 AE=0 会把一个已知设计当成 bug 长期卡红。
            #   · 于是判"**色调有没有整体跑掉**"：RMSE ≤0.15 且 相对均值偏差 ≤25%。
            # 实测（修复后）= RMSE 0.0435、均值 0.547 vs 源 0.504（+8.6%）⇒ 余量 3.4 倍。
            # 而 §194 那个 bug 的数值是 RMSE 0.44、均值 0.079（−84%）⇒ 这条判据一眼就能抓住它。
            # ⚠️ 均值必须只看 **R 通道**：源是 3 通道、导出常带 alpha（alpha=1），
            # 用 %[fx:mean]（全通道平均）算出来会平白高 30%（实测 0.496 vs 0.653）—— 差的是通道数，不是画面。
            LMEAN_S=$($MAGICK "$d/src.png" -format '%[fx:mean.r]' info: 2>/dev/null)
            LMEAN_O=$($MAGICK "$LO" -format '%[fx:mean.r]' info: 2>/dev/null)
            LREL=$(awk -v a="$LMEAN_S" -v b="$LMEAN_O" 'BEGIN{ if (a + 0 == 0) { print 999 } else { printf "%.4f", (b - a) / a } }')
            # 解析守卫：LRM 已经是括号里的归一值；空串/非数字必须**判失败**而不是当成 0
            #（本项目踩过多次："格式一变，sed 静默给出垃圾，空串被 awk 当成 0 ⇒ 假绿"）
            case "$LRM" in
                ''|*[!0-9.]*) bad "J 原图无损($lfmt)：RMSE 解析失败（原始「$LRM」）—— 判据格式变了？"; LRMN=9 ;;
                *) LRMN=$LRM ;;
            esac
            [ -n "$LBD" ] || LBD=未知
            # ⚠️ 阈值在 §207 收紧过一次：原来定 RMSE ≤0.15 / 均值偏差 ≤25%，
            # 是因为当时导出会做一档"本图自适应曝光"（无编辑也 +8%~12%）。§207 让它只在
            # 真有调色目标时才生效之后，无编辑导出已经**逐点等于源**（实测 RMSE 1.1e-4 / 7.8e-5）。
            # 所以现在按"原图无损"的字面口径判：RMSE ≤0.002 且 |均值偏差| ≤1%
            #（实测余量约 20 倍；而两次真实的 bug 是 RMSE 0.44 与 0.042 —— 都逃不掉）。
            LOK=$(awk -v r="$LRMN" -v rel="$LREL" 'BEGIN{ ar = (rel < 0 ? -rel : rel); print (r <= 0.002 && ar <= 0.01) ? "ok" : "bad" }')
            if [ "$LAE" = "0" ]; then
                ok "J 原图无损($lfmt)：无编辑导出与原图逐点一致（AE=0，位深 $LBD）"
            elif [ "$LOK" = "ok" ]; then
                # ⚠️ 变量后面紧跟中文时必须写"美元花括号"形式：POSIX shell 会吃掉紧跟的汉字首字节
                #（本项目 §165 记过这条，51 处；这里又踩了一次 —— 显示成"位深 ??RMSE ??"）
                ok "J 原图无损($lfmt)：无编辑导出与源同色调（位深 ${LBD}，RMSE ${LRMN}，均值偏差 $(awk -v r="$LREL" 'BEGIN{printf "%.0f%%", r*100}')）"
            else
                bad "J 原图无损($lfmt)：无编辑导出**色调整体跑掉**了（位深 ${LBD}，RMSE ${LRMN} 应 ≤0.15，均值偏差 $(awk -v r="$LREL" 'BEGIN{printf "%.0f%%", r*100}') 应 ≤25%）—— 源 $d/src.png ｜ 导出 $LO"
            fi
        fi
    done
fi

# K 导出目录里没有可导出的图时，必须**在 stderr 如实说明**
# 为什么单列：`--run=export:<dir>` 的语义是"导出这个目录里的图"。指错目录时它原来只写界面状态栏、
# stderr 一个字都没有 —— 在自动化里表现为"静默成功"，本轮就因此把"目录里没有图"误判成"导出卡死"，
# 白白查了二十分钟。这与本项目历史那几次（水印 LOGO 缺失 / 挑图目录不存在 / CLI 路径打错）是同一类坑。
rm -rf /tmp/expcheck_empty; mkdir -p /tmp/expcheck_empty
ELOG=/tmp/expcheck_empty.log
: > "$ELOG"
("$APP" --import="$SRC" --run=export:/tmp/expcheck_empty > "$ELOG" 2>&1 &)
i=0
while [ $i -lt 25 ]; do
    sleep 1; i=$((i+1))
    grep -q '可导出' "$ELOG" 2>/dev/null && break
done
pkill -f 'release/ContentRetouch' >/dev/null 2>&1 || true
sleep 1
if grep -aq '没有可导出的图' "$ELOG" 2>/dev/null; then
    ok "K 空目录如实报告（导出目录里没有图时在 stderr 说明，不再静默空转）"
else
    bad "K 空目录**没有任何提示** —— 指错导出目录时会表现为静默成功（自动化里看不出来）"
fi

echo "导出体检：A/B/C/D + E 设置矩阵 + F 大图 + J 原图无损 + K 空目录如实报告"$([ "$fail" = "0" ] && echo "全部通过" || echo "有失败")
exit $fail
