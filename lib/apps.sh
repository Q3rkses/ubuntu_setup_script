#!/usr/bin/env bash
# lib/apps.sh: the everyday applications and dev tools that are not part of any
# other stage's job.
#
# Sourced by install.sh. Provides: vxo_apps.
#
# DISTRIBUTION POLICY, in order of preference:
#
#   1. apt from the Ubuntu archive        everything that is packaged there
#   2. apt from the vendor's own repo     Docker, and only Docker
#   3. cargo                              Rust tools with no archive package
#
# Explicitly NOT used: flatpak and snap. Both are deliberate. Every package
# below exists in the archive or in a vendor apt repo, so reaching for a third
# packaging system would add an updater, a sandbox and a runtime download for no
# benefit. If you find yourself wanting to add a flatpak here, add the apt
# package instead, or leave it to be installed by hand.
#
# SCOPE: Ubuntu 22.04 only, stock GNOME.

[[ -n "${_VXO_APPS_SOURCED:-}" ]] && return 0
_VXO_APPS_SOURCED=1

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# ─────────────────────────── the package set ───────────────────────────

# C/C++ tooling beyond the compiler itself. clangd is the language server the
# nvim config's mason.lua expects to find; clang-format and clang-tidy are what
# vortex-ci runs, so having them locally means the same verdict before you push.
VXO_APPS_CXX_TOOLS=(
    clangd
    clang-format
    clang-tidy
    doxygen
    lcov
)

# Shell tooling. shellcheck and shfmt are what this repo's own quality gate
# runs, so anyone editing the installer needs them.
VXO_APPS_SHELL_TOOLS=(
    shellcheck
    shfmt
)

# Terminal everyday tools.
VXO_APPS_TERMINAL=(
    btop
    tmux
    imagemagick
)

# GNOME configuration front-ends. gnome-tweaks exposes the settings that are not
# in Settings; extension-manager is how you browse and toggle extensions without
# a browser plugin. lib/extensions.sh installs extensions non-interactively, but
# you still want the GUI when you go looking for a new one.
VXO_APPS_GNOME=(
    gnome-tweaks
    gnome-shell-extension-manager
)

# Fonts. The Nerd Font itself is handled in lib/base.sh; FiraCode is here
# because it is a plain archive package and several editors default to it.
VXO_APPS_FONTS=(
    fonts-firacode
)

# Input methods. The desktop stage configures the en/no/jp source list; without
# ibus-mozc the Japanese entry in that list resolves to nothing and silently
# disappears from the switcher. Package and configuration have to ship together.
VXO_APPS_INPUT=(
    ibus
    ibus-mozc
)

# Docker's own packages, from Docker's apt repo (see _vxo_apps_docker_repo).
# docker.io in the Ubuntu archive is an older, differently-packaged Docker
# without the compose and buildx plugins, so it is not a substitute.
VXO_APPS_DOCKER=(
    docker-ce
    docker-ce-cli
    containerd.io
    docker-buildx-plugin
    docker-compose-plugin
)

# ─────────────────────────── entrypoint ───────────────────────────

vxo_apps() {
    apt_update_once

    apt_install \
        "${VXO_APPS_CXX_TOOLS[@]}" \
        "${VXO_APPS_SHELL_TOOLS[@]}" \
        "${VXO_APPS_TERMINAL[@]}" \
        "${VXO_APPS_GNOME[@]}" \
        "${VXO_APPS_FONTS[@]}" \
        "${VXO_APPS_INPUT[@]}"

    _vxo_apps_docker
}

# ─────────────────────────── docker ───────────────────────────

_vxo_apps_docker() {
    if have docker && pkg_installed docker-ce; then
        log_skip "Docker already installed from Docker's apt repo"
        _vxo_apps_docker_group
        return 0
    fi

    _vxo_apps_docker_repo
    apt_install "${VXO_APPS_DOCKER[@]}"
    _vxo_apps_docker_group

    log_ok "Docker installed from Docker's apt repo"
}

_vxo_apps_docker_repo() {
    local keyring="/etc/apt/keyrings/docker.gpg"
    local listfile="/etc/apt/sources.list.d/docker.list"

    apt_install ca-certificates curl gnupg

    if [[ -f "$keyring" ]]; then
        log_skip "Docker apt signing key already present"
    else
        local tmp; tmp="$(mktemp -d)"
        run curl -fsSL -o "$tmp/docker.asc" https://download.docker.com/linux/ubuntu/gpg
        run sudo install -d -m 0755 /etc/apt/keyrings
        run sudo gpg --dearmor --yes -o "$keyring" "$tmp/docker.asc"
        run sudo chmod 0644 "$keyring"
        rm -rf "$tmp"
        log_ok "added the Docker apt signing key"
    fi

    # UBUNTU_CODENAME, not VERSION_CODENAME: on an Ubuntu derivative the latter
    # is the derivative's own codename, which Docker's repo has never heard of.
    local codename
    codename="$(_os_release_field UBUNTU_CODENAME)"
    [[ -n "$codename" ]] || codename="$(_os_release_field VERSION_CODENAME)"
    [[ -n "$codename" ]] || { log_warn "could not read the Ubuntu codename, skipping Docker"; return 1; }

    _vxo_apps_write_root_file "$listfile" \
        "deb [arch=$(dpkg --print-architecture) signed-by=${keyring}] https://download.docker.com/linux/ubuntu ${codename} stable"

    run sudo apt-get update -qq
}

# Without this every docker command needs sudo, which then writes root-owned
# files into your bind mounts. Takes effect on next login, like the shortcuts.
#
# `id -un` rather than $USER: the variable is set by login shells, and this
# installer is routinely run from contexts that are not one (a container's
# `bash -c`, a CI step). Under `set -u` a bare $USER there is not a wrong value,
# it is an immediate unbound-variable abort.
_vxo_apps_docker_group() {
    local user
    user="${USER:-$(id -un)}"

    if [[ "${VXO_DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] would add $user to the docker group"
        return 0
    fi

    # Process substitution, not a pipe: `grep -qw` exits at the first match and
    # SIGPIPEs `id`, which `set -o pipefail` reports as a failed pipeline. See
    # lib/common.sh:pkg_installed.
    if grep -qw docker < <(id -nG "$user" 2>/dev/null); then
        log_skip "$user is already in the docker group"
        return 0
    fi

    run sudo groupadd -f docker
    run sudo usermod -aG docker "$user" || { log_warn "could not add $user to the docker group"; return 0; }

    log_ok "added $user to the docker group"
    log_warn "Log out and back in before docker works without sudo."
}

# Same helper as lib/browser.sh and lib/nvim.sh use. The guard keeps this module
# independently sourceable via --only=apps.
if ! declare -F _vxo_apps_write_root_file >/dev/null 2>&1; then
_vxo_apps_write_root_file() {
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
