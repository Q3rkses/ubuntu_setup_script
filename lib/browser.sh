#!/usr/bin/env bash
# lib/browser.sh: Chrome, Brave, Vivaldi or Firefox from the vendor's own apt repo.
#
# No snaps, anywhere. On modern Ubuntu `apt install firefox` pulls a
# transitional package that installs the snap instead, so the Mozilla repo is
# paired with an apt pin that outranks it. Chrome, Brave and Vivaldi have no snap
# in the archive, but they get the same treatment for consistency.
#
# SCOPE: Ubuntu 22.04 only, stock GNOME.

[[ -n "${_VXO_BROWSER_SOURCED:-}" ]] && return 0
_VXO_BROWSER_SOURCED=1

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# Write a root-owned config file without needing a pipe, so `run` (and therefore
# --dry-run) still covers the privileged step. Shared with lib/nvim.sh; the
# guard keeps either module independently sourceable.
if ! declare -F _vxo_write_root_file >/dev/null 2>&1; then
_vxo_write_root_file() {
    local dest="$1" content="$2"
    if [[ -f "$dest" ]] && [[ "$(cat "$dest" 2>/dev/null)" == "$content" ]]; then
        log_skip "$dest already current"
        return 0
    fi
    local tmp; tmp="$(mktemp)"
    printf '%s\n' "$content" >"$tmp"
    run sudo install -D -m 0644 "$tmp" "$dest"
    rm -f "$tmp"
    log_ok "wrote $dest"
}
fi

# _vxo_add_keyring <name> <key-url>: dearmor a vendor key into /etc/apt/keyrings.
# Echoes the keyring path. Never uses apt-key, which is deprecated and removed.
_vxo_add_keyring() {
    local name="$1" url="$2"
    local keyring="/etc/apt/keyrings/${name}.gpg"

    if [[ -f "$keyring" ]]; then
        log_skip "signing key for $name already present"
        printf '%s\n' "$keyring"
        return 0
    fi

    local tmp; tmp="$(mktemp -d)"
    run curl -fsSL -o "$tmp/${name}.key" "$url"
    run sudo install -d -m 0755 /etc/apt/keyrings
    # Vendor keys come both armoured and binary; --dearmor handles armoured and
    # dearmoring an already-binary key is an error, so fall back to a plain copy.
    if ! sudo gpg --dearmor --yes -o "$keyring" "$tmp/${name}.key" 2>/dev/null; then
        run sudo install -m 0644 "$tmp/${name}.key" "$keyring"
    fi
    run sudo chmod 0644 "$keyring"
    rm -rf "$tmp"
    log_ok "added the $name apt signing key"
    printf '%s\n' "$keyring"
}

# ─────────────────────────── chrome ───────────────────────────

_vxo_browser_chrome() {
    if have google-chrome || have google-chrome-stable; then
        log_skip "Google Chrome already installed"
        return 0
    fi

    apt_update_once
    local keyring; keyring="$(_vxo_add_keyring google-chrome https://dl.google.com/linux/linux_signing_key.pub)"

    _vxo_write_root_file /etc/apt/sources.list.d/google-chrome.list \
        "deb [arch=amd64 signed-by=${keyring}] http://dl.google.com/linux/chrome/deb/ stable main"

    run sudo apt-get update -qq
    apt_install google-chrome-stable
    log_ok "Google Chrome installed from Google's apt repo"
}

# ─────────────────────────── brave ───────────────────────────

_vxo_browser_brave() {
    if have brave-browser; then
        log_skip "Brave already installed"
        return 0
    fi

    apt_update_once
    local keyring; keyring="$(_vxo_add_keyring brave-browser https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg)"

    _vxo_write_root_file /etc/apt/sources.list.d/brave-browser-release.list \
        "deb [arch=$(dpkg --print-architecture) signed-by=${keyring}] https://brave-browser-apt-release.s3.brave.com/ stable main"

    run sudo apt-get update -qq
    apt_install brave-browser
    log_ok "Brave installed from Brave's apt repo"
}

# ─────────────────────────── vivaldi ───────────────────────────

_vxo_browser_vivaldi() {
    if have vivaldi || have vivaldi-stable; then
        log_skip "Vivaldi already installed"
        return 0
    fi

    apt_update_once
    local keyring; keyring="$(_vxo_add_keyring vivaldi https://repo.vivaldi.com/archive/linux_signing_key.pub)"

    _vxo_write_root_file /etc/apt/sources.list.d/vivaldi.list \
        "deb [arch=$(dpkg --print-architecture) signed-by=${keyring}] https://repo.vivaldi.com/archive/deb/ stable main"

    run sudo apt-get update -qq
    apt_install vivaldi-stable
    log_ok "Vivaldi installed from Vivaldi's apt repo"
}

# ─────────────────────────── firefox ───────────────────────────

_vxo_browser_firefox() {
    # A snap-installed firefox provides the binary but is not what we want, so
    # check for the apt package specifically rather than just the command.
    if pkg_installed firefox && have firefox; then
        log_skip "Firefox already installed from apt"
        return 0
    fi

    if have snap && snap list firefox >/dev/null 2>&1; then
        log_warn "Firefox is currently installed as a snap."
        log_warn "The deb from Mozilla's repo will be installed alongside it; remove the snap"
        log_warn "afterwards with: sudo snap remove firefox"
    fi

    apt_update_once
    local keyring; keyring="$(_vxo_add_keyring mozilla https://packages.mozilla.org/apt/repo-signing-key.gpg)"

    _vxo_write_root_file /etc/apt/sources.list.d/mozilla.list \
        "deb [signed-by=${keyring}] https://packages.mozilla.org/apt mozilla main"

    # Without this pin Ubuntu's transitional `firefox` package (which installs
    # the snap) outranks Mozilla's build and apt silently picks the snap.
    _vxo_write_root_file /etc/apt/preferences.d/mozilla \
        "$(printf 'Package: *\nPin: origin packages.mozilla.org\nPin-Priority: 1000\n')"

    run sudo apt-get update -qq
    apt_install firefox
    log_ok "Firefox installed from Mozilla's apt repo (snap pinned out)"
}

# ─────────────────────────── entrypoint ───────────────────────────

vxo_browser() {
    case "${VXO_BROWSER:-chrome}" in
        chrome)  _vxo_browser_chrome ;;
        brave)   _vxo_browser_brave ;;
        vivaldi) _vxo_browser_vivaldi ;;
        firefox) _vxo_browser_firefox ;;
        *)       die "unknown browser: '${VXO_BROWSER:-}' (expected chrome, brave, vivaldi or firefox)" ;;
    esac
}
