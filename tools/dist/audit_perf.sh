#!/bin/sh
# 性能/内存回归体检：预览延迟（滑杆手感就是它决定的）+ 批量导出的峰值内存与吞吐。
#
# 为什么需要它：这个项目吃过一次大亏 —— 换天空曾经 74 秒/张（改完 0.3 秒）。
# 这类回归**不会**让任何功能测试变红，只会让用户觉得"卡"；而且它没有历史门。
# 判据刻意给足余量（这是"灾难性回归警报"，不是精确基准）：
#   A 预览中位延迟 < ${PREVIEW_MEDIAN_MAX:-300} ms（实测量级 8 ms，余量 ~37 倍）
#   B 预览 p95 < 10 × 中位（防抖动/长尾）
#   C 8 张批量导出：峰值 RSS < ${BATCH_RSS_MAX_MB:-3500} MB（灾难性泄漏警报）
#   D 8 张批量导出能跑完且吞吐 > 0.1 张/秒（不死锁、不极慢）
#
# 用法：sh tools/dist/audit_perf.sh
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
APP="$ROOT/app-retouch/.build/release/ContentRetouch"
IMG="$ROOT/douyin_favorites/images"
PHOTO="${1:-$IMG/0001_7673816620465215714_01.webp}"
DIR=/tmp/perf_audit_dir

[ -x "$APP" ] || { echo "先编译：cd app-retouch && swift build -c release"; exit 1; }
[ -f "$PHOTO" ] || { echo "缺夹具 $PHOTO —— 没测到不算通过"; exit 1; }

fail=0
ok()  { echo "  V $1"; }
bad() { echo "  X $1"; fail=1; }

# ── A/B 预览延迟 ───────────────────────────────────────────────
# 跑一次预览基准：$1=1 时用重参数档（磨皮/肤色/补光/暗角/颗粒/收腰），$2=标签
# 为什么要重参数这一档：只量空参数会得出"预览 8 ms、余量 35 倍"这种**偏乐观**的结论 ——
# 空参数下管线常常退化成"原图直出"，而真实修图是挂着效果的（实测 8.7 ms → 21.7 ms，2.5 倍）。
# 内部计时：这个门在 2026-09-26 发版时那一步耗了 955 秒，而它自己的**测量值全都正常**
# （7.46 / 19.43 / 13.53 ms）—— 说明时间花在"等"上，但从外面看不出是等等哪一段。
# 所以每段自己报耗时，下次直接看得出来。（门在忙机器上慢，不该靠猜。）
tmark() { printf "  · 耗时 %-22s %d 秒\n" "$1" "$(($(date +%s) - TMARK))"; TMARK=$(date +%s); }
TMARK=$(date +%s)

bench_once() {
    heavy="$1"; tag="$2"; photo="${3:-$PHOTO}"; z="${4:-0}"; log="/tmp/perf_bench_$tag.log"
    : > "$log"
    if [ "$heavy" = "1" ]; then
        CR_BENCH_HEAVY=1 "$APP" --import="$photo" --zoom="$z" --bench-preview=15 > "$log" 2>&1 &
    else
        "$APP" --import="$photo" --zoom="$z" --bench-preview=15 > "$log" 2>&1 &
    fi
    pid=$!
    i=0
    while [ $i -lt 30 ]; do
        sleep 2; i=$((i+1))
        grep -qE 'BENCH-SUM|预览性能' "$log" 2>/dev/null && break
    done
    kill $pid 2>/dev/null
    wait $pid 2>/dev/null || true
    grep -oE 'BENCH-SUM.*' "$log" | head -1
}

line=$(bench_once 0 plain)
tmark "空参数基准"
if [ -z "$line" ]; then bad "A 预览延迟：没拿到基准行（见 /tmp/perf_bench_plain.log）"
else
    echo "  · 空参数 $line"
    # ⚠️ 取字段必须用**带前导空格的完整键名**：汇总行里还有 render_median/crit_median/hist_median，
    # 用 '.*median=' 这种贪婪写法会取到最后一个（实测把 hist_median 1.48 ms 当成总中位，报了"假快"）。
    med=$(echo "$line" | grep -oE ' median=[0-9.]+' | head -1 | sed 's/.*=//')
    p95=$(echo "$line" | grep -oE ' p95=[0-9.]+' | head -1 | sed 's/.*=//')
    # ⚠️ 解析守卫：格式一变，sed 会静默给出垃圾（空串会被 awk 当成 0 → 假绿）。非数字直接判失败。
    case "$med.$p95" in
        *[!0-9.]*|.) bad "A 预览延迟：解析出的数字不合法（median=「${med}」 p95=「${p95}」）—— 基准行格式变了？"; fail=1 ;;
    esac
    if awk -v m="$med" 'BEGIN{exit !(m < 300)}'; then ok "A 预览中位延迟 ${med} ms（上限 300）"
    else bad "A 预览中位延迟 ${med} ms 超上限 300（灾难性变慢？）"; fi
    if awk -v m="$med" -v p="$p95" 'BEGIN{exit !(p < 10*m + 5)}'; then ok "B 预览 p95 ${p95} ms < 10×中位"
    else bad "B 预览 p95 ${p95} ms 相对中位 ${med} ms 过长尾（抖动）"; fi
    # F 量到的必须是**真的预览图**，不是占位图。
    # 为什么要有这条：基准在"图还没装好"时会拿占位图跑，量出 0.67 ms 这种"快得不可能"的数字，
    # 看着像性能提升、其实是根本没测到（2026-09-26 实测踩到）。work=WxH 由应用自报。
    work=$(echo "$line" | grep -oE 'work=[0-9]+x[0-9]+' | head -1 | sed 's/work=//')
    if [ -z "$work" ]; then
        bad "F 预览延迟：汇总行里没有 work=WxH（旧格式？）—— 分不清量的是不是真预览图"
    else
        wmax=$(echo "$work" | awk -Fx '{print ($1 > $2) ? $1 : $2}')
        if [ "$wmax" -ge 700 ]; then ok "F 量到的是真预览图（work=${work}）"
        else bad "F 量到的是占位图（work=${work}，长边 < 700）—— 这组延迟数字不能用"; fi
    fi
    nilr=$(echo "$line" | grep -oE 'nil_render=[0-9]+' | head -1 | sed 's/nil_render=//')
    if [ -n "$nilr" ] && [ "$nilr" -gt 0 ]; then bad "F' 有 $nilr 次出图失败（createCGImage 返回 nil）—— 出图耗时不可信"; fi
fi

# ── A'/G 重参数档（真实修图口径）────────────────────────────────
# 与空参数相比，重参数是"挂着磨皮/肤色/补光/颗粒/收腰"的情形 —— 用户拖滑杆时面对的就是它。
hlist=$(bench_once 1 heavy)
tmark "重参数基准"
if [ -z "$hlist" ]; then bad "A' 重参数预览：没拿到基准行（见 /tmp/perf_bench_heavy.log）"
else
    echo "  · 重参数 $hlist"
    hmed=$(echo "$hlist" | grep -oE ' median=[0-9.]+' | head -1 | sed 's/.*=//')
    hcrit=$(echo "$hlist" | grep -oE 'crit_median=[0-9.]+' | head -1 | sed 's/crit_median=//')
    hheavy=$(echo "$hlist" | grep -oE 'heavy=[0-9]' | head -1 | sed 's/heavy=//')
    [ -n "$hcrit" ] || hcrit=0
    if [ "$hheavy" != "1" ]; then
        bad "A' 重参数档没生效（应用自报 heavy=$hheavy）—— 这一档等于没测"
    elif awk -v m="$hmed" 'BEGIN{exit !(m < 300)}'; then ok "A' 重参数预览中位 $hmed ms (上限 300)"
    else bad "A' 重参数预览中位 $hmed ms 超上限 300"; fi
    # G 关键路径：总耗时里**会挡住界面**的那一段（图构建 + 出图），直方图已异步、不算在内。
    # 这才是"滑杆跟不跟手"的真身：实测 6MP 重参数 23 ms。
    if awk -v c="$hcrit" 'BEGIN{exit !(c < 300)}'; then
        ok "G 重参数关键路径 $hcrit ms (上限 300，直方图已异步不计)"
    else bad "G 重参数关键路径 $hcrit ms 超上限 300"; fi
fi

# ── G2 高倍 + 重参数（24MP 源片放到 400%）────────────────────────
# 为什么单列一档：§169 那个"掩膜降采样"只在工作图长边 >1600 时生效，fit 档根本测不到它。
# 这一档是它生效的现场：实测关键路径从 109 ms（不降采样）降到 ~20 ms。
RAW="$ROOT/HP7A4670.CR3"
if [ ! -f "$RAW" ]; then
    bad "G2 高倍档缺夹具 $RAW —— 没测到不算通过"
else
    zlist=$(bench_once 1 zoom400 "$RAW" 400)
    tmark "高倍基准"
    if [ -z "$zlist" ]; then bad "G2 高倍重参数：没拿到基准行（见 /tmp/perf_bench_zoom400.log）"
    else
        echo "  · 高倍(400%) $zlist"
        zcrit=$(echo "$zlist" | grep -oE ' crit_median=[0-9.]+' | head -1 | sed 's/.*=//')
        zwork=$(echo "$zlist" | grep -oE ' work=[0-9]+x[0-9]+' | head -1 | sed 's/.*=//')
        [ -n "$zcrit" ] || zcrit=9999
        # 判据：关键路径 <300 ms 之外，还要求"这一档确实是大图"（否则等于没测到降采样那条路）
        zwmax=$(echo "$zwork" | awk -Fx '{print ($1 > $2) ? $1 : $2}')
        if [ -z "$zwmax" ] || [ "$zwmax" -lt 1600 ]; then
            bad "G2 高倍档的工作图只有 $zwork（长边 <1600）—— 没走到掩膜降采样那条路，这一档没意义"
        elif awk -v c="$zcrit" 'BEGIN{exit !(c < 300)}'; then
            ok "G2 高倍(400%)关键路径 $zcrit ms (工作图 $zwork)"
        else bad "G2 高倍(400%)关键路径 $zcrit ms 超上限 300"; fi
    fi
fi

# ── I 祛瑕档：掩膜加强之后这一档的代价（§191）────────────────────
# 为什么单列：§191 把斑点掩膜加强了 5~33 倍（threshold 终于生效），掩膜一变强，
# bboxOfBright 的包围盒就可能越过 18/40px 门槛 ⇒ 算法从模糊填充换成样例修补甚至 LaMa。
# 这种代价在"空参数/重参数"两档里**完全看不见**（那两档根本没开祛瑕）——
# 不补这一档，以后谁把祛瑕改慢 10 倍，门都不会响。实测（门夹具 1050x1400）：
# 空参数 9.80 ms ／ 祛瑕三件套 11.11 ms ／ 单开鼻孔 8.72 ms。
for bmode in blemish nostril; do
    blog="/tmp/perf_bench_"$bmode".log"
    : > "$blog"
    CR_BENCH_ONLY="$bmode" "$APP" --import="$PHOTO" --zoom=0 --bench-preview=15 > "$blog" 2>&1 &
    pid=$!
    i=0
    while [ $i -lt 30 ]; do
        sleep 2; i=$((i+1))
        grep -qE 'BENCH-SUM' "$blog" 2>/dev/null && break
    done
    kill $pid 2>/dev/null
    wait $pid 2>/dev/null || true
    bline=$(grep -oE 'BENCH-SUM.*' "$blog" | head -1)
    if [ -z "$bline" ]; then
        bad "I 祛瑕档($bmode)：没拿到基准行（见 $blog）—— 没测到不算通过"
    else
        echo "  · 祛瑕档($bmode) $bline"
        bonly=$(echo "$bline" | grep -oE ' only=[A-Za-z_-]+' | head -1 | sed 's/.*=//')
        bmed=$(echo "$bline" | grep -oE ' median=[0-9.]+' | head -1 | sed 's/.*=//')
        [ -n "$bmed" ] || bmed=9999
        case "$bmed" in *[!0-9.]*) bmed=9999 ;; esac
        if [ "$bonly" != "$bmode" ]; then
            bad "I 祛瑕档($bmode)：应用自报 only=【$bonly】—— 这一档没真的开上（等于没测）"
        elif awk -v m="$bmed" 'BEGIN{exit !(m < 60)}'; then
            ok "I 祛瑕档($bmode) 预览中位 $bmed ms（上限 60，实测基线 8.7~11.1）"
        else
            bad "I 祛瑕档($bmode) 预览中位 $bmed ms 超上限 60 —— 掩膜/算法是不是变重了"
        fi
    fi
done
tmark "祛瑕档基准"

# ── H 掩膜降采样不许改画面（同一组参数，只换"掩膜在多大分辨率上算"）─────────
# 用 24MP RAW（工作图够大，才会真的走到降采样那条路）；没有就退回普通夹具，
# 但那样这一档测不到降采样 —— 所以打印出来说明，别让人误以为测过了。
if [ -f "$RAW" ]; then RAWFOR_MASK="$RAW"; else RAWFOR_MASK="$PHOTO"; echo "  · H 提示：没有 24MP RAW，用普通夹具测（工作图较小，可能走不到降采样那条路）"; fi
# 这是 §169 提速的**安全网**：提速 7 倍很容易，别把画质也提没了。
# 应用自报 MASKREDUCE-SUM maxdiff/meandiff（512px 采样）；判据：最大差 ≤2 级。
mlog=/tmp/perf_maskreduce.log
: > "$mlog"
CR_MASKREDUCE=1 CR_IMPORT="$RAWFOR_MASK" "$APP" --zoom=400 > "$mlog" 2>&1 &
mpid=$!
i=0
while [ $i -lt 30 ]; do
    sleep 2; i=$((i+1))
    grep -q 'MASKREDUCE-SUM' "$mlog" 2>/dev/null && break
done
kill $mpid 2>/dev/null
wait $mpid 2>/dev/null || true
tmark "掩膜等价性"
mline=$(grep -oE 'MASKREDUCE-SUM.*' "$mlog" | head -1)
if [ -z "$mline" ]; then
    bad "H 掩膜降采样等价性：没拿到 MASKREDUCE-SUM（见 $mlog）—— 没测到不算通过"
else
    echo "  · $mline"
    mdiff=$(echo "$mline" | grep -oE ' maxdiff=[0-9]+' | head -1 | sed 's/.*=//')
    [ -n "$mdiff" ] || mdiff=9999
    if [ "$mdiff" -le 2 ]; then ok "H 掩膜降采样不改画面：最大差 $mdiff 级（≤2）"
    else bad "H 掩膜降采样把画面改了：最大差 $mdiff 级（>2）—— 提速不能拿画质换"; fi
fi

# ── C/D/E 批量导出：峰值内存 + 吞吐 + 并行度是否真有收益 ────────────
rm -rf "$DIR"; mkdir -p "$DIR"
n=0
for f in $(ls "$IMG" | grep -E '\.(jpg|webp|png)$' | sort | awk 'NR % 173 == 1' | head -8); do
    cp "$IMG/$f" "$DIR/" ; n=$((n+1))
done
[ "$n" -ge 1 ] || { echo "  X C/D/E 批量导出：取不到夹具"; fail=1; n=0; }

# 跑一次批量导出：$1=并行度（空字符串=用应用默认），$2=标签
# 每次换一个**新的输入目录**：应用会跳过输出目录里已有的文件（断点续跑特性），
# 复用目录会让第二轮变成"0 张 0.00 s"，看着像变快了、其实什么都没干（本轮实测踩到）。
batch_run() {
    w="$1"; tag="$2"
    bin="/tmp/perf_batchin_$tag"; out="/tmp/perf_batch_$tag.log"
    rm -rf "$bin"; mkdir -p "$bin"; cp "$DIR"/* "$bin"/
    : > "$out"
    if [ -n "$w" ]; then
        CR_IMPORT="$PHOTO" "$APP" --run=export:"$bin" --export-workers="$w" > "$out" 2>&1 &
    else
        CR_IMPORT="$PHOTO" "$APP" --run=export:"$bin" > "$out" 2>&1 &
    fi
    pid=$!; peak=0; t0=$(date +%s)
    while kill -0 $pid 2>/dev/null; do
        rss=$(ps -o rss= -p $pid 2>/dev/null | tr -d ' ')
        [ -n "$rss" ] && [ "$rss" -gt "$peak" ] && peak=$rss
        grep -q '导出完成' "$out" 2>/dev/null && break
        sleep 0.3
    done
    kill $pid 2>/dev/null
    wait $pid 2>/dev/null || true
    t1=$(date +%s); dt=$((t1 - t0)); [ "$dt" -lt 1 ] && dt=1
    dn=$(grep -oE '导出完成：[0-9]+ 张' "$out" | grep -oE '[0-9]+' | head -1)
    [ -n "$dn" ] || dn=0
    # 用应用自报的导出耗时（只算导出那一段、两位小数）；墙钟只有秒级精度，
    # 而两次的差别就在 0.7 s 对 1.5 s —— 拿墙钟比会看不出差异。
    as=$(grep -oE '张 [0-9.]+ s（' "$out" | head -1 | grep -oE '[0-9.]+')
    [ -n "$as" ] || as=0
    wk=$(grep -oE '并行 [0-9]+' "$out" | head -1 | grep -oE '[0-9]+')
    [ -n "$wk" ] || wk=?
    echo "$dt $((peak / 1024)) $dn $as $wk"
}

if [ "$n" -ge 1 ]; then
    sline=$(batch_run 1 serial)
    tmark "批量串行"
    set -- $sline; s_mb=$2; s_n=$3; s_s=$4
    echo "  · 批量 $n 张 串行（--export-workers=1）：峰值 RSS $s_mb MB ｜ 导出 $s_s s ｜ 成功 $s_n 张"
    if [ "$s_mb" -lt "${BATCH_RSS_MAX_MB:-3500}" ]; then ok "C 批量峰值内存 $s_mb MB（上限 3500）"
    else bad "C 批量峰值内存 $s_mb MB 超上限 3500（可能内存泄漏）"; fi
    speed=$(awk -v d="$s_n" -v t="$1" 'BEGIN{print (t<=0)?d:(d/t)}')
    if awk -v s="$speed" 'BEGIN{exit !(s > 0.1)}'; then ok "D 批量跑完：$s_n/$n 张，吞吐 $speed 张/秒"
    else bad "D 批量吞吐过低：$s_n/$n 张，$speed 张/秒"; fi

    pline=$(batch_run "" default)
    tmark "批量默认并行度"
    set -- $pline; p_dt=$1; p_mb=$2; p_n=$3; p_s=$4; p_w=$5
    echo "  · 批量 $n 张 应用默认并行度（$p_w 路）：峰值 RSS $p_mb MB ｜ 导出 $p_s s ｜ 成功 $p_n 张"
    if [ "$p_mb" -lt "${BATCH_RSS_MAX_MB:-3500}" ]; then ok "C' 默认并行度峰值内存 $p_mb MB（上限 3500）"
    else bad "C' 默认并行度峰值内存 $p_mb MB 超上限 3500"; fi

    # ── C'' 大文件批量：40MP 级的片子不能被 6MP 夹具那一档代表 ──────────
    # 为什么单列：C/C' 的夹具是 6MP 级（2160x2880），而真正会顶爆内存的是 40MP 级 ——
    # 两者差一个量级。§195 实测：40MP 只导入 441 MB ｜ 单张 8 位 JPEG 导出 667 MB ｜
    # 单张 16 位 TIFF 622 MB ｜ **4 张 40MP 批量 1389~1507 MB**。
    # 上限 2500 MB = 实测 1507 的 1.66 倍余量。
    BIGM=""
    if [ -f "$ROOT/douyin_favorites/images/0049_7658970207381179702_04.webp" ]; then
        BIGM="$ROOT/douyin_favorites/images/0049_7658970207381179702_04.webp"
    else
        BIGM=$(ls -S "$ROOT"/douyin_favorites/images/*.webp 2>/dev/null | head -1)
    fi
    if [ -n "$BIGM" ] && [ -f "$BIGM" ]; then
        bd=/tmp/perf_bigbatch; rm -rf "$bd"; mkdir -p "$bd"
        for bi in 1 2 3 4; do cp "$BIGM" "$bd/p$bi.webp"; done
        blog=/tmp/perf_bigbatch.log
        : > "$blog"
        CR_IMPORT="$bd/p1.webp" "$APP" --run=export:"$bd" > "$blog" 2>&1 &
        bpid=$!; bpeak=0
        while kill -0 $bpid 2>/dev/null; do
            rss=$(ps -o rss= -p $bpid 2>/dev/null | tr -d ' ')
            [ -n "$rss" ] && [ "$rss" -gt "$bpeak" ] && bpeak=$rss
            grep -q '导出完成' "$blog" 2>/dev/null && break
            sleep 0.3
        done
        kill $bpid 2>/dev/null; wait $bpid 2>/dev/null || true
        bmb=$((bpeak / 1024))
        bn=$(grep -oE '导出完成：[0-9]+ 张' "$blog" | grep -oE '[0-9]+' | head -1); [ -n "$bn" ] || bn=0
        echo "  · 大文件批量 4 张 40MP：峰值 RSS $bmb MB ｜ 成功 $bn 张"
        if [ "$bn" -lt 1 ]; then bad "C'' 大文件批量：一张都没导出（见 $blog）—— 没测到不算通过"
        elif [ "$bmb" -lt "${BIG_RSS_MAX_MB:-2500}" ]; then ok "C'' 大文件批量峰值内存 $bmb MB（上限 2500，实测基线 1389~1507）"
        else bad "C'' 大文件批量峰值内存 $bmb MB 超上限 2500 —— 大文件这条路的内存是不是爆了"; fi
        tmark "大文件批量"
    else
        echo "  · C'' 跳过：找不到大图夹具"
    fi
    # E1 **确定性**判据：默认并行度（应用自报）必须 ≥2。
    # 为什么用"自报值"而不是计时：计时在忙机器上不可靠 —— 同一份代码实测：
    #   空载 5 次：默认 4 路 0.75~1.31 s，串行 1.22~2.05 s（比值 0.50~0.69）
    #   发版时（编译/体检压着机器）2 次：1.88 对 2.08（0.90）、2.72 对 2.61（1.04，并行反而更慢）
    # 也就是"并行有没有收益"在被占满的机器上量不出来（8 核都忙时 4 路只是多一份争用）。
    # 而"默认值被改回 1"是**确定性回归**：读自报值就能抓住，且不受负载影响。
    case "$p_w" in
        ''|*[!0-9]*) bad "E1 读不到默认并行度（自报「${p_w}」）—— 基准行格式变了？" ;;
        *) if [ "$p_w" -ge 2 ]; then ok "E1 默认并行度是多路（$p_w 路）"
           else bad "E1 默认并行度是 $p_w 路（=串行）—— 批量吞吐会少 1.7 倍，默认值被改回去了？"; fi ;;
    esac
    if [ "$p_n" != "$n" ]; then bad "E2 默认并行度没跑完：$p_n/$n 张"
    else
        # 计时对比**只作信息，不作判据** —— 这一条是拿两次假红换来的结论：
        #   同一份代码，空载 5 次：0.50~0.69；发版时被编译/体检压着 2 次：0.90、1.04（并行反而更慢）。
        # "并行是否更快"在 8 核被占满时量不出来（多出来的 worker 只是多一份争用），
        # 把它当硬判据 = 让门在忙机器上假红（9.10.27/9.10.28 两次发版都这么红过）。
        # 所以：真正守住回归的是确定性的 E1（默认值是不是多路），吞吐只打印给人看。
        ratio=$(awk -v a="$p_s" -v b="$s_s" 'BEGIN{ if (b<=0) print "9.00"; else printf "%.2f", a/b }')
        echo "  · E2 并行收益（信息，不判分）：默认 $p_w 路 $p_s s 对串行 $s_s s（比值 ${ratio}）；空载下该值应 ~0.5~0.7，被机器压着时会接近 1"
    fi
fi

echo "性能体检：$([ "$fail" = "0" ] && echo "全部通过" || echo "有失败")"
exit $fail
