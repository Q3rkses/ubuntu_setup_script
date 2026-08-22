#!/usr/bin/env bash
# lib/kitty_fastfetch.sh: the kitty terminal emulator and the fastfetch splash.
#
# The fastfetch config is a template: dotfiles/fastfetch/config.jsonc carries a
# @@VXO_LOGO@@ placeholder that is substituted here with the profile's splash
# image, so the same config serves the vortex logo and a personal one.
#
# kitty is in the jammy archive at 0.21.2, which is old but supports every
# option dotfiles/kitty/kitty.conf sets, so it is taken from apt as-is rather
# than chased upstream. fastfetch is not in the archive at all on this release;
# see _vxo_install_fastfetch.
#
# SCOPE: Ubuntu 22.04 only, stock GNOME.

[[ -n "${_VXO_KITTY_FASTFETCH_SOURCED:-}" ]] && return 0
_VXO_KITTY_FASTFETCH_SOURCED=1

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

VXO_FASTFETCH_DIR="$HOME/.config/fastfetch"
VXO_FASTFETCH_ICONS="$VXO_FASTFETCH_DIR/icons"

# ─────────────────────────── kitty ───────────────────────────

_vxo_install_kitty() {
    if have kitty; then
        log_skip "kitty already installed ($(kitty --version 2>/dev/null | head -1))"
    else
        apt_update_once
        apt_install kitty
    fi

    install_file "$VXO_DOTFILES/kitty/kitty.conf" "$HOME/.config/kitty/kitty.conf"
    install_file "$VXO_DOTFILES/kitty/theme.conf" "$HOME/.config/kitty/theme.conf"
}

# Make kitty the terminal GNOME and Debian alternatives reach for. Both of these
# are best-effort: a missing schema or alternative is a warning, never a failure.
_vxo_set_default_terminal() {
    local kitty_bin
    kitty_bin="$(command -v kitty || true)"
    [[ -n "$kitty_bin" ]] || return 0

    if have gsettings && gsettings writable org.gnome.desktop.default-applications.terminal exec >/dev/null 2>&1; then
        run gsettings set org.gnome.desktop.default-applications.terminal exec 'kitty' \
            || log_warn "could not set the GNOME default terminal"
    else
        log_skip "GNOME default-applications.terminal schema unavailable"
    fi

    # Process substitution, not a pipe: `grep -q` exits early and SIGPIPEs the
    # writer, which `set -o pipefail` would report as a failure.
    if update-alternatives --query x-terminal-emulator >/dev/null 2>&1 \
        && grep -qF "$kitty_bin" < <(update-alternatives --query x-terminal-emulator 2>/dev/null); then
        run sudo update-alternatives --set x-terminal-emulator "$kitty_bin" \
            || log_warn "could not set the x-terminal-emulator alternative"
    else
        log_skip "kitty is not registered as an x-terminal-emulator alternative"
    fi
}

# ─────────────────────────── fastfetch ───────────────────────────

# fastfetch is NOT in the Ubuntu 22.04 archive — it first appears in later
# releases — so on this release the upstream .deb below is the normal path, not
# an exotic fallback. Expect every 22.04 install to take it.
#
# The apt-first check stays anyway, and is not dead code: it makes the module
# correct on a release that does package fastfetch, and it is what keeps a
# re-run cheap on a machine where fastfetch arrived from apt some other way.
_vxo_install_fastfetch() {
    if have fastfetch; then
        log_skip "fastfetch already installed ($(fastfetch --version 2>/dev/null | head -1))"
        return 0
    fi

    apt_update_once
    if apt-cache show fastfetch >/dev/null 2>&1; then
        apt_install fastfetch
        return 0
    fi

    log_info "fastfetch is not in the archive for Ubuntu $(ubuntu_release), using the upstream .deb instead"

    # Same reasoning as lib/nvim.sh: the release lookup below is a bare `curl`
    # against the GitHub API, so a dry run would really call it. Harmless but
    # dishonest, and on a rate-limited network it reports a scary warning about
    # a step the dry run was never going to perform.
    if [[ "${VXO_DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] would install the upstream fastfetch .deb from GitHub releases"
        return 0
    fi

    local arch; arch="$(dpkg --print-architecture)"
    if [[ "$arch" != "amd64" ]]; then
        log_warn "no prebuilt fastfetch .deb for architecture '$arch', skipping fastfetch"
        return 0
    fi

    local tag
    tag="$(curl -fsSL https://api.github.com/repos/fastfetch-cli/fastfetch/releases/latest 2>/dev/null \
        | grep -F '"tag_name"' | head -1 | awk -F'"' '{print $4}')" || true
    if [[ -z "$tag" ]]; then
        log_warn "could not determine the latest fastfetch release (GitHub API rate limit?), skipping fastfetch"
        return 0
    fi

    local tmp; tmp="$(mktemp -d)"
    local deb="$tmp/fastfetch.deb"
    local url="https://github.com/fastfetch-cli/fastfetch/releases/download/${tag}/fastfetch-linux-${arch}.deb"

    log_info "downloading fastfetch ${tag}"
    if ! run curl -fsSL -o "$deb" "$url"; then
        log_warn "download failed: $url. Skipping fastfetch."
        rm -rf "$tmp"
        return 0
    fi

    run sudo dpkg -i "$deb" || run sudo apt-get -f install -y
    rm -rf "$tmp"

    have fastfetch || log_warn "fastfetch still not on PATH after installing the .deb"
}

# Resolve the splash image, copy it into the icons dir, echo its absolute path.
# Falls back to the profile default rather than failing the stage.
_vxo_resolve_logo() {
    local profile="${VXO_PROFILE:-vortex}"
    local default_src dest

    if [[ "$profile" == "vortex" ]]; then
        default_src="$VXO_ASSETS/logos/vortex.png"
    else
        default_src="$VXO_ASSETS/logos/holo_gt3.png"
    fi

    run mkdir -p "$VXO_FASTFETCH_ICONS"

    if [[ -n "${VXO_LOGO_SRC:-}" ]]; then
        local tmp; tmp="$(mktemp -d)"
        local candidate
        candidate="$tmp/$(basename "${VXO_LOGO_SRC%%\?*}")"
        [[ "$candidate" == */ ]] && candidate="$tmp/custom-logo.png"

        local got=0
        if [[ "$VXO_LOGO_SRC" =~ ^https?:// ]]; then
            log_info "fetching custom splash image from $VXO_LOGO_SRC"
            curl -fsSL -o "$candidate" "$VXO_LOGO_SRC" 2>/dev/null && got=1
        elif [[ -f "$VXO_LOGO_SRC" ]]; then
            cp -f "$VXO_LOGO_SRC" "$candidate" && got=1
        else
            log_warn "custom splash image not found: $VXO_LOGO_SRC"
        fi

        if ((got == 1)) && grep -qi 'image data' < <(file -b "$candidate" 2>/dev/null); then
            dest="$VXO_FASTFETCH_ICONS/$(basename "$candidate")"
            run cp -f "$candidate" "$dest"
            rm -rf "$tmp"
            log_ok "using custom splash image: $dest"
            printf '%s\n' "$dest"
            return 0
        fi

        log_warn "'$VXO_LOGO_SRC' is not a usable image, falling back to the $profile default"
        rm -rf "$tmp"
    fi

    if [[ ! -f "$default_src" ]]; then
        log_warn "bundled logo missing: $default_src. fastfetch will render without one."
        printf '%s\n' ""
        return 0
    fi

    dest="$VXO_FASTFETCH_ICONS/$(basename "$default_src")"
    run cp -f "$default_src" "$dest"
    printf '%s\n' "$dest"
}

_vxo_install_fastfetch_config() {
    local template="$VXO_DOTFILES/fastfetch/config.jsonc"
    [[ -f "$template" ]] || die "fastfetch template missing: $template"

    local logo; logo="$(_vxo_resolve_logo)"

    local rendered; rendered="$(mktemp)"
    # The logo path can contain slashes, so use a separator that cannot appear
    # in a POSIX path component.
    sed "s|@@VXO_LOGO@@|${logo}|" "$template" >"$rendered"

    if grep -qF '@@VXO_LOGO@@' "$rendered"; then
        rm -f "$rendered"
        die "fastfetch template substitution failed: @@VXO_LOGO@@ is still present"
    fi

    install_file "$rendered" "$VXO_FASTFETCH_DIR/config.jsonc"
    rm -f "$rendered"

    # The CPU module shells out to this for a short "Vendor Model (Nth Gen)"
    # label instead of the raw lscpu string.
    install_file "$VXO_DOTFILES/fastfetch/cpu-label.sh" "$VXO_FASTFETCH_DIR/cpu-label.sh" 0755
}

# ─────────────────────────── entrypoint ───────────────────────────

vxo_kitty_fastfetch() {
    _vxo_install_kitty
    _vxo_set_default_terminal
    _vxo_install_fastfetch
    _vxo_install_fastfetch_config

    if have fastfetch; then
        log_ok "fastfetch configured. Open kitty with Super+Enter to see the splash."
    fi
}
