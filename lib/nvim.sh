#!/usr/bin/env bash
# lib/nvim.sh: the editor stage. Dispatches on $VXO_EDITOR to Neovim or VS Code.
#
# Neovim deliberately does NOT come from apt: archive versions lag, and
# cannot load a modern lazy.nvim config at all. We take the upstream stable
# tarball instead and require >= 0.10. On 22.04 that is not a preference but a
# hard requirement — jammy's neovim is 0.6.1, which the config cannot load.
#
# SCOPE: Ubuntu 22.04 only, stock GNOME.

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

# Everything the config actually shells out to, taken from nvimconf's own
# README rather than guessed at. Grouped by what breaks without it:
#
#   ripgrep        <Leader>fw live grep. Snacks' grep picker has no fallback.
#   fd-find        the file picker's finder.
#   fzf            fuzzy matching for the pickers, and Ctrl+R in the shell.
#   nodejs         mason installs bash-language-server, prettier and lemminx
#                  as npm packages. Without a usable node/npm they fail at
#                  install time and the LSP simply never attaches, with no
#                  error in the editor. That is the failure mode this list has
#                  always warned about; on 22.04 it is not hypothetical, see
#                  _vxo_install_nodejs below. This entry is normally already
#                  satisfied by the time apt_install reaches it, and stays in
#                  the list so the NodeSource-unavailable fallback still ends
#                  up with *a* node rather than none.
#
#                  npm is deliberately NOT listed. NodeSource's nodejs bundles
#                  its own npm, while the archive npm depends on the archive
#                  nodejs — asking apt for it would drag Node 12 back in on top
#                  of the Node 20 we just installed and undo the whole point.
#   python3-venv   mason builds basedpyright and any pip-backed tool inside a
#                  venv, so the module has to be present or those installs have
#                  nowhere to go. Note that 22.04 is NOT a PEP 668
#                  externally-managed release — a plain pip install still
#                  succeeds here — so this is wanted for the ordinary reason
#                  (isolation from the system interpreter), not because the
#                  distro refuses pip outright.
#   python3-full   the stdlib pieces (tkinter, distutils successors) that
#                  python3-minimal leaves out and that some tools import.
#   unzip          mason unpacks most of its release archives with it.
#   gdu            <Leader>tu disk-usage terminal.
#   imagemagick    Snacks image preview and the markdown renderer.
#   ghostscript    the PDF half of that preview pipeline.
#   wl-clipboard   the system clipboard under Wayland. Without it "+y is a
#                  silent no-op, which is the single most confusing failure
#                  in this whole list.
#   xclip          the same for an X11 session.
#   xdg-utils      xdg-open, which gx and the markdown renderer use to open
#                  links in the browser.
#   git            lazy.nvim clones every plugin with it.
#
# build-essential is not listed here only because lib/base.sh and
# lib/toolchain.sh both guarantee it; treesitter compiles every parser with
# that C compiler, so it is a hard requirement of this stage too.
#
# Several of these usually arrive with the base stage. apt_install is
# idempotent, so listing them again costs nothing and keeps this module
# runnable on its own via --only=editor.
VXO_NVIM_DEPS=(
    git
    ripgrep
    fd-find
    fzf
    nodejs
    python3-venv
    python3-full
    unzip
    gdu
    imagemagick
    ghostscript
    wl-clipboard
    xclip
    xdg-utils
)

_vxo_install_nvim_deps() {
    apt_update_once
    # Before the apt_install below, not after: this is what puts a modern
    # nodejs in place, so by the time the list is installed the `nodejs` entry
    # in it is already satisfied and skips instead of pulling Node 12 in first
    # and having it replaced a moment later.
    _vxo_install_nodejs
    apt_install "${VXO_NVIM_DEPS[@]}"
    _vxo_install_lazygit
    _vxo_check_nvim_deps
}

# ─────────────────────────── node.js ───────────────────────────
#
# Ubuntu 22.04's archive nodejs is 12.22.9 and its npm is 8.5.1. mason installs
# bash-language-server, prettier and lemminx as npm packages and every one of
# them requires Node >= 18: on a stock jammy those installs fail inside mason,
# nothing surfaces in the editor, and the language server for those filetypes
# simply never attaches. That is the exact failure mode VXO_NVIM_DEPS has always
# warned about, except on this release it happens on every single install rather
# than in theory.
#
# So Node comes from NodeSource's apt repo instead, following the same
# vendor-repo pattern as lib/browser.sh and _vxo_editor_vscode below: the key
# dearmoured into /etc/apt/keyrings and a `signed-by=` source line. Never
# apt-key (deprecated, and it trusts the key for every repo on the machine),
# never a piped install script.
#
# 20 is the LTS line, which is what "new enough for mason" wants without
# chasing current.
VXO_NODE_MAJOR=20

# What mason's npm-backed servers actually require. Anything at or above this is
# left alone, so a machine that already has node from nvm, a newer NodeSource
# line, or a hand install is not touched.
VXO_NODE_MIN_MAJOR=18

VXO_NODE_KEYRING="/etc/apt/keyrings/nodesource.gpg"
VXO_NODE_LIST="/etc/apt/sources.list.d/nodesource.list"
VXO_NODE_KEY_URL="https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key"

# Echo the major version of the node on PATH, or nothing at all. Both names are
# tried: everything mason runs invokes `node`, but Debian/Ubuntu have
# historically shipped the interpreter as `nodejs`, and reporting "no node" for
# a machine that has one under the other name would reinstall it every run.
_vxo_node_major() {
    local bin
    for bin in node nodejs; do
        if have "$bin"; then
            "$bin" --version 2>/dev/null | sed -nE 's/^v?([0-9]+).*/\1/p'
            return 0
        fi
    done
}

_vxo_node_recent_enough() {
    local major
    major="$(_vxo_node_major)"
    [[ -n "$major" ]] || return 1
    ((major >= VXO_NODE_MIN_MAJOR))
}

_vxo_install_nodejs() {
    if _vxo_node_recent_enough; then
        log_skip "node v$(_vxo_node_major) is already >= $VXO_NODE_MIN_MAJOR, leaving it alone"
        return 0
    fi

    # A dry run must not reach the network. The key fetch below is a bare
    # `curl`, the same reason _vxo_install_neovim_binary and
    # _vxo_install_lazygit carry this guard: without it --dry-run really
    # downloads the key and then warns about a step it was never going to take.
    if [[ "${VXO_DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] would add the NodeSource apt repo (node_${VXO_NODE_MAJOR}.x)"
        log_info "[dry-run]   and install nodejs from it"
        return 0
    fi

    apt_install ca-certificates curl gnupg

    if _vxo_nodesource_repo; then
        run sudo apt-get update -qq || log_warn "apt update after adding NodeSource reported a problem"
        _VXO_APT_UPDATED=1

        # nodejs only. NodeSource's package carries its own npm; asking for the
        # archive npm here would pull the archive nodejs back in as its
        # dependency and put Node 12 on the machine again.
        if run sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs; then
            hash -r 2>/dev/null || true
            if _vxo_node_recent_enough; then
                log_ok "Node.js $(node --version 2>/dev/null || printf 'v%s.x' "$VXO_NODE_MAJOR") installed from NodeSource"
                return 0
            fi
            log_warn "NodeSource nodejs installed but node is still v$(_vxo_node_major)"
        else
            log_warn "the NodeSource nodejs package would not install"
        fi
    fi

    _vxo_node_archive_fallback
}

# Key + source line. Returns non-zero, having warned, if either could not be put
# in place, so the caller can degrade instead of failing the stage.
_vxo_nodesource_repo() {
    if [[ -f "$VXO_NODE_KEYRING" ]]; then
        log_skip "NodeSource apt signing key already present"
    else
        local tmp
        tmp="$(mktemp -d)"
        if ! curl -fsSL -o "$tmp/nodesource.key" "$VXO_NODE_KEY_URL"; then
            rm -rf "$tmp"
            log_warn "could not fetch the NodeSource signing key from $VXO_NODE_KEY_URL"
            return 1
        fi
        run sudo install -d -m 0755 /etc/apt/keyrings
        if ! run sudo gpg --dearmor --yes -o "$VXO_NODE_KEYRING" "$tmp/nodesource.key"; then
            rm -rf "$tmp"
            log_warn "could not dearmour the NodeSource signing key"
            return 1
        fi
        run sudo chmod 0644 "$VXO_NODE_KEYRING"
        rm -rf "$tmp"
        log_ok "added the NodeSource apt signing key"
    fi

    # "nodistro" is not a placeholder that should have been the codename.
    # NodeSource's current layout publishes one release-independent suite per
    # Node major, and that suite is literally named nodistro; there is no jammy
    # component to point at.
    _vxo_write_root_file "$VXO_NODE_LIST" \
        "deb [signed-by=${VXO_NODE_KEYRING}] https://deb.nodesource.com/node_${VXO_NODE_MAJOR}.x nodistro main"
}

# Last resort when NodeSource is unreachable or refuses to install. The archive
# pair is taken together on purpose: they depend on each other, and node without
# npm leaves mason with no package manager at all, which is strictly worse than
# an old one. Said loudly, because the resulting breakage is silent.
_vxo_node_archive_fallback() {
    log_warn "falling back to Ubuntu $(ubuntu_release)'s own nodejs and npm."
    log_warn "That is Node 12, and mason's node-backed servers (bash-language-server,"
    log_warn "prettier, lemminx) need Node >= ${VXO_NODE_MIN_MAJOR}. Expect them to fail to install"
    log_warn "and their language servers never to attach."
    log_warn "Retry once the network allows NodeSource: ./install.sh --only=editor"
    apt_install nodejs npm
}

# lazygit is not optional the way the rest are. AstroNvim gates <Leader>gg and
# <Leader>tl on `executable("lazygit")`, so a missing binary just means the
# keymaps quietly never exist, but nvimconf also sets snacks `lazygit.enabled`,
# and that picker errors when invoked without it.
#
# It is not in every Ubuntu archive, so try apt and fall back to the upstream
# release tarball, the same way lib/kitty_fastfetch.sh handles fastfetch.
_vxo_install_lazygit() {
    if have lazygit; then
        log_skip "lazygit already installed ($(lazygit --version 2>/dev/null | head -1))"
        return 0
    fi

    if apt-cache show lazygit >/dev/null 2>&1; then
        apt_install lazygit
        return 0
    fi

    log_info "lazygit is not in the archive for Ubuntu $(ubuntu_release), using the upstream release instead"

    # Same reasoning as the neovim tarball above: the release lookup is a bare
    # curl against the GitHub API, so a dry run would really call it.
    if [[ "${VXO_DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] would install the upstream lazygit release into /usr/local/bin"
        return 0
    fi

    local arch; arch="$(dpkg --print-architecture)"
    local asset_arch
    case "$arch" in
        amd64) asset_arch="x86_64" ;;
        arm64) asset_arch="arm64" ;;
        *)     log_warn "no prebuilt lazygit for architecture '$arch', skipping lazygit"; return 0 ;;
    esac

    local ver
    ver="$(curl -fsSL https://api.github.com/repos/jesseduffield/lazygit/releases/latest 2>/dev/null \
        | grep -F '"tag_name"' | head -1 | awk -F'"' '{print $4}')" || true
    ver="${ver#v}"
    if [[ -z "$ver" ]]; then
        log_warn "could not determine the latest lazygit release (GitHub API rate limit?), skipping lazygit"
        return 0
    fi

    local tmp; tmp="$(mktemp -d)"
    local url="https://github.com/jesseduffield/lazygit/releases/download/v${ver}/lazygit_${ver}_Linux_${asset_arch}.tar.gz"

    log_info "downloading lazygit ${ver}"
    if ! run curl -fsSL -o "$tmp/lazygit.tar.gz" "$url"; then
        log_warn "download failed: $url. Skipping lazygit."
        rm -rf "$tmp"
        return 0
    fi

    if ! run tar -xzf "$tmp/lazygit.tar.gz" -C "$tmp" lazygit; then
        log_warn "could not unpack the lazygit tarball, skipping lazygit"
        rm -rf "$tmp"
        return 0
    fi

    run sudo install -m 0755 "$tmp/lazygit" /usr/local/bin/lazygit
    rm -rf "$tmp"

    hash -r 2>/dev/null || true
    if have lazygit; then
        log_ok "installed lazygit: $(lazygit --version 2>/dev/null | head -1)"
    else
        log_warn "lazygit still not on PATH after installing it"
    fi
}

# The mason tools in nvimconf are fetched at first launch, not by this
# installer, so a missing interpreter shows up much later as "the LSP does not
# work" rather than as an install failure. Say it now instead.
_vxo_check_nvim_deps() {
    _vxo_link_fd

    local missing=() cmd
    for cmd in node npm python3 rg fzf git; do
        have "$cmd" || missing+=("$cmd")
    done

    if ((${#missing[@]} > 0)); then
        log_warn "not on PATH after installing the editor dependencies: ${missing[*]}"
        log_warn "mason will fail to install some language servers until they are."
        return 0
    fi

    log_ok "all neovim runtime dependencies present"
}

# Ubuntu ships fd-find's binary as `fdfind`, because `fd` is taken by another
# package. Every fd-aware nvim plugin looks for `fd`, finds nothing, and quietly
# falls back to a slower finder or to none at all. A shim in ~/.local/bin is the
# packaged workaround Debian itself documents.
_vxo_link_fd() {
    if have fd; then
        log_skip "fd already on PATH"
        return 0
    fi

    local fdfind; fdfind="$(command -v fdfind 2>/dev/null || true)"
    if [[ -z "$fdfind" ]]; then
        log_warn "neither fd nor fdfind is installed, so nvim's file picker will use its fallback finder"
        return 0
    fi

    run mkdir -p "$HOME/.local/bin"
    run ln -sfn "$fdfind" "$HOME/.local/bin/fd"
    log_ok "linked $fdfind → ~/.local/bin/fd"
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
