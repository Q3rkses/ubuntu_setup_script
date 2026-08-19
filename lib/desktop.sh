#!/usr/bin/env bash
# lib/desktop.sh: the GNOME settings that make a fresh install feel like the
# machine you already had. Appearance, input sources, pointer behaviour, window
# manager policy, dock, favourites.
#
# Sourced by install.sh. Provides: vxo_desktop.
#
# WHY THIS EXISTS. Keyboard shortcuts (lib/shortcuts.sh) were the only desktop
# state the installer used to reproduce, so a reinstall handed back a machine
# with the right keybindings and nothing else: light theme, no Norwegian
# keyboard, inverted scrolling, windows auto-maximising, fractional scaling off.
# Every setting here was read off a working machine rather than invented.
#
# Everything is a gsettings write and everything is guarded. A key that does not
# exist on this GNOME version is skipped with a note, never fatal: GNOME renames
# and removes keys between releases and a reinstall must not die because one of
# them moved.
#
# Stock GNOME only. No compositor or WM logic.

[[ -n "${_VXO_DESKTOP_SOURCED:-}" ]] && return 0
_VXO_DESKTOP_SOURCED=1

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# ─────────────────────────── the settings ───────────────────────────

# Appearance. Two mechanisms have to agree, because Ubuntu moved from named Yaru
# theme variants (Yaru-magenta-dark) to a native accent-colour key around
# GNOME 47 without dropping the variants:
#
#   * accent-color   drives libadwaita/GTK4 apps and the shell on GNOME 47+.
#   * gtk-theme      still drives GTK3 apps, which is most of the desktop's
#     icon-theme    long tail.
#
# IMPORTANT, and the reason this used to half-work: accent-color is an ENUM, and
# on Ubuntu 26.04 its members are blue, teal, green, yellow, orange, red, pink,
# purple, slate and brown. There is no 'magenta'. Writing it made gsettings
# reject the value and the desktop kept whatever accent it already had, silently.
# Ubuntu's magenta is exposed upstream as 'pink', so that is what we write; the
# Yaru-magenta* variants below carry the actual magenta tint for GTK3.
VXO_DESKTOP_ACCENT="pink"

# Theme table: VXO_THEME → color-scheme, GTK theme, icon theme.
#
# "dark-magenta" is Ubuntu's magenta Yaru on a dark base, i.e. the reference
# machine. "dark-pink" keeps GNOME's own pink accent over the neutral dark Yaru,
# so the colour shows up only where an accent belongs rather than tinting the
# whole shell. "light" is the same magenta Yaru on a light base.
_vxo_theme_spec() {
    case "${VXO_THEME:-dark-magenta}" in
        dark-magenta) printf "prefer-dark|Yaru-magenta-dark|Yaru-magenta-dark" ;;
        dark-pink)    printf "prefer-dark|Yaru-dark|Yaru-dark" ;;
        light)        printf "prefer-light|Yaru-magenta|Yaru-magenta" ;;
        *)
            log_warn "unknown theme '${VXO_THEME:-}', falling back to dark-magenta"
            printf "prefer-dark|Yaru-magenta-dark|Yaru-magenta-dark"
            ;;
    esac
}

# Input sources, in switcher order. The FIRST entry is the default layout at
# login, and English (US) leads: it is what the installer's own prompts, every
# code sample and most documentation assume, and a Norwegian layout that the
# user did not ask for turns every bracket and slash into a hunt.
#
# The ibus entry needs the ibus-mozc package, which lib/apps.sh installs. Without
# it this list still applies but the Japanese entry resolves to nothing and
# quietly vanishes from the switcher, which looks exactly like a bug.
VXO_DESKTOP_INPUT_SOURCES="[('xkb', 'us'), ('xkb', 'no'), ('ibus', 'mozc-jp')]"

# Pointer. Negative speeds are slower than the default; these are the values off
# the reference machine, not guesses.
VXO_DESKTOP_TOUCHPAD_SPEED="-0.0073529411764705621"
VXO_DESKTOP_MOUSE_SPEED="-0.3529411764705882"

# Dock. RIGHT edge, not extended to full height, and hot-keys off so Super+<n>
# stays available for workspaces (see lib/shortcuts.sh, which clears the
# overlapping GNOME Shell bindings for the same reason).
VXO_DESKTOP_DOCK_POSITION="RIGHT"

vxo_desktop() {
    _vxo_desktop_available || return 0

    # lib/shortcuts.sh already snapshots /org/gnome/ before it writes. Take
    # another one here so --only=desktop is independently reversible.
    _vxo_desktop_backup

    _vxo_desktop_appearance
    _vxo_desktop_input_sources
    _vxo_desktop_peripherals
    _vxo_desktop_window_policy
    _vxo_desktop_dock
    _vxo_desktop_icons
    _vxo_desktop_favourites
    _vxo_desktop_account_picture

    log_ok "Desktop settings applied."
    log_warn "Log out and back in: the theme, input sources and fractional scaling"
    log_warn "only fully apply to a fresh session."
}

# ─────────────────────────── guards ───────────────────────────

_vxo_desktop_available() {
    if ! have gsettings; then
        stage_abort "gsettings not found, skipping desktop settings. \
Re-run from a graphical session: ./install.sh --only=desktop"
        return 1
    fi
    if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
        stage_abort "No D-Bus session bus (running over SSH or without a desktop session). \
Skipping desktop settings. Re-run from a graphical session: ./install.sh --only=desktop"
        return 1
    fi
    return 0
}

_vxo_desktop_backup() {
    local dest
    dest="$VXO_BACKUP_DIR/dconf-desktop-$(date +%s).ini"
    if [[ "${VXO_DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] would dump /org/gnome/ to $dest"
        return 0
    fi
    dconf dump /org/gnome/ >"$dest" 2>/dev/null || {
        log_warn "dconf dump failed, continuing without a settings backup"
        return 0
    }
    log_info "Backed up current GNOME settings → $dest"
    log_info "Restore with: dconf load /org/gnome/ < '$dest'"
}

# ─────────────────────────── gsettings helpers ───────────────────────────

# gset_soft <schema> <key> <value>
#
# Like lib/shortcuts.sh:gset, but a missing schema or key is a logged skip rather
# than a failure. Used for everything that GNOME has renamed, removed or moved
# between releases, and for extension schemas that only exist once the extension
# is installed.
gset_soft() {
    local schema="$1" key="$2" value="$3"

    if ! gsettings writable "$schema" "$key" >/dev/null 2>&1; then
        log_skip "$schema $key does not exist on this GNOME version"
        return 0
    fi

    local current
    current="$(gsettings get "$schema" "$key" 2>/dev/null || echo "")"
    if [[ "$current" == "$value" ]]; then
        log_skip "$key already $value"
        return 0
    fi

    if ! run gsettings set "$schema" "$key" "$value"; then
        log_warn "could not set $schema $key to $value"
        return 0
    fi
    log_ok "$key → $value"
}

# True when a GTK/icon theme of this name is actually installed. Setting
# gtk-theme to a theme that is not on disk gives you the fallback theme (Adwaita
# light) with no error anywhere, which is a genuinely confusing outcome.
_vxo_theme_installed() {
    local name="$1" kind="$2"   # kind: themes | icons
    local dir
    for dir in "$HOME/.local/share/$kind" "$HOME/.$kind" "/usr/share/$kind"; do
        [[ -d "$dir/$name" ]] && return 0
    done
    return 1
}

# ─────────────────────────── appearance ───────────────────────────

_vxo_desktop_appearance() {
    local iface=org.gnome.desktop.interface

    local scheme gtk_theme icon_theme
    IFS='|' read -r scheme gtk_theme icon_theme <<<"$(_vxo_theme_spec)"
    log_info "theme: ${VXO_THEME:-dark-magenta} ($scheme, $gtk_theme)"

    gset_soft "$iface" color-scheme "'$scheme'"
    gset_soft "$iface" clock-show-weekday "true"
    gset_soft "$iface" show-battery-percentage "true"
    gset_soft "$iface" font-hinting "'slight'"

    # kitty asks for the Nerd Font directly, but the starship prompt also turns
    # up in GNOME Terminal, Text Editor and anything else that reads this key,
    # and the stock Ubuntu Mono has none of the patched glyphs. Only set it if
    # the font really is on disk, otherwise every monospace app falls back to a
    # font fontconfig picked at random.
    local mono="${VXO_NERD_FONT_NAME:-JetBrainsMono Nerd Font}"
    if grep -qF "$mono" < <(fc-list 2>/dev/null); then
        gset_soft "$iface" monospace-font-name "'$mono 12'"
    else
        log_skip "'$mono' is not installed, leaving the GNOME monospace font alone"
    fi

    # GNOME 47+ / Ubuntu's current approach: a named accent colour applied to
    # whatever the base theme is.
    gset_soft "$iface" accent-color "'$VXO_DESKTOP_ACCENT'"

    # The older approach: a per-accent Yaru theme variant. Only set when the
    # theme is really installed, so this is a no-op on a release that dropped
    # the variants in favour of accent-color above. The Yaru-* variants come
    # from yaru-theme-gtk / yaru-theme-icon, which a stock Ubuntu desktop
    # already has; a server or derivative image may not.
    if _vxo_theme_installed "$gtk_theme" themes; then
        gset_soft "$iface" gtk-theme "'$gtk_theme'"
    else
        log_skip "GTK theme '$gtk_theme' is not installed (accent-color covers this on newer GNOME)"
    fi

    if _vxo_theme_installed "$icon_theme" icons; then
        gset_soft "$iface" icon-theme "'$icon_theme'"
    else
        log_skip "icon theme '$icon_theme' is not installed"
    fi
}

# ─────────────────────────── input sources ───────────────────────────

_vxo_desktop_input_sources() {
    gset_soft org.gnome.desktop.input-sources sources "$VXO_DESKTOP_INPUT_SOURCES"
    gset_soft org.gnome.desktop.input-sources per-window "false"

    # Said out loud because the failure mode is silent: the entry is present in
    # the list and simply never appears in the switcher.
    if ! pkg_installed ibus-mozc; then
        log_warn "ibus-mozc is not installed, so the Japanese input source will not appear."
        log_warn "Install it with: ./install.sh --only=apps"
    fi
}

# ─────────────────────────── pointer ───────────────────────────

_vxo_desktop_peripherals() {
    local touchpad=org.gnome.desktop.peripherals.touchpad
    local mouse=org.gnome.desktop.peripherals.mouse

    gset_soft "$touchpad" natural-scroll "true"
    gset_soft "$touchpad" two-finger-scrolling-enabled "true"
    gset_soft "$touchpad" send-events "'enabled'"
    gset_soft "$touchpad" speed "$VXO_DESKTOP_TOUCHPAD_SPEED"

    gset_soft "$mouse" speed "$VXO_DESKTOP_MOUSE_SPEED"
}

# ─────────────────────────── window manager policy ───────────────────────────

_vxo_desktop_window_policy() {
    # auto-maximize makes every window that opens near screen height snap to
    # maximised, which fights a tiling-ish four-workspace workflow.
    gset_soft org.gnome.mutter auto-maximize "false"
    gset_soft org.gnome.mutter center-new-windows "false"

    # Fractional scaling. This is an experimental-features list rather than a
    # boolean, so it has to be written as a whole array: appending is not a
    # thing gsettings does. scale-monitor-framebuffer is the one that enables
    # the 125%/150% options in Settings → Displays.
    gset_soft org.gnome.mutter experimental-features "['scale-monitor-framebuffer']"
}

# ─────────────────────────── dock ───────────────────────────

# Ubuntu's dock is the ubuntu-dock extension, which reads dash-to-dock's schema.
# On a non-Ubuntu GNOME the schema is absent and every write below skips.
_vxo_desktop_dock() {
    local dock=org.gnome.shell.extensions.dash-to-dock

    if ! gsettings writable "$dock" dock-position >/dev/null 2>&1; then
        log_skip "dash-to-dock schema not present, leaving the dock alone"
        return 0
    fi

    gset_soft "$dock" dock-position "'$VXO_DESKTOP_DOCK_POSITION'"
    gset_soft "$dock" dock-fixed "false"
    gset_soft "$dock" extend-height "false"

    # The trash and removable-drive tiles are Ubuntu defaults nobody asked for;
    # favourites below already covers what belongs on the dock.
    gset_soft "$dock" show-trash "false"
    gset_soft "$dock" show-mounts "false"

    # hot-keys binds Super+<n> to "launch the Nth dock item", which is the same
    # collision lib/shortcuts.sh clears in GNOME Shell's own keybindings. Both
    # have to be off or Super+1..4 does two things at once.
    gset_soft "$dock" hot-keys "false"
}

# ─────────────────────────── desktop icons ───────────────────────────

# Desktop Icons NG (ding), Ubuntu's default desktop-icons extension. The Home
# folder icon on the desktop is redundant with the dock's Nautilus/Files entry
# and with the sidebar bookmark; nobody asked for a second way to get there.
# On a non-Ubuntu GNOME the schema is absent and this write skips.
_vxo_desktop_icons() {
    local ding=org.gnome.shell.extensions.ding

    if ! gsettings writable "$ding" show-home >/dev/null 2>&1; then
        log_skip "desktop-icons (ding) schema not present, leaving desktop icons alone"
        return 0
    fi

    gset_soft "$ding" show-home "false"
}

# ─────────────────────────── favourites ───────────────────────────

# Derived from the choices made during this install rather than hard-coded, so
# the dock does not end up pinning a browser that was never installed.
_vxo_desktop_favourites() {
    local -a favs=()

    case "${VXO_BROWSER:-}" in
        chrome)  favs+=("google-chrome.desktop") ;;
        brave)   favs+=("brave-browser.desktop") ;;
        vivaldi) favs+=("vivaldi-stable.desktop") ;;
        firefox) favs+=("firefox.desktop") ;;
    esac

    favs+=("org.gnome.Nautilus.desktop")

    have kitty && favs+=("kitty.desktop")
    [[ "${VXO_EDITOR:-nvim}" == "vscode" ]] && have code && favs+=("code.desktop")

    if ((${#favs[@]} == 0)); then
        log_skip "no favourites to pin"
        return 0
    fi

    # Only pin entries that really exist, or the dock renders a blank tile.
    local -a present=()
    local f d
    for f in "${favs[@]}"; do
        for d in "$HOME/.local/share/applications" /usr/share/applications /var/lib/snapd/desktop/applications; do
            if [[ -f "$d/$f" ]]; then
                present+=("$f")
                break
            fi
        done
    done

    if ((${#present[@]} == 0)); then
        log_skip "none of the intended favourites have a .desktop file yet"
        return 0
    fi

    local value="[" first=1
    for f in "${present[@]}"; do
        ((first)) || value+=", "
        value+="'$f'"
        first=0
    done
    value+="]"

    gset_soft org.gnome.shell favorite-apps "$value"
}

# ─────────────────────────── account picture ───────────────────────────

# Vortex profile only: a personal install already picked its own splash image
# for a reason, and forcing a team logo onto someone's account picture would
# fight that choice. Uses AccountsService (what GNOME Settings itself calls),
# not a hand-edited file, so it stays consistent if the daemon rewrites its
# state.
_vxo_desktop_account_picture() {
    if [[ "${VXO_PROFILE:-}" != "vortex" ]]; then
        log_skip "account picture: personal profile, leaving it alone"
        return 0
    fi

    if ! have gdbus; then
        log_skip "gdbus not found, leaving the account picture alone"
        return 0
    fi

    if [[ "${VXO_DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] would set the account picture to the Vortex logo"
        return 0
    fi

    local logo; logo="$(_vxo_resolve_logo)"
    [[ -n "$logo" && -f "$logo" ]] || { log_skip "no logo resolved, leaving the account picture alone"; return 0; }

    if run gdbus call --system \
        --dest org.freedesktop.Accounts \
        --object-path "/org/freedesktop/Accounts/User$(id -u)" \
        --method org.freedesktop.Accounts.User.SetIconFile "$logo" >/dev/null; then
        log_ok "account picture set to $logo"
    else
        log_warn "could not set the account picture via AccountsService (no polkit auth?)"
    fi
}
