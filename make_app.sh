#!/bin/bash
# 组装 VCSExplorer.app（原生 arm64，ad-hoc 签名）
# 用法: ./make_app.sh [输出目录]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE/dist}"
APP="$OUT/VCSExplorer.app"
NAME="VCSExplorer"
BUNDLE_ID="local.vcsexplorer"

echo "==> 编译 release 版本"
cd "$HERE"
swift build -c release --product "$NAME"

BIN="$(swift build -c release --show-bin-path)/$NAME"
[ -f "$BIN" ] || { echo "找不到可执行文件: $BIN"; exit 1; }

echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/$NAME"
chmod 755 "$APP/Contents/MacOS/$NAME"
printf 'APPL????' > "$APP/Contents/PkgInfo"

bundle_dylibs() {
    local main_bin="$APP/Contents/MacOS/$NAME"
    local fw_dir="$APP/Contents/Frameworks"
    mkdir -p "$fw_dir"

    while true; do
        local found_new=0
        local targets=("$main_bin")
        while IFS= read -r -d '' dylib; do
            targets+=("$dylib")
        done < <(find "$fw_dir" -maxdepth 1 -name "*.dylib" -print0)

        for target in "${targets[@]}"; do
            while IFS= read -r dep; do
                case "$dep" in
                    /opt/homebrew/*|/usr/local/*)
                        local base
                        base="$(basename "$dep")"
                        local dest="$fw_dir/$base"
                        if [ ! -f "$dest" ]; then
                            cp -L "$dep" "$dest"
                            chmod 755 "$dest"
                            install_name_tool -id "@rpath/$base" "$dest"
                            if command -v /usr/bin/vtool >/dev/null 2>&1; then
                                /usr/bin/vtool -set-build-version macos 14.0 14.0 -replace -output "$dest" "$dest" 2>/dev/null || true
                            fi
                            found_new=1
                        fi
                        install_name_tool -change "$dep" "@rpath/$base" "$target"
                        ;;
                esac
            done < <(otool -L "$target" | tail -n +2 | awk '{print $1}')
        done

        if [ "$found_new" -eq 0 ]; then
            break
        fi
    done

    install_name_tool -delete_rpath "/opt/homebrew/opt/subversion/lib" "$main_bin" 2>/dev/null || true
    install_name_tool -delete_rpath "/opt/homebrew/opt/apr/lib" "$main_bin" 2>/dev/null || true
    install_name_tool -delete_rpath "/usr/local/opt/subversion/lib" "$main_bin" 2>/dev/null || true
    install_name_tool -delete_rpath "/usr/local/opt/apr/lib" "$main_bin" 2>/dev/null || true
    while IFS= read -r rpath_entry; do
        case "$rpath_entry" in
            /Library/Developer/CommandLineTools/*|/opt/homebrew/*|/usr/local/*)
                install_name_tool -delete_rpath "$rpath_entry" "$main_bin" 2>/dev/null || true
                ;;
        esac
    done < <(otool -l "$main_bin" | awk '/cmd LC_RPATH/{getline; getline; print $2}')
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$main_bin" 2>/dev/null || true
}

echo "==> 收集并重写内置动态库 (Frameworks)"
bundle_dylibs

RES_DIR="$HERE/Apps/VCSExplorer/Resources"
if [ -f "$RES_DIR/AppIcon-1024.png" ] && [ -f "$HERE/scripts/make_icons.sh" ] && { [ ! -f "$RES_DIR/AppIcon.icns" ] || [ "$RES_DIR/AppIcon-1024.png" -nt "$RES_DIR/AppIcon.icns" ]; }; then
    bash "$HERE/scripts/make_icons.sh"
fi
if [ -f "$RES_DIR/AppIcon.icns" ]; then
    cp "$RES_DIR/AppIcon.icns" "$APP/Contents/Resources/"
fi
for illust in welcome.png no-changes.png select-commit.png; do
    if [ -f "$RES_DIR/$illust" ]; then
        cp "$RES_DIR/$illust" "$APP/Contents/Resources/"
    fi
done

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>VCS Explorer</string>
    <key>CFBundleDisplayName</key><string>VCS Explorer</string>
    <key>CFBundleExecutable</key><string>VCSExplorer</string>
    <key>CFBundleIdentifier</key><string>local.vcsexplorer</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>SwiftVCS</string>
    <key>CFBundleDocumentTypes</key>
    <array/>
</dict>
</plist>
PLIST

echo "==> 签名（ad-hoc；不启用沙箱，故无容器身份问题）"
for dylib in "$APP/Contents/Frameworks"/*.dylib; do
    if [ -f "$dylib" ]; then
        codesign --force --sign - "$dylib"
    fi
done
codesign --force --deep --sign - "$APP" 2>&1 | tail -1
codesign --verify --strict --verbose=1 "$APP" && echo "    签名校验通过"

ZIP_OUT="$OUT/VCSExplorer-arm64.zip"
rm -f "$ZIP_OUT"
ditto -c -k --keepParent "$APP" "$ZIP_OUT"

echo "==> 产物"
du -sh "$APP" "$ZIP_OUT"
file "$APP/Contents/MacOS/$NAME"
echo "$APP"
