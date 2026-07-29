#!/usr/bin/env bash
# lib/rust.sh: Rust toolchain, personal profile only.
#
# rustup rather than the apt `rustc`/`cargo` packages: apt's Rust is frozen at
# whatever the release shipped and cannot be pinned or switched per-project.
#
# SCOPE: Ubuntu 26.04 only, stock GNOME.

[[ -n "${_VXO_RUST_SOURCED:-}" ]] && return 0
_VXO_RUST_SOURCED=1

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

VXO_RUST_COMPONENTS=(rust-analyzer clippy rustfmt)
VXO_CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"

_vxo_rustup_bin() { printf '%s\n' "$VXO_CARGO_HOME/bin/rustup"; }
_vxo_cargo_bin()  { printf '%s\n' "$VXO_CARGO_HOME/bin/cargo"; }

_vxo_install_rustup() {
    local rustup; rustup="$(_vxo_rustup_bin)"

    if [[ -x "$rustup" ]] || have rustup; then
        [[ -x "$rustup" ]] || rustup="$(command -v rustup)"
        log_info "rustup already installed, updating the stable toolchain"
        run "$rustup" update stable || log_warn "rustup update failed, keeping the existing toolchain"
        return 0
    fi

    apt_update_once
    apt_install curl build-essential pkg-config libssl-dev

    local tmp; tmp="$(mktemp -d)"
    log_info "downloading the rustup installer"
    run curl --proto '=https' --tlsv1.2 -sSf -o "$tmp/rustup-init.sh" https://sh.rustup.rs

    # --no-modify-path: the managed .bashrc already puts ~/.cargo/bin on PATH and
    # sources ~/.cargo/env, so letting rustup edit shell rc files would duplicate it.
    run sh "$tmp/rustup-init.sh" -y --no-modify-path --default-toolchain stable
    rm -rf "$tmp"

    [[ -x "$(_vxo_rustup_bin)" ]] || die "rustup installation finished but $(_vxo_rustup_bin) is missing"
    log_ok "rustup installed"
}

_vxo_add_rust_components() {
    local rustup; rustup="$(_vxo_rustup_bin)"
    [[ -x "$rustup" ]] || { log_warn "rustup not found, skipping components"; return 0; }

    local installed component
    installed="$("$rustup" component list --installed 2>/dev/null || true)"

    for component in "${VXO_RUST_COMPONENTS[@]}"; do
        if grep -q "^${component}" <<<"$installed"; then
            log_skip "rust component already present: $component"
            continue
        fi
        run "$rustup" component add "$component" \
            || log_warn "could not add the '$component' component"
    done
}

vxo_rust() {
    if [[ "${VXO_PROFILE:-}" != "personal" ]]; then
        stage_abort "rust is a personal-profile addition, skipping on the '${VXO_PROFILE:-unset}' profile"
        return 0
    fi

    _vxo_install_rustup
    _vxo_add_rust_components

    local cargo; cargo="$(_vxo_cargo_bin)"
    if [[ -x "$cargo" ]]; then
        log_ok "cargo: $("$cargo" --version 2>/dev/null)"
    elif [[ "${VXO_DRY_RUN:-0}" != "1" ]]; then
        log_warn "cargo not found at $cargo. Open a new shell and check 'cargo --version'."
    fi
}
