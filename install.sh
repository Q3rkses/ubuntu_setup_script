#!/usr/bin/env bash
# install.sh: the VortexNTNU / personal Ubuntu onboarding installer.
#
#   Fresh Ubuntu ISO  ──►  fully configured dev environment.
#
# Scope, deliberately narrow: Ubuntu 22.04 with stock GNOME. There is no
# distro detection and no window-manager logic anywhere in this repo. ROS 2
# Humble requires Ubuntu 22.04 and runs last, as an isolated failure domain.
#
# Preconditions you must satisfy before running this (see the checklist at the
# top of README.md): Ubuntu 22.04, a sudo account, a working GitHub SSH key.
# The installer verifies all three up front and refuses to start otherwise.
#
#   ./install.sh              guided install
#   ./install.sh --help       all flags
#   ./install.sh --resume     continue after a failure, skipping finished stages
#   ./install.sh --only=ros2  retry just the ROS 2 stage

set -euo pipefail

VXO_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "$VXO_SELF_DIR/lib/common.sh"
# shellcheck source=lib/prompts.sh
source "$VXO_SELF_DIR/lib/prompts.sh"

for _mod in base toolchain cxxlibs apps ssh_github shortcuts desktop extensions \
            bashrc kitty_fastfetch plymouth wallpaper nvim browser rust ros2; do
    # shellcheck disable=SC1090
    source "$VXO_SELF_DIR/lib/${_mod}.sh"
done
unset _mod

# ───────────────────────────── stage table ─────────────────────────────
# name | description | function | hard|soft. Order is the install order.
# "soft" stages may fail without taking the rest of the install down with them.

# Ordering notes, because two of these are load-bearing:
#
#   * `desktop` pins the dock favourites and only pins entries whose .desktop
#     file already exists, so it has to run after `browser`, `editor` and
#     `kitty-fastfetch` rather than before them.
#   * `boot-splash` reuses the image fastfetch resolved, so it runs after
#     `kitty-fastfetch`. It falls back to the bundled logo when run on its own.
VXO_STAGES=(
    "apt-upgrade|System update (apt update && apt upgrade)|vxo_apt_upgrade|hard"
    "base-packages|Base packages, Nerd Font and starship|vxo_base_packages|hard"
    "toolchain|GCC/G++ 12 toolchain (pinned via update-alternatives)|vxo_toolchain|hard"
    "cxx-libs|Eigen (apt) and CasADi (built from source)|vxo_cxx_libs|soft"
    "apps|Dev tools, Docker, GNOME front-ends, input methods|vxo_apps|soft"
    "git-config|Git identity (name, email, defaults)|vxo_git_config|hard"
    "bashrc|Shell configuration (.bashrc, .bash_aliases)|vxo_bashrc|hard"
    "kitty-fastfetch|Kitty terminal and fastfetch splash|vxo_kitty_fastfetch|soft"
    "boot-splash|Plymouth boot splash (your terminal logo)|vxo_boot_splash|soft"
    "editor|Editor (Neovim or VS Code)|vxo_editor|soft"
    "browser|Web browser|vxo_browser|soft"
    "shortcuts|GNOME keyboard shortcuts|vxo_shortcuts|soft"
    "desktop|GNOME appearance, input sources, pointer, dock|vxo_desktop|soft"
    "gnome-extensions|GNOME extensions (rounded window corners, lock screen blur)|vxo_gnome_extensions|soft"
    "wallpaper|Desktop wallpaper (personal profile)|vxo_wallpaper|soft"
    "rust|Rust toolchain via rustup (personal profile)|vxo_rust|soft"
    "ros2|ROS 2 Humble and the vortex workspace|vxo_ros2|soft"
)

list_stages() {
    local entry
    printf 'Stages, in order:\n\n'
    for entry in "${VXO_STAGES[@]}"; do
        IFS='|' read -r name desc _ _ <<<"$entry"
        local mark="  "
        stage_done "$name" && mark=" ✓"
        printf '%s %-16s %s\n' "$mark" "$name" "$desc"
    done
    printf '\n(✓ = recorded complete in %s)\n' "$VXO_STATE_FILE"
}

stage_selected() {
    [[ -z "$VXO_ONLY" ]] && return 0
    local want
    IFS=',' read -ra want <<<"$VXO_ONLY"
    local w
    for w in "${want[@]}"; do
        [[ "$w" == "$1" ]] && return 0
    done
    return 1
}

# ───────────────────────────── main ─────────────────────────────

main() {
    parse_args "$@"

    if [[ "$VXO_LIST_STAGES" == "1" ]]; then
        list_stages
        exit 0
    fi

    banner

    # Preconditions, checked before a single package is touched. Both of these
    # exit rather than degrade: an unsupported release or a missing GitHub key
    # produces a broken half-install that is worse than no install at all.
    require_ubuntu
    vxo_require_github_ssh

    if [[ -n "$VXO_ONLY" ]]; then
        log_info "Running only: $VXO_ONLY"
    fi

    collect_answers
    summarise_answers

    if [[ "$VXO_DRY_RUN" == "1" ]]; then
        log_warn "DRY RUN: nothing will be modified."
    elif ! confirm "Proceed with this plan?" "y"; then
        die "Aborted by user. Nothing was changed."
    fi

    sudo_keepalive

    local entry name desc fn mode
    for entry in "${VXO_STAGES[@]}"; do
        IFS='|' read -r name desc fn mode <<<"$entry"
        stage_selected "$name" || continue
        run_stage "$name" "$desc" "$fn" "$mode"
    done

    finish
}

finish() {
    # A dry run checkpoints nothing by design, so the completeness analysis below
    # would report every stage as outstanding and tell the user to re-run work
    # they never asked to happen.
    if [[ "$VXO_DRY_RUN" == "1" ]]; then
        printf '\n' >&2
        log_ok "Dry run finished. Nothing was installed or modified."
        log_info "Run the same command without --dry-run to apply it."
        return 0
    fi

    # Three outcomes, not two: done, deliberately skipped (wrong profile, wrong
    # Ubuntu release), and genuinely incomplete. Only the last one is worth
    # asking the user to re-run.
    local incomplete=() skipped=()
    local entry name
    for entry in "${VXO_STAGES[@]}"; do
        IFS='|' read -r name _ _ _ <<<"$entry"
        # With --only, the stages that were never selected are not "incomplete",
        # they were not asked for. Listing them told the user to re-run thirteen
        # stages after a deliberate one-stage run, which is noise that trains
        # people to ignore this summary.
        stage_selected "$name" || continue
        stage_done "$name" && continue
        if stage_was_skipped "$name"; then
            skipped+=("$name")
        else
            incomplete+=("$name")
        fi
    done

    printf '\n' >&2
    if ((${#skipped[@]} > 0)); then
        log_info "Stages skipped (not applicable to this profile or release): ${skipped[*]}"
    fi

    if ((${#incomplete[@]} == 0)); then
        log_ok "All applicable stages complete."
    else
        log_warn "Stages not completed: ${incomplete[*]}"
        log_warn "Re-run them with: ./install.sh --only=$(IFS=,; echo "${incomplete[*]}")"
    fi

    cat >&2 <<EOF

${C_BOLD}${C_GREEN}Setup finished for ${VXO_NAME}.${C_RESET}

Next steps:
  1. ${C_BOLD}Reboot${C_RESET}. Three things need it rather than just a new session:
       · the new boot splash (it lives in the initramfs)
       · the rounded-corners extension (Wayland cannot reload the shell)
       · your docker group membership
     A logout would cover the shortcuts, theme and shell environment, but not
     those, so reboot once here and be done with it.
  2. Open Kitty with ${C_BOLD}Super+Enter${C_RESET}. You should see the fastfetch splash.
  3. Run the verification checklist:
       ${C_CYAN}./tests/verify_install.sh${C_RESET}

Full log: $VXO_LOG_FILE
EOF
}

main "$@"
