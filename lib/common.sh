#!/usr/bin/env bash
# lib/common.sh: logging, state/checkpointing, idempotency helpers, error trapping.
# Sourced by install.sh and by every lib/*.sh module. Never executed directly.
#
# SCOPE: Ubuntu 22.04 only, stock GNOME. No distro detection, no WM logic.

# Guard against double-sourcing.
[[ -n "${_VXO_COMMON_SOURCED:-}" ]] && return 0
_VXO_COMMON_SOURCED=1

set -euo pipefail

# ─────────────────────────── paths ───────────────────────────

# Repo root, resolved from this file's location so modules can be run standalone.
VXO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export VXO_ROOT
export VXO_DOTFILES="$VXO_ROOT/dotfiles"
export VXO_ASSETS="$VXO_ROOT/assets"

# State lives outside the repo so `git clean` / re-clone doesn't lose progress.
export VXO_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/vortex-onboarding"
export VXO_STATE_FILE="$VXO_STATE_DIR/install_state"
export VXO_LOG_DIR="$VXO_STATE_DIR/logs"
export VXO_BACKUP_DIR="$VXO_STATE_DIR/backups"
mkdir -p "$VXO_STATE_DIR" "$VXO_LOG_DIR" "$VXO_BACKUP_DIR"

export VXO_LOG_FILE="${VXO_LOG_FILE:-$VXO_LOG_DIR/install-$(date +%Y%m%d-%H%M%S).log}"

# ─────────────────────────── colours ───────────────────────────

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m'
else
    C_RESET=''; C_BOLD=''; C_DIM=''
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_CYAN=''
fi

# ─────────────────────────── logging ───────────────────────────
# Every message goes to stderr (so stdout stays usable for value-returning
# helpers) and is appended verbatim, uncoloured, to the log file.

_log() {
    local colour="$1" tag="$2"; shift 2
    printf '%s%s%s %s\n' "$colour" "$tag" "$C_RESET" "$*" >&2
    printf '[%s] %s %s\n' "$(date +%H:%M:%S)" "$tag" "$*" >>"$VXO_LOG_FILE"
}

log_info()  { _log "$C_BLUE"   "::"   "$@"; }
log_ok()    { _log "$C_GREEN"  " ✓"   "$@"; }
log_warn()  { _log "$C_YELLOW" " !"   "$@"; }
log_error() { _log "$C_RED"    " ✗"   "$@"; }
log_skip()  { _log "$C_DIM"    " ·"   "$@"; }

log_step() {
    printf '\n%s%s▸ %s%s\n' "$C_BOLD" "$C_CYAN" "$*" "$C_RESET" >&2
    printf '\n[%s] === %s ===\n' "$(date +%H:%M:%S)" "$*" >>"$VXO_LOG_FILE"
}

die() { log_error "$@"; exit 1; }

# ─────────────────────────── error trapping ───────────────────────────

_vxo_on_err() {
    local exit_code=$1 line=$2 cmd=$3
    log_error "Failed at ${BASH_SOURCE[1]:-?}:${line} (exit ${exit_code})"
    log_error "  command: ${cmd}"
    log_error "  full log: $VXO_LOG_FILE"
    if [[ -n "${VXO_CURRENT_STAGE:-}" ]]; then
        log_error "  stage '${VXO_CURRENT_STAGE}' did NOT complete and was not checkpointed."
        log_error "  Re-run with: ./install.sh --resume    (completed stages will be skipped)"
    fi
}
trap '_vxo_on_err "$?" "$LINENO" "$BASH_COMMAND"' ERR

# ─────────────────────────── dry run ───────────────────────────
# VXO_DRY_RUN=1 prints privileged/mutating commands instead of running them.

run() {
    if [[ "${VXO_DRY_RUN:-0}" == "1" ]]; then
        printf '%s  [dry-run] %s%s\n' "$C_DIM" "$*" "$C_RESET" >&2
        return 0
    fi
    printf '[%s] + %s\n' "$(date +%H:%M:%S)" "$*" >>"$VXO_LOG_FILE"
    "$@"
}

# ─────────────────────────── state / checkpointing ───────────────────────────

touch "$VXO_STATE_FILE"

stage_done() { grep -qxF "$1" "$VXO_STATE_FILE" 2>/dev/null; }

# A dry run must never checkpoint. Otherwise `--dry-run` followed by `--resume`
# skips every stage it only pretended to perform, leaving an unconfigured machine
# that the state file claims is fully installed.
mark_stage_done() {
    if [[ "${VXO_DRY_RUN:-0}" == "1" ]]; then
        return 0
    fi
    stage_done "$1" || printf '%s\n' "$1" >>"$VXO_STATE_FILE"
}

clear_stage() {
    local tmp; tmp="$(mktemp)"
    grep -vxF "$1" "$VXO_STATE_FILE" >"$tmp" 2>/dev/null || true
    mv "$tmp" "$VXO_STATE_FILE"
}

# stage_abort <reason>
#
# A module calls this to bow out of its own stage without failing the install,
# e.g. ROS 2 on a non-22.04 host, or rust on the vortex profile. The stage is
# NOT checkpointed, so --resume will try it again.
#
# The stage name is recorded so the final summary can tell "deliberately not
# applicable here" apart from "failed, please retry". Telling a vortex user to
# re-run the personal-only rust stage is worse than saying nothing.
VXO_SKIPPED_STAGES=()
stage_abort() {
    VXO_STAGE_ABORTED=1
    if [[ -n "${VXO_CURRENT_STAGE:-}" ]]; then
        VXO_SKIPPED_STAGES+=("$VXO_CURRENT_STAGE")
    fi
    log_warn "$*"
}

# True when the named stage bowed out on purpose during this run.
stage_was_skipped() {
    local s
    for s in ${VXO_SKIPPED_STAGES+"${VXO_SKIPPED_STAGES[@]}"}; do
        [[ "$s" == "$1" ]] && return 0
    done
    return 1
}

# run_stage <name> <description> <function> [soft]
#
# Honours --resume (VXO_RESUME=1): a stage already recorded in the state file is
# skipped. Without --resume every stage runs; all stages are idempotent, so a
# full re-run is always safe.
#
# "soft" stages are isolated failure domains: if the function errors out, the
# installer reports it and carries on instead of dying. ROS 2 is soft because a
# 40-minute colcon build must never cost the user their dotfiles and editor.
run_stage() {
    local name="$1" desc="$2" fn="$3" mode="${4:-hard}"

    if [[ "${VXO_RESUME:-0}" == "1" ]] && stage_done "$name"; then
        log_skip "[$name] $desc (already completed, skipped by --resume)"
        return 0
    fi

    log_step "$desc"
    VXO_CURRENT_STAGE="$name"
    VXO_STAGE_ABORTED=0

    local rc=0
    if [[ "$mode" == "soft" ]]; then
        # Subshell-free guard: `|| rc=$?` suspends errexit for the call, and the
        # ERR trap still reports the failing line from inside the function.
        "$fn" || rc=$?
    else
        "$fn"
    fi

    VXO_CURRENT_STAGE=""

    if ((rc != 0)); then
        log_error "[$name] failed (exit $rc). Continuing with the rest of the install."
        log_error "  retry just this stage later with: ./install.sh --only=$name"
        return 0
    fi

    # stage_abort already logged why. Don't append "re-run later with --only=X":
    # a stage that bowed out because it doesn't apply (rust on the vortex
    # profile) will bow out again for the same reason, and telling
    # the user to retry it makes a correct install look broken.
    if [[ "${VXO_STAGE_ABORTED:-0}" == "1" ]]; then
        log_skip "[$name] skipped"
        return 0
    fi

    mark_stage_done "$name"
    log_ok "[$name] done"
}

# ─────────────────────────── idempotency helpers ───────────────────────────

have() { command -v "$1" >/dev/null 2>&1; }

# NOTE: process substitution, not a pipe. Under `set -o pipefail`, `cmd | grep -q`
# is a false-negative generator: grep -q exits at the first match, the writer gets
# SIGPIPE, and the pipeline reports failure even though the match succeeded. A
# false negative here would make apt_install re-run on every invocation, quietly
# destroying idempotency. Do not "simplify" this back into a pipeline.
pkg_installed() {
    grep -q '^install ok installed$' < <(dpkg-query -W -f='${Status}' "$1" 2>/dev/null)
}

# apt_install pkg...: installs only what is missing, so re-runs are no-ops.
apt_install() {
    local missing=()
    local p
    for p in "$@"; do
        pkg_installed "$p" || missing+=("$p")
    done
    if ((${#missing[@]} == 0)); then
        log_skip "apt: already installed: $*"
        return 0
    fi
    log_info "apt: installing ${missing[*]}"
    run sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
}

apt_update_once() {
    if [[ "${_VXO_APT_UPDATED:-0}" == "1" ]]; then return 0; fi
    log_info "apt: refreshing package lists"
    run sudo apt-get update -qq
    _VXO_APT_UPDATED=1
}

# backup_file <path>: copies to <path>.bak.<epoch> AND into the central backup
# dir. Never overwrites an existing backup. No-op if the file doesn't exist.
backup_file() {
    local target="$1"
    [[ -e "$target" ]] || return 0
    local ts; ts="$(date +%s)"
    local sidecar="${target}.bak.${ts}"
    run cp -a "$target" "$sidecar"
    run cp -a "$target" "$VXO_BACKUP_DIR/$(basename "$target").bak.${ts}"
    log_info "backed up $(basename "$target") → $sidecar"
}

# install_file <src> <dest> [mode]: backs up dest if it differs, then copies.
install_file() {
    local src="$1" dest="$2" mode="${3:-0644}"
    [[ -f "$src" ]] || die "install_file: source missing: $src"
    if [[ -f "$dest" ]] && cmp -s "$src" "$dest"; then
        log_skip "$(basename "$dest") already up to date"
        return 0
    fi
    backup_file "$dest"
    run mkdir -p "$(dirname "$dest")"
    run install -m "$mode" "$src" "$dest"
    log_ok "installed $dest"
}

# ensure_line <file> <line>: appends the line if it is not already there verbatim.
ensure_line() {
    local file="$1" line="$2"
    run mkdir -p "$(dirname "$file")"
    [[ -f "$file" ]] || run touch "$file"
    if grep -qxF "$line" "$file" 2>/dev/null; then
        log_skip "already present in $(basename "$file"): $line"
        return 0
    fi
    if [[ "${VXO_DRY_RUN:-0}" == "1" ]]; then
        printf '%s  [dry-run] append to %s: %s%s\n' "$C_DIM" "$file" "$line" "$C_RESET" >&2
        return 0
    fi
    printf '%s\n' "$line" >>"$file"
    log_ok "appended to $(basename "$file"): $line"
}

# ensure_block <file> <marker> <content>: an idempotent managed block. Replaces
# the existing block between the markers if the content changed, otherwise does
# nothing.
ensure_block() {
    local file="$1" marker="$2" content="$3"
    local begin="# >>> vortex-onboarding: ${marker} >>>"
    local end="# <<< vortex-onboarding: ${marker} <<<"

    run mkdir -p "$(dirname "$file")"
    [[ -f "$file" ]] || run touch "$file"

    local desired; desired="$(printf '%s\n%s\n%s\n' "$begin" "$content" "$end")"

    if grep -qF "$begin" "$file" 2>/dev/null; then
        local current
        current="$(sed -n "\|^${begin}\$|,\|^${end}\$|p" "$file")"
        if [[ "$current" == "$desired" ]]; then
            log_skip "block '$marker' already current in $(basename "$file")"
            return 0
        fi
        backup_file "$file"
        if [[ "${VXO_DRY_RUN:-0}" == "1" ]]; then
            printf '%s  [dry-run] replace block %s in %s%s\n' "$C_DIM" "$marker" "$file" "$C_RESET" >&2
            return 0
        fi
        local tmp; tmp="$(mktemp)"
        sed "\|^${begin}\$|,\|^${end}\$|d" "$file" >"$tmp"
        printf '%s\n' "$desired" >>"$tmp"
        cat "$tmp" >"$file"
        rm -f "$tmp"
        log_ok "updated block '$marker' in $(basename "$file")"
    else
        if [[ "${VXO_DRY_RUN:-0}" == "1" ]]; then
            printf '%s  [dry-run] append block %s to %s%s\n' "$C_DIM" "$marker" "$file" "$C_RESET" >&2
            return 0
        fi
        printf '\n%s\n' "$desired" >>"$file"
        log_ok "added block '$marker' to $(basename "$file")"
    fi
}

# ─────────────────────────── platform guards ───────────────────────────

# /etc/os-release is the authority here, not `lsb_release`. The lsb-release
# package is NOT installed on minimal Ubuntu images (server, cloud, container),
# so keying off it makes the installer refuse to run on a perfectly valid Ubuntu.
# os-release is guaranteed present. lsb_release remains a fallback only.
_os_release_field() {
    local field="$1"
    if [[ -r /etc/os-release ]]; then
        # Subshell: /etc/os-release sets ID/VERSION_ID/NAME, which must not leak
        # into the installer's environment.
        (
            # shellcheck disable=SC1091
            . /etc/os-release
            printf '%s' "${!field:-}"
        )
    fi
}

ubuntu_release() {
    local v; v="$(_os_release_field VERSION_ID)"
    if [[ -z "$v" ]] && have lsb_release; then
        v="$(lsb_release -rs 2>/dev/null || true)"
    fi
    printf '%s' "${v:-unknown}"
}

ubuntu_id() {
    local v; v="$(_os_release_field ID)"
    if [[ -z "$v" ]] && have lsb_release; then
        v="$(lsb_release -is 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
    fi
    printf '%s' "${v:-unknown}"
}

require_ubuntu() {
    local id; id="$(ubuntu_id)"
    [[ "$id" == "ubuntu" ]] || die "This installer supports Ubuntu only (detected: $id)."

    local rel; rel="$(ubuntu_release)"
    case "$rel" in
        22.04) log_ok "Ubuntu $rel is supported" ;;
        *) die "Unsupported Ubuntu release: $rel. This installer targets Ubuntu 22.04 (jammy) only." ;;
    esac
}

# ─────────────────────────── sudo ───────────────────────────

# Prompt for sudo once, then refresh in the background for the run's duration.
sudo_keepalive() {
    [[ "${VXO_DRY_RUN:-0}" == "1" ]] && return 0
    [[ -n "${_VXO_SUDO_PID:-}" ]] && return 0

    log_info "Requesting sudo once up front (cached for the whole install)."
    sudo -v || die "sudo is required to install packages."

    ( while true; do sudo -n true 2>/dev/null || exit; sleep 50; done ) &
    _VXO_SUDO_PID=$!
    # shellcheck disable=SC2064  # expand PID now, not at trap time
    trap "kill $_VXO_SUDO_PID 2>/dev/null || true" EXIT
}

# ─────────────────────────── misc ───────────────────────────

confirm() {
    local prompt="$1" default="${2:-y}" reply
    if [[ "${VXO_NONINTERACTIVE:-0}" == "1" ]]; then
        [[ "$default" == "y" ]]
        return
    fi
    local hint="[Y/n]"; [[ "$default" == "n" ]] && hint="[y/N]"
    read -r -p "$(printf '%s?%s %s %s ' "$C_YELLOW" "$C_RESET" "$prompt" "$hint")" reply </dev/tty
    reply="${reply:-$default}"
    [[ "${reply,,}" == "y" || "${reply,,}" == "yes" ]]
}

# Clone or update a repo. Idempotent: existing checkouts are fetched, not clobbered.
git_sync() {
    local url="$1" dest="$2" branch="${3:-}"
    if [[ -d "$dest/.git" ]]; then
        log_info "updating $(basename "$dest")"
        run git -C "$dest" fetch --quiet --all --prune
        if [[ -n "$branch" ]]; then
            if git -C "$dest" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
                run git -C "$dest" checkout --quiet "$branch"
                # Only fast-forward: never discard local work.
                run git -C "$dest" merge --ff-only "origin/$branch" \
                    || log_warn "$(basename "$dest"): local changes block fast-forward, left as is"
            else
                log_warn "$(basename "$dest"): branch '$branch' not on origin, left as is"
            fi
        fi
    else
        log_info "cloning $(basename "$dest")"
        run mkdir -p "$(dirname "$dest")"
        if [[ -n "$branch" ]]; then
            run git clone --quiet --branch "$branch" "$url" "$dest"
        else
            run git clone --quiet "$url" "$dest"
        fi
    fi
}
