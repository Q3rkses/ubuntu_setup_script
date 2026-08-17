#!/usr/bin/env bash
# lib/nvim.sh: the editor stage. Dispatches on $VXO_EDITOR to Neovim or VS Code.
#
# Neovim deliberately does NOT come from apt: archive versions lag, and
# cannot load a modern lazy.nvim config at all. We take the upstream stable
# tarball instead and require >= 0.10.
#
# SCOPE: Ubuntu 26.04 only, stock GNOME.

[[ -n "${_VXO_NVIM_SOURCED:-}" ]] && return 0
_VXO_NVIM_SOURCED=1

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

VXO_NVIM_MIN_MAJOR=0
VXO_NVIM_MIN_MINOR=10
VXO_NVIM_REPO_SSH="git@github.com:Q3rkses/nvimconf.git"
VXO_NVIM_REPO_HTTPS="https://github.com/Q3rkses/nvimconf.git"
VXO_NVIM_CONFIG_DIR="$HOME/.config/nvim"

# Write a root-owned config file without needing a pipe, so `run` (and therefore
# --dry-run) still covers the privileged step. Shared with lib/browser.sh; the
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

# ─────────────────────────── neovim ───────────────────────────

# Echo the installed nvim version as "major minor", or nothing if absent.
_vxo_nvim_version() {
    have nvim || return 0
    nvim --version 2>/dev/null | head -1 \
        | sed -nE 's/^NVIM v([0-9]+)\.([0-9]+).*/\1 \2/p'
}

_vxo_nvim_is_recent_enough() {
    local ver major minor
    ver="$(_vxo_nvim_version)"
    [[ -n "$ver" ]] || return 1
    read -r major minor <<<"$ver"
    ((major > VXO_NVIM_MIN_MAJOR)) && return 0
    ((major == VXO_NVIM_MIN_MAJOR && minor >= VXO_NVIM_MIN_MINOR))
}

_vxo_install_neovim_binary() {
    if _vxo_nvim_is_recent_enough; then
        log_skip "neovim already >= ${VXO_NVIM_MIN_MAJOR}.${VXO_NVIM_MIN_MINOR} ($(nvim --version | head -1))"
        return 0
    fi

    if have nvim; then
        log_info "neovim $(nvim --version | head -1) is too old for the config, installing upstream stable"
    fi

    # A dry run must not reach the network. Everything below fetches the stable
    # tarball with a bare `curl` rather than through `run`, so without this guard
    # `--dry-run` really downloads it and then `die`s when it cannot, which is
    # both a surprise and a lie about what the real install would do.
    if [[ "${VXO_DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] would download the neovim stable tarball, unpack it into /opt"
        log_info "[dry-run]   and link it as /usr/local/bin/nvim"
        return 0
    fi

    local arch; arch="$(dpkg --print-architecture)"
    if [[ "$arch" != "amd64" ]]; then
        log_warn "no upstream neovim tarball for architecture '$arch', falling back to apt"
        apt_update_once
        apt_install neovim
        return 0
    fi

    local tmp; tmp="$(mktemp -d)"
    local tarball="$tmp/nvim.tar.gz"

    # Release asset was renamed between versions; try the current name first.
    local names=("nvim-linux-x86_64.tar.gz" "nvim-linux64.tar.gz")
    local got="" name
    for name in "${names[@]}"; do
        local url="https://github.com/neovim/neovim/releases/download/stable/${name}"
        log_info "trying $name"
        if curl -fsSL -o "$tarball" "$url" 2>/dev/null; then
            got="$name"
            break
        fi
    done

    if [[ -z "$got" ]]; then
        rm -rf "$tmp"
        die "could not download the neovim stable tarball (tried: ${names[*]})"
    fi

    # The archive's top-level directory matches the asset name minus .tar.gz.
    local topdir="${got%.tar.gz}"
    run tar -xzf "$tarball" -C "$tmp"
    [[ -x "$tmp/$topdir/bin/nvim" ]] || { rm -rf "$tmp"; die "unexpected neovim tarball layout (no $topdir/bin/nvim)"; }

    run sudo rm -rf "/opt/$topdir"
    run sudo mv "$tmp/$topdir" "/opt/$topdir"
    run sudo ln -sfn "/opt/$topdir/bin/nvim" /usr/local/bin/nvim
    rm -rf "$tmp"

    hash -r 2>/dev/null || true
    log_ok "installed neovim: $(nvim --version 2>/dev/null | head -1)"
}

_vxo_install_nvim_deps() {
    apt_update_once
    # ripgrep/fd-find usually arrive with the base stage; apt_install is
    # idempotent so listing them again costs nothing and keeps this module
    # runnable on its own via --only=editor.
    apt_install ripgrep fd-find python3-venv nodejs npm unzip
}

_vxo_clone_nvim_config() {
    local url="$VXO_NVIM_REPO_HTTPS" via="HTTPS"
    # SSH is a verified precondition of every real install, so this is SSH unless
    # the run used --skip-ssh-check. The declare -F guard keeps this module
    # sourceable on its own, without ssh_github.sh.
    if declare -F vxo_use_ssh_remotes >/dev/null && vxo_use_ssh_remotes; then
        url="$VXO_NVIM_REPO_SSH"; via="SSH"
    fi
    log_info "fetching the neovim config over $via"

    if [[ -e "$VXO_NVIM_CONFIG_DIR" ]]; then
        local existing=""
        if [[ -d "$VXO_NVIM_CONFIG_DIR/.git" ]]; then
            existing="$(git -C "$VXO_NVIM_CONFIG_DIR" remote get-url origin 2>/dev/null || true)"
        fi
        if [[ "$existing" == *nvimconf* ]]; then
            git_sync "$url" "$VXO_NVIM_CONFIG_DIR"
            return 0
        fi
        # Someone else's config, or an unversioned directory. Move it aside;
        # never delete a config we did not create.
        local backup
        backup="${VXO_NVIM_CONFIG_DIR}.bak.$(date +%s)"
        log_warn "$VXO_NVIM_CONFIG_DIR exists and is not nvimconf, moving it to $backup"
        run mv "$VXO_NVIM_CONFIG_DIR" "$backup"
    fi

    git_sync "$url" "$VXO_NVIM_CONFIG_DIR"
}

# Pre-warm the plugin manager so the first real launch is instant rather than a
# multi-minute download. Best effort: a failure here costs speed, not function.
_vxo_nvim_lazy_sync() {
    have nvim || { log_warn "nvim not on PATH, skipping plugin sync"; return 0; }

    local log="$VXO_LOG_DIR/nvim-lazy-sync.log"
    log_info "syncing neovim plugins headlessly (up to 10 min, log: $log)"

    if [[ "${VXO_DRY_RUN:-0}" == "1" ]]; then
        log_skip "[dry-run] nvim --headless '+Lazy! sync' +qa"
        return 0
    fi

    local rc=0
    timeout 600 nvim --headless "+Lazy! sync" +qa >"$log" 2>&1 || rc=$?

    if ((rc == 124)); then
        log_warn "plugin sync timed out after 10 min. The first launch of nvim will finish it. Log: $log"
    elif ((rc != 0)); then
        log_warn "plugin sync exited $rc. nvim still works, the first launch will retry. Log: $log"
    else
        log_ok "neovim plugins synced"
    fi
    return 0
}

_vxo_editor_nvim() {
    _vxo_install_nvim_deps
    _vxo_install_neovim_binary
    _vxo_clone_nvim_config
    _vxo_nvim_lazy_sync
    _vxo_nvim_make_default
}

# ─────────────────────── neovim as THE default editor ───────────────────────
#
# "Default editor" is four unrelated mechanisms on Ubuntu, and setting only one
# of them is why nano keeps reappearing:
#
#   1. $EDITOR / $VISUAL / $SUDO_EDITOR   most CLI tools. Written to env.sh by
#                                         lib/bashrc.sh, not here.
#   2. update-alternatives "editor"       what /usr/bin/editor points at. This
#                                         is what `sensible-editor` resolves,
#                                         and what several Debian tools call
#                                         when $EDITOR is unset.
#   3. git core.editor / sequence.editor  git ignores $EDITOR when these are
#                                         set. Handled in lib/ssh_github.sh.
#   4. xdg-mime associations              double-clicking a file in Nautilus.
#
# This function does 2 and 4.
_vxo_nvim_make_default() {
    _vxo_nvim_alternatives
    _vxo_nvim_mime_defaults
}

_vxo_nvim_alternatives() {
    local bin=/usr/local/bin/nvim
    [[ -e "$bin" ]] || bin="$(command -v nvim 2>/dev/null || echo /usr/local/bin/nvim)"

    # Priority 200 beats Ubuntu's stock entries (nano is 40, vim.tiny 15), so
    # even auto mode resolves to Neovim. --set then pins it in manual mode, so a
    # later apt install of some higher-priority editor cannot take it back.
    run sudo update-alternatives --install /usr/bin/editor editor "$bin" 200 \
        || { log_warn "could not register $bin with update-alternatives"; return 0; }
    run sudo update-alternatives --set editor "$bin" \
        || log_warn "could not set the editor alternative to $bin"

    log_ok "update-alternatives: editor -> $bin"
}

# Text-ish MIME types that should open in Neovim from the file manager.
#
# nvim.desktop ships with Terminal=true, so GNOME launches it inside the default
# terminal. That is the intended behaviour, not a bug: a terminal editor with no
# terminal has nowhere to draw.
VXO_NVIM_MIMETYPES=(
    text/plain
    text/markdown
    text/csv
    text/x-c
    text/x-csrc
    text/x-chdr
    text/x-c++src
    text/x-c++hdr
    text/x-python
    text/x-java
    text/x-lua
    text/x-makefile
    text/x-tex
    text/x-shellscript
    application/x-shellscript
    application/json
    application/xml
    application/x-yaml
    application/toml
)

_vxo_nvim_mime_defaults() {
    if ! have xdg-mime; then
        log_warn "xdg-mime is missing, so file-manager associations were left alone"
        return 0
    fi

    # The desktop entry comes from the distro's neovim packaging. The tarball
    # install does not ship one, so write it if it is absent.
    _vxo_nvim_desktop_entry

    if [[ "${VXO_DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] would set nvim.desktop as the default for ${#VXO_NVIM_MIMETYPES[@]} MIME types"
        return 0
    fi

    local m failed=0
    for m in "${VXO_NVIM_MIMETYPES[@]}"; do
        xdg-mime default nvim.desktop "$m" 2>/dev/null || failed=$((failed + 1))
    done

    if ((failed > 0)); then
        log_warn "$failed of ${#VXO_NVIM_MIMETYPES[@]} MIME associations could not be set"
    fi
    log_ok "nvim opens text files from the file manager (${#VXO_NVIM_MIMETYPES[@]} MIME types)"
}

# Only written when the packaging did not provide one, so we never fight the
# distro's own entry.
_vxo_nvim_desktop_entry() {
    local sys=/usr/share/applications/nvim.desktop
    local own="$HOME/.local/share/applications/nvim.desktop"

    if [[ -f "$sys" ]]; then
        log_skip "using the packaged $sys"
        return 0
    fi

    local content
    content="$(cat <<'EOF'
[Desktop Entry]
Name=Neovim
GenericName=Text Editor
Comment=Edit text files
TryExec=nvim
Exec=nvim %F
Terminal=true
Type=Application
Keywords=Text;editor;
Icon=nvim
Categories=Utility;TextEditor;
MimeType=text/plain;text/markdown;text/x-c;text/x-csrc;text/x-chdr;text/x-c++src;text/x-c++hdr;text/x-python;text/x-java;text/x-lua;text/x-makefile;text/x-tex;text/x-shellscript;application/x-shellscript;application/json;application/xml;
EOF
)"

    if [[ "${VXO_DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] would write $own"
        return 0
    fi

    mkdir -p "$(dirname "$own")"
    printf '%s\n' "$content" >"$own"
    update-desktop-database "$(dirname "$own")" 2>/dev/null || true
    log_ok "wrote $own"
}

# ─────────────────────────── vs code ───────────────────────────

# apt only, never snap. Having both the snap and the deb installed leaves two
# independent updaters fighting over the same `code` binary, so we pin one
# source and stay on it.
_vxo_editor_vscode() {
    if have code && pkg_installed code; then
        log_skip "VS Code already installed from apt"
        return 0
    fi

    apt_update_once
    apt_install wget gpg apt-transport-https

    local keyring="/etc/apt/keyrings/packages.microsoft.gpg"
    local listfile="/etc/apt/sources.list.d/vscode.list"

    if [[ ! -f "$keyring" ]]; then
        local tmp; tmp="$(mktemp -d)"
        run curl -fsSL -o "$tmp/ms.asc" https://packages.microsoft.com/keys/microsoft.asc
        run sudo install -d -m 0755 /etc/apt/keyrings
        run sudo gpg --dearmor --yes -o "$keyring" "$tmp/ms.asc"
        run sudo chmod 0644 "$keyring"
        rm -rf "$tmp"
        log_ok "added the Microsoft apt signing key"
    else
        log_skip "Microsoft apt signing key already present"
    fi

    local line
    line="deb [arch=$(dpkg --print-architecture) signed-by=${keyring}] https://packages.microsoft.com/repos/code stable main"
    _vxo_write_root_file "$listfile" "$line"

    run sudo apt-get update -qq
    apt_install code
    log_ok "VS Code installed from the Microsoft apt repo"
}

# ─────────────────────────── entrypoint ───────────────────────────

vxo_editor() {
    case "${VXO_EDITOR:-nvim}" in
        nvim)   _vxo_editor_nvim ;;
        vscode) _vxo_editor_vscode ;;
        *)      die "unknown editor: '${VXO_EDITOR:-}' (expected nvim or vscode)" ;;
    esac
}
