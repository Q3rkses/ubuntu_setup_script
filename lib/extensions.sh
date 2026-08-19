#!/usr/bin/env bash
# lib/extensions.sh: GNOME Shell extensions, installed non-interactively.
#
# Sourced by install.sh. Provides: vxo_gnome_extensions.
#
# Currently one extension: Rounded Window Corners Reborn, which clips every
# window to a rounded rectangle. Add more by appending to VXO_EXTENSIONS.
#
# HOW THIS WORKS, and why it is not just "unzip into the extensions dir":
#
#   * Extensions are pinned to a GNOME Shell major version. extensions.gnome.org
#     exposes a shell_version_map per extension, so we ask the API which release
#     matches THIS shell rather than downloading "latest" and getting an
#     extension that refuses to load.
#   * Schemas have to be compiled after unpacking. An extension whose schemas are
#     not compiled loads and then throws on its first settings read, which
#     presents as "the extension does nothing".
#   * Enabling goes through gsettings, not `gnome-extensions enable`. Under
#     Wayland the running shell cannot be restarted, so it has not scanned the
#     new directory yet and `gnome-extensions enable` fails with "not found".
#     Writing enabled-extensions directly works now and takes effect at the next
#     login, which is the same session boundary the rest of this installer
#     already asks for.
#
# Stock GNOME only.

[[ -n "${_VXO_EXTENSIONS_SOURCED:-}" ]] && return 0
_VXO_EXTENSIONS_SOURCED=1

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

VXO_EXT_DIR="$HOME/.local/share/gnome-shell/extensions"
VXO_EXT_API="https://extensions.gnome.org"

VXO_ROUNDED_UUID="rounded-window-corners@fxgn"

# uuid per line. Extend this list to install more.
VXO_EXTENSIONS=(
    "$VXO_ROUNDED_UUID"
)

# Corner radius in pixels. GNOME's own libadwaita windows use 12; the extension
# ships a default of 15. 8 sits at the top of the 4-8 range that reads as
# "softened" rather than "bubbly" at 1x scaling. Override with --rounded-radius=N.
VXO_ROUNDED_RADIUS="${VXO_ROUNDED_RADIUS:-8}"

# ─────────────────────────── entrypoint ───────────────────────────

vxo_gnome_extensions() {
    _vxo_ext_available || return 0

    local shell_major; shell_major="$(_vxo_shell_major)"
    if [[ -z "$shell_major" ]]; then
        stage_abort "could not determine the GNOME Shell version, skipping extensions"
        return 0
    fi
    log_info "GNOME Shell $shell_major"

    local uuid installed=0
    for uuid in "${VXO_EXTENSIONS[@]}"; do
        if _vxo_ext_install "$uuid" "$shell_major"; then
            _vxo_ext_enable "$uuid"
            installed=$((installed + 1))
        fi
    done

    ((installed > 0)) || { log_warn "no extensions were installed"; return 0; }

    # User extensions off globally would make every install above inert.
    gset_soft org.gnome.shell disable-user-extensions "false"

    _vxo_rounded_corners_configure

    log_warn "Log out and back in for the extensions to load. Under Wayland the"
    log_warn "running shell cannot pick up a newly installed extension."
}

# ─────────────────────────── guards ───────────────────────────

_vxo_ext_available() {
    if ! have gsettings; then
        stage_abort "gsettings not found, skipping GNOME extensions."
        return 1
    fi
    if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
        stage_abort "No D-Bus session bus (running over SSH or without a desktop session). \
Skipping GNOME extensions. Re-run from a graphical session: ./install.sh --only=gnome-extensions"
        return 1
    fi
    if ! have gnome-shell; then
        stage_abort "gnome-shell is not installed, skipping GNOME extensions."
        return 1
    fi
    # gset_soft lives in desktop.sh. Sourced here so --only=gnome-extensions works.
    if ! declare -F gset_soft >/dev/null 2>&1; then
        # shellcheck source=lib/desktop.sh
        source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/desktop.sh"
    fi
    return 0
}

_vxo_shell_major() {
    gnome-shell --version 2>/dev/null | sed -nE 's/^GNOME Shell ([0-9]+).*/\1/p'
}

# ─────────────────────────── install ───────────────────────────

# _vxo_ext_install <uuid> <shell-major>: true when the extension is on disk
# afterwards. Never fatal: an extension that has no release for this shell is a
# warning, because the desktop is perfectly usable without rounded corners.
_vxo_ext_install() {
    local uuid="$1" shell_major="$2"
    local dest="$VXO_EXT_DIR/$uuid"

    if [[ -f "$dest/metadata.json" ]]; then
        log_skip "extension already installed: $uuid"
        return 0
    fi

    if [[ "${VXO_DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] would install the $uuid extension for GNOME Shell $shell_major"
        return 0
    fi

    have jq || apt_install jq
    have unzip || apt_install unzip

    local info
    info="$(curl -fsSL "$VXO_EXT_API/extension-info/?uuid=${uuid}&shell_version=${shell_major}" 2>/dev/null)" || info=""
    if [[ -z "$info" ]]; then
        log_warn "extensions.gnome.org did not answer for $uuid, skipping it"
        return 1
    fi

    # A null download_url means the extension exists but has no release for this
    # shell major. That is a real, reportable state, not a network error.
    local path
    path="$(jq -r '.download_url // empty' <<<"$info")"
    if [[ -z "$path" ]]; then
        log_warn "$uuid has no release for GNOME Shell $shell_major, skipping it"
        log_warn "  check https://extensions.gnome.org and install it by hand if you need it"
        return 1
    fi

    local tmp; tmp="$(mktemp -d)"
    if ! curl -fsSL -o "$tmp/ext.zip" "${VXO_EXT_API}${path}"; then
        rm -rf "$tmp"
        log_warn "could not download $uuid, skipping it"
        return 1
    fi

    mkdir -p "$dest"
    if ! unzip -oq "$tmp/ext.zip" -d "$dest"; then
        rm -rf "$tmp" "$dest"
        log_warn "could not unpack $uuid, skipping it"
        return 1
    fi
    rm -rf "$tmp"

    # Without this the extension loads and then throws on its first settings
    # read, which looks identical to "the extension does nothing".
    if [[ -d "$dest/schemas" ]]; then
        if have glib-compile-schemas; then
            glib-compile-schemas "$dest/schemas" 2>>"$VXO_LOG_FILE" \
                || log_warn "could not compile the schemas for $uuid; its settings will not apply"
        else
            log_warn "glib-compile-schemas is missing, so $uuid settings will not apply"
        fi
    fi

    local version
    version="$(jq -r '.version // "?"' "$dest/metadata.json" 2>/dev/null || echo '?')"
    log_ok "installed extension $uuid (version $version)"
}

# Append to enabled-extensions rather than overwriting it, so extensions the user
# enabled by hand survive a re-run.
_vxo_ext_enable() {
    local uuid="$1"

    if [[ "${VXO_DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] would add $uuid to org.gnome.shell enabled-extensions"
        return 0
    fi

    local raw
    raw="$(gsettings get org.gnome.shell enabled-extensions 2>/dev/null || echo "@as []")"

    if [[ "$raw" == *"'$uuid'"* ]]; then
        log_skip "extension already enabled: $uuid"
        return 0
    fi

    local -a current=()
    if [[ "$raw" != "@as []" && "$raw" != "[]" ]]; then
        local cleaned="${raw#[}"; cleaned="${cleaned%]}"
        local IFS=','
        local part
        for part in $cleaned; do
            part="${part#"${part%%[![:space:]]*}"}"
            part="${part%"${part##*[![:space:]]}"}"
            part="${part#\'}"; part="${part%\'}"
            [[ -n "$part" ]] && current+=("$part")
        done
    fi
    current+=("$uuid")

    local value="[" first=1 e
    for e in "${current[@]}"; do
        ((first)) || value+=", "
        value+="'$e'"
        first=0
    done
    value+="]"

    run gsettings set org.gnome.shell enabled-extensions "$value" \
        || { log_warn "could not enable $uuid"; return 0; }
    log_ok "enabled extension $uuid"

    # Best effort on top: on X11 this makes it live immediately. Expected to fail
    # under Wayland because the shell has not scanned the directory yet, so the
    # output is discarded rather than reported as a problem.
    have gnome-extensions && gnome-extensions enable "$uuid" >/dev/null 2>&1 || true
}

# ─────────────────────── rounded corners settings ───────────────────────

# This extension's schema lives only inside its own extension directory
# (compiled there by _vxo_ext_install), never in a location the system schema
# cache or the standalone `gsettings` command searches. Only gnome-shell's own
# extension runtime resolves it, via a SettingsSchemaSource pointed straight at
# that directory — so `gsettings writable ...`/`gset_soft` against this schema
# always report "no such schema" and silently do nothing here, regardless of
# whether the extension installed correctly. `dconf write` sidesteps schema
# resolution entirely: it writes straight to the dconf keys the extension reads
# from at the path its schema declares (org/.../rounded-window-corners-reborn),
# which works whether or not gnome-shell has loaded the extension yet.
VXO_ROUNDED_DCONF_BASE="/org/gnome/shell/extensions/rounded-window-corners-reborn"

# The radius (and the border color/enable flags below it) live inside
# global-rounded-corner-settings, a single a{sv} dict holding padding,
# borderRadius, smoothing, borderColor and the keep-when-maximized flags.
# dconf has no way to write one member of a dict, so the whole value is
# rewritten. Every member below other than borderRadius/borderColor matches
# the extension's own schema default.
_vxo_rounded_corners_configure() {
    local radius="$VXO_ROUNDED_RADIUS"

    if ! [[ "$radius" =~ ^[0-9]+$ ]] || ((radius < 0 || radius > 40)); then
        log_warn "invalid corner radius '$radius', falling back to 6"
        radius=6
    fi

    if ! have dconf; then
        log_skip "dconf not found, so the rounded-corner settings were not written"
        return 0
    fi

    local value
    value="{'padding': <{'left': <uint32 1>, 'right': <uint32 1>, 'top': <uint32 1>, 'bottom': <uint32 1>}>, 'keepRoundedCorners': <{'maximized': <false>, 'fullscreen': <false>}>, 'borderRadius': <uint32 ${radius}>, 'smoothing': <0>, 'borderColor': <[0.75, 0.75, 0.75, 1.0]>, 'enabled': <true>}"

    run dconf write "$VXO_ROUNDED_DCONF_BASE/global-rounded-corner-settings" "$value"

    # border-width is a separate top-level key from borderColor above, defaults
    # to 0, and the extension draws no border at all until it is set. 1px,
    # grayish-white (borderColor, [0.75, 0.75, 0.75] on a 0-1 scale) outline.
    run dconf write "$VXO_ROUNDED_DCONF_BASE/border-width" "1"

    # The extension skips libadwaita apps by default, on the reasoning that they
    # round themselves. That leaves a visibly mixed desktop: GTK4 apps at their
    # own 12px and everything else at ours. Turning the skip off makes the
    # extension clip every window to the same radius, which is what "all windows
    # rounded" actually means.
    run dconf write "$VXO_ROUNDED_DCONF_BASE/skip-libadwaita-app" "false"
    run dconf write "$VXO_ROUNDED_DCONF_BASE/skip-libhandy-app" "false"

    log_ok "window corner radius set to ${radius}px, border 1px grayish-white, for all windows"
}
