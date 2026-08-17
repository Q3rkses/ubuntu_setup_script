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
    26.04) pass "Ubuntu release" "$release" ;;
    *)     fail "Ubuntu release" "got '$release', expected 26.04" ;;
esac

for compiler in gcc g++; do
    if command -v "$compiler" >/dev/null 2>&1; then
        ver="$("$compiler" -dumpversion 2>/dev/null | cut -d. -f1)"
        if [[ "$ver" == "13" ]]; then
            pass "$compiler is version 13" "$("$compiler" --version | head -1)"
        else
            fail "$compiler is version 13" "got major version '$ver', expected 13"
        fi
    else
        fail "$compiler is version 13" "'$compiler' is not on PATH"
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

if command -v starship >/dev/null 2>&1 || [[ -x "$HOME/.local/bin/starship" ]]; then
    pass "starship installed" "$( (starship --version 2>/dev/null || "$HOME/.local/bin/starship" --version 2>/dev/null) | head -1)"
else
    fail "starship installed" "not on PATH and not at ~/.local/bin/starship"
fi

# Process substitution rather than a pipe: `grep -q` exits on the first match,
# SIGPIPEs the writer, and `set -o pipefail` would turn that into a false negative.
if [[ -f "$HOME/.local/share/blesh/ble.sh" ]]; then
    if [[ -f "$HOME/.blerc" ]]; then
        pass "ble.sh autosuggestions" "installed, configured via ~/.blerc"
    else
        fail "ble.sh autosuggestions" "ble.sh present but ~/.blerc is missing"
    fi
else
    fail "ble.sh autosuggestions" "$HOME/.local/share/blesh/ble.sh missing, so no inline suggestions"
fi

if grep -qi "JetBrainsMono Nerd Font" < <(fc-list 2>/dev/null); then
    pass "JetBrainsMono Nerd Font" "glyphs will render in kitty and starship"
else
    fail "JetBrainsMono Nerd Font" "not in fc-list, so icons will show as boxes"
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
    check_custom wofi-drun  "<Super>r"      "Super+R opens the wofi launcher"

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
    check_gsetting org.gnome.desktop.interface color-scheme "prefer-dark" \
        "Dark mode enabled"

    # Norwegian, US and Japanese, in that order. Checked by substring so the
    # order of the other two does not make this brittle.
    for src in "'no'" "'us'" "mozc-jp"; do
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

    rwc_uuid="rounded-window-corners@fxgn"
    rwc_schema="org.gnome.shell.extensions.rounded-window-corners-reborn"

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
        rwc_radius="$(sed -nE "s/.*'borderRadius': <?uint32 ([0-9]+)>?.*/\1/p" <<<"$rwc_value")"
        if [[ -z "$rwc_radius" ]]; then
            fail "Window corner radius" "could not read borderRadius from: $rwc_value"
        elif ((rwc_radius >= 4 && rwc_radius <= 8)); then
            pass "Window corner radius" "${rwc_radius}px"
        else
            fail "Window corner radius" "got ${rwc_radius}px, expected 4-8. Re-run with --rounded-radius=N"
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
    vivaldi) check_cmd "Vivaldi installed"       vivaldi ;;
    firefox) check_cmd "Firefox installed"       firefox ;;
    "")
        if command -v google-chrome-stable >/dev/null 2>&1 \
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

ROS_SETUP="/opt/ros/lyrical/setup.bash"
ROS_WS="$HOME/code/ros2_ws"
ROS_REPOS=(vortex-auv vortex-msgs vortex-utils vortex-ci stonefish_ros2
           vortex-stonefish-interface vortex-stonefish-sim stim300-driver)

if [[ "$VXO_ROS" != "1" ]]; then
    skip "ROS 2 Lyrical" "not selected during install"
elif [[ "$release" != "26.04" ]]; then
    skip "ROS 2 Lyrical" "requires Ubuntu 26.04, this machine runs $release"
else
    if [[ -f "$ROS_SETUP" ]]; then
        pass "ROS 2 Lyrical installed" "$ROS_SETUP"
    else
        fail "ROS 2 Lyrical installed" "$ROS_SETUP is missing"
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
    for pkg in yasmin yasmin_ros yasmin_viewer; do
        [[ -d "/opt/ros/lyrical/share/$pkg" ]] || yasmin_missing+=("$pkg")
    done
    if ((${#yasmin_missing[@]} == 0)); then
        pass "YASMIN installed" "yasmin, yasmin_ros, yasmin_viewer"
    else
        fail "YASMIN installed" "missing: ${yasmin_missing[*]}. Re-run ./install.sh --only=ros2"
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
  6. Press ${C_BOLD}Super+R${C_RESET}          → the wofi application launcher appears.
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

EOF

((FAIL == 0))
