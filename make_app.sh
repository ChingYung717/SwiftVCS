#!/bin/bash
# 组装当前架构的 VCSExplorer.app，可选 Developer ID 签名与公证。
# 用法: ./make_app.sh [输出目录]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE/dist}"
APP="$OUT/VCSExplorer.app"
NAME="VCSExplorer"
VERSION="${SWIFTVCS_VERSION:-1.0.0}"
SIGN_IDENTITY="${SWIFTVCS_SIGN_IDENTITY:--}"
NOTARY_PROFILE="${SWIFTVCS_NOTARY_PROFILE:-}"
source "$HERE/scripts/svn_build_env.sh"
source "$HERE/scripts/bundle_notices.sh"
if [ -n "$NOTARY_PROFILE" ] && [ "$SIGN_IDENTITY" = "-" ]; then
    echo '公证需要 SWIFTVCS_SIGN_IDENTITY 指定 Developer ID Application 身份' >&2
    exit 1
fi

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
    local notices="$APP/Contents/Resources/ThirdParty"
    local brew_prefix
    brew_prefix="$(brew --prefix)"
    mkdir -p "$fw_dir" "$notices"
    printf 'Library\tFormula\tVersion\n' > "$notices/components.tsv"

    while true; do
        local found_new=0
        local targets=("$main_bin")
        while IFS= read -r -d '' dylib; do
            targets+=("$dylib")
        done < <(find "$fw_dir" -maxdepth 1 -name "*.dylib" -print0)

        for target in "${targets[@]}"; do
            while IFS= read -r dep; do
                case "$dep" in
                    "$brew_prefix"/*|/opt/homebrew/*|/usr/local/*)
                        local base
                        base="$(basename "$dep")"
                        local dest="$fw_dir/$base"
                        if [ ! -f "$dest" ]; then
                            cp -L "$dep" "$dest"
                            chmod 755 "$dest"
                            install_name_tool -id "@rpath/$base" "$dest"
                            bundle_dylib_notices "$dep" "$notices" "$base"
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

    for target in "$main_bin" "$fw_dir"/*.dylib; do
        while IFS= read -r rpath_entry; do
            case "$rpath_entry" in
                "$brew_prefix"/*|/Library/Developer/CommandLineTools/*|/opt/homebrew/*|/usr/local/*)
                    install_name_tool -delete_rpath "$rpath_entry" "$target"
                    ;;
            esac
        done < <(otool -l "$target" | awk '/cmd LC_RPATH/{getline; getline; print $2}')
    done
    if ! otool -l "$main_bin" | awk '/cmd LC_RPATH/{getline; getline; if ($2 == "@executable_path/../Frameworks") found=1} END {exit !found}'; then
        install_name_tool -add_rpath "@executable_path/../Frameworks" "$main_bin"
    fi
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

cp "$HERE/LICENSE" "$HERE/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/"
# 保留 dylib 的原始部署版本，以实际依赖中的最高版本为准。
MIN_MACOS="$(otool -l "$APP/Contents/MacOS/$NAME" "$APP/Contents/Frameworks/"*.dylib |
    awk '
        /cmd LC_BUILD_VERSION/ { build=1; next }
        build && $1=="minos" { print $2; build=0 }
        /cmd LC_VERSION_MIN_MACOSX/ { legacy=1; next }
        legacy && $1=="version" { print $2; legacy=0 }
    ' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"
[ -n "$MIN_MACOS" ] || { echo '无法读取最低 macOS 版本' >&2; exit 1; }
ARCH="$(lipo -archs "$APP/Contents/MacOS/$NAME")"
case "$ARCH" in
    arm64|x86_64) ;;
    *) echo "不支持的产物架构：$ARCH" >&2; exit 1 ;;
esac

cat > "$APP/Contents/Info.plist" <<PLIST
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
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>SwiftVCS</string>
    <key>CFBundleDocumentTypes</key>
    <array/>
</dict>
</plist>
PLIST

echo "==> 签名（${ARCH}，macOS ${MIN_MACOS}+）"
sign_args=(--force --sign "$SIGN_IDENTITY")
if [ "$SIGN_IDENTITY" != "-" ]; then
    sign_args+=(--options runtime --timestamp)
fi
for dylib in "$APP/Contents/Frameworks/"*.dylib; do
    codesign "${sign_args[@]}" "$dylib"
done
codesign "${sign_args[@]}" "$APP"
codesign --verify --deep --strict --verbose=1 "$APP"

ZIP_OUT="$OUT/VCSExplorer-$ARCH.zip"
ZIP_TMP="$OUT/.VCSExplorer-$ARCH-$$.zip"
trap 'rm -f "$ZIP_TMP"' EXIT
ditto -c -k --norsrc --keepParent "$APP" "$ZIP_TMP"
if [ -n "$NOTARY_PROFILE" ]; then
    xcrun notarytool submit "$ZIP_TMP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    ditto -c -k --norsrc --keepParent "$APP" "$ZIP_TMP"
fi
mv -f "$ZIP_TMP" "$ZIP_OUT"

echo "==> 产物"
du -sh "$APP" "$ZIP_OUT"
file "$APP/Contents/MacOS/$NAME"
echo "$APP"
