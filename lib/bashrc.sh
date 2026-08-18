#!/usr/bin/env bash
# lib/bashrc.sh: shell configuration and the things it depends on.
#
# Sourced by install.sh. Provides: vxo_bashrc.
#
# The shipped .bashrc is generic: it guards every optional tool and reads the
# per-machine choices (profile, editor, workspace path) from a small generated
# env file. That keeps one dotfile working for both profiles instead of
# templating the .bashrc itself.

[[ -n "${_VXO_BASHRC_SOURCED:-}" ]] && return 0
_VXO_BASHRC_SOURCED=1

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# The ROS 2 workspace root. Replaces the old ~/vscopium/ros2_ws layout; ros2.sh
# clones into $VXO_ROS_WS/src.
export VXO_ROS_WS="$HOME/code/ros2_ws"

VXO_ENV_FILE="$HOME/.config/vortex-onboarding/env.sh"
VXO_NVM_DIR="$HOME/.nvm"
VXO_NVM_VERSION="v0.40.1"

VXO_BLESH_DIR="$HOME/.local/share/blesh"
VXO_BLESH_MAIN="$VXO_BLESH_DIR/ble.sh"

vxo_bashrc() {
    _vxo_write_env_file
    _vxo_install_login_hooks
    _vxo_install_shell_files
    _vxo_install_nvm
    _vxo_install_blesh
    _vxo_make_workspace
}

# ble.sh gives inline autosuggestions from history plus live syntax
# highlighting, the bash counterpart to PowerShell's predictive IntelliSense.
#
# Best-effort on purpose: this stage is "hard", and a shell nicety failing to
# build must not cost the user their dotfiles. The managed .bashrc guards both
# the source and the attach, so a missing ble.sh is simply inert.
_vxo_install_blesh() {
    install_file "$VXO_DOTFILES/blerc" "$HOME/.blerc"

    if [[ -f "$VXO_BLESH_MAIN" ]]; then
        log_skip "ble.sh already installed"
        return 0
    fi

    if [[ "${VXO_DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] would build and install ble.sh to $VXO_BLESH_DIR"
        return 0
    fi

    # gawk is ble.sh's preferred awk; make comes with build-essential.
    apt_install gawk make git

    local tmp; tmp="$(mktemp -d)"
    log_info "building ble.sh (about a minute)"

    if ! git clone --recursive --depth 1 --shallow-submodules \
            https://github.com/akinomyoga/ble.sh.git "$tmp/ble.sh" \
            >>"$VXO_LOG_FILE" 2>&1; then
        rm -rf "$tmp"
        log_warn "could not clone ble.sh, so shell autosuggestions will be unavailable."
        log_warn "Retry later with: ./install.sh --only=bashrc"
        return 0
    fi

    if ! make -C "$tmp/ble.sh" install PREFIX="$HOME/.local" >>"$VXO_LOG_FILE" 2>&1; then
        rm -rf "$tmp"
        log_warn "ble.sh failed to build (see $VXO_LOG_FILE), continuing without it."
        return 0
    fi

    rm -rf "$tmp"

    if [[ -f "$VXO_BLESH_MAIN" ]]; then
        log_ok "ble.sh installed to $VXO_BLESH_DIR"
    else
        log_warn "ble.sh reported success but $VXO_BLESH_MAIN is missing, continuing without it."
    fi
}

# ───────────────────────────── generated env ─────────────────────────────

# Written before the .bashrc that reads it, so the very next shell is correct.
# Make env.sh reach login shells and the GUI session, not just interactive ones.
#
# The managed .bashrc sources env.sh, but .bashrc returns immediately for
# non-interactive shells. That leaves two gaps that matter for EDITOR:
#
#   * the GNOME session. Nautilus, and anything launched from the Activities
#     overview, inherit the environment GDM built from ~/.profile. Without this,
#     EDITOR is unset for every GUI app.
#   * `ssh host <command>` and other non-interactive login shells.
#
# ~/.profile covers both on a stock Ubuntu install. The ~/.bash_profile case is
# the awkward one: when that file exists, bash reads it INSTEAD of ~/.profile
# and the hook below would never run, so it gets its own copy. A fresh ISO has
# no ~/.bash_profile, hence the existence check rather than creating one.
_vxo_install_login_hooks() {
    local hook
    hook="$(cat <<'EOF'
if [ -f "$HOME/.config/vortex-onboarding/env.sh" ]; then
    . "$HOME/.config/vortex-onboarding/env.sh"
fi
EOF
)"

    ensure_block "$HOME/.profile" "vortex-onboarding-env" "$hook"

    # Deliberately not created when absent: an empty ~/.bash_profile would stop
    # bash reading ~/.profile at all, which is a worse outcome than this hook.
    if [[ -f "$HOME/.bash_profile" ]]; then
        ensure_block "$HOME/.bash_profile" "vortex-onboarding-env" "$hook"
    fi
}

# EDITOR/VISUAL/SUDO_EDITOR, but only when Neovim was the choice.
#
# These three cover almost everything that asks "which editor?": git (when
# core.editor is unset), sudoedit, crontab -e, less -v, and most TUI tools.
# SUDO_EDITOR is separate because sudoedit checks it before the other two.
#
# Nothing is emitted for the VS Code choice. `code` blocks until the window is
# closed only with --wait, and an EDITOR that returns instantly makes git think
# you saved an empty commit message.
_vxo_editor_env_lines() {
    [[ "${VXO_EDITOR:-nvim}" == "nvim" ]] || return 0
    cat <<'EOF'

# Default editor. Set here rather than in .bashrc so that re-running
# --only=bashrc updates it, and so the value is identical in every shell.
export EDITOR="nvim"
export VISUAL="nvim"
export SUDO_EDITOR="nvim"
EOF
}

_vxo_write_env_file() {
    local content
    content="$(cat <<EOF
# Generated by vortex-onboarding. Do not edit; re-run ./install.sh --only=bashrc
# Consumed by ~/.bashrc and by tests/verify_install.sh. Keep every key the
# verifier reads (profile, editor, browser, theme, ros) present, or its
# profile-specific checks silently degrade to SKIP and stop testing anything.
export VXO_PROFILE="${VXO_PROFILE:-vortex}"
export VXO_EDITOR="${VXO_EDITOR:-nvim}"
export VXO_BROWSER="${VXO_BROWSER:-}"
export VXO_THEME="${VXO_THEME:-dark-magenta}"
export VXO_ROS="${VXO_ROS:-0}"
export VXO_ROS_WS="\$HOME/code/ros2_ws"
$(_vxo_editor_env_lines)
EOF
)"

    if [[ "${VXO_DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] would write $VXO_ENV_FILE"
        return 0
    fi

    mkdir -p "$(dirname "$VXO_ENV_FILE")"
    if [[ -f "$VXO_ENV_FILE" ]] && [[ "$(cat "$VXO_ENV_FILE")" == "$content" ]]; then
        log_skip "$(basename "$VXO_ENV_FILE") already up to date"
        return 0
    fi

    printf '%s\n' "$content" >"$VXO_ENV_FILE"
    log_ok "wrote $VXO_ENV_FILE (profile=${VXO_PROFILE:-vortex}, editor=${VXO_EDITOR:-nvim}, browser=${VXO_BROWSER:-unset}, theme=${VXO_THEME:-dark-magenta}, ros=${VXO_ROS:-0})"
}

# ───────────────────────────── dotfiles ─────────────────────────────

_vxo_install_shell_files() {
    install_file "$VXO_DOTFILES/bashrc"       "$HOME/.bashrc"
    install_file "$VXO_DOTFILES/bash_aliases" "$HOME/.bash_aliases"

    if [[ "${VXO_PROFILE:-vortex}" == "personal" ]]; then
        install_file "$VXO_DOTFILES/bash_aliases.personal" "$HOME/.bash_aliases.personal"
    else
        log_skip "vortex profile, skipping personal aliases"
    fi
}

# ───────────────────────────── nvm ─────────────────────────────

# The .bashrc lazy-loads nvm, so the directory has to exist for the stub to be
# defined. PROFILE=/dev/null stops the upstream installer appending its own
# (eager, ~200ms) block to the .bashrc we just installed.
_vxo_install_nvm() {
    if [[ -s "$VXO_NVM_DIR/nvm.sh" ]]; then
        log_skip "nvm already installed at $VXO_NVM_DIR"
        return 0
    fi

    if [[ "${VXO_DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] would install nvm $VXO_NVM_VERSION to $VXO_NVM_DIR"
        return 0
    fi

    log_info "Installing nvm $VXO_NVM_VERSION"
    local url="https://raw.githubusercontent.com/nvm-sh/nvm/${VXO_NVM_VERSION}/install.sh"

    if ! curl -fsSL --retry 3 "$url" | PROFILE=/dev/null NVM_DIR="$VXO_NVM_DIR" bash; then
        log_warn "nvm installation failed, so the lazy nvm stub will simply not activate"
        return 0
    fi

    log_ok "nvm installed to $VXO_NVM_DIR"
}

# ───────────────────────────── workspace ─────────────────────────────

# Created here rather than in ros2.sh so the .bashrc's workspace sourcing has a
# valid path even on a machine where ROS was never installed.
_vxo_make_workspace() {
    run mkdir -p "$VXO_ROS_WS/src"
    log_ok "ROS 2 workspace root ready at $VXO_ROS_WS"
}
