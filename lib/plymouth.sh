#!/usr/bin/env bash
# lib/plymouth.sh: the boot splash. Puts your terminal splash image on screen
# during boot and shutdown, in place of the manufacturer or Ubuntu logo.
#
# Sourced by install.sh. Provides: vxo_boot_splash.
#
# WHAT UBUNTU DOES BY DEFAULT, and what this changes.
#
# Ubuntu's default Plymouth theme is `bgrt`. BGRT is an ACPI table in which the
# firmware parks the vendor logo it drew at power-on, and the bgrt theme's whole
# purpose is to keep showing that logo so the handoff from firmware to kernel is
# seamless. That is why a stock Ubuntu boot shows a Dell or Lenovo badge and not
# an Ubuntu one. The relevant switch is UseFirmwareBackground=true.
#
# This module installs a sibling theme with the same spinner but
# UseFirmwareBackground=false and our own image as the watermark, then points the
# default.plymouth alternative at it and rebuilds the initramfs. The theme has to
# be in the initramfs because Plymouth starts before the root filesystem is
# mounted; changing the alternative without rebuilding changes nothing at all.
#
# ONE HONEST LIMIT. The logo the firmware itself paints between pressing power
# and GRUB starting belongs to the UEFI, is stored in the firmware's own flash,
# and no change made from inside Linux can touch it. What this module controls is
# everything from Plymouth onward, which in practice is all but the first second
# or so. Replacing the firmware logo means a vendor tool or a reflash, which is
# emphatically not something an onboarding script should be doing.
#
# Reverse the whole thing with:
#   sudo update-alternatives --auto default.plymouth && sudo update-initramfs -u
#
# SCOPE: Ubuntu 22.04 only.

[[ -n "${_VXO_PLYMOUTH_SOURCED:-}" ]] && return 0
_VXO_PLYMOUTH_SOURCED=1

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

VXO_SPLASH_NAME="vortex-splash"
VXO_SPLASH_DIR="/usr/share/plymouth/themes/$VXO_SPLASH_NAME"
VXO_SPLASH_FILE="$VXO_SPLASH_DIR/${VXO_SPLASH_NAME}.plymouth"
VXO_SPLASH_STOCK="/usr/share/plymouth/themes/spinner"

# update-alternatives priority. bgrt registers at 110, so this has to outrank it
# for `--auto` to resolve here too. We also --set it explicitly.
VXO_SPLASH_PRIORITY=200

# The watermark is drawn at its native pixel size: Plymouth does no scaling. The
# bundled logo is 636px wide, which is overbearing on a 1080p panel, so cap it.
VXO_SPLASH_MAX_WIDTH=480

# Set by any step that actually modified something. The initramfs rebuild is the
# expensive part of this stage, 30 to 60 seconds, and re-running it when nothing
# changed is the difference between a re-run being a no-op and being the slowest
# thing in the installer.
VXO_SPLASH_CHANGED=0

vxo_boot_splash() {
    VXO_SPLASH_CHANGED=0

    if [[ "${VXO_BOOT_SPLASH:-1}" != "1" ]]; then
        stage_abort "boot splash: disabled with --no-boot-splash"
        return 0
    fi

    _vxo_splash_deps || return 0
    _vxo_splash_preload_gpu_module

    local src; src="$(_vxo_splash_source_image)"
    if [[ -z "$src" ]]; then
        stage_abort "boot splash: no splash image available, leaving the boot theme alone"
        return 0
    fi
    log_info "boot splash image: $src"

    _vxo_splash_stage_assets "$src"
    _vxo_splash_write_theme

    if _vxo_splash_activate; then
        _vxo_splash_rebuild_initramfs
    fi
}

# ─────────────────────────── dependencies ───────────────────────────

_vxo_splash_deps() {
    apt_update_once

    # plymouth-theme-spinner supplies the animation frames, progress bar, and
    # password-entry graphics this theme reuses. plymouth-label draws the text.
    apt_install plymouth plymouth-label plymouth-theme-spinner

    if [[ "${VXO_DRY_RUN:-0}" == "1" ]]; then
        return 0
    fi

    # stage_abort, not a bare `return 1`. The caller bails out with `return 0`,
    # which run_stage reads as success and checkpoints, so the stage would be
    # recorded as done having installed nothing at all. stage_abort records it as
    # deliberately skipped instead, which is both honest and re-runnable.
    if [[ ! -d "$VXO_SPLASH_STOCK" ]]; then
        stage_abort "boot splash: $VXO_SPLASH_STOCK is missing even after installing plymouth-theme-spinner"
        return 1
    fi

    # No initramfs-tools means no initramfs to put the theme into, which is
    # normal inside a container and abnormal on real hardware.
    if ! have update-initramfs; then
        stage_abort "boot splash: update-initramfs is missing (a container?), so a new theme could not take effect"
        return 1
    fi

    return 0
}

# ─────────────────────────── early KMS ───────────────────────────

# Without this, the real GPU driver is not in the initramfs at all: it only
# loads later, from the root filesystem, well after Plymouth has already
# started drawing on the kernel's generic simple-framebuffer. Measured on a
# TigerLake Iris Xe laptop: simple-framebuffer registers at 0.96s, i915 does
# not take over until 4.15s. For those ~3s the splash is on a crude fallback
# surface, then visibly resets once the real driver takes over — which reads
# as "the logo shows up late" rather than being there from Plymouth's first
# frame. Detected via lspci rather than hardcoded to i915: this exact chip
# also exposes the newer `xe` driver, so whichever one the kernel actually
# bound is the one worth preloading.
_vxo_splash_preload_gpu_module() {
    local driver
    driver="$(lspci -k -d ::0300 2>/dev/null | awk -F': ' '/Kernel driver in use/ {print $2; exit}')"
    [[ -n "$driver" ]] || return 0

    local modules_file=/etc/initramfs-tools/modules
    [[ -f "$modules_file" ]] || return 0

    if grep -qxF "$driver" "$modules_file" 2>/dev/null; then
        log_skip "boot splash: $driver already preloaded in the initramfs"
        return 0
    fi

    if [[ "${VXO_DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] would preload $driver in the initramfs for an earlier display handoff"
        return 0
    fi

    run sudo sh -c "printf '%s\n' '$driver' >> '$modules_file'" \
        || { log_warn "boot splash: could not preload $driver in the initramfs"; return 0; }

    VXO_SPLASH_CHANGED=1
    log_ok "boot splash: preloading $driver in the initramfs, for an earlier display handoff"
}

# ─────────────────────────── the image ───────────────────────────

# Deliberately prefers the image fastfetch actually resolved over the bundled
# default. That file is the one you see in the terminal, including a --logo
# override, so "the same sticker as my terminal" stays true by construction
# rather than by two lists happening to agree.
_vxo_splash_source_image() {
    local icons="$HOME/.config/fastfetch/icons"
    local candidate

    if [[ -d "$icons" ]]; then
        for candidate in "$icons"/*.png; do
            [[ -f "$candidate" ]] || continue
            printf '%s' "$candidate"
            return 0
        done
    fi

    # Nothing resolved yet (this stage running before kitty-fastfetch, or via
    # --only=boot-splash on a fresh clone), so fall back to the profile default.
    if [[ "${VXO_PROFILE:-vortex}" == "personal" ]]; then
        candidate="$VXO_ASSETS/logos/holo_gt3.png"
    else
        candidate="$VXO_ASSETS/logos/vortex.png"
    fi
    [[ -f "$candidate" ]] && printf '%s' "$candidate"
}

# ─────────────────────────── theme assets ───────────────────────────

# Copy the spinner's graphics into our own theme dir and drop our image in as
# watermark.png.
#
# The theme gets its own ImageDir rather than pointing ImageDir at the spinner's
# directory, because two-step reads watermark.png from ImageDir and sharing the
# directory would mean overwriting Ubuntu's own spinner watermark. That file
# belongs to plymouth-theme-spinner, so apt would silently restore it on the next
# upgrade and the splash would revert to the Ubuntu logo.
_vxo_splash_stage_assets() {
    local src="$1"

    if [[ "${VXO_DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] would stage the spinner assets and $src into $VXO_SPLASH_DIR"
        return 0
    fi

    run sudo install -d -m 0755 "$VXO_SPLASH_DIR"

    # Everything except the stock watermark and the theme descriptor. Files that
    # are already byte-identical are left alone, so a re-run copies nothing and
    # leaves VXO_SPLASH_CHANGED clear.
    local f base copied=0 unchanged=0
    for f in "$VXO_SPLASH_STOCK"/*.png; do
        [[ -f "$f" ]] || continue
        base="$(basename "$f")"
        [[ "$base" == "watermark.png" ]] && continue
        if [[ -f "$VXO_SPLASH_DIR/$base" ]] && cmp -s "$f" "$VXO_SPLASH_DIR/$base"; then
            unchanged=$((unchanged + 1))
            continue
        fi
        sudo install -m 0644 "$f" "$VXO_SPLASH_DIR/$base" || continue
        copied=$((copied + 1))
    done

    if ((copied > 0)); then
        VXO_SPLASH_CHANGED=1
        log_info "boot splash: staged $copied graphics from the spinner theme ($unchanged already current)"
    else
        log_skip "boot splash: all $unchanged spinner graphics already current"
    fi

    _vxo_splash_install_watermark "$src"
}

_vxo_splash_install_watermark() {
    local src="$1"
    local dest="$VXO_SPLASH_DIR/watermark.png"

    local width=""
    if have identify; then
        width="$(identify -format '%w' "$src" 2>/dev/null || true)"
    fi

    # Resize when we can measure it and it is too wide. Without imagemagick the
    # image is used at native size, which is worse-looking but still correct, so
    # this is not worth failing over.
    if have convert && [[ "$width" =~ ^[0-9]+$ ]] && ((width > VXO_SPLASH_MAX_WIDTH)); then
        local tmp; tmp="$(mktemp -d)"
        if convert "$src" -resize "${VXO_SPLASH_MAX_WIDTH}x" -strip "$tmp/watermark.png" 2>>"$VXO_LOG_FILE"; then
            _vxo_splash_place_watermark "$tmp/watermark.png" "$dest" \
                "logo scaled ${width}px → ${VXO_SPLASH_MAX_WIDTH}px wide"
            rm -rf "$tmp"
            return 0
        fi
        rm -rf "$tmp"
        log_warn "boot splash: could not resize the logo, using it at native size"
    elif [[ -z "$width" ]]; then
        log_warn "boot splash: imagemagick is absent, so the logo is used at native size"
    fi

    _vxo_splash_place_watermark "$src" "$dest" "installed $dest"
}

# Copy only when the bytes differ, so a re-run does not mark the stage changed
# and trigger a pointless initramfs rebuild.
_vxo_splash_place_watermark() {
    local from="$1" dest="$2" what="$3"

    if [[ -f "$dest" ]] && cmp -s "$from" "$dest"; then
        log_skip "boot splash: watermark already current"
        return 0
    fi

    run sudo install -m 0644 "$from" "$dest"
    VXO_SPLASH_CHANGED=1
    log_ok "boot splash: $what"
}

# ─────────────────────────── theme descriptor ───────────────────────────

# A two-step theme, which is the module both spinner and bgrt use. The values
# that matter here:
#
#   UseFirmwareBackground=false   the whole point. true is what makes stock
#                                 Ubuntu keep showing the vendor's BGRT logo.
#   WatermarkVerticalAlignment    .44 puts the logo slightly above centre, so
#                                 the spinner below it reads as one composition
#                                 rather than two unrelated things.
#   VerticalAlignment=.75         the spinner, below the logo.
#   ImageDir                      our own directory, see _vxo_splash_stage_assets.
_vxo_splash_write_theme() {
    local content
    content="$(cat <<EOF
[Plymouth Theme]
Name=Vortex splash
Description=Generated by vortex-onboarding: the terminal splash image, shown at boot instead of the firmware or Ubuntu logo. Regenerate with ./install.sh --only=boot-splash
ModuleName=two-step

[two-step]
Font=Ubuntu 12
TitleFont=Ubuntu Light 30
ImageDir=$VXO_SPLASH_DIR
DialogHorizontalAlignment=.5
DialogVerticalAlignment=.7
TitleHorizontalAlignment=.5
TitleVerticalAlignment=.382
HorizontalAlignment=.5
VerticalAlignment=.75
WatermarkHorizontalAlignment=.5
WatermarkVerticalAlignment=.44
Transition=none
TransitionDuration=0.0
BackgroundStartColor=0x000000
BackgroundEndColor=0x000000
ProgressBarBackgroundColor=0x606060
ProgressBarForegroundColor=0xffffff
DialogClearsFirmwareBackground=true
MessageBelowAnimation=true

[boot-up]
UseEndAnimation=false
UseFirmwareBackground=false

[shutdown]
UseEndAnimation=false
UseFirmwareBackground=false

[reboot]
UseEndAnimation=false
UseFirmwareBackground=false

[updates]
SuppressMessages=true
ProgressBarShowPercentComplete=true
UseProgressBar=true
Title=Installing Updates...
SubTitle=Do not turn off your computer

[system-upgrade]
SuppressMessages=true
ProgressBarShowPercentComplete=true
UseProgressBar=true
Title=Upgrading System...
SubTitle=Do not turn off your computer

[firmware-upgrade]
SuppressMessages=true
ProgressBarShowPercentComplete=true
UseProgressBar=true
Title=Upgrading Firmware...
SubTitle=Do not turn off your computer
EOF
)"

    if [[ "${VXO_DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] would write $VXO_SPLASH_FILE"
        return 0
    fi

    if [[ -f "$VXO_SPLASH_FILE" ]] && [[ "$(cat "$VXO_SPLASH_FILE" 2>/dev/null)" == "$content" ]]; then
        log_skip "boot splash: theme descriptor already current"
        return 0
    fi

    local tmp; tmp="$(mktemp)"
    printf '%s\n' "$content" >"$tmp"
    run sudo install -D -m 0644 "$tmp" "$VXO_SPLASH_FILE"
    rm -f "$tmp"
    VXO_SPLASH_CHANGED=1
    log_ok "boot splash: wrote $VXO_SPLASH_FILE"
}

# ─────────────────────────── activation ───────────────────────────

# default.plymouth is an update-alternatives link on Ubuntu, not a plain symlink.
# Writing the symlink by hand works until the next plymouth upgrade re-runs
# update-alternatives and silently reverts it, so go through the tool.
_vxo_splash_activate() {
    if [[ "${VXO_DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] would register $VXO_SPLASH_NAME with update-alternatives and select it"
        return 0
    fi

    local before
    before="$(update-alternatives --query default.plymouth 2>/dev/null | awk '/^Value:/ {print $2}')"

    run sudo update-alternatives --install \
        /usr/share/plymouth/themes/default.plymouth default.plymouth \
        "$VXO_SPLASH_FILE" "$VXO_SPLASH_PRIORITY" \
        || { log_warn "boot splash: could not register the theme with update-alternatives"; return 1; }

    run sudo update-alternatives --set default.plymouth "$VXO_SPLASH_FILE" \
        || { log_warn "boot splash: could not select the theme"; return 1; }

    local current
    current="$(update-alternatives --query default.plymouth 2>/dev/null | awk '/^Value:/ {print $2}')"
    if [[ "$current" != "$VXO_SPLASH_FILE" ]]; then
        log_warn "boot splash: default.plymouth is '$current', expected $VXO_SPLASH_FILE"
        return 1
    fi

    if [[ "$before" != "$current" ]]; then
        VXO_SPLASH_CHANGED=1
        log_ok "boot splash: default.plymouth → $VXO_SPLASH_NAME (was ${before:-unset})"
    else
        log_skip "boot splash: default.plymouth already $VXO_SPLASH_NAME"
    fi
}

# Plymouth runs from the initramfs, before the root filesystem is available, so
# the theme is only in effect once it has been copied in there. Skipping this
# leaves the alternative pointing at a theme that never gets used, which is the
# single easiest way to conclude "it didn't work".
_vxo_splash_rebuild_initramfs() {
    if [[ "${VXO_DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] would run update-initramfs -u -k all"
        return 0
    fi

    # Nothing changed, so the initramfs already holds this exact theme. Rebuilding
    # it would burn 30 to 60 seconds to produce a byte-identical result.
    if ((VXO_SPLASH_CHANGED == 0)); then
        log_skip "boot splash: nothing changed, so the initramfs was left alone"
        return 0
    fi

    log_info "boot splash: rebuilding the initramfs (30 to 60 seconds)"
    if ! run sudo update-initramfs -u -k all; then
        log_warn "boot splash: update-initramfs failed, so the new theme is not in the initramfs yet."
        log_warn "Run it yourself and reboot: sudo update-initramfs -u -k all"
        return 1
    fi

    log_ok "boot splash: initramfs rebuilt. The new splash appears on the next boot."

    # `quiet splash` is what tells the kernel to hand the screen to Plymouth at
    # all. A fresh Ubuntu install always has it; a machine someone has been
    # tuning may not, and without it none of the above is visible.
    if ! grep -q 'splash' /etc/default/grub 2>/dev/null; then
        log_warn "boot splash: 'splash' is not in GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub,"
        log_warn "so the splash will not be shown. Add it, then: sudo update-grub"
    fi
}
