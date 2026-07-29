#!/usr/bin/env bash
# lib/ssh_github.sh: git identity and a working GitHub SSH key.
#
# Sourced by install.sh. Provides: vxo_git_ssh.
# Exports VXO_SSH_OK (1|0), which later stages use to pick ssh or https remotes.
#
# Every repo this installer clones (nvimconf, the vortex ROS packages) lives
# behind a git@github.com remote, and a fresh Ubuntu ISO has no key at all. So
# this stage runs early and, if it cannot get SSH working, says so loudly and
# lets the rest of the install continue over https.

[[ -n "${_VXO_SSH_GITHUB_SOURCED:-}" ]] && return 0
_VXO_SSH_GITHUB_SOURCED=1

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

VXO_SSH_KEY="$HOME/.ssh/id_ed25519"
VXO_GITHUB_KEYS_URL="https://github.com/settings/ssh/new"
VXO_SSH_MAX_ATTEMPTS=5

export VXO_SSH_OK="${VXO_SSH_OK:-0}"

vxo_git_ssh() {
    _vxo_git_identity
    _vxo_github_ssh
}

# ───────────────────────────── git identity ─────────────────────────────

_vxo_git_identity() {
    have git || die "git is missing. The base-packages stage should have installed it."

    log_info "Configuring git identity for $VXO_NAME"
    run git config --global user.name "$VXO_NAME"

    if [[ -n "${VXO_EMAIL:-}" ]]; then
        run git config --global user.email "$VXO_EMAIL"
    else
        log_warn "No git email set. Run: git config --global user.email you@example.com"
    fi

    run git config --global init.defaultBranch main
    run git config --global pull.rebase true

    if [[ "${VXO_EDITOR:-nvim}" == "nvim" ]]; then
        run git config --global core.editor "nvim -f"
    else
        run git config --global core.editor "code --wait"
    fi

    log_ok "git identity configured"
}

# ───────────────────────────── github ssh ─────────────────────────────

# GitHub always exits 1 for `ssh -T` (it never gives you a shell), so the exit
# code tells us nothing. The greeting text is the actual signal.
_vxo_github_ssh_works() {
    local out
    out="$(ssh -o BatchMode=yes \
               -o StrictHostKeyChecking=accept-new \
               -o ConnectTimeout=10 \
               -T git@github.com 2>&1 || true)"
    grep -qi "successfully authenticated" <<<"$out"
}

# True when git clones should use SSH remotes rather than HTTPS.
#
# Uses the result of the git-ssh stage when it ran in this invocation. When it
# did not, say `./install.sh --only=ros2` to retry a failed build, VXO_SSH_OK is
# still at its default 0. Naively trusting that would clone every repo over
# HTTPS on a machine whose SSH key works fine, so probe GitHub once and cache
# the answer for the rest of the run.
vxo_use_ssh_remotes() {
    [[ "${VXO_SSH_OK:-0}" == "1" ]] && return 0

    if [[ -z "${_VXO_SSH_PROBED:-}" ]]; then
        _VXO_SSH_PROBED=1
        _VXO_SSH_PROBE_RC=1
        if [[ "${VXO_DRY_RUN:-0}" != "1" ]] && _vxo_github_ssh_works; then
            _VXO_SSH_PROBE_RC=0
            VXO_SSH_OK=1
            export VXO_SSH_OK
            log_info "GitHub SSH key works, using SSH remotes"
        fi
    fi
    return "$_VXO_SSH_PROBE_RC"
}

_vxo_github_ssh() {
    if [[ "${VXO_DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] would verify or create a GitHub SSH key"
        VXO_SSH_OK=1
        return 0
    fi

    apt_install openssh-client

    if _vxo_github_ssh_works; then
        log_ok "GitHub SSH authentication already works"
        VXO_SSH_OK=1
        return 0
    fi

    _vxo_ssh_dir_perms
    _vxo_known_hosts
    _vxo_ensure_key
    _vxo_agent_add

    if _vxo_github_ssh_works; then
        log_ok "GitHub SSH authentication works"
        VXO_SSH_OK=1
        return 0
    fi

    _vxo_prompt_add_key
}

_vxo_ssh_dir_perms() {
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
}

_vxo_known_hosts() {
    local kh="$HOME/.ssh/known_hosts"
    touch "$kh"
    chmod 600 "$kh"

    if ssh-keygen -F github.com -f "$kh" >/dev/null 2>&1; then
        log_skip "github.com already in known_hosts"
        return 0
    fi

    log_info "Adding github.com host keys to known_hosts"
    ssh-keyscan -t rsa,ecdsa,ed25519 github.com 2>/dev/null >>"$kh" \
        || log_warn "ssh-keyscan failed, so the host key will be accepted on first connect instead"
}

# Never overwrite an existing key. If the user already has any public key we
# assume it is the one they want and only offer to register it.
_vxo_ensure_key() {
    local existing=()
    local f
    for f in "$HOME"/.ssh/id_*.pub; do
        [[ -f "$f" ]] && existing+=("$f")
    done

    if ((${#existing[@]} > 0)); then
        # Prefer our canonical key if it is among them, else take the first.
        if [[ -f "${VXO_SSH_KEY}.pub" ]]; then
            log_info "Using existing key ${VXO_SSH_KEY}.pub"
        else
            VXO_SSH_KEY="${existing[0]%.pub}"
            log_info "Using existing key ${VXO_SSH_KEY}.pub"
        fi
        chmod 600 "$VXO_SSH_KEY" 2>/dev/null || true
        return 0
    fi

    log_info "No SSH key found, generating a new ed25519 key"
    ssh-keygen -t ed25519 -C "${VXO_EMAIL:-$VXO_NAME}" -f "$VXO_SSH_KEY" -N "" -q
    chmod 600 "$VXO_SSH_KEY"
    chmod 644 "${VXO_SSH_KEY}.pub"
    log_ok "Generated $VXO_SSH_KEY"
}

_vxo_agent_add() {
    local rc=0
    ssh-add -l >/dev/null 2>&1 || rc=$?

    # Exit status 2 means "no agent reachable"; 1 means "agent up, no keys".
    if ((rc == 2)); then
        log_info "Starting ssh-agent"
        eval "$(ssh-agent -s)" >/dev/null
    fi

    ssh-add "$VXO_SSH_KEY" >/dev/null 2>&1 \
        || log_warn "Could not add $VXO_SSH_KEY to ssh-agent (not fatal)"
}

# Show the public key and wait for the user to paste it into GitHub.
_vxo_prompt_add_key() {
    local pub; pub="$(cat "${VXO_SSH_KEY}.pub")"

    cat >&2 <<EOF

${C_BOLD}${C_YELLOW}  ┌──────────────────────────────────────────────────────────┐
  │  Add this SSH key to your GitHub account to continue      │
  └──────────────────────────────────────────────────────────┘${C_RESET}

  1. Open ${C_CYAN}${VXO_GITHUB_KEYS_URL}${C_RESET}
  2. Title: anything (e.g. "$(hostname)")
  3. Key type: Authentication Key
  4. Paste the key below, then click "Add SSH key".

${C_GREEN}${pub}${C_RESET}

EOF

    _vxo_notify_gui "$pub"

    if [[ "${VXO_NONINTERACTIVE:-0}" == "1" ]]; then
        VXO_SSH_OK=0
        stage_abort "Non-interactive mode: cannot wait for the key to be added to GitHub. \
Add it manually (see above), then re-run: ./install.sh --only=git-ssh"
        return 0
    fi

    # Best effort: a headless or misconfigured xdg-open must not fail the stage.
    if have xdg-open; then
        (xdg-open "$VXO_GITHUB_KEYS_URL" >/dev/null 2>&1 &) || true
    fi

    local attempt reply
    for ((attempt = 1; attempt <= VXO_SSH_MAX_ATTEMPTS; attempt++)); do
        reply=""
        read -r -p "$(printf '%sPress Enter once the key is added (attempt %d/%d), or type "skip": %s' \
            "$C_BOLD" "$attempt" "$VXO_SSH_MAX_ATTEMPTS" "$C_RESET")" reply </dev/tty || reply="skip"

        if [[ "${reply,,}" == "skip" ]]; then
            break
        fi

        if _vxo_github_ssh_works; then
            log_ok "GitHub SSH authentication works"
            VXO_SSH_OK=1
            return 0
        fi

        log_warn "Still cannot authenticate to GitHub over SSH."
    done

    VXO_SSH_OK=0
    stage_abort "GitHub SSH is not working. Repositories will be cloned over https instead, \
which works for read-only use but means you cannot push. Fix it later with: \
./install.sh --only=git-ssh"
}

# A desktop notification in addition to the terminal output, so the key is hard
# to miss when the installer is running in a window behind the browser.
_vxo_notify_gui() {
    local pub="$1"
    if have zenity; then
        (zenity --info --width=600 \
                --title="Add this SSH key to GitHub" \
                --text="Add this key at ${VXO_GITHUB_KEYS_URL}\n\n${pub}" \
                >/dev/null 2>&1 &) || true
    elif have notify-send; then
        (notify-send "vortex-onboarding" \
                     "Add your new SSH key to GitHub. See the terminal." \
                     >/dev/null 2>&1 &) || true
    fi
}
