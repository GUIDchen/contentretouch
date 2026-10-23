#!/bin/sh
# 多图参数体检：在若干张不同内容的照片上跑 CR_AUDIT，合并成"参数 × 照片"峰值矩阵。
# 为什么多图：一张照片验不了依赖内容的参数（换天空/宠物/过曝恢复）——
# 它们在婚礼照上是 0，换到有天空/有宠物/有过曝的照片上才看得出是活的。
#
# 用法：
#   sh tools/dist/audit_params.sh run   [每张等待秒数]   # 跑批 + 打印矩阵
#   sh tools/dist/audit_params.sh save  [等待秒数]       # 跑批 + 存基线 tools/dist/baselines/audit_params.json
#   sh tools/dist/audit_params.sh check [等待秒数]       # 跑批 + 与基线比对，有回归退出码非 0
ROOT=/Users/you/Documents/DeepSeek-Harness-Projects/dsh-xiutu
APP=$ROOT/app-retouch/.build/release/ContentRetouch
MODE=${1:-run}
WAIT=${2:-60}   # 婚礼照要跑人脸+身体检测，实测 26 秒不够（缺照片会让比对不可信）
IMG=$ROOT/douyin_favorites/images
RAW=$ROOT/2604_wedding/00_RAW_readonly
OUT=/tmp/audit_multi.txt
BASE=$ROOT/tools/dist/baselines/audit_params.json
: > $OUT

run_one() {
  path=$1; why=$2
  [ -f "$path" ] || return 0
  name=$(basename "$path")
  log="/tmp/audit_multi_$name.log"
  # ⚠️ 超时**重试一次**（§197）。为什么：这张表在忙机器上会跑不完 ——
  # 实测 load 18~52 时两次发版分别丢在**不同的**照片上（夹具完好、产品代码未动、上一版同一张能过），
  # 而"缺照片"会让整条发版链中止（宁可中止也不发没体检过的包，这个原则不动）。
  # 重试**不掩盖真问题**：第二次仍失败就照常判失败，并把当时的 load 写进日志，
  # 好让"负载导致"与"这张图真的卡住"分得开。
  attempt=1
  while [ "$attempt" -le 2 ]; do
    : > "$log"
    CR_IMPORT="$path" CR_AUDIT=1 "$APP" > "$log" 2>&1 &
    pid=$!
    i=0
    while [ $i -lt $((WAIT / 2)) ]; do
      sleep 2; i=$((i+1))
      grep -q 'AUDIT 结论' "$log" 2>/dev/null && break
    done
    kill $pid 2>/dev/null
    wait $pid 2>/dev/null
    grep -q 'AUDIT 结论' "$log" 2>/dev/null && break
    # ⚠️ 记到**独立**的 retry 日志里：每次重试都会 `: > "$log"` 清空主日志，
    # 写在主日志里的话第一次超时的证据会被第二次冲掉（实测只剩"第 2 次"那行）。
    echo "PAUDIT 第 $attempt 次超时（$(basename "$path")，load $(uptime | sed 's/.*load averages: //' | cut -d' ' -f1)），重试一次" >> "/tmp/audit_retry_$name.log"
    attempt=$((attempt + 1))
  done
  {
    echo "### $name|$why"
    grep -E '^AUDIT ' "$log" 2>/dev/null || echo 'AUDIT(两次都超时，没出表)'
    grep -aE '^PAUDIT ' "/tmp/audit_retry_$name.log" 2>/dev/null
    echo ''
  } >> $OUT
}

run_one "$RAW/wedding_01.jpg" "人脸+身体"
run_one "$IMG/0001_7676844130508479842_23.webp" "宠物"
run_one "$IMG/0184_7379189016593321253_05.webp" "天空"
run_one "$IMG/0001_7676844130508479842_18.webp" "手部"
run_one "$IMG/0001_7685569954204725839_07.webp" "过曝（80% 像素接近 230）"
echo "跑批完成（$(grep -c '^###' $OUT) 张）"
case "$MODE" in
  save)  python3 $ROOT/tools/merge_audit.py --json "$BASE" ;;
  check) python3 $ROOT/tools/merge_audit.py --check "$BASE" ;;
  *)     python3 $ROOT/tools/merge_audit.py ;;
esac