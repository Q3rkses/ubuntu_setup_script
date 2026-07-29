#!/usr/bin/env bash
# lib/toolchain.sh: pin the C/C++ compiler.
#
# Sourced by install.sh. Provides: vxo_toolchain.
#
# We pin an explicit major version rather than chasing "newest", so two machines
# set up a month apart end up with the same compiler. Vortex code is mostly C++;
# a silent toolchain drift between members is a real source of "works on my
# machine" bugs.

[[ -n "${_VXO_TOOLCHAIN_SOURCED:-}" ]] && return 0
_VXO_TOOLCHAIN_SOURCED=1

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# The one place the pinned version is written down.
VXO_GCC_VERSION=13

# update-alternatives priority. Higher than Ubuntu's stock entries so auto mode
# also resolves to our pin.
VXO_GCC_PRIORITY=130

vxo_toolchain() {
    local v="$VXO_GCC_VERSION"

    if _vxo_gcc_already_pinned; then
        log_skip "gcc/g++ already pinned to $v ($(gcc --version | head -1))"
        return 0
    fi

    _vxo_ensure_gcc_packages
    _vxo_register_alternatives
    _vxo_verify_gcc
}

# True when update-alternatives already resolves gcc to our pinned binary.
_vxo_gcc_already_pinned() {
    local want="/usr/bin/gcc-$VXO_GCC_VERSION"
    # Process substitution, not a pipe. See lib/common.sh:pkg_installed for why
    # `cmd | grep -q` is unsafe under `set -o pipefail`.
    grep -qx "Value: $want" < <(update-alternatives --query gcc 2>/dev/null)
}

# apt candidate exists for a package name?
_vxo_apt_available() {
    local cand
    cand="$(apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ {print $2}')"
    [[ -n "$cand" && "$cand" != "(none)" ]]
}

_vxo_ensure_gcc_packages() {
    local v="$VXO_GCC_VERSION"

    apt_update_once

    # Ubuntu 26.04 carries gcc-13 in the archive (verified: 13.4.0-10ubuntu1), so
    # no PPA is needed. If a future release drops it, fail loudly rather than
    # silently reaching for ppa:ubuntu-toolchain-r/test. An unreviewed PPA on a
    # C++ team's compiler is not something to add behind the user's back.
    if ! _vxo_apt_available "gcc-$v" || ! _vxo_apt_available "g++-$v"; then
        die "gcc-$v / g++-$v are not available on Ubuntu $(ubuntu_release). \
The installer pins GCC $v (see VXO_GCC_VERSION in lib/toolchain.sh); \
change that constant deliberately rather than working around it here."
    fi

    apt_install "gcc-$v" "g++-$v"
}

_vxo_register_alternatives() {
    local v="$VXO_GCC_VERSION"

    log_info "Registering gcc-$v with update-alternatives (priority $VXO_GCC_PRIORITY)"
    run sudo update-alternatives \
        --install /usr/bin/gcc gcc "/usr/bin/gcc-$v" "$VXO_GCC_PRIORITY" \
        --slave /usr/bin/g++ g++ "/usr/bin/g++-$v" \
        --slave /usr/bin/gcc-ar gcc-ar "/usr/bin/gcc-ar-$v" \
        --slave /usr/bin/gcc-nm gcc-nm "/usr/bin/gcc-nm-$v" \
        --slave /usr/bin/gcc-ranlib gcc-ranlib "/usr/bin/gcc-ranlib-$v"

    # Explicit --set (manual mode) so a later apt install of a newer gcc with a
    # higher priority cannot silently move the symlink under us.
    run sudo update-alternatives --set gcc "/usr/bin/gcc-$v"
}

_vxo_verify_gcc() {
    local v="$VXO_GCC_VERSION"

    if [[ "${VXO_DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] would verify gcc reports version $v"
        return 0
    fi

    local gcc_major cxx_major
    gcc_major="$(gcc -dumpversion 2>/dev/null | cut -d. -f1)"
    cxx_major="$(g++ -dumpversion 2>/dev/null | cut -d. -f1)"

    [[ "$gcc_major" == "$v" ]] || die "gcc still reports major version '$gcc_major', expected $v"
    [[ "$cxx_major" == "$v" ]] || die "g++ still reports major version '$cxx_major', expected $v"

    log_ok "$(gcc --version | head -1)"
    log_ok "$(g++ --version | head -1)"
}
