#!/bin/sh
# 把一版更新发布出去：生成清单 -> 验签 -> 上传 -> 在线核对
#
# 用法
#   sh tools/dist/publish_update.sh \
#     --artifact dist/ContentHarvester.app.tar.gz \
#     --version 0.4.0 --notes "这次改了什么" \
#     --base-url https://你的域名/dl/ \
#     --upload "rsync -av dist/latest.json dist/ContentHarvester.app.tar.gz 你的服务器:/var/www/dl/"
#
# 不带 --upload 时只生成清单并验签，文件自己拷走即可。
# 为什么要有它：发布最容易「少传一个文件」或「清单指向旧版本」，这里把顺序固定下来，
# 最后还会把远端清单与本地比对一次。
set -e

ART=""; VER=""; NOTES=""; BASE=""; UPLOAD=""
while [ $# -gt 0 ]; do
  case "$1" in
    --artifact) ART="$2"; shift 2 ;;
    --version)  VER="$2"; shift 2 ;;
    --notes)    NOTES="$2"; shift 2 ;;
    --base-url) BASE="$2"; shift 2 ;;
    --upload)   UPLOAD="$2"; shift 2 ;;
    -h|--help)  sed -n '2,11p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

[ -n "$ART" ] || { echo "需要 --artifact <更新包>（.app.tar.gz）" >&2; exit 2; }
[ -n "$VER" ] || { echo "需要 --version <版本号>" >&2; exit 2; }
[ -f "$ART" ] || { echo "找不到更新包: $ART" >&2; exit 2; }
case "$ART" in
  *.app.tar.gz) : ;;
  *) echo "macOS 的更新包应是 .app.tar.gz（当前是 ${ART}）" >&2; exit 2 ;;
esac
[ -f "$ART.sig" ] || { echo "找不到签名 $ART.sig（构建时缺 TAURI_SIGNING_PRIVATE_KEY？）" >&2; exit 2; }
[ -n "$BASE" ] || { echo "需要 --base-url：清单里要写下载地址（例如 https://your.host/dl/）" >&2; exit 2; }
case "$BASE" in
  https://*) : ;;
  *) echo "警告：Tauri 的 updater 只接受 https 端点（当前 ${BASE}）" >&2 ;;
esac

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
NAME=$(basename "$ART")

# 清单必须与被上传的那份更新包放在同一个目录，先统一收进 dist/
if [ "$(cd "$(dirname "$ART")" && pwd)" != "$ROOT/dist" ]; then
  cp -f "$ART" "$ART.sig" "$ROOT/dist/"
fi

echo "== 1/4 生成清单 =="
set -- --artifact "$ROOT/dist/$NAME" --version "$VER" --base-url "$BASE" --out "$ROOT/dist/latest.json"
if [ -n "$NOTES" ]; then set -- "$@" --notes "$NOTES"; fi
node "$ROOT/tools/dist/make_update_manifest.mjs" "$@"

echo
echo "== 2/4 本地验签（清单 / 更新包 / 签名 / 公钥） =="
node "$ROOT/tools/dist/verify_signature.mjs" --manifest "$ROOT/dist/latest.json" --dir "$ROOT/dist"

echo
if [ -n "$UPLOAD" ]; then
  echo "== 3/4 上传 =="
  echo "  $UPLOAD"
  sh -c "$UPLOAD"
else
  echo "== 3/4 跳过上传（没给 --upload） =="
  echo "  要上传的文件：dist/latest.json 与 dist/$NAME"
fi

echo
echo "== 4/4 在线核对 =="
URL="$BASE/latest.json"
echo "  拉取 $URL"
if curl -fsSL --max-time 20 "$URL" -o /tmp/_remote_latest.json; then
  node -e 'const fs=require("node:fs");const l=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));const r=JSON.parse(fs.readFileSync("/tmp/_remote_latest.json","utf8"));const a=l.platforms["darwin-aarch64"]||{};const b=r.platforms["darwin-aarch64"]||{};const same=l.version===r.version&&a.url===b.url&&a.signature===b.signature;console.log("  远端版本 "+r.version+" / 本地 "+l.version);console.log(same?"  ✅ 远端清单与本地一致":"  ❌ 远端清单与本地不一致（没传上去？传的是旧文件？）");if(!same)process.exit(1)' "$ROOT/dist/latest.json"
else
  echo "  ⚠️ 拉不到远端清单（地址不对？还没生效？）——请手动确认"
fi

echo
echo "完成：客户端「高级 -> 更新 -> 检查更新」应能看到 ${VER}；确认无误后再点「下载并安装」。"
