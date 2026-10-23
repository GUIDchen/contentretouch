#!/bin/sh
# 一键自检（改完代码跑这个就够）：
#   1) 编译
#   2) coretest（数值断言全绿）
#   3) 界面截图回归（14 个面板与基线比；外观钉死为深色，避免系统换肤造成假差异）
#   4) 人脸解析模型能不能找到 + 推理一次
#   5) 打包并核对产物（.app / .dmg 体积、模型是否进包）
#
# 用法：sh tools/dist/preflight.sh
# 非 0 退出 = 有一项没过，逐条看上面的输出。
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

fail=0
# 门要能失败，但**不能因为机器负载假红**：每个门失败后自动重试一次（只对"两次都红"判失败）。
# 为什么放在这里而不是每个脚本里：一处改动覆盖所有门；让 12 个脚本各写一遍必然漏。
# 每个门的**硬超时**：门自己卡住（等 App、等文件）也不能把发版挂住。
# 为什么加：2026-09-26 发 9.10.34 时，撤销/重做门那一"步"耗了 **931 秒**（同一个门单跑只要 6 秒），
# 整个预检被拖到 70 分钟。门里的等待循环是有上限的，但那之后还有一句 `wait $pid` ——
# App 要是没退出，这一句就无限等下去。超时后连子进程一起杀掉，并如实说明"是超时，不是判据红"。
GATE_TIMEOUT=${GATE_TIMEOUT:-300}
run_gate_once() {   # $1=脚本 $2=日志 → 0=跑完且通过；1=跑完但没过；2=超时被杀
    sh "$1" > "$2" 2>&1 &
    gate_pid=$!
    waited=0
    while kill -0 $gate_pid 2>/dev/null && [ "$waited" -lt "$GATE_TIMEOUT" ]; do
        sleep 2; waited=$((waited + 2))
    done
    if kill -0 $gate_pid 2>/dev/null; then
        # 先杀子进程（App 实例才是真正会挂住的东西），再杀门本身
        for child in $(pgrep -P $gate_pid 2>/dev/null); do kill -9 $child 2>/dev/null; done
        kill -9 $gate_pid 2>/dev/null
        wait $gate_pid 2>/dev/null
        return 2
    fi
    wait $gate_pid 2>/dev/null
}

run_gate() {   # $1=名字 $2=脚本 $3=日志
    run_gate_once "$2" "$3"
    gate_rc=$?
    if [ "$gate_rc" = "0" ]; then return 0; fi
    if [ "$gate_rc" = "2" ]; then
        cp "$3" "$3.first" 2>/dev/null || true
        echo "  （$1 超过 ${GATE_TIMEOUT} 秒仍未结束，已强杀 —— 这是**超时**，不是判据红；日志 $3）"
        echo "  （超时后重试一次）"
        run_gate_once "$2" "$3"
        return $?
    fi
    # ⚠️ 先把第一次的日志**留下来**再重试：重试是同名覆盖的，原来这行只打印一句"重试一次"，
    # 于是"第一次到底是哪条判据红的"永久丢失 —— 2026-09-26 发版时性能门就红过一次，
    # 重试通过后无从查起（只能靠猜）。证据先留档，再看结果。
    cp "$3" "$3.first" 2>/dev/null || true
    echo "  （$1 第一次没通过，重试一次 —— 负载高时 App 启动会超预算；第一次的日志留在 $3.first）"
    run_gate_once "$2" "$3"     # 重试也走带超时的同一条路（否则重试照样能挂住）
}

# 每步打印"上一步花了多久"：发版到底慢在哪，得能一眼看出来（不然只剩"很久"这种印象）
STEP_T0=$(date +%s)
step() {
    now=$(date +%s)
    if [ -n "$STEP_NAME" ]; then printf "  （%s 用时 %d 秒）\n" "$STEP_NAME" $((now - STEP_T0)); fi
    STEP_NAME="$1"; STEP_T0=$now
    printf "\n== %s ==\n" "$1"
}
finish_steps() { [ -n "$STEP_NAME" ] && printf "  （%s 用时 %d 秒）\n" "$STEP_NAME" $(($(date +%s) - STEP_T0)); }

# 互斥：两套体检同时跑会互相踩（同名临时目录、抢 App 实例）——
# 第 164 节那次假红就是"我手动跑的 coretest 和预检里的 coretest 撞在同一个临时目录"。
# 用 mkdir 做原子锁；已经在跑就直接退出，别把机器压成两倍、也别产出互相干扰的数字。
LOCK=/tmp/contentretouch-preflight.lock
if ! mkdir "$LOCK" 2>/dev/null; then
    echo "另一个预检正在跑（锁：$LOCK）—— 等它结束再跑，或者确认它已死掉后 rm -rf $LOCK"
    exit 2
fi
echo $$ > "$LOCK/pid" 2>/dev/null || true
trap 'finish_steps; rm -rf "$LOCK"' EXIT

step "1/5 编译"
if (cd app-retouch && swift build -c release >/tmp/preflight_build.log 2>&1); then
    echo "  编译通过"
else
    echo "  编译失败："; tail -20 /tmp/preflight_build.log; exit 1
fi

step "2/5 coretest"
# 注意：不能只留最后 3 行 —— 那样失败时打印不出是哪条（踩过：只显示「有断言失败：」后面空着）
app-retouch/.build/release/coretest > /tmp/preflight_test.log 2>&1 || true
if grep -q "未通过 0 项" /tmp/preflight_test.log; then
    grep -E "通过" /tmp/preflight_test.log | tail -1
else
    echo "  有断言失败："
    grep -E "\[!!\]" /tmp/preflight_test.log | head -20
    fail=1
fi

step "2.5/5 参数接线审计（UI 绑定了但没进管线/快照的控件）"
if python3 tools/dist/audit_ui_params.py > /tmp/preflight_audit.log 2>&1; then
    # ⚠️ 这里以前是一串**硬编码名字白名单**（brushDensity|brushPressure|…）当"已知误报"。
    # 白名单会腐烂：真掉了也会被静默放过。现在"笔触构造层"由审计脚本按文件职责自己认，
    # 所以任何 MISSING 都是新问题，不再排除任何名字。
    stray=$(grep '^MISSING ' /tmp/preflight_audit.log | head -5 || true)
    if [ -n "$stray" ]; then
        echo "  发现疑似“拖了没用”的控件："; echo "$stray"; fail=1
    else
        # 把"检查了几个"说出来：这个审计曾经扫到 0 个控件还报"没问题"（第 133 节）
        n=$(grep -oE 'UI 上的参数绑定共 [0-9]+ 个' /tmp/preflight_audit.log | head -1)
        echo "  没有疑似失效控件（${n:-绑定数未知}；不再用名字白名单排除）"
    fi
else
    echo "  审计脚本没跑起来（跳过）"
fi

step "2.6/5 重复实现审计（界面里是不是又写了一份核心逻辑）"
if python3 tools/dist/audit_dupes.py > /tmp/preflight_dupes.log 2>&1; then
    # 通过 = 没有**新的**同名实现；已知的两处（职责不同）会连带打印出来，便于复查
    grep -E '已确认同名|没有\*\*新的\*\*同名' /tmp/preflight_dupes.log | sed 's/^/  /' || true
else
    # 脚本只在出现**新的**同名时返回 1（已知的两处写在脚本的 KNOWN_DUPES 里），
    # 所以这里判失败是对的：新的同名要么是调用核心，要么就是界面又写了一份。
    echo "  发现新的同名实现，逐条确认："; tail -12 /tmp/preflight_dupes.log
    fail=1
fi

step "2.7/5 交互工具体检（涂抹/修补/仿制/液化/裁剪：状态 → 渲染这条链）"
if run_gate "tools" tools/dist/audit_tools.sh /tmp/preflight_tools.log; then
    grep -E '^  V ' /tmp/preflight_tools.log | sed 's/^/  /' || true
    tail -1 /tmp/preflight_tools.log
else
    echo "  有工具没通过："; grep -E '^  X |^!!|缺夹具' /tmp/preflight_tools.log | head -8; fail=1
fi

step "2.8/5 导出通路体检（全分辨率 / 裁剪进导出 / 手动编辑进导出）"
if run_gate "export" tools/dist/audit_export.sh /tmp/preflight_export.log; then
    grep -E '^  [V·] ' /tmp/preflight_export.log | sed 's/^/  /' || true
else
    echo "  导出通路有问题："; grep -E '^  X |缺夹具' /tmp/preflight_export.log | head -6; fail=1
fi

step "2.9/5 撤销/重做体检（安全网：8 条判据）"
if run_gate "undo" tools/dist/audit_undo.sh /tmp/preflight_undo.log; then
    grep -E '^  V ' /tmp/preflight_undo.log | sed 's/^/  /' || true
    tail -1 /tmp/preflight_undo.log
else
    echo "  撤销/重做有问题："; grep -E '^  X |^!!' /tmp/preflight_undo.log | head -8; fail=1
fi

step "2.10/5 多图切换体检（每张图自己的编辑还在不在）"
if run_gate "strip" tools/dist/audit_strip.sh /tmp/preflight_strip.log; then
    grep -E '^  V ' /tmp/preflight_strip.log | sed 's/^/  /' || true
    tail -1 /tmp/preflight_strip.log
else
    echo "  多图切换有问题："; grep -E '^  X |^!!' /tmp/preflight_strip.log | head -8; fail=1
fi

step "2.11/5 预设体检（套用/取消/切换/撤销后再套）"
if run_gate "preset" tools/dist/audit_preset.sh /tmp/preflight_preset.log; then
    grep -E '^  V ' /tmp/preflight_preset.log | sed 's/^/  /' || true
    tail -1 /tmp/preflight_preset.log
else
    echo "  预设有问题："; grep -E '^  X |^!!' /tmp/preflight_preset.log | head -8; fail=1
fi

step "2.12/5 一键智能体检（智能裁剪 / 肩线校平 / 按人物裁剪，带真值）"
if run_gate "smart" tools/dist/audit_smart.sh /tmp/preflight_smart.log; then
    grep -E '^  V ' /tmp/preflight_smart.log | sed 's/^/  /' || true
    tail -1 /tmp/preflight_smart.log
else
    echo "  一键智能有问题："; grep -E '^  X |^!!' /tmp/preflight_smart.log | head -8; fail=1
fi

step "2.13/5 画布坐标体检（屏幕坐标 → 图像坐标：中心/3-4 点/越界）"
if run_gate "canvas" tools/dist/audit_canvas.sh /tmp/preflight_canvas.log; then
    grep -E '^  V ' /tmp/preflight_canvas.log | sed 's/^/  /' || true
    tail -1 /tmp/preflight_canvas.log
else
    echo "  画布坐标有问题："; grep -E '^  X |^!!|FAIL' /tmp/preflight_canvas.log | head -8; fail=1
fi

step "2.14/5 CLI 体检（批量/无头通路的退出码契约）"
if run_gate "cli" tools/dist/audit_cli.sh /tmp/preflight_cli.log; then
    grep -E '^  V ' /tmp/preflight_cli.log | sed 's/^/  /' || true
    tail -1 /tmp/preflight_cli.log
else
    echo "  CLI 有问题："; grep -E '^  X |^!!' /tmp/preflight_cli.log | head -8; fail=1
fi

step "2.15/5 参考追色体检（正常参考 / 纯色与缺失参考必须被拒）"
if run_gate "ref" tools/dist/audit_ref.sh /tmp/preflight_ref.log; then
    grep -E '^  V ' /tmp/preflight_ref.log | sed 's/^/  /' || true
    tail -1 /tmp/preflight_ref.log
else
    echo "  参考追色有问题："; grep -E '^  X |^!!' /tmp/preflight_ref.log | head -8; fail=1
fi

step "2.16/5 挑图体检（排序/覆盖/CSV/--top/清晰度语义/退出码）"
if run_gate "pick" tools/dist/audit_pick.sh /tmp/preflight_pick.log; then
    grep -E '^  V ' /tmp/preflight_pick.log | sed 's/^/  /' || true
    tail -1 /tmp/preflight_pick.log
else
    echo "  挑图有问题："; grep -E '^  X |^!!' /tmp/preflight_pick.log | head -8; fail=1
fi

step "2.17/5 场景推荐体检（四类内容 → 四个类别 + 自洽 + 建议落地）"
if run_gate "scene" tools/dist/audit_scene.sh /tmp/preflight_scene.log; then
    grep -E '^  V ' /tmp/preflight_scene.log | sed 's/^/  /' || true
    tail -1 /tmp/preflight_scene.log
else
    echo "  场景推荐有问题："; grep -E '^  X |^!!' /tmp/preflight_scene.log | head -8; fail=1
fi

step "2.18/5 断点续跑体检（只补缺的 + 已有产物不动 + 记录不追加）"
if run_gate "resume" tools/dist/audit_resume.sh /tmp/preflight_resume.log; then
    grep -E '^  V ' /tmp/preflight_resume.log | sed 's/^/  /' || true
    tail -1 /tmp/preflight_resume.log
else
    echo "  断点续跑有问题："; grep -E '^  X |^!!' /tmp/preflight_resume.log | head -8; fail=1
fi

step "2.19/5 性能/内存体检（预览延迟 + 批量峰值内存/吞吐）"
if run_gate "perf" tools/dist/audit_perf.sh /tmp/preflight_perf.log; then
    grep -E '^  [V·] ' /tmp/preflight_perf.log | sed 's/^/  /' || true
    tail -1 /tmp/preflight_perf.log
else
    echo "  性能有问题："; grep -E '^  X |^!!' /tmp/preflight_perf.log | head -8; fail=1
fi

step "2.20/5 门体检（清单一致 / 语法 / 没测到必须失败）"
if run_gate "gates" tools/dist/audit_gates.sh /tmp/preflight_gates.log; then
    grep -E '^  [V·] ' /tmp/preflight_gates.log | sed 's/^/  /' || true
    tail -1 /tmp/preflight_gates.log
else
    echo "  体检网自身有问题："; grep -E '^  X ' /tmp/preflight_gates.log | head -8; fail=1
fi

step "2.21/5 按部位体检（脸/眼/唇/鼻/耳/手臂/腿：变在该部位里）"
if run_gate "parts" tools/dist/audit_parts.sh /tmp/preflight_parts.log; then
    grep -E '^  V ' /tmp/preflight_parts.log | tail -8 | sed 's/^/  /' || true
    tail -1 /tmp/preflight_parts.log
else
    echo "  按部位有问题："; grep -E '^  X |^!!' /tmp/preflight_parts.log | head -8; fail=1
fi

step "2.22/5 稳定性体检（连换图/套预设/撤销 30 轮：内存要平台化）"
if run_gate "stress" tools/dist/audit_stress.sh /tmp/preflight_stress.log; then
    grep -E '^  V ' /tmp/preflight_stress.log | sed 's/^/  /' || true
    tail -1 /tmp/preflight_stress.log
else
    echo "  稳定性有问题："; grep -E '^  X |^!!' /tmp/preflight_stress.log | head -6; fail=1
fi

step "3/5 界面截图回归"
# ⚠️ §256：这里原来是
#     ui_baseline.sh check 2>&1 | tail -16 | tee ... | grep -q "界面与基线一致"
#   两个错叠在一起：① tail -16 写死（面板从 14 涨到 20 后，**结尾的汇总行被截掉** ⇒ grep 找不到
#   「界面与基线一致」⇒ 明明全绿也判失败）；② 那句「14 个面板」也是写死的旧文案。
#   现在改成**看退出码**（门在差异时自己 exit 1，§253 的变异测试验过：变异 1、改回 0），
#   面板数从日志里读，不写死。顺带说明：这次发布被中止，说明 fail-safe 是可靠的 ——
#   宁可白跑一次，也不把没体检过的包发出去。
if sh tools/dist/ui_baseline.sh check > /tmp/preflight_ui.log 2>&1; then
    n=$(grep -oE "比对 [0-9]+ 个面板" /tmp/preflight_ui.log | tail -1)
    echo "  ${n:-界面与基线一致}"
else
    echo "  界面有差异："; grep -E "✗|X " /tmp/preflight_ui.log | head -10; fail=1
fi

step "3.5/5 多图冒烟（不同来源的 6 张：导入→渲染→截图）"
if sh tools/dist/smoke_multi.sh 6 > /tmp/preflight_smoke.log 2>&1; then
    tail -1 /tmp/preflight_smoke.log
else
    echo "  有多图失败："; tail -8 /tmp/preflight_smoke.log; fail=1
fi

step "4/5 人脸解析模型"
if app-retouch/.build/release/retouch-cli --model-check; then
    echo "  模型可用"
else
    # 没模型时皮肤掩膜会退回肤色阈值（明显更粗，见账本第 100/101 节），
    # 分发给用户的包里缺这个 = 静默降级，所以算失败，不算"提示"。
    echo "  模型不可用：皮肤掩膜会退回肤色阈值，分发包会静默降级"; fail=1
fi

step "5/5 打包与产物体积"
sh app-retouch/build_app.sh release >/tmp/preflight_pack.log 2>&1
APP_SIZE=$(du -sm dist/ContentRetouch.app | cut -f1)
MODEL_OK="缺失"
[ -f dist/ContentRetouch.app/Contents/Resources/Models/FaceParsing.mlmodel ] && MODEL_OK="已进包"
echo "  .app = ${APP_SIZE} MB，模型 $MODEL_OK"
if [ "$MODEL_OK" != "已进包" ]; then echo "  ⚠ 模型没进包，分发包里会退回肤色阈值"; fail=1; fi

# ⚠️ 打包后的 .app 冒烟：**发给用户的是这个包**，而上面所有冒烟测的都是
# app-retouch/.build/release/ContentRetouch —— 包路径变了（模型在 Contents/Resources、
# 可执行文件在 Contents/MacOS）而没人验证过它能不能起来。打包脚本漏拷资源这类问题，
# 以前只有用户拿到 dmg 才会发现。
PKG=dist/ContentRetouch.app/Contents/MacOS/ContentRetouch
PKG_FIXTURE=douyin_favorites/images/0184_7379189016593321253_05.webp
PKG_SHOT=/tmp/preflight_pkg_smoke.png
if [ ! -x "$PKG" ]; then
    echo "  ✗ 包里没有可执行文件：$PKG"; fail=1
elif [ ! -f "$PKG_FIXTURE" ]; then
    echo "  ✗ 缺夹具 ${PKG_FIXTURE}（没测到就不算通过）"; fail=1
else
    rm -f "$PKG_SHOT"
    CR_IMPORT="$ROOT/$PKG_FIXTURE" "$PKG" --module 精修 --panel 1 --screenshot "$PKG_SHOT" >/dev/null 2>&1 || true
    if [ -s "$PKG_SHOT" ]; then
        echo "  打包后的 .app 起得来并出图 $(${MAGICK:-/opt/homebrew/bin/magick} identify -format '%wx%h' "$PKG_SHOT" 2>/dev/null || echo '?')"
    else
        echo "  ✗ 打包后的 .app 起不来 / 没出图"; fail=1
    fi
fi
rm -f "$PKG_SHOT"

echo
if [ "$fail" = "0" ]; then
    finish_steps
echo "全部通过 ✅"
else
    echo "有项目未通过 ❌（见上面标了 ✗ 的行）"
    exit 1
fi
