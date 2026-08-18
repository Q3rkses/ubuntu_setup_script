#!/usr/bin/env bash
# lib/base.sh: system update, base packages, Nerd Font, starship, ulauncher.
#
# Sourced by install.sh. Provides: vxo_apt_upgrade, vxo_base_packages.

[[ -n "${_VXO_BASE_SOURCED:-}" ]] && return 0
_VXO_BASE_SOURCED=1

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# The font family name the kitty config asks for. Keep these two in lockstep
# with dotfiles/kitty/kitty.conf.
VXO_NERD_FONT_NAME="JetBrainsMono Nerd Font"
VXO_NERD_FONT_ZIP="JetBrainsMono.zip"
VXO_NERD_FONT_DIR="$HOME/.local/share/fonts/NerdFonts/JetBrainsMono"

# Packages every profile gets. Kept as one list so the apt_install call is a
# single transaction and re-runs are cheap no-ops.
VXO_BASE_PACKAGES=(
    build-essential
    cmake
    ninja-build
    pkg-config
    git
    curl
    wget
    ca-certificates
    gnupg
    software-properties-common
    apt-transport-https
    python3-pip
    python3-venv
    fzf
    ripgrep
    fd-find
    ranger
    jq
    unzip
    fontconfig
    bash-completion
    wl-clipboard
    xclip
)

# ───────────────────────────── system update ─────────────────────────────

vxo_apt_upgrade() {
    log_info "Refreshing package lists"
    run sudo apt-get update
    _VXO_APT_UPDATED=1

    log_info "Upgrading installed packages (this can take a while on a fresh ISO)"
    run sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

    log_ok "System is up to date"
}

# ───────────────────────────── base packages ─────────────────────────────

vxo_base_packages() {
    apt_update_once
    apt_install "${VXO_BASE_PACKAGES[@]}"

    _vxo_install_nerd_font
    _vxo_install_starship
    _vxo_install_ulauncher
}

# kitty, fastfetch and starship all render glyphs that plain JetBrains Mono does
# not carry. Without the Nerd Font everything shows tofu boxes.
#
# Process substitution rather than `fc-list | grep -q`: under `set -o pipefail`
# grep -q exits at the first match and SIGPIPEs fc-list, which emits hundreds of
# lines, so the pipeline reports failure on a successful match. That false
# negative re-downloads the font on every run. See lib/common.sh:pkg_installed.
_vxo_install_nerd_font() {
    if grep -qF "$VXO_NERD_FONT_NAME" < <(fc-list 2>/dev/null); then
        log_skip "$VXO_NERD_FONT_NAME already installed"
        return 0
    fi

    if [[ "${VXO_DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] would download and install $VXO_NERD_FONT_NAME"
        return 0
    fi

    log_info "Installing $VXO_NERD_FONT_NAME"

    local tmp
    tmp="$(mktemp -d)"

    # Cleanup is explicit, NOT `trap ... RETURN`. A RETURN trap set inside a
    # function is installed globally, so it fires again when the *calling*
    # function returns, at which point $tmp is out of scope and `set -u` kills
    # the stage with "tmp: unbound variable". Explicit removal is less elegant
    # and actually correct.
    local url="https://github.com/ryanoasis/nerd-fonts/releases/latest/download/${VXO_NERD_FONT_ZIP}"
    if ! curl -fsSL --retry 3 -o "$tmp/$VXO_NERD_FONT_ZIP" "$url"; then
        rm -rf "$tmp"
        die "Could not download the Nerd Font from $url"
    fi

    mkdir -p "$VXO_NERD_FONT_DIR"
    if ! unzip -oq "$tmp/$VXO_NERD_FONT_ZIP" -d "$VXO_NERD_FONT_DIR" -x 'LICENSE*' 'README*' 'OFL*'; then
        rm -rf "$tmp"
        die "Could not unpack $VXO_NERD_FONT_ZIP"
    fi
    rm -rf "$tmp"

    fc-cache -f "$VXO_NERD_FONT_DIR" >/dev/null

    if grep -qF "$VXO_NERD_FONT_NAME" < <(fc-list 2>/dev/null); then
        log_ok "$VXO_NERD_FONT_NAME installed to $VXO_NERD_FONT_DIR"
    else
        die "Nerd Font unpacked but fontconfig still cannot see '$VXO_NERD_FONT_NAME'"
    fi
}

# The .bashrc tests for the starship binary at this exact path, so honour it
# rather than letting the installer pick /usr/local/bin.
_vxo_install_starship() {
    local dest="$HOME/.local/bin/starship"

    if [[ -x "$dest" ]]; then
        log_skip "starship already installed ($("$dest" --version 2>/dev/null | head -1))"
    elif [[ "${VXO_DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] would install starship to $dest"
    else
        log_info "Installing starship to $dest"
        mkdir -p "$HOME/.local/bin"
        # The official installer is the only supported distribution channel;
        # --bin-dir keeps it out of /usr/local so no sudo is needed.
        if ! curl -sS https://starship.rs/install.sh | sh -s -- --yes --bin-dir "$HOME/.local/bin"; then
            die "starship installation failed"
        fi
        log_ok "starship installed"
    fi

    install_file "$VXO_DOTFILES/starship.toml" "$HOME/.config/starship.toml"
}

# ───────────────────────────── ulauncher ─────────────────────────────

# The Super+F application launcher. The binding itself is set in shortcuts.sh;
# this installs the launcher, its settings and its autostart entry.
#
# Not in the Ubuntu archive, so it comes from the upstream maintainer's PPA.
# That is the only PPA this installer adds; see lib/apps.sh for the wider
# distribution policy.
VXO_ULAUNCHER_PPA="ppa:agornostal/ulauncher"

_vxo_install_ulauncher() {
    _vxo_ulauncher_package
    _vxo_ulauncher_config
    _vxo_ulauncher_autostart
}

# add-apt-repository is idempotent, but it also runs its own `apt update` and
# prompts on a tty, so guard on the sources file and pass -y.
_vxo_ulauncher_package() {
    if pkg_installed ulauncher; then
        log_skip "ulauncher already installed"
        return 0
    fi

    if [[ "${VXO_DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] would add $VXO_ULAUNCHER_PPA and install ulauncher"
        return 0
    fi

    # The PPA is a soft dependency of the whole stage: a Launchpad outage, or a
    # release the PPA has no build for yet, must not cost the user their base
    # packages. Everything below degrades to a warning.
    if ! _vxo_ulauncher_ppa_present; then
        apt_install software-properties-common
        if ! run sudo add-apt-repository -y "$VXO_ULAUNCHER_PPA"; then
            log_warn "could not add $VXO_ULAUNCHER_PPA, so ulauncher was not installed."
            log_warn "Super+F will do nothing until you install it. Retry: ./install.sh --only=base-packages"
            return 0
        fi
        # add-apt-repository already refreshed the lists it added; make the rest
        # of the install reuse that instead of doing a second full update.
        _VXO_APT_UPDATED=1
    fi

    if ! run sudo DEBIAN_FRONTEND=noninteractive apt-get install -y ulauncher; then
        log_warn "ulauncher failed to install from $VXO_ULAUNCHER_PPA (no build for Ubuntu $(ubuntu_release)?)."
        log_warn "Super+F will do nothing until you install it."
        return 0
    fi

    log_ok "ulauncher installed from $VXO_ULAUNCHER_PPA"
}

# Both the deb822 (.sources) and the legacy (.list) layouts, because 26.04 writes
# the former and an upgraded machine may still carry the latter.
_vxo_ulauncher_ppa_present() {
    grep -rqs "ppa.launchpadcontent.net/agornostal/ulauncher" \
        /etc/apt/sources.list.d/ /etc/apt/sources.list 2>/dev/null
}

# Written before the package is even guaranteed to be there: ulauncher reads
# these at startup and rewrites the file on exit, so seeding it first is what
# makes the first launch already look right.
_vxo_ulauncher_config() {
    install_file "$VXO_DOTFILES/ulauncher/settings.json" "$HOME/.config/ulauncher/settings.json"
}

# ulauncher must already be running for `ulauncher-toggle` (the Super+F command)
# to show anything, so it has to start with the session.
#
# GDK_BACKEND=x11 is load-bearing under Wayland, not cargo cult: ulauncher's
# window is an override-redirect popup that Wayland does not let a client
# position, so the native-Wayland process starts and then never appears. Running
# it through XWayland is upstream's own documented workaround.
_vxo_ulauncher_autostart() {
    install_file "$VXO_DOTFILES/ulauncher/ulauncher.desktop" \
        "$HOME/.config/autostart/ulauncher.desktop"

    # Start it now as well, so Super+F works in the current session rather than
    # only after the next login the installer already asks for.
    if [[ "${VXO_DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] would start ulauncher for the current session"
        return 0
    fi

    have ulauncher || return 0
    if pgrep -u "$(id -u)" -f 'ulauncher' >/dev/null 2>&1; then
        log_skip "ulauncher is already running"
        return 0
    fi

    GDK_BACKEND=x11 setsid ulauncher --hide-window >/dev/null 2>&1 &
    log_ok "ulauncher started (Super+F)"
}
