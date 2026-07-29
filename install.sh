#!/usr/bin/env bash
# install.sh: the VortexNTNU / personal Ubuntu onboarding installer.
#
#   Fresh Ubuntu ISO  ──►  fully configured dev environment.
#
# Scope, deliberately narrow: Ubuntu 26.04 with stock GNOME. There is no
# distro detection and no window-manager logic anywhere in this repo. ROS 2
# requires Ubuntu 26.04 and runs last, as an isolated failure domain.
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

for _mod in base toolchain ssh_github shortcuts bashrc kitty_fastfetch wallpaper nvim browser rust ros2; do
    # shellcheck disable=SC1090
    source "$VXO_SELF_DIR/lib/${_mod}.sh"
done
unset _mod

# ───────────────────────────── stage table ─────────────────────────────
# name | description | function | hard|soft. Order is the install order.
# "soft" stages may fail without taking the rest of the install down with them.

VXO_STAGES=(
    "apt-upgrade|System update (apt update && apt upgrade)|vxo_apt_upgrade|hard"
    "base-packages|Base packages, Nerd Font and starship|vxo_base_packages|hard"
    "toolchain|GCC/G++ 13 toolchain (pinned via update-alternatives)|vxo_toolchain|hard"
    "git-ssh|Git identity and GitHub SSH key|vxo_git_ssh|soft"
    "shortcuts|GNOME keyboard shortcuts|vxo_shortcuts|soft"
    "bashrc|Shell configuration (.bashrc, .bash_aliases)|vxo_bashrc|hard"
    "kitty-fastfetch|Kitty terminal and fastfetch splash|vxo_kitty_fastfetch|soft"
    "wallpaper|Desktop wallpaper (personal profile)|vxo_wallpaper|soft"
    "editor|Editor (Neovim or VS Code)|vxo_editor|soft"
    "browser|Web browser|vxo_browser|soft"
    "rust|Rust toolchain via rustup (personal profile)|vxo_rust|soft"
    "ros2|ROS 2 Lyrical and the vortex workspace|vxo_ros2|soft"
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
    require_ubuntu

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
  1. ${C_BOLD}Log out and back in${C_RESET}. GNOME keyboard shortcuts and the new
     default shell environment only apply to a fresh session.
  2. Open Kitty with ${C_BOLD}Super+Enter${C_RESET}. You should see the fastfetch splash.
  3. Run the verification checklist:
       ${C_CYAN}./tests/verify_install.sh${C_RESET}

Full log: $VXO_LOG_FILE
EOF
}

main "$@"
