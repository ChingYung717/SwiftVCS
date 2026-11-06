#!/bin/bash
# 将 AppIcon-1024.png 转换为标准 macOS AppIcon.icns
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Apps/VCSExplorer/Resources/AppIcon-1024.png"
OUT="$ROOT/Apps/VCSExplorer/Resources/AppIcon.icns"

if [ ! -f "$SRC" ]; then
    echo "错误: 找不到源图标文件 $SRC" >&2
    exit 1
fi

TMP_BASE="$(mktemp -d)"
SET="$TMP_BASE/AppIcon.iconset"
trap 'rm -rf "$TMP_BASE"' EXIT
mkdir -p "$SET"

for s in 16 32 128 256 512; do
    /usr/bin/sips -s format png -z "$s" "$s" "$SRC" --out "$SET/icon_${s}x${s}.png" >/dev/null
    s2=$((s * 2))
    /usr/bin/sips -s format png -z "$s2" "$s2" "$SRC" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done

/usr/bin/iconutil -c icns "$SET" -o "$OUT"
echo "已生成图标: $OUT"
