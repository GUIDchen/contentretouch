#!/bin/sh
# §340 分层评测集 v3：复用现有 App 探针（MCAUDIT）取几何；
# 修正 §339 的口径错误 —— 头发占比的分母必须是**脸裁剪面积**（(1.7 x 脸长边)^2），不是整张工作图。
# 正则全部来自实测输出：MCAUDIT 共 N 张脸 / 类01 皮肤 / 类17 头发 / 工作图共 N / 脸 WxH
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PKG="$ROOT/dist/ContentRetouch.app/Contents/MacOS/ContentRetouch"
SRC="$ROOT/douyin_favorites/images"
CAND="${1:-12}"
[ -x "$PKG" ] || { echo "缺少打包后的 App：$PKG"; exit 2; }
TMP=$(mktemp -d /tmp/evalv3.XXXXXX)
ROWS="$TMP/rows.tsv"; : > "$ROWS"
STEP=$(awk -v n=13484 -v c="$CAND" "BEGIN{ s=int(n/c); if (s<1) s=1; print s }")
find "$SRC" -maxdepth 1 -type f | sort | awk -v k="$STEP" "NR % k == 1" | head -n "$CAND" > "$TMP/list.txt"
N_CAND=$(wc -l < "$TMP/list.txt" | tr -d " ")
echo "候选 ${N_CAND} 张（步长 ${STEP}）"
printf "%-14s %-6s %-9s %-10s %-9s %-10s\n" 文件 脸数 脸宽x高 头发占脸比 皮肤px 判定
while IFS= read -r f; do
  log="$TMP/one.log"
  CR_IMPORT="$f" CR_MCAUDIT=1 "$PKG" > "$log" 2>&1 &
  pid=$!
  i=0; while [ "$i" -lt 45 ]; do i=$((i+1)); grep -q "MCAUDIT 完" "$log" 2>/dev/null && break; sleep 1; done
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  faces=$(sed -n "s/.*MCAUDIT 共 \([0-9]*\) 张脸.*/\1/p" "$log" | head -1)
  [ -n "$faces" ] || faces=0
  dims=$(sed -n "s/.*脸 \([0-9]*\)x\([0-9]*\).*/\1 \2/p" "$log" | head -1)
  fw=$(echo "$dims" | cut -d" " -f1); [ -n "$fw" ] || fw=0
  fh=$(echo "$dims" | cut -d" " -f2); [ -n "$fh" ] || fh=0
  hair=$(sed -n "s/.*MCAUDIT 脸1 类17： *\([0-9]*\) px.*/\1/p" "$log" | head -1)
  [ -n "$hair" ] || hair=0
  skin=$(sed -n "s/.*MCAUDIT 脸1 类01： *\([0-9]*\) px.*/\1/p" "$log" | head -1)
  [ -n "$skin" ] || skin=0
  hpct=$(awk -v h="$hair" -v w="$fw" -v hh="$fh" "BEGIN{ side=w; if (hh>w) side=hh; side=side*1.7; if (side>0) printf \"%.1f\", 100*h/(side*side); else printf \"0.0\" }")
  verdict=纳入
  [ "$faces" -ge 1 ] || verdict=无脸
  if [ "$faces" -ge 1 ]; then awk -v p="$hpct" "BEGIN{ exit (p>=10 && p<=50) ? 0 : 1 }" || verdict=头发越界; fi
  printf "%-14s %-6s %-9s %-10s %-9s %-10s\n" "$(basename "$f" | cut -c1-12)" "$faces" "${fw}x${fh}" "$hpct" "$skin" "$verdict"
  printf "%s\t%s\t%s\t%s\t%s\t%s\n" "$f" "$faces" "${fw}x${fh}" "$hpct" "$hair" "$verdict" >> "$ROWS"
done < "$TMP/list.txt"
echo; echo "=== 汇总 ==="
awk -F"\t" '{ n++; if ($2+0>=1 && $4+0>=10 && $4+0<=50) ok++; if ($6=="无脸") nf++ } END { printf "  纳入 %d ／ 候选 %d ｜ 无脸 %d\n", ok+0, n+0, nf+0 }' "$ROWS"
cp "$ROWS" /tmp/eval_rows.tsv
cp "$TMP/list.txt" /tmp/eval_list.txt
awk -F"\t" '{ printf "{\047path\047: \047%s\047, \047faces\047: %s, \047faceWH\047: \047%s\047, \047hairPct\047: %s, \047verdict\047: \047%s\047}\n", $1, $2, $3, $4, $6 }' "$ROWS" > /tmp/eval_set.json
echo "  明细 /tmp/eval_rows.tsv ｜ 评测集 /tmp/eval_set.json（$(wc -l < /tmp/eval_rows.tsv | tr -d " ") 行）"
rm -rf "$TMP"
