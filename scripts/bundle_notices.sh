#!/bin/bash
# 从实际装入的 Homebrew keg 收集许可证，而不是从当前 formula 版本推测。
bundle_dylib_notices() {
    local source="$1" destination="$2" name="$3"
    local keg formula version docs file found=0
    keg="$(dirname "$(dirname "$(realpath "$source")")")"
    version="$(basename "$keg")"
    formula="$(basename "$(dirname "$keg")")"
    docs="$destination/$formula-$version"
    printf '%s\t%s\t%s\n' "$name" "$formula" "$version" >> "$destination/components.tsv"
    if [ -d "$docs" ]; then return; fi
    mkdir -p "$docs"
    for file in "$keg"/LICENSE* "$keg"/NOTICE* "$keg"/COPYING* "$keg"/COPYRIGHT*; do
        [ -f "$file" ] || continue
        cp "$file" "$docs/"
        found=1
    done
    if [ "$found" -eq 0 ]; then
        echo "未找到 $formula $version 的许可证" >&2
        return 1
    fi
    if [ "$formula" = gettext ]; then
        bundle_gettext_source "$keg" "$docs"
    fi
}

bundle_gettext_source() {
    local keg="$1" docs="$2"
    local formula="$keg/.brew/gettext.rb"
    local url digest archive cache lgpl_path
    url="$(awk -F\" '/^  url / { print $2; exit }' "$formula")"
    digest="$(awk -F\" '/^  sha256 / { print $2; exit }' "$formula")"
    archive="${url##*/}"
    if [[ "$archive" != gettext-*.tar.* || ! "$digest" =~ ^[0-9a-f]{64}$ ]]; then
        echo "无法识别 gettext 源码版本或 SHA-256" >&2
        return 1
    fi
    cache="$HERE/.build/license-sources/$digest"
    local source_archive="${SWIFTVCS_GETTEXT_SOURCE:-$cache/$archive}"
    if [ -z "${SWIFTVCS_GETTEXT_SOURCE:-}" ]; then
        mkdir -p "$cache"
        if ! printf '%s  %s\n' "$digest" "$source_archive" | shasum -a 256 --check --status 2>/dev/null; then
            local download
            download="$(mktemp "$cache/download.XXXXXXXX")"
            if ! curl --fail --silent --show-error --location --retry 2 --max-time 360 \
                "https://ftp.gnu.org/gnu/gettext/$archive" -o "$download" ||
                ! printf '%s  %s\n' "$digest" "$download" | shasum -a 256 --check; then
                rm -f "$download"
                return 1
            fi
            mv -f "$download" "$source_archive"
        fi
    fi
    printf '%s  %s\n' "$digest" "$source_archive" | shasum -a 256 --check
    cp "$source_archive" "$docs/$archive"
    cp "$formula" "$docs/"
    lgpl_path="$(tar -tf "$source_archive" | awk '/\/COPYING\.LIB$/ && !found { print; found=1 }')"
    if [ -z "$lgpl_path" ]; then
        echo 'gettext 源码包缺少 LGPL 正文' >&2
        return 1
    fi
    tar -xOf "$source_archive" "$lgpl_path" > "$docs/COPYING.LIB"
}
