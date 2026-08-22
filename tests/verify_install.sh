#!/usr/bin/env bash
# tests/verify_install.sh: post-install checklist.
#
# Deliberately NOT `set -e`: every check must run so you get the full picture in
# one pass, not just the first failure. Exits non-zero if anything FAILed.
#
#   ./tests/verify_install.sh
#
# Checks that do not apply to your profile report SKIP, not FAIL.

set -uo pipefail

VXO_TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$VXO_TESTS_DIR/../lib/common.sh"

# common.sh sets -e for the installer; verification wants to keep going.
set +e
trap - ERR

# Recover the choices made at install time, if the installer recorded them.
VXO_ENV_FILE="$HOME/.config/vortex-onboarding/env.sh"
if [[ -f "$VXO_ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$VXO_ENV_FILE"
    log_info "profile settings loaded from $VXO_ENV_FILE"
else
    log_warn "$VXO_ENV_FILE not found, so profile-specific checks will be inferred or skipped"
fi

VXO_PROFILE="${VXO_PROFILE:-}"
VXO_EDITOR="${VXO_EDITOR:-}"
VXO_BROWSER="${VXO_BROWSER:-}"
VXO_THEME="${VXO_THEME:-dark-magenta}"
VXO_ROS="${VXO_ROS:-}"

PASS=0; FAIL=0; SKIPPED=0
FAILED_NAMES=()

# ─────────────────────────── result helpers ───────────────────────────

_row() {
    local status="$1" colour="$2" name="$3" detail="$4"
    printf '%s%-4s%s %-34s %s\n' "$colour" "$status" "$C_RESET" "$name" "$detail"
}

pass() { PASS=$((PASS + 1)); _row "PASS" "$C_GREEN" "$1" "${2:-}"; }
skip() { SKIPPED=$((SKIPPED + 1)); _row "SKIP" "$C_DIM" "$1" "${2:-}"; }
fail() {
    FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1")
    _row "FAIL" "$C_RED" "$1" "${2:-}"
}

# check_cmd <name> <command> [expected-hint]
check_cmd() {
    local name="$1" cmd="$2"
    if command -v "$cmd" >/dev/null 2>&1; then
        pass "$name" "$(command -v "$cmd")"
    else
        fail "$name" "'$cmd' is not on PATH"
    fi
}

section() { printf '\n%s%s%s\n' "$C_BOLD$C_CYAN" "$1" "$C_RESET"; }

# ─────────────────────────── checks ───────────────────────────

section "System"

# ubuntu_release() reads /etc/os-release, which minimal images always have.
# lsb_release is not installed on server/cloud/container Ubuntu.
release="$(ubuntu_release)"
case "$release" in
    22.04) pass "Ubuntu release" "$release" ;;
    *)     fail "Ubuntu release" "got '$release', expected 22.04" ;;
esac

for compiler in gcc g++; do
    if command -v "$compiler" >/dev/null 2>&1; then
        ver="$("$compiler" -dumpversion 2>/dev/null | cut -d. -f1)"
        if [[ "$ver" == "12" ]]; then
            pass "$compiler is version 12" "$("$compiler" --version | head -1)"
        else
            fail "$compiler is version 12" "got major version '$ver', expected 12"
        fi
    else
        fail "$compiler is version 12" "'$compiler' is not on PATH"
    fi
done

section "C++ libraries"

# Eigen is header-only, so "installed" means the headers resolve, not that a
# library exists.
if [[ -f /usr/include/eigen3/Eigen/src/Core/util/Macros.h ]]; then
    eigen_ver="$(awk '/define EIGEN_WORLD_VERSION/ {w=$3} /define EIGEN_MAJOR_VERSION/ {m=$3} /define EIGEN_MINOR_VERSION/ {p=$3} END {print w"."m"."p}' \
        /usr/include/eigen3/Eigen/src/Core/util/Macros.h)"
    pass "Eigen headers" "$eigen_ver at /usr/include/eigen3"
else
    fail "Eigen headers" "/usr/include/eigen3 is missing (apt install libeigen3-dev)"
fi

if [[ -d /usr/local/include/eigen3 ]]; then
    fail "No shadowing Eigen in /usr/local" "a second Eigen there overrides the apt one and can break ROS builds"
else
    pass "No shadowing Eigen in /usr/local" ""
fi

if [[ -f /usr/local/lib/libcasadi.so ]]; then
    pass "CasADi installed" "/usr/local/lib/libcasadi.so"

    # The point of building from source is the plugins Debian strips out, so
    # check for those specifically rather than just for the library.
    casadi_missing=()
    for plugin in ipopt cvodes osqp; do
        case "$plugin" in
            ipopt)  sofile=/usr/local/lib/libcasadi_nlpsol_ipopt.so ;;
            cvodes) sofile=/usr/local/lib/libcasadi_integrator_cvodes.so ;;
            osqp)   sofile=/usr/local/lib/libcasadi_conic_osqp.so ;;
        esac
        [[ -f "$sofile" ]] || casadi_missing+=("$plugin")
    done
    if ((${#casadi_missing[@]} == 0)); then
        pass "CasADi solver plugins" "ipopt, cvodes, osqp all present"
    else
        fail "CasADi solver plugins" "missing: ${casadi_missing[*]}. Re-run ./install.sh --only=cxx-libs"
    fi
else
    fail "CasADi installed" "/usr/local/lib/libcasadi.so is missing. Run ./install.sh --only=cxx-libs"
fi

section "Core tools"

check_cmd "kitty installed"     kitty
check_cmd "fastfetch installed" fastfetch
check_cmd "fzf installed"       fzf
check_cmd "ripgrep installed"   rg
check_cmd "git installed"       git

# The Super+F launcher. `ulauncher-toggle` is what the keybinding runs, and it
# only does anything when the daemon is already up, so all three are checked.
check_cmd "ulauncher installed" ulauncher
check_cmd "ulauncher-toggle on PATH" ulauncher-toggle

if [[ -f "$HOME/.config/autostart/ulauncher.desktop" ]]; then
    pass "ulauncher starts with the session" "$HOME/.config/autostart/ulauncher.desktop"
else
    fail "ulauncher starts with the session" "no autostart entry, so Super+F will do nothing after a reboot"
fi

if pgrep -u "$(id -u)" -f ulauncher >/dev/null 2>&1; then
    pass "ulauncher is running" "Super+F will open it"
else
    fail "ulauncher is running" "the daemon is not up; log out and back in, or run: ulauncher --hide-window &"
fi

_starship_bin=""
if [[ -x "$HOME/.local/bin/starship" ]]; then
    _starship_bin="$HOME/.local/bin/starship"
elif command -v starship >/dev/null 2>&1; then
    _starship_bin="$(command -v starship)"
fi

if [[ -n "$_starship_bin" ]]; then
    pass "starship installed" "$("$_starship_bin" --version 2>/dev/null | head -1)"
else
    fail "starship installed" "not on PATH and not at ~/.local/bin/starship"
fi

# The binary existing is not the same as the prompt working. A typo in
# starship.toml does not stop starship from running, it just silently drops the
# broken module, so render an actual prompt and look at what comes back.
if [[ -n "$_starship_bin" ]]; then
    if [[ -f "$HOME/.config/starship.toml" ]]; then
        _starship_err="$(STARSHIP_CONFIG="$HOME/.config/starship.toml" \
            "$_starship_bin" prompt --status=0 2>&1 >/dev/null)"
        _starship_out="$(STARSHIP_CONFIG="$HOME/.config/starship.toml" \
            "$_starship_bin" prompt --status=0 2>/dev/null)"
        if [[ -n "$_starship_err" ]]; then
            fail "starship config valid" "starship complained: ${_starship_err//$'\n'/ }"
        elif [[ -z "$_starship_out" ]]; then
            fail "starship config valid" "the prompt rendered empty"
        else
            pass "starship config valid" "the config at ~/.config/starship.toml renders a prompt"
        fi
    else
        fail "starship config valid" "no ~/.config/starship.toml, so you get the default prompt"
    fi
fi

# The rc invokes starship by its full path, so match the command loosely rather
# than looking for a literal 'starship init bash'.
if grep -qE 'starship[^ ]* init bash' "$HOME/.bashrc" 2>/dev/null; then
    pass "starship wired into bash" "your ~/.bashrc runs 'starship init bash'"
else
    fail "starship wired into bash" "your ~/.bashrc never initialises starship, so the prompt stays plain"
fi

# Process substitution rather than a pipe: `grep -q` exits on the first match,
# SIGPIPEs the writer, and `set -o pipefail` would turn that into a false negative.
# Same search order the managed .bashrc uses: the installer's own ~/.local
# build first, then a system-wide copy someone installed by hand.
blesh_found=""
for blesh_candidate in \
    "$HOME/.local/share/blesh/ble.sh" \
    /usr/local/share/blesh/ble.sh \
    /usr/share/blesh/ble.sh
do
    if [[ -f "$blesh_candidate" ]]; then
        blesh_found="$blesh_candidate"
        break
    fi
done

if [[ -n "$blesh_found" ]]; then
    if [[ -f "$HOME/.blerc" ]]; then
        pass "ble.sh autosuggestions" "$blesh_found, configured via ~/.blerc"
    else
        fail "ble.sh autosuggestions" "$blesh_found present but ~/.blerc is missing"
    fi
else
    fail "ble.sh autosuggestions" "no ble.sh under ~/.local, /usr/local or /usr, so no inline suggestions"
fi

if grep -qi "JetBrainsMono Nerd Font" < <(fc-list 2>/dev/null); then
    pass "JetBrainsMono Nerd Font" "glyphs will render in kitty and starship"
else
    fail "JetBrainsMono Nerd Font" "not in fc-list, so icons will show as boxes"
fi

# A font can be named "Nerd Font" and still be a plain build with none of the
# patched glyphs. These three codepoints are the ones the shipped configs lean
# on hardest: the starship user icon (plane 15), the git branch icon and a
# powerline separator. If fontconfig can serve all three, the patching is real.
_glyphs_missing=()
for _cp in f0548 f418 e0b0; do
    [[ -n "$(fc-list ":charset=$_cp:family=JetBrainsMono Nerd Font" 2>/dev/null)" ]] \
        || _glyphs_missing+=("U+${_cp^^}")
done
if ((${#_glyphs_missing[@]} == 0)); then
    pass "Nerd Font glyph coverage" "prompt and terminal icons resolve to real glyphs"
else
    fail "Nerd Font glyph coverage" "missing ${_glyphs_missing[*]}, so those icons show as boxes"
fi

# kitty is configured for the Nerd Font, but the starship prompt also shows up
# in every GTK terminal, and GNOME picks that font from this key.
if command -v gsettings >/dev/null 2>&1; then
    _mono="$(gsettings get org.gnome.desktop.interface monospace-font-name 2>/dev/null | tr -d "'")"
    if [[ "$_mono" == *"Nerd Font"* ]]; then
        pass "GNOME monospace font" "$_mono"
    else
        fail "GNOME monospace font" "'$_mono' has no Nerd Font glyphs; icons box up outside kitty"
    fi
fi

section "Shell configuration"

for f in "$HOME/.bashrc" "$HOME/.bash_aliases"; do
    base="$(basename "$f")"
    if [[ ! -f "$f" ]]; then
        fail "$base installed" "missing"
    elif grep -q "vortex-onboarding" "$f" 2>/dev/null; then
        pass "$base installed" "managed by vortex-onboarding"
    else
        fail "$base installed" "present but not the managed version"
    fi
done

section "GNOME keyboard shortcuts"

# expected: "<schema> <key> <wanted-substring> <human description>"
check_gsetting() {
    local schema="$1" key="$2" want="$3" desc="$4"
    local actual
    actual="$(gsettings get "$schema" "$key" 2>/dev/null)"
    if [[ -z "$actual" ]]; then
        fail "$desc" "could not read $schema $key"
    elif [[ "$actual" == *"$want"* ]]; then
        pass "$desc" "$actual"
    else
        fail "$desc" "expected to contain '$want', got $actual"
    fi
}

if ! command -v gsettings >/dev/null 2>&1; then
    skip "GNOME shortcuts" "gsettings not available"
elif [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
    skip "GNOME shortcuts" "no session bus. Run this from a desktop session, not SSH."
else
    for n in 1 2 3 4; do
        check_gsetting org.gnome.desktop.wm.keybindings "switch-to-workspace-$n" \
            "<Super>$n" "Super+$n switches to workspace $n"
    done

    # GNOME stores the shifted digits by keysym name.
    shifted=(exclam at numbersign dollar)
    for i in 0 1 2 3; do
        check_gsetting org.gnome.desktop.wm.keybindings "move-to-workspace-$((i + 1))" \
            "${shifted[$i]}" "Super+Shift+$((i + 1)) moves window to workspace $((i + 1))"
    done

    check_gsetting org.gnome.desktop.wm.keybindings close "<Super>q" \
        "Super+Q closes the focused window"

    # Custom keybindings live in relocatable schemas.
    check_custom() {
        local slot="$1" want_binding="$2" desc="$3"
        local path="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/${slot}/"
        local schema="org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:${path}"
        local binding command
        binding="$(gsettings get "$schema" binding 2>/dev/null)"
        command="$(gsettings get "$schema" command 2>/dev/null)"
        if [[ "$binding" == *"$want_binding"* ]]; then
            pass "$desc" "${binding} → ${command}"
        else
            fail "$desc" "expected binding '$want_binding', got ${binding:-<unset>}"
        fi
    }

    check_custom kitty-term "<Super>Return" "Super+Enter opens kitty"
    check_custom ulauncher  "<Super>f"      "Super+F opens the ulauncher launcher"

    check_gsetting org.gnome.shell.keybindings show-screenshot-ui "<Super>s" \
        "Super+S opens the screenshot UI"
fi

section "Desktop settings"

# check_gsetting_soft: like check_gsetting, but a key this GNOME version does not
# have reports SKIP. Used for everything GNOME has renamed between releases, so
# the verifier does not manufacture failures on a newer shell.
check_gsetting_soft() {
    local schema="$1" key="$2" want="$3" desc="$4"
    if ! gsettings writable "$schema" "$key" >/dev/null 2>&1; then
        skip "$desc" "$schema $key does not exist on this GNOME version"
        return 0
    fi
    check_gsetting "$schema" "$key" "$want" "$desc"
}

if ! command -v gsettings >/dev/null 2>&1; then
    skip "Desktop settings" "gsettings not available"
elif [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
    skip "Desktop settings" "no session bus. Run this from a desktop session, not SSH."
else
    # The colour scheme follows the theme chosen at install time, so read the
    # answer back rather than asserting one of the three is universally right.
    want_scheme="prefer-dark"
    case "$VXO_THEME" in
        light) want_scheme="prefer-light" ;;
        *)     want_scheme="prefer-dark" ;;
    esac
    check_gsetting org.gnome.desktop.interface color-scheme "$want_scheme" \
        "Colour scheme matches the '$VXO_THEME' theme"

    # accent-color arrived in GNOME 47 and does not exist on 22.04's GNOME 42,
    # so this reports SKIP here and the Yaru-magenta* GTK/icon variants are what
    # actually carry the accent. Where the key does exist it is an enum with no
    # 'magenta' member, and Ubuntu's magenta is upstream's 'pink'. See
    # lib/desktop.sh.
    check_gsetting_soft org.gnome.desktop.interface accent-color "pink" \
        "Accent colour set"

    # English (US) leads, then Norwegian, then Japanese. Checked by substring so
    # the order of the other two does not make this brittle.
    for src in "'us'" "'no'" "mozc-jp"; do
        check_gsetting org.gnome.desktop.input-sources sources "$src" \
            "Input source present: $src"
    done

    if dpkg-query -W -f='${Status}' ibus-mozc 2>/dev/null | grep -q '^install ok installed$'; then
        pass "ibus-mozc installed" "the Japanese input source will appear in the switcher"
    else
        fail "ibus-mozc installed" "the Japanese source is configured but has no engine. Run ./install.sh --only=apps"
    fi

    check_gsetting org.gnome.desktop.peripherals.touchpad natural-scroll "true" \
        "Touchpad natural scrolling"
    check_gsetting org.gnome.mutter auto-maximize "false" \
        "Windows do not auto-maximize"
    check_gsetting org.gnome.mutter experimental-features "scale-monitor-framebuffer" \
        "Fractional scaling available"
    check_gsetting_soft org.gnome.shell.extensions.dash-to-dock dock-position "RIGHT" \
        "Dock on the right edge"

    section "GNOME extensions"

    # Two upstreams, split by shell major, with different dconf schemas and
    # different key names inside the settings dict. GNOME 42 (22.04) runs
    # yilozt's original; GNOME 46+ runs the Reborn fork. See lib/extensions.sh.
    shell_major="$(gnome-shell --version 2>/dev/null | sed -nE 's/^GNOME Shell ([0-9]+).*/\1/p')"
    if [[ -n "$shell_major" ]] && ((shell_major >= 46)); then
        rwc_uuid="rounded-window-corners@fxgn"
        rwc_schema="org.gnome.shell.extensions.rounded-window-corners-reborn"
        rwc_radius_key="borderRadius"
    else
        rwc_uuid="rounded-window-corners@yilozt"
        rwc_schema="org.gnome.shell.extensions.rounded-window-corners"
        rwc_radius_key="border_radius"
    fi

    if [[ -f "$HOME/.local/share/gnome-shell/extensions/$rwc_uuid/metadata.json" ]]; then
        pass "Rounded corners extension installed" "$rwc_uuid"
    else
        fail "Rounded corners extension installed" "not in ~/.local/share/gnome-shell/extensions. Run ./install.sh --only=gnome-extensions"
    fi

    if gsettings get org.gnome.shell enabled-extensions 2>/dev/null | grep -q "$rwc_uuid"; then
        pass "Rounded corners extension enabled" "listed in enabled-extensions"
    else
        fail "Rounded corners extension enabled" "not in org.gnome.shell enabled-extensions"
    fi

    # The radius is one member of an a{sv} dict, so match the member rather than
    # trying to reproduce the whole GVariant literal.
    if ! gsettings writable "$rwc_schema" global-rounded-corner-settings >/dev/null 2>&1; then
        skip "Window corner radius" "the extension's schemas are not compiled, so its settings do not apply"
    else
        rwc_value="$(gsettings get "$rwc_schema" global-rounded-corner-settings 2>/dev/null)"
        rwc_radius="$(sed -nE "s/.*'${rwc_radius_key}': <?uint32 ([0-9]+)>?.*/\1/p" <<<"$rwc_value")"
        if [[ -z "$rwc_radius" ]]; then
            fail "Window corner radius" "could not read $rwc_radius_key from: $rwc_value"
        elif ((rwc_radius >= 4 && rwc_radius <= 8)); then
            pass "Window corner radius" "${rwc_radius}px"
        else
            fail "Window corner radius" "got ${rwc_radius}px, expected 4-8. Re-run with --rounded-radius=N"
        fi
    fi

    # Lock screen extension, also split by shell major: Lockscreen Studio's
    # metadata starts at 45, so GNOME 42 gets Blur my Shell's lockscreen
    # component instead. See lib/extensions.sh.
    if [[ -n "$shell_major" ]] && ((shell_major >= 45)); then
        lock_uuid="lockscreen-studio@pedro.projects"
    else
        lock_uuid="blur-my-shell@aunetx"
    fi

    if [[ -f "$HOME/.local/share/gnome-shell/extensions/$lock_uuid/metadata.json" ]]; then
        pass "Lock screen extension installed" "$lock_uuid"
    else
        fail "Lock screen extension installed" "not in ~/.local/share/gnome-shell/extensions. Run ./install.sh --only=gnome-extensions"
    fi

    if gsettings get org.gnome.shell enabled-extensions 2>/dev/null | grep -q "$lock_uuid"; then
        pass "Lock screen extension enabled" "listed in enabled-extensions"
    else
        fail "Lock screen extension enabled" "not in org.gnome.shell enabled-extensions"
    fi

    # Only Blur my Shell gets settings written; Lockscreen Studio is left on its
    # own defaults, so there is nothing to assert for it.
    if [[ "$lock_uuid" == "blur-my-shell@aunetx" ]]; then
        if ! command -v dconf >/dev/null 2>&1; then
            skip "Lock screen blur enabled" "dconf is not installed"
        elif [[ "$(dconf read /org/gnome/shell/extensions/blur-my-shell/lockscreen/blur)" == "true" ]]; then
            pass "Lock screen blur enabled" "blur-my-shell lockscreen/blur = true"
        else
            fail "Lock screen blur enabled" "blur-my-shell lockscreen/blur is not true. Run ./install.sh --only=gnome-extensions"
        fi
    fi
fi

section "Boot splash"

SPLASH_THEME="/usr/share/plymouth/themes/vortex-splash/vortex-splash.plymouth"

if [[ ! -f "$SPLASH_THEME" ]]; then
    fail "Boot splash theme installed" "$SPLASH_THEME is missing. Run ./install.sh --only=boot-splash"
else
    pass "Boot splash theme installed" "$SPLASH_THEME"

    if [[ -f /usr/share/plymouth/themes/vortex-splash/watermark.png ]]; then
        pass "Boot splash image staged" "watermark.png"
    else
        fail "Boot splash image staged" "watermark.png is missing, so the splash has no logo"
    fi

    # UseFirmwareBackground=true is exactly what makes stock Ubuntu keep showing
    # the vendor's BGRT logo, so this is the check that the OEM badge is gone.
    if grep -q '^UseFirmwareBackground=false' "$SPLASH_THEME"; then
        pass "Manufacturer logo suppressed" "UseFirmwareBackground=false"
    else
        fail "Manufacturer logo suppressed" "the theme still uses the firmware (BGRT) background"
    fi

    active="$(update-alternatives --query default.plymouth 2>/dev/null | awk '/^Value:/ {print $2}')"
    if [[ "$active" == "$SPLASH_THEME" ]]; then
        pass "Boot splash selected" "default.plymouth → vortex-splash"
    else
        fail "Boot splash selected" "default.plymouth points at '${active:-nothing}'"
    fi

    # The alternative can be correct while the initramfs still carries the old
    # theme, in which case nothing visible changes and it looks like the whole
    # thing failed. This is the check that catches that.
    if command -v lsinitramfs >/dev/null 2>&1; then
        initrd="/boot/initrd.img-$(uname -r)"
        if [[ ! -r "$initrd" ]]; then
            skip "Boot splash is in the initramfs" "cannot read $initrd"
        elif lsinitramfs "$initrd" 2>/dev/null | grep -q 'themes/vortex-splash'; then
            pass "Boot splash is in the initramfs" "$(basename "$initrd")"
        else
            fail "Boot splash is in the initramfs" "run: sudo update-initramfs -u -k all"
        fi
    else
        skip "Boot splash is in the initramfs" "lsinitramfs is not installed"
    fi
fi

if grep -q 'splash' /etc/default/grub 2>/dev/null; then
    pass "GRUB passes 'splash'" "the kernel hands the screen to Plymouth"
else
    fail "GRUB passes 'splash'" "add it to GRUB_CMDLINE_LINUX_DEFAULT, then: sudo update-grub"
fi

section "Apps and dev tools"

for tool in docker btop tmux clangd clang-format shellcheck shfmt doxygen; do
    check_cmd "$tool installed" "$tool"
done

# The GNOME front-ends. Both are only meaningful on a desktop session, and the
# binary that gnome-shell-extension-manager installs is called extension-manager,
# not gnome-extensions-manager, which is the usual reason a by-hand check for it
# comes back empty on a machine that has it.
if command -v gnome-shell >/dev/null 2>&1; then
    check_cmd "GNOME Tweaks installed"      gnome-tweaks
    check_cmd "Extension Manager installed" extension-manager
else
    skip "GNOME Tweaks installed"      "not a GNOME desktop"
    skip "Extension Manager installed" "not a GNOME desktop"
fi

if grep -qw docker < <(id -nG "${USER:-$(id -un)}" 2>/dev/null); then
    pass "In the docker group" "docker works without sudo after the next login"
else
    fail "In the docker group" "docker needs sudo. Run ./install.sh --only=apps, then log out and back in"
fi

section "Editor"

case "$VXO_EDITOR" in
    vscode)
        check_cmd "VS Code installed" code
        ;;
    nvim|"")
        if command -v nvim >/dev/null 2>&1; then
            nvim_ver="$(nvim --version | head -1)"
            read -r nv_major nv_minor <<<"$(sed -nE 's/^NVIM v([0-9]+)\.([0-9]+).*/\1 \2/p' <<<"$nvim_ver")"
            if [[ -n "${nv_minor:-}" ]] && { (( nv_major > 0 )) || (( nv_minor >= 10 )); }; then
                pass "neovim >= 0.10" "$nvim_ver"
            else
                fail "neovim >= 0.10" "$nvim_ver is too old for the config"
            fi

            if [[ -d "$HOME/.config/nvim/.git" ]] \
                && grep -q nvimconf < <(git -C "$HOME/.config/nvim" remote get-url origin 2>/dev/null); then
                pass "nvim config is nvimconf" "$(git -C "$HOME/.config/nvim" remote get-url origin)"
            else
                fail "nvim config is nvimconf" "$HOME/.config/nvim is not a clone of Q3rkses/nvimconf"
            fi
            # "Default editor" is four separate mechanisms. Check each, because
            # setting only some of them is exactly how nano keeps coming back.
            if [[ "${EDITOR:-}" == nvim* ]]; then
                pass "\$EDITOR is nvim" "$EDITOR"
            else
                fail "\$EDITOR is nvim" "got '${EDITOR:-unset}'. Open a new shell, or re-run ./install.sh --only=bashrc"
            fi

            if [[ "${VISUAL:-}" == nvim* && "${SUDO_EDITOR:-}" == nvim* ]]; then
                pass "\$VISUAL and \$SUDO_EDITOR are nvim" ""
            else
                fail "\$VISUAL and \$SUDO_EDITOR are nvim" "VISUAL='${VISUAL:-unset}' SUDO_EDITOR='${SUDO_EDITOR:-unset}'"
            fi

            alt="$(update-alternatives --query editor 2>/dev/null | awk '/^Value:/ {print $2}')"
            if [[ "$alt" == *nvim ]]; then
                pass "update-alternatives editor" "$alt"
            else
                fail "update-alternatives editor" "points at '${alt:-nothing}', so /usr/bin/editor is not nvim"
            fi

            git_ed="$(git config --global core.editor 2>/dev/null || true)"
            git_seq="$(git config --global sequence.editor 2>/dev/null || true)"
            if [[ "$git_ed" == nvim* && "$git_seq" == nvim* ]]; then
                pass "git uses nvim" "core.editor and sequence.editor"
            else
                fail "git uses nvim" "core.editor='${git_ed:-unset}' sequence.editor='${git_seq:-unset}'"
            fi

            # Tools the config shells out to. lazygit is the one that matters:
            # nvimconf enables the snacks lazygit picker, which errors without it.
            if command -v lazygit >/dev/null 2>&1; then
                pass "lazygit installed" "$(lazygit --version 2>/dev/null | head -1)"
            else
                fail "lazygit installed" "<Leader>gg and the snacks lazygit picker will not work"
            fi

            if command -v xdg-mime >/dev/null 2>&1; then
                mime_default="$(xdg-mime query default text/plain 2>/dev/null || true)"
                if [[ "$mime_default" == nvim.desktop ]]; then
                    pass "text files open in nvim" "text/plain -> nvim.desktop"
                else
                    fail "text files open in nvim" "text/plain -> '${mime_default:-nothing}'"
                fi
            else
                skip "text files open in nvim" "xdg-mime is not installed"
            fi
        elif [[ -z "$VXO_EDITOR" ]]; then
            skip "neovim" "editor choice unknown and nvim is absent"
        else
            fail "neovim >= 0.10" "nvim is not on PATH"
        fi
        ;;
    *)
        skip "Editor" "unrecognised editor choice '$VXO_EDITOR'"
        ;;
esac

section "Browser"

case "$VXO_BROWSER" in
    chrome)  check_cmd "Google Chrome installed" google-chrome-stable ;;
    brave)   check_cmd "Brave installed"         brave-browser ;;
    vivaldi) check_cmd "Vivaldi installed"       vivaldi ;;
    firefox) check_cmd "Firefox installed"       firefox ;;
    "")
        if command -v google-chrome-stable >/dev/null 2>&1 \
            || command -v brave-browser >/dev/null 2>&1 \
            || command -v vivaldi >/dev/null 2>&1 \
            || command -v firefox >/dev/null 2>&1; then
            pass "A browser is installed" "browser choice not recorded"
        else
            skip "Browser" "no browser choice recorded and none of the three found"
        fi
        ;;
    *) skip "Browser" "unrecognised browser choice '$VXO_BROWSER'" ;;
esac

section "Rust (personal profile)"

if [[ "$VXO_PROFILE" == "personal" ]]; then
    if command -v cargo >/dev/null 2>&1 || [[ -x "$HOME/.cargo/bin/cargo" ]]; then
        pass "cargo installed" "$( (cargo --version 2>/dev/null || "$HOME/.cargo/bin/cargo" --version) | head -1)"
    else
        fail "cargo installed" "not on PATH and not at ~/.cargo/bin/cargo"
    fi
else
    skip "cargo installed" "not part of the '${VXO_PROFILE:-unknown}' profile"
fi

section "ROS 2"

ROS_SETUP="/opt/ros/humble/setup.bash"
ROS_WS="$HOME/code/ros2_ws"
ROS_REPOS=(vortex-auv vortex-msgs vortex-vkf vortex-utils vortex-ci stonefish_ros2
           vortex-stonefish-interface vortex-stonefish-sim stim300-driver)

if [[ "$VXO_ROS" != "1" ]]; then
    skip "ROS 2 Humble" "not selected during install"
elif [[ "$release" != "22.04" ]]; then
    skip "ROS 2 Humble" "requires Ubuntu 22.04, this machine runs $release"
else
    if [[ -f "$ROS_SETUP" ]]; then
        pass "ROS 2 Humble installed" "$ROS_SETUP"
    else
        fail "ROS 2 Humble installed" "$ROS_SETUP is missing"
    fi

    # "Not built yet" and "the build failed" look identical on disk, but they are
    # very different things to report. ros2.sh drops a marker when it stops early
    # for --skip-ros-build, so an intentionally-unbuilt workspace reads as SKIP
    # rather than a failure the user goes hunting for.
    if [[ -f "$ROS_WS/install/setup.bash" ]]; then
        pass "Workspace built" "$ROS_WS/install/setup.bash"
    elif [[ -f "$VXO_STATE_DIR/ros_build_skipped" ]]; then
        skip "Workspace built" "installed but not built (--skip-ros-build); finish with ./install.sh --only=ros2"
    else
        fail "Workspace built" "$ROS_WS/install/setup.bash is missing, so colcon build did not finish"
    fi

    yasmin_missing=()
    for pkg in yasmin yasmin_ros; do
        [[ -d "/opt/ros/humble/share/$pkg" ]] || yasmin_missing+=("$pkg")
    done
    if ((${#yasmin_missing[@]} == 0)); then
        pass "YASMIN installed" "yasmin, yasmin_ros"
    else
        fail "YASMIN installed" "missing: ${yasmin_missing[*]}. Re-run ./install.sh --only=ros2"
    fi

    # yasmin_viewer is checked separately and never fails the run:
    # ros-humble-yasmin-viewer has not been released into the Humble index at
    # all, so the installer skips it with a warning by design. Failing here
    # would report a problem with no fix, and train people to ignore the
    # verifier's output.
    if [[ -d "/opt/ros/humble/share/yasmin_viewer" ]]; then
        pass "YASMIN viewer installed" "yasmin_viewer"
    else
        skip "YASMIN viewer" "not released for Humble; build it in $ROS_WS/src if you need the web UI"
    fi

    # Stonefish is a plain C++ library, not a ROS package, so it shows up in
    # neither /opt/ros nor the workspace. stonefish_ros2 find_package()s it, and
    # without it every simulator package fails to configure.
    if [[ -f /usr/local/lib/cmake/Stonefish/StonefishConfig.cmake ]]; then
        pass "Stonefish library installed" "/usr/local/lib/cmake/Stonefish"
    else
        fail "Stonefish library installed" "the simulator packages cannot build without it. Run ./install.sh --only=ros2"
    fi

    missing_repos=()
    for repo in "${ROS_REPOS[@]}"; do
        [[ -d "$ROS_WS/src/$repo" ]] || missing_repos+=("$repo")
    done
    if ((${#missing_repos[@]} == 0)); then
        pass "All ${#ROS_REPOS[@]} workspace repos cloned" "$ROS_WS/src"
    else
        fail "All ${#ROS_REPOS[@]} workspace repos cloned" "missing: ${missing_repos[*]}"
    fi

    if [[ -f "$ROS_SETUP" ]]; then
        # ROS setup scripts trip over `set -u`, hence the subshell.
        # shellcheck disable=SC1090  # path is a runtime value
        if doctor_out="$( set +u; . "$ROS_SETUP" >/dev/null 2>&1; ros2 doctor 2>&1 )"; then
            pass "ros2 doctor" "$(grep -ciE 'warning|error' <<<"$doctor_out") warnings/errors reported"
        else
            fail "ros2 doctor" "exited non-zero. Run it yourself: source $ROS_SETUP && ros2 doctor"
        fi
    else
        skip "ros2 doctor" "ROS 2 is not installed"
    fi
fi

# ─────────────────────────── summary ───────────────────────────

printf '\n%s%s%s\n' "$C_BOLD" "────────────────────────────────────────────────────────" "$C_RESET"
printf '%s%d passed%s   %s%d failed%s   %s%d skipped%s\n' \
    "$C_GREEN" "$PASS" "$C_RESET" \
    "$C_RED" "$FAIL" "$C_RESET" \
    "$C_DIM" "$SKIPPED" "$C_RESET"

if ((FAIL > 0)); then
    printf '\n%sFailed checks:%s\n' "$C_RED$C_BOLD" "$C_RESET"
    for n in "${FAILED_NAMES[@]}"; do printf '  · %s\n' "$n"; done
    printf '\nRe-run the relevant stage, e.g.:  ./install.sh --only=shortcuts\n'
    printf 'List every stage with:            ./install.sh --list-stages\n'
fi

cat <<EOF

${C_BOLD}Checks you have to make yourself${C_RESET}
These cannot be verified from a script, so try them now:

  1. ${C_BOLD}Reboot${C_RESET} first, not just log out. The boot splash lives in the
     initramfs, Wayland cannot load a new shell extension into a running
     session, and the docker group only applies to a fresh login.
  2. Press ${C_BOLD}Super+Enter${C_RESET}      → kitty opens, showing the fastfetch splash
     with the logo on the left and no missing-glyph boxes.
  3. Press ${C_BOLD}Super+2${C_RESET}, ${C_BOLD}Super+1${C_RESET} → the desktop switches between workspaces.
  4. With a window focused, press ${C_BOLD}Super+Shift+3${C_RESET} → the window moves to
     workspace 3; ${C_BOLD}Super+3${C_RESET} follows it there.
  5. Press ${C_BOLD}Super+Q${C_RESET}          → the focused window closes.
  6. Press ${C_BOLD}Super+F${C_RESET}          → the ulauncher application launcher appears.
  7. Run ${C_BOLD}nvim${C_RESET}               → the config loads with no error popups
     (or ${C_BOLD}code .${C_RESET} if you chose VS Code).
  8. Open a new terminal    → the starship prompt renders with icons.
  9. During the reboot in step 1, watch the screen → your terminal splash
     image appears with the spinner under it, in place of the manufacturer
     badge. Note that the logo the firmware draws in the first second, before
     GRUB, belongs to the UEFI and cannot be changed from Linux.
 10. Look at any window corner → softly rounded, not square, and the same
     radius on a GTK4 app (Files) as on kitty.
 11. Press ${C_BOLD}Super+Space${C_RESET}      → the input switcher cycles Norwegian, US
     and Japanese.
 12. Press ${C_BOLD}Super+L${C_RESET}          → the lock screen background is blurred rather
     than sharp. On GNOME 42 this is Blur my Shell's lockscreen
     component; nothing else it can blur should have changed.

EOF

((FAIL == 0))
