#!/usr/bin/env bash
# lib/prompts.sh: argument parsing and all interactive Q&A.
#
# Every answer is exported as a VXO_* variable and can equally be supplied by a
# flag, so the installer runs unattended in CI:
#
#   ./install.sh --name "Cyprian Osinski" --profile=vortex --editor=nvim \
#                --browser=chrome --yes
#
# Exports: VXO_NAME VXO_EMAIL VXO_PROFILE VXO_ROS VXO_EDITOR VXO_BROWSER VXO_LOGO_SRC

[[ -n "${_VXO_PROMPTS_SOURCED:-}" ]] && return 0
_VXO_PROMPTS_SOURCED=1

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

VXO_NAME="${VXO_NAME:-}"
VXO_EMAIL="${VXO_EMAIL:-}"
VXO_PROFILE="${VXO_PROFILE:-}"
VXO_ROS="${VXO_ROS:-}"
VXO_EDITOR="${VXO_EDITOR:-}"
VXO_BROWSER="${VXO_BROWSER:-}"
VXO_LOGO_SRC="${VXO_LOGO_SRC:-}"

usage() {
    cat <<'EOF'
VortexNTNU / personal Ubuntu onboarding installer

USAGE
    ./install.sh [options]

    Run with no options for the guided interactive install.

OPTIONS
    --name "First Last"        Full name (git config + welcome banner)
    --email you@example.com    Git email (optional; asked only if unset)
    --profile=vortex|personal  Which profile to install
    --ros / --no-ros           Install ROS 2 Lyrical (personal profile only;
                               the vortex profile always installs ROS 2)
    --skip-ros-build           Install ROS 2 and clone the workspace, but stop
                               before rosdep and colcon build
    --editor=nvim|vscode       Editor to install
    --browser=chrome|vivaldi|firefox
    --logo=PATH|URL            Personal-profile fastfetch splash image
    --wallpaper=slideshow|static|none
                               Desktop wallpaper (personal profile).
                               Default: slideshow of the bundled GT3 RS images.
    --yes, -y                  Non-interactive: accept defaults, never prompt
    --resume                   Skip stages already recorded as complete
    --dry-run                  Print what would happen; change nothing
    --only=STAGE[,STAGE...]    Run only these stages (e.g. --only=ros2)
    --list-stages              Print stage names and exit
    --help, -h                 This message

EXAMPLES
    ./install.sh
    ./install.sh --name "Ada Lovelace" --profile=vortex --editor=nvim --browser=chrome -y
    ./install.sh --resume                 # continue after a failed ROS 2 build
    ./install.sh --only=ros2              # retry just the ROS 2 stage

SCOPE
    Ubuntu 26.04 with stock GNOME only.
EOF
}

parse_args() {
    while (($# > 0)); do
        case "$1" in
            --name)        VXO_NAME="${2:?--name needs a value}"; shift 2 ;;
            --name=*)      VXO_NAME="${1#*=}"; shift ;;
            --email)       VXO_EMAIL="${2:?--email needs a value}"; shift 2 ;;
            --email=*)     VXO_EMAIL="${1#*=}"; shift ;;
            --profile)     VXO_PROFILE="${2:?--profile needs a value}"; shift 2 ;;
            --profile=*)   VXO_PROFILE="${1#*=}"; shift ;;
            --editor)      VXO_EDITOR="${2:?--editor needs a value}"; shift 2 ;;
            --editor=*)    VXO_EDITOR="${1#*=}"; shift ;;
            --browser)     VXO_BROWSER="${2:?--browser needs a value}"; shift 2 ;;
            --browser=*)   VXO_BROWSER="${1#*=}"; shift ;;
            --logo)        VXO_LOGO_SRC="${2:?--logo needs a value}"; shift 2 ;;
            --logo=*)      VXO_LOGO_SRC="${1#*=}"; shift ;;
            --wallpaper)   VXO_WALLPAPER_MODE="${2:?--wallpaper needs a value}"; shift 2 ;;
            --wallpaper=*) VXO_WALLPAPER_MODE="${1#*=}"; shift ;;
            --ros)         VXO_ROS=1; shift ;;
            --no-ros)      VXO_ROS=0; shift ;;
            --skip-ros-build) VXO_SKIP_ROS_BUILD=1; shift ;;
            -y|--yes)      VXO_NONINTERACTIVE=1; shift ;;
            --resume)      VXO_RESUME=1; shift ;;
            --dry-run)     VXO_DRY_RUN=1; shift ;;
            --only)        VXO_ONLY="${2:?--only needs a value}"; shift 2 ;;
            --only=*)      VXO_ONLY="${1#*=}"; shift ;;
            --list-stages) VXO_LIST_STAGES=1; shift ;;
            -h|--help)     usage; exit 0 ;;
            *)             usage >&2; die "Unknown option: $1" ;;
        esac
    done
    case "${VXO_WALLPAPER_MODE:-slideshow}" in
        slideshow|static|none) ;;
        *) die "Invalid --wallpaper: ${VXO_WALLPAPER_MODE} (expected slideshow, static or none)" ;;
    esac
    export VXO_WALLPAPER_MODE="${VXO_WALLPAPER_MODE:-slideshow}"
    export VXO_SKIP_ROS_BUILD="${VXO_SKIP_ROS_BUILD:-0}"
    export VXO_NONINTERACTIVE="${VXO_NONINTERACTIVE:-0}"
    export VXO_RESUME="${VXO_RESUME:-0}"
    export VXO_DRY_RUN="${VXO_DRY_RUN:-0}"
    export VXO_ONLY="${VXO_ONLY:-}"
    export VXO_LIST_STAGES="${VXO_LIST_STAGES:-0}"
}

# ask_choice <varname> <question> <default> <option>...
# No-op if the variable already holds a valid option (i.e. a flag set it).
ask_choice() {
    local varname="$1" question="$2" default="$3"; shift 3
    local options=("$@")
    local current="${!varname:-}"

    local opt
    if [[ -n "$current" ]]; then
        for opt in "${options[@]}"; do
            [[ "$current" == "$opt" ]] && { log_skip "$question → $current (from flag)"; return 0; }
        done
        die "Invalid value for ${varname}: '$current' (expected one of: ${options[*]})"
    fi

    if [[ "$VXO_NONINTERACTIVE" == "1" ]]; then
        printf -v "$varname" '%s' "$default"
        export "${varname?}"
        log_skip "$question → $default (default, non-interactive)"
        return 0
    fi

    printf '\n%s%s%s\n' "$C_BOLD" "$question" "$C_RESET" >&2
    local i
    for i in "${!options[@]}"; do
        local mark=" "; [[ "${options[$i]}" == "$default" ]] && mark="*"
        printf '  %s%d) %-10s%s%s\n' "$C_CYAN" "$((i + 1))" "${options[$i]}" "$mark" "$C_RESET" >&2
    done

    local reply
    while true; do
        read -r -p "$(printf 'Choice [1-%d, default %s]: ' "${#options[@]}" "$default")" reply </dev/tty
        if [[ -z "$reply" ]]; then
            printf -v "$varname" '%s' "$default"; export "${varname?}"; return 0
        fi
        if [[ "$reply" =~ ^[0-9]+$ ]] && ((reply >= 1 && reply <= ${#options[@]})); then
            printf -v "$varname" '%s' "${options[$((reply - 1))]}"; export "${varname?}"; return 0
        fi
        for opt in "${options[@]}"; do
            if [[ "${reply,,}" == "$opt" ]]; then
                printf -v "$varname" '%s' "$opt"; export "${varname?}"; return 0
            fi
        done
        log_warn "Please enter a number 1-${#options[@]} or an option name."
    done
}

ask_text() {
    local varname="$1" question="$2" default="${3:-}"
    if [[ -n "${!varname:-}" ]]; then
        log_skip "$question → ${!varname} (from flag)"
        return 0
    fi
    if [[ "$VXO_NONINTERACTIVE" == "1" ]]; then
        [[ -n "$default" ]] || die "$varname is required in non-interactive mode (no default)."
        printf -v "$varname" '%s' "$default"; export "${varname?}"
        return 0
    fi
    local reply hint=""
    [[ -n "$default" ]] && hint=" [$default]"
    while true; do
        read -r -p "$(printf '\n%s%s%s%s: ' "$C_BOLD" "$question" "$hint" "$C_RESET")" reply </dev/tty
        reply="${reply:-$default}"
        [[ -n "$reply" ]] && break
        log_warn "This cannot be empty."
    done
    printf -v "$varname" '%s' "$reply"; export "${varname?}"
}

banner() {
    cat >&2 <<EOF

${C_CYAN}${C_BOLD}  ╔══════════════════════════════════════════════════════╗
  ║        VortexNTNU · Ubuntu onboarding installer       ║
  ╚══════════════════════════════════════════════════════╝${C_RESET}
  ${C_DIM}Ubuntu $(ubuntu_release) · stock GNOME · log: $VXO_LOG_FILE${C_RESET}

EOF
}

collect_answers() {
    ask_text   VXO_NAME    "Your full name (used for git config and the welcome banner)"
    ask_choice VXO_PROFILE "Which install profile?" "vortex" "vortex" "personal"

    # The vortex profile is ROS-first by definition, so ROS 2 is not optional
    # there. Only the personal profile gets the choice.
    if [[ "$VXO_PROFILE" == "vortex" ]]; then
        VXO_ROS=1
        log_info "vortex profile → ROS 2 Lyrical will be installed"
    elif [[ -z "$VXO_ROS" ]]; then
        if [[ "$VXO_NONINTERACTIVE" == "1" ]]; then
            VXO_ROS=0
        elif confirm "Install ROS 2 Lyrical as well? (adds ~30-60 min at the end)" "n"; then
            VXO_ROS=1
        else
            VXO_ROS=0
        fi
    fi
    export VXO_ROS

    ask_choice VXO_EDITOR  "Which editor?" "nvim" "nvim" "vscode"
    ask_choice VXO_BROWSER "Which browser?" "chrome" "chrome" "vivaldi" "firefox"

    # Personal profile: optional custom fastfetch splash image.
    if [[ "$VXO_PROFILE" == "personal" && -z "$VXO_LOGO_SRC" && "$VXO_NONINTERACTIVE" != "1" ]]; then
        if confirm "Use a custom terminal splash image instead of the bundled one?" "n"; then
            ask_text VXO_LOGO_SRC "Path or URL to the image (png)"
        fi
    fi

    if [[ -z "$VXO_EMAIL" ]]; then
        if [[ "$VXO_NONINTERACTIVE" == "1" ]]; then
            VXO_EMAIL=""
        else
            read -r -p "$(printf '\n%sGit email (blank to skip)%s: ' "$C_BOLD" "$C_RESET")" VXO_EMAIL </dev/tty
        fi
    fi
    export VXO_EMAIL

    # ROS 2 needs 26.04. Warn now rather than 40 minutes in.
    if [[ "$VXO_ROS" == "1" && "$(ubuntu_release)" != "26.04" ]]; then
        log_warn "ROS 2 Lyrical requires Ubuntu 26.04; you are on $(ubuntu_release)."
        log_warn "Everything else will install; the ROS 2 stage will abort on its own."
    fi
}

summarise_answers() {
    cat >&2 <<EOF

${C_BOLD}Plan${C_RESET}
  Name      ${C_CYAN}${VXO_NAME}${C_RESET}
  Profile   ${C_CYAN}${VXO_PROFILE}${C_RESET}
  Editor    ${C_CYAN}${VXO_EDITOR}${C_RESET}
  Browser   ${C_CYAN}${VXO_BROWSER}${C_RESET}
  ROS 2     ${C_CYAN}$([[ "$VXO_ROS" == "1" ]] && echo "Lyrical (last stage)" || echo "no")${C_RESET}
  Splash    ${C_CYAN}$([[ -n "$VXO_LOGO_SRC" ]] && echo "$VXO_LOGO_SRC" || { [[ "$VXO_PROFILE" == "vortex" ]] && echo "Vortex logo" || echo "GT3 RS logo"; })${C_RESET}
  Wallpaper ${C_CYAN}$([[ "$VXO_PROFILE" == "personal" ]] && echo "GT3 RS ${VXO_WALLPAPER_MODE}" || echo "unchanged (vortex profile)")${C_RESET}

EOF
}
