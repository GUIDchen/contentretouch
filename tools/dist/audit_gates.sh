#!/bin/sh
# "门自己的门"：保证这套体检网本身不腐烂。
#
# 为什么需要它：门越多，越容易出现"新加的门忘了挂进 preflight"（等于没有）、
# "某个门在夹具缺失时静默通过"（第 128 节那个毛病的第 N 次复发）、"脚本语法坏了没人发现"。
# 这条检查把这三件事变成自动的。
#
# 判据：
#   A 清单一致：tools/dist/audit_*.sh 与 preflight.sh 里引用的**必须一一对上**
#     （唯一例外是 audit_params.sh —— 它由 release.sh 调用，见下 WAIVED）
#   B 语法：每个门脚本都要能过 sh -n
#   C **没测到必须失败**：把夹具指到一个不存在的路径，每个接受夹具参数的门都必须**快速非零退出**
#     （这条最值钱：它把"没测到不算通过"从一句口号变成自动纪律）
#
# 用法：sh tools/dist/audit_gates.sh
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
DIST="$ROOT/tools/dist"
PRE="$DIST/preflight.sh"
# 由别的入口调用、不进 preflight 的门（必须写明理由）
WAIVED="audit_params.sh"

fail=0
ok()  { echo "  V $1"; }
bad() { echo "  X $1"; fail=1; }

all=$(ls "$DIST"/audit_*.sh | xargs -n1 basename | sort)
used=$(grep -oE 'audit_[a-z_]+\.sh' "$PRE" | sort -u)

echo "  门总数：$(echo "$all" | wc -l | tr -d ' ') ｜ preflight 引用：$(echo "$used" | wc -l | tr -d ' ')"

# A 清单一致
missing=""
for f in $all; do
    echo "$used" | grep -qx "$f" && continue
    echo "$WAIVED" | grep -qx "$f" && continue
    missing="$missing $f"
done
extra=""
for f in $used; do
    [ -f "$DIST/$f" ] || extra="$extra $f"
done
if [ -z "$missing" ] && [ -z "$extra" ]; then ok "A 清单一致：每个门都挂在 preflight 上（豁免：${WAIVED}）"
else
    [ -n "$missing" ] && bad "A 有门没挂进 preflight：$missing"
    [ -n "$extra" ] && bad "A preflight 引用了不存在的门：$extra"
fi

# B 语法
syn=""
for f in $all; do sh -n "$DIST/$f" 2>/dev/null || syn="$syn $f"; done
if [ -z "$syn" ]; then ok "B 语法：$(echo "$all" | wc -l | tr -d ' ') 个门都能过 sh -n"
else bad "B 语法有问题：$syn"; fi

# C 夹具缺失必须非零退出（只对"接受夹具参数"的门；用超时兜住万一挂住的）
nohook=""
probed=0
for f in $all; do
    # 只对"夹具可被参数覆盖"的门做这条判据（`\${1:-…}` 形式）；夹具写死在脚本里的门不适用。
    # 另外两类要排除：audit_params.sh（它的 $1 是"等待秒数"，跑一批要几分钟，不是夹具）、本脚本自己。
    echo "$WAIVED" | grep -qx "$f" && continue
    [ "$f" = "audit_gates.sh" ] && continue
    grep -q '\${1:-' "$DIST/$f" || { nohook="$nohook $f"; continue; }
    probed=$((probed + 1))
    # ⚠️ macOS 上没有 `timeout`（那是 coreutils 的 gtimeout）——
    # 用 `timeout 25 …` 会以 rc=127 静默通过，这条判据就成了摆设（第一版就是这样，自己踩了自己）。
    # 改成"后台跑 + 轮询 + 到点杀"。
    sh "$DIST/$f" /tmp/audit_gates_missing_$$.jpg > /tmp/audit_gates_probe.log 2>&1 &
    gpid=$!
    i=0; rc=999
    while [ $i -lt 25 ]; do
        sleep 1; i=$((i+1))
        if ! kill -0 "$gpid" 2>/dev/null; then set +e; wait "$gpid"; rc=$?; set -e; break; fi
    done
    if kill -0 "$gpid" 2>/dev/null; then kill -9 "$gpid" 2>/dev/null; rc=124; fi
    if [ "$rc" -eq 0 ]; then bad "C 夹具不存在却退出 0（没测到算通过）：$f"
    elif [ "$rc" -eq 124 ]; then bad "C 夹具不存在时卡住（25 秒超时）：$f"
    fi
done
echo "  · 抽查了 $probed 个门（夹具可覆盖的那些）；夹具写死的：$nohook"
[ -z "$nohook" ] || echo "  · 不接受夹具参数的门（夹具写死在脚本里）：$nohook"
[ "$fail" = "0" ] && ok "C 没测到必须失败：所有夹具可覆盖的门都做到了"

echo "门体检：$([ "$fail" = "0" ] && echo "全部通过" || echo "有失败")"
exit $fail
