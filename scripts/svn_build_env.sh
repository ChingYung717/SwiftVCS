#!/bin/bash
# Execute for a SwiftVCS build, or source for other SwiftPM commands.
_swiftvcs_build_env() {
    local root svn apr apr_util pc_dir
    local script_path
    if [ -n "${ZSH_VERSION:-}" ]; then
        script_path="${(%):-%x}"
    else
        script_path="${BASH_SOURCE[0]}"
    fi
    root="$(cd "$(dirname "$script_path")/.." && pwd)" || return
    svn="$(brew --prefix subversion)" || return
    apr="$(brew --prefix apr)" || return
    apr_util="$(brew --prefix apr-util)" || return
    if [ ! -f "$svn/include/subversion-1/svn_client.h" ] || [ ! -f "$apr/include/apr-1/apr.h" ] ||
       [ ! -f "$apr_util/lib/libaprutil-1.dylib" ]; then
        echo 'Install dependencies with brew install subversion apr apr-util pkgconf' >&2
        return 1
    fi
    pc_dir="$root/.build/pkgconfig"
    mkdir -p "$pc_dir" || return
    cat > "$pc_dir/swiftvcs-svn.pc" <<PC
Name: SwiftVCS Subversion dependencies
Description: Homebrew Subversion and APR
Version: 1
Cflags: -I"$svn/include/subversion-1" -I"$apr/include/apr-1"
Libs: -L"$svn/lib" -L"$apr/lib" -L"$apr_util/lib" -lsvn_client-1 -lsvn_ra-1 -lsvn_subr-1 -lsvn_wc-1 -lsvn_diff-1 -lapr-1
PC
    export PKG_CONFIG_PATH="$pc_dir${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
}
if [ -z "${ZSH_VERSION:-}" ] && [ "${BASH_SOURCE[0]}" = "$0" ]; then
    _swiftvcs_build_env || exit $?
    package_root="$(cd "$(dirname "$0")/.." && pwd)" || exit 1
    exec swift build --package-path "$package_root" "$@"
else
    _swiftvcs_build_env
fi
