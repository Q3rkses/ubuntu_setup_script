#!/usr/bin/env bash
# lib/shortcuts.sh: GNOME keyboard shortcuts.
#
# Sourced by install.sh. Provides: vxo_shortcuts.
#
# Stock GNOME only: everything here is a gsettings write. There is deliberately
# no window-manager or compositor logic in this repo. Ubuntu ships GNOME and
# that is the only desktop this installer targets.
#
# The bindings installed here:
#   Super+1..4          switch to workspace 1..4
#   Super+Shift+1..4    move the focused window to workspace 1..4
#   Super+Enter         open kitty
#   Super+Q             close the focused window
#   Super+F             ulauncher application launcher
#   Super+Up/Down       maximize / unmaximize
#   Super+S             the GNOME screenshot/screencast UI

[[ -n "${_VXO_SHORTCUTS_SOURCED:-}" ]] && return 0
_VXO_SHORTCUTS_SOURCED=1

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

VXO_WM_SCHEMA="org.gnome.desktop.wm.keybindings"
VXO_MEDIA_SCHEMA="org.gnome.settings-daemon.plugins.media-keys"
VXO_CUSTOM_SCHEMA="org.gnome.settings-daemon.plugins.media-keys.custom-keybinding"
VXO_CUSTOM_BASE="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings"

VXO_WORKSPACE_COUNT=4

vxo_shortcuts() {
    _vxo_shortcuts_available || return 0

    _vxo_backup_dconf
    _vxo_workspaces_fixed
    _vxo_workspace_bindings
    _vxo_window_bindings
    _vxo_shell_bindings
    _vxo_free_super_number_keys
    _vxo_custom_bindings

    log_ok "Shortcuts written."
    log_warn "Log out and back in for the new keybindings to take effect."
}

# ───────────────────────────── guards ─────────────────────────────

# Never die here: a headless or SSH run should skip shortcuts and let the rest
# of the install finish.
_vxo_shortcuts_available() {
    if ! have gsettings || ! have dconf; then
        stage_abort "gsettings/dconf not found, skipping GNOME shortcuts. \
Install them and re-run: ./install.sh --only=shortcuts"
        return 1
    fi

    if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
        stage_abort "No D-Bus session bus (running over SSH or without a desktop session). \
skipping GNOME shortcuts. Re-run from a graphical session: ./install.sh --only=shortcuts"
        return 1
    fi

    return 0
}

# ───────────────────────────── backup ─────────────────────────────

# The user has been bitten by orphaned schemas leaking in from an old dconf
# dump, so take a full, restorable snapshot before touching anything.
_vxo_backup_dconf() {
    local dest
    dest="$VXO_BACKUP_DIR/dconf-gnome-$(date +%s).ini"

    if [[ "${VXO_DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] would dump /org/gnome/ to $dest"
        return 0
    fi

    dconf dump /org/gnome/ >"$dest" 2>/dev/null || {
        log_warn "dconf dump failed, continuing without a settings backup"
        return 0
    }

    log_ok "Backed up current GNOME settings → $dest"
    log_info "Restore them at any time with: dconf load /org/gnome/ < '$dest'"
}

# ───────────────────────────── gsettings helpers ─────────────────────────────

# gset <schema[:path]> <key> <value>. Idempotent: skips when already set.
gset() {
    local schema="$1" key="$2" value="$3"
    local current

    current="$(gsettings get "$schema" "$key" 2>/dev/null || echo "")"
    if [[ "$current" == "$value" ]]; then
        log_skip "$key already $value"
        return 0
    fi

    run gsettings set "$schema" "$key" "$value"
    log_ok "$key → $value"
}

# Render a GVariant string array from the arguments.
_vxo_gv_array() {
    if (($# == 0)); then
        printf '@as []'
        return 0
    fi
    local out="[" first=1 item
    for item in "$@"; do
        ((first)) || out+=", "
        out+="'${item}'"
        first=0
    done
    printf '%s]' "$out"
}

# Strip the surrounding quotes gsettings puts around a string value.
_vxo_gv_unquote() {
    local s="$1"
    s="${s#\'}"
    s="${s%\'}"
    printf '%s' "$s"
}

# ───────────────────────────── workspaces ─────────────────────────────

# Fixed workspaces are a precondition: with dynamic workspaces GNOME creates and
# destroys them on the fly, so "switch to workspace 4" is not a stable target.
_vxo_workspaces_fixed() {
    gset org.gnome.mutter dynamic-workspaces false
    gset org.gnome.desktop.wm.preferences num-workspaces "$VXO_WORKSPACE_COUNT"
}

_vxo_workspace_bindings() {
    # Super+Shift+<n> arrives as a shifted keysym on X11 (exclam, at, ...) but
    # as the plain digit under some Wayland layouts. Binding both forms means
    # the shortcut works either way.
    local -a shifted=(exclam at numbersign dollar)

    local i
    for ((i = 1; i <= VXO_WORKSPACE_COUNT; i++)); do
        gset "$VXO_WM_SCHEMA" "switch-to-workspace-$i" \
            "$(_vxo_gv_array "<Super>$i")"

        gset "$VXO_WM_SCHEMA" "move-to-workspace-$i" \
            "$(_vxo_gv_array "<Shift><Super>${shifted[$((i - 1))]}" "<Shift><Super>$i")"
    done
}

_vxo_window_bindings() {
    gset "$VXO_WM_SCHEMA" close       "$(_vxo_gv_array '<Super>q')"
    gset "$VXO_WM_SCHEMA" maximize    "$(_vxo_gv_array '<Super>Up')"
    gset "$VXO_WM_SCHEMA" unmaximize  "$(_vxo_gv_array '<Super>Down' '<Alt>F5')"
}

# GNOME Shell's own bindings, which live in a different schema from the window
# manager's and are therefore easy to miss.
_vxo_shell_bindings() {
    local shell=org.gnome.shell.keybindings

    # Super+S for the screenshot and screencast UI. GNOME's default is PrintScr,
    # which several laptop keyboards only expose behind an Fn combination.
    gset "$shell" show-screenshot-ui "$(_vxo_gv_array '<Super>s')"

    # Super alone already opens the overview, so the extra toggle-overview
    # binding (Super+S in some releases) is a collision waiting to happen with
    # the screenshot binding above. Clear it rather than leave two owners.
    gset "$shell" toggle-overview "@as []"
}

# GNOME Shell binds Super+1..9 to "launch/focus the Nth dash favourite", which
# collides head-on with using Super+1..4 for workspaces. Clear them.
_vxo_free_super_number_keys() {
    local i
    for ((i = 1; i <= 9; i++)); do
        gset org.gnome.shell.keybindings "switch-to-application-$i" "@as []"
    done
}

# ───────────────────────────── custom keybindings ─────────────────────────────

# Read the current custom-keybindings list into the named array variable.
_vxo_read_custom_list() {
    local -n _out="$1"
    _out=()

    local raw
    raw="$(gsettings get "$VXO_MEDIA_SCHEMA" custom-keybindings 2>/dev/null || echo "@as []")"
    [[ "$raw" == "@as []" || "$raw" == "[]" ]] && return 0

    # "['/a/', '/b/']" → one path per line.
    local cleaned
    cleaned="${raw#[}"
    cleaned="${cleaned%]}"

    local IFS=','
    local part
    for part in $cleaned; do
        part="${part#"${part%%[![:space:]]*}"}"   # ltrim
        part="${part%"${part##*[![:space:]]}"}"   # rtrim
        part="$(_vxo_gv_unquote "$part")"
        [[ -n "$part" ]] && _out+=("$part")
    done
}

# Commands owned by an older revision of this installer, or by a hand-made
# binding for the same job. Any registered custom binding running one of these
# is removed and replaced by the definitions below.
#
# Both entries earn their place:
#
#   * wofi-drun was the Super+R launcher this installer shipped before
#     ulauncher. Leaving it registered means a machine that has been through
#     both versions answers Super+R with a launcher nobody configured any more.
#   * ulauncher-toggle is what we are about to install ourselves. A hand-rolled
#     binding for it almost always sits at a generic slug like `custom0`, and
#     two custom bindings on <Super>f make GNOME pick one at random.
VXO_RETIRED_COMMANDS=(
    "$HOME/.local/bin/wofi-drun"
    "wofi-drun"
    "ulauncher-toggle"
)

# True when this path's command is one we are taking over, AND the path is not
# the one we are about to write. The second half matters on a re-run: our own
# binding runs ulauncher-toggle too, and retiring it would delete the shortcut
# every single time.
_vxo_is_retired() {
    local path="$1" keep="$2"
    [[ "$path" == "$keep" ]] && return 1

    local cmd retired
    cmd="$(_vxo_gv_unquote "$(gsettings get "$VXO_CUSTOM_SCHEMA:$path" command 2>/dev/null || echo "''")")"
    [[ -n "$cmd" ]] || return 1

    for retired in "${VXO_RETIRED_COMMANDS[@]}"; do
        [[ "$cmd" == "$retired" ]] && return 0
    done
    return 1
}

# An orphan is a registered path whose schema carries neither a name nor a
# command. It is the residue of a dconf dump from another machine or distro.
# Left in place they show up as blank rows in Settings and can shadow real
# bindings.
_vxo_is_orphan() {
    local path="$1"
    local name cmd
    name="$(_vxo_gv_unquote "$(gsettings get "$VXO_CUSTOM_SCHEMA:$path" name 2>/dev/null || echo "''")")"
    cmd="$(_vxo_gv_unquote "$(gsettings get "$VXO_CUSTOM_SCHEMA:$path" command 2>/dev/null || echo "''")")"
    [[ -z "$name" && -z "$cmd" ]]
}

# define_custom <slug> <name> <command> <binding>
_vxo_define_custom() {
    local slug="$1" name="$2" cmd="$3" binding="$4"
    local path="$VXO_CUSTOM_BASE/$slug/"
    local schema="$VXO_CUSTOM_SCHEMA:$path"

    gset "$schema" name    "'$name'"
    gset "$schema" command "'$cmd'"
    gset "$schema" binding "'$binding'"

    printf '%s' "$path"
}

_vxo_custom_bindings() {
    if [[ "${VXO_DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] would define custom keybindings: kitty-term (Super+Return), ulauncher (Super+F)"
        return 0
    fi

    local -a existing=()
    _vxo_read_custom_list existing

    local ulauncher_slot="$VXO_CUSTOM_BASE/ulauncher/"

    # Prune orphans and retired bindings, keep everything else the user had.
    local -a keep=()
    local path
    for path in "${existing[@]}"; do
        if _vxo_is_orphan "$path"; then
            log_warn "Pruning orphaned keybinding entry: $path"
            run dconf reset -f "$path"
        elif _vxo_is_retired "$path" "$ulauncher_slot"; then
            log_warn "Replacing superseded launcher keybinding: $path"
            run dconf reset -f "$path"
        else
            keep+=("$path")
        fi
    done

    local kitty_path ulauncher_path
    kitty_path="$(_vxo_define_custom kitty-term "Kitty (terminal)" "/usr/bin/kitty" "<Super>Return")"
    ulauncher_path="$(_vxo_define_custom ulauncher "Ulauncher" "ulauncher-toggle" "<Super>f")"

    # Append ours only if not already registered, so re-runs are no-ops and
    # unrelated user bindings survive.
    local p want
    for want in "$kitty_path" "$ulauncher_path"; do
        local found=0
        for p in "${keep[@]}"; do
            [[ "$p" == "$want" ]] && { found=1; break; }
        done
        ((found)) || keep+=("$want")
    done

    gset "$VXO_MEDIA_SCHEMA" custom-keybindings "$(_vxo_gv_array "${keep[@]}")"
}
