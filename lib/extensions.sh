#!/usr/bin/env bash
# lib/extensions.sh: GNOME Shell extensions, installed non-interactively.
#
# Sourced by install.sh. Provides: vxo_gnome_extensions.
#
# Two extensions: Rounded Window Corners (clips every window to a rounded
# rectangle) and a lock screen blur extension. Both are version-resolved: which
# upstream provides them depends on the GNOME Shell major, see the uuid blocks
# below. Add more by appending to the list built in vxo_gnome_extensions.
#
# HOW THIS WORKS, and why it is not just "unzip into the extensions dir":
#
#   * Extensions are pinned to a GNOME Shell major version, and the API will NOT
#     do that pinning for you. extension-info/?uuid=...&shell_version=42 accepts
#     the shell_version parameter and then ignores it: it answers with the
#     extension's newest build regardless, so its top-level .download_url can
#     easily be a zip whose metadata says shell-version 46..50. Installing that
#     on GNOME 42 "succeeds", and the extension then refuses to load with
#     nothing to show for it but an entry in the shell's journal.
#
#     So the version match is made HERE, not by the server: we read
#     .shell_version_map, look up the entry keyed by this shell's major, and
#     build the download URL from that entry's pk. No entry for this shell
#     means there is no build for this shell, and we skip with a warning rather
#     than falling back to .download_url — a fallback there is exactly how you
#     end up with a silently inert extension.
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

# Rounded window corners has two upstreams, and which one applies is decided by
# the shell major rather than by preference:
#
#   * yilozt's original, metadata shell-version 40..44. This is the only one
#     that loads on Ubuntu 22.04, which ships GNOME Shell 42.
#   * fxgn's "Reborn" fork, metadata shell-version 46..50. This is what a
#     current GNOME wants, and what this installer used on 26.04.
#
# Note the gap: neither supports GNOME 45. On such a shell the version-map
# lookup in _vxo_ext_install finds nothing and skips with a warning, which is
# the honest outcome — there is no build to install.
#
# They are not interchangeable at the settings level either: the fork renamed
# both its dconf path and its keys, so _vxo_rounded_corners_configure has to
# know which one it is talking to.
VXO_ROUNDED_UUID_LEGACY="rounded-window-corners@yilozt"
VXO_ROUNDED_UUID_REBORN="rounded-window-corners@fxgn"

# The lock screen extension splits on shell major for the same reason rounded
# corners does — no single upstream covers both ends:
#
#   * Lockscreen Studio, metadata shell-version 45..50. Blur, text and clock
#     styling on the lock screen. This is what the installer used on 26.04, and
#     it has NO build for GNOME 42; asking for one is how you get an extension
#     that unpacks and then never loads.
#   * Blur my Shell, metadata shell-version 3.36..50, which very much includes
#     42. Its `lockscreen` component is the same idea reduced to the part that
#     matters here: a gaussian blur over the lock screen background.
#
# So 22.04 is not left without one. Blur my Shell is the wider-ranging of the
# two — left alone it also blurs the panel, the overview, the app grid and
# application windows — and _vxo_lockscreen_configure turns those off, because
# what was asked for here is a lock screen extension and the rest of this
# installer's desktop stage already decides how the desktop looks. Re-enable any
# of them from the Extension Manager GUI that lib/apps.sh installs.
VXO_LOCKSCREEN_UUID_STUDIO="lockscreen-studio@pedro.projects"
VXO_LOCKSCREEN_UUID_BLUR="blur-my-shell@aunetx"

# Corner radius in pixels, applied to whichever variant is installed. GNOME's own
# libadwaita windows use 12, and the extensions default to 15 (Reborn) and 12
# (yilozt). 8 sits at the top of the 4-8 range that reads as "softened" rather
# than "bubbly" at 1x scaling. Override with --rounded-radius=N.
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

    # Which rounded-corners upstream this shell can actually run. Resolved here,
    # once, and then carried through install/enable/configure so those three
    # cannot disagree about which extension is on the machine.
    local rounded_uuid; rounded_uuid="$(_vxo_rounded_uuid "$shell_major")"
    local lock_uuid; lock_uuid="$(_vxo_lockscreen_uuid "$shell_major")"

    # uuid per line. Extend this list to install more.
    local -a extensions=(
        "$rounded_uuid"
        "$lock_uuid"
    )

    local uuid installed=0 rounded_ok=0 lock_ok=0
    for uuid in "${extensions[@]}"; do
        if _vxo_ext_install "$uuid" "$shell_major"; then
            _vxo_ext_enable "$uuid"
            installed=$((installed + 1))
            # `if`, not `[[ ... ]] && x=1`: the last such line in this body sets
            # the loop iteration's exit status, and a uuid can only match one of
            # the two, so the non-matching test would leave the body returning
            # non-zero for errexit to trip over if this stage ever stopped being
            # a soft one.
            if [[ "$uuid" == "$rounded_uuid" ]]; then rounded_ok=1; fi
            if [[ "$uuid" == "$lock_uuid" ]]; then lock_ok=1; fi
        fi
    done

    ((installed > 0)) || { log_warn "no extensions were installed"; return 0; }

    # User extensions off globally would make every install above inert.
    gset_soft org.gnome.shell disable-user-extensions "false"

    # Only when the extension is really there. The two variants read different
    # dconf paths, so writing settings for one that was never installed would
    # leave keys nothing reads behind and prove nothing.
    if ((rounded_ok == 1)); then
        _vxo_rounded_corners_configure "$rounded_uuid"
    else
        log_skip "rounded corners was not installed, so its settings were not written"
    fi

    if ((lock_ok == 1)); then
        _vxo_lockscreen_configure "$lock_uuid"
    else
        log_skip "the lock screen extension was not installed, so its settings were not written"
    fi

    log_warn "Log out and back in for the extensions to load. Under Wayland the"
    log_warn "running shell cannot pick up a newly installed extension."
}

# GNOME >= 46 gets the Reborn fork, everything older gets yilozt's original. A
# GNOME 45 shell therefore resolves to the legacy uuid and is then correctly
# rejected by the version-map check in _vxo_ext_install, because that upstream
# stops at 44 and no other one starts before 46.
_vxo_rounded_uuid() {
    local shell_major="$1"
    if ((shell_major >= 46)); then
        printf '%s' "$VXO_ROUNDED_UUID_REBORN"
    else
        printf '%s' "$VXO_ROUNDED_UUID_LEGACY"
    fi
}

# GNOME >= 45 gets Lockscreen Studio, everything older gets Blur my Shell. The
# cut is at 45 because that is where Studio's own metadata starts; Blur my Shell
# covers 3.36..50 and so is a valid answer for any shell this installer will
# meet, which makes it the right fallback rather than a stopgap.
_vxo_lockscreen_uuid() {
    local shell_major="$1"
    if ((shell_major >= 45)); then
        printf '%s' "$VXO_LOCKSCREEN_UUID_STUDIO"
    else
        printf '%s' "$VXO_LOCKSCREEN_UUID_BLUR"
    fi
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

    # The version match happens here, and ONLY here.
    #
    # The shell_version= parameter in the query above is accepted and ignored by
    # extensions.gnome.org: the response's top-level .download_url points at the
    # extension's newest build whatever you ask for. Trusting it on GNOME 42
    # installs a zip whose metadata.json says shell-version 46..50, which
    # unpacks fine, enables fine, and then never loads — the worst kind of
    # failure this module can produce, because everything reports success.
    #
    # .shell_version_map is the part of the response that is actually keyed by
    # shell major. Its entries carry exactly two fields:
    #   "42": {"pk": 39213, "version": 11}
    # .pk is the primary key of one specific uploaded build, .version is that
    # build's user-facing version number. There is no .version_tag member —
    # despite the download endpoint spelling its parameter that way, the value
    # it wants is the pk. Reading .version_tag here yields empty for EVERY
    # extension, which would make this function skip all of them and install
    # nothing at all.
    #
    # No entry for this shell means no build for this shell: skip, do not fall
    # back to .download_url.
    local version_tag
    version_tag="$(jq -r --arg v "$shell_major" '.shell_version_map[$v].pk // empty' <<<"$info")"
    if [[ -z "$version_tag" ]]; then
        # Spelled out so this cannot be mistaken for the network failure above.
        # Nothing was downloaded and nothing went wrong; the extension simply
        # has no build for this shell (Lockscreen Studio on GNOME 42, for
        # instance, because it supports 45 and newer only).
        local supported
        supported="$(jq -r '(.shell_version_map // {}) | keys_unsorted | join(", ")' <<<"$info" 2>/dev/null || true)"
        log_warn "$uuid has no build for GNOME Shell $shell_major, skipping it"
        if [[ -n "$supported" ]]; then
            log_warn "  extensions.gnome.org lists builds for GNOME Shell: $supported"
        fi
        log_warn "  this is a version mismatch, not a download failure: nothing was fetched"
        log_warn "  check https://extensions.gnome.org and install it by hand if you need it"
        return 1
    fi

    local path="/download-extension/${uuid}.shell-extension.zip?version_tag=${version_tag}"

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
# from at the path its schema declares, which works whether or not gnome-shell
# has loaded the extension yet.
#
# The flip side of bypassing schema resolution is that dconf will happily store
# a key, or a dict member, that the schema never declared. The extension reads
# the members it knows by name and ignores the rest, so a settings write aimed
# at the wrong variant does not error — it just does nothing, which is the same
# silently-inert outcome the version pinning above exists to avoid. Hence the
# split below: the fork renamed both its dconf path and several of its keys, and
# each branch has to stay faithful to its own schema.
VXO_ROUNDED_DCONF_REBORN="/org/gnome/shell/extensions/rounded-window-corners-reborn"
VXO_ROUNDED_DCONF_LEGACY="/org/gnome/shell/extensions/rounded-window-corners"

# _vxo_rounded_corners_configure <uuid>: settings for whichever variant is
# installed.
#
# Common to both: the radius lives inside global-rounded-corner-settings, a
# single a{sv} dict. dconf cannot write one member of a dict, so the whole value
# is rewritten, and every member other than the radius (and, on Reborn, the
# border colour) is the extension's own schema default reproduced verbatim.
#
# Where they differ (verified against each extension's own gschema):
#
#                       Reborn (@fxgn)        yilozt (@yilozt)
#   dconf path          ...-reborn/           ...rounded-window-corners/
#   radius member       borderRadius          border_radius
#   keep-when-maximized keepRoundedCorners    keep_rounded_corners
#   border colour       borderColor, inside   border-color, a SEPARATE
#                       the dict, as <[..]>   top-level (dddd) key
#   'enabled' member    present               absent entirely
#
# border-width, skip-libadwaita-app and skip-libhandy-app are top-level keys
# with the same names and types in both.
_vxo_rounded_corners_configure() {
    local uuid="$1"
    local radius="$VXO_ROUNDED_RADIUS"

    if ! [[ "$radius" =~ ^[0-9]+$ ]] || ((radius < 0 || radius > 40)); then
        log_warn "invalid corner radius '$radius', falling back to 6"
        radius=6
    fi

    if ! have dconf; then
        log_skip "dconf not found, so the rounded-corner settings were not written"
        return 0
    fi

    local base value
    if [[ "$uuid" == "$VXO_ROUNDED_UUID_REBORN" ]]; then
        base="$VXO_ROUNDED_DCONF_REBORN"
        value="{'padding': <{'left': <uint32 1>, 'right': <uint32 1>, 'top': <uint32 1>, 'bottom': <uint32 1>}>, 'keepRoundedCorners': <{'maximized': <false>, 'fullscreen': <false>}>, 'borderRadius': <uint32 ${radius}>, 'smoothing': <0>, 'borderColor': <[0.75, 0.75, 0.75, 1.0]>, 'enabled': <true>}"
        run dconf write "$base/global-rounded-corner-settings" "$value"
    else
        base="$VXO_ROUNDED_DCONF_LEGACY"
        # No 'enabled' and no 'borderColor' in this dict: both are members the
        # yilozt schema does not declare, and adding them would be stored and
        # then ignored. Its border colour is the top-level key written below.
        value="{'padding': <{'left': <uint32 1>, 'right': <uint32 1>, 'top': <uint32 1>, 'bottom': <uint32 1>}>, 'keep_rounded_corners': <{'maximized': <false>, 'fullscreen': <false>}>, 'border_radius': <uint32 ${radius}>, 'smoothing': <0>}"
        run dconf write "$base/global-rounded-corner-settings" "$value"

        # (dddd), not the a{sv} member Reborn uses. Same colour, different home.
        run dconf write "$base/border-color" "(0.75, 0.75, 0.75, 1.0)"
    fi

    # border-width is a top-level key in both variants, defaults to 0, and
    # neither extension draws a border at all until it is set. 1px, grayish-white
    # ([0.75, 0.75, 0.75] on a 0-1 scale) outline.
    run dconf write "$base/border-width" "1"

    # Both skip libadwaita apps by default, on the reasoning that they round
    # themselves. That leaves a visibly mixed desktop: GTK4 apps at their own
    # 12px and everything else at ours. Turning the skip off makes the extension
    # clip every window to the same radius, which is what "all windows rounded"
    # actually means.
    run dconf write "$base/skip-libadwaita-app" "false"
    run dconf write "$base/skip-libhandy-app" "false"

    log_ok "window corner radius set to ${radius}px, border 1px grayish-white, for all windows ($uuid)"
}

# ─────────────────────── lock screen settings ───────────────────────

# Blur my Shell's dconf root. Every component is a child of this path, one
# subdirectory per component, exactly as its gschema declares them.
VXO_BLUR_DCONF="/org/gnome/shell/extensions/blur-my-shell"

# Components Blur my Shell blurs out of the box, minus the lock screen. Written
# false because this stage installs it AS a lock screen extension: blurring the
# panel and the overview is a desktop-wide appearance change that lib/desktop.sh
# owns, and `applications` in particular puts a live gaussian blur behind every
# window, which costs GPU on the laptops this is deployed to and fights the
# rounded-corner clipping configured above.
#
# These are all plain booleans named `blur` under their own component path, so
# the list is the paths and the value is the same for each.
VXO_BLUR_OFF_COMPONENTS=(
    panel
    overview
    appfolder
    applications
    window-list
    screenshot
    dash-to-dock
)

# _vxo_lockscreen_configure <uuid>: settings for whichever lock screen extension
# this shell got.
#
# dconf rather than gsettings for the same reason as the rounded-corner settings
# above: the schema is compiled inside the extension's own directory, which the
# standalone `gsettings` command does not search, so gset_soft would report "no
# such schema" and do nothing whether or not the extension installed correctly.
_vxo_lockscreen_configure() {
    local uuid="$1"

    # Lockscreen Studio ships usable defaults and exposes its styling through
    # its own preferences window. Nothing to write, and writing guesses into an
    # a{sv} it did not declare would be stored and then ignored — the same
    # silently-inert outcome the rest of this module exists to avoid.
    if [[ "$uuid" == "$VXO_LOCKSCREEN_UUID_STUDIO" ]]; then
        log_skip "$uuid uses its own defaults, configure it from its preferences window"
        return 0
    fi

    if ! have dconf; then
        log_skip "dconf not found, so the lock screen settings were not written"
        return 0
    fi

    # The extension's own lockscreen defaults, pinned explicitly. customize=true
    # is what makes sigma and brightness under this path apply at all: left
    # false, the component falls back to the extension's global blur values,
    # which a later change elsewhere in the GUI would silently drag along.
    run dconf write "$VXO_BLUR_DCONF/lockscreen/blur" "true"
    run dconf write "$VXO_BLUR_DCONF/lockscreen/customize" "true"
    run dconf write "$VXO_BLUR_DCONF/lockscreen/sigma" "30"
    run dconf write "$VXO_BLUR_DCONF/lockscreen/brightness" "0.6"

    local component
    for component in "${VXO_BLUR_OFF_COMPONENTS[@]}"; do
        run dconf write "$VXO_BLUR_DCONF/$component/blur" "false"
    done

    log_ok "lock screen blur on (sigma 30, brightness 0.6); every other Blur my Shell component off ($uuid)"
}
