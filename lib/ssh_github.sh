#!/usr/bin/env bash
# lib/ssh_github.sh: the GitHub SSH precondition, and git identity.
#
# Sourced by install.sh. Provides:
#   vxo_require_github_ssh  preflight gate, run before anything is installed
#   vxo_git_config          the git-config stage (name, email, defaults)
#   vxo_use_ssh_remotes     true when clones should use git@github.com
#
# A working GitHub SSH key is a PRECONDITION of this installer, not something it
# sets up for you. Every repo it clones lives behind a git@github.com remote, and
# half of them are private to VortexNTNU, so an install without a key produces a
# half-empty workspace and a member who thinks the script worked.
#
# So the check is a hard gate at the very top of the run: no key, no install. It
# does not generate keys, does not walk you through GitHub's settings pages, and
# does not quietly fall back to HTTPS. If the gate fails it prints GitHub's own
# documentation and exits, having changed nothing on your machine.

[[ -n "${_VXO_SSH_GITHUB_SOURCED:-}" ]] && return 0
_VXO_SSH_GITHUB_SOURCED=1

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# GitHub's own guide. Linked rather than reproduced: it covers ed25519 vs rsa,
# passphrases, the agent, and the browser steps, and it stays current when
# GitHub moves things around.
VXO_GITHUB_SSH_DOC="https://docs.github.com/en/authentication/connecting-to-github-with-ssh"

# ─────────────────────────── the precondition ───────────────────────────

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

# Any private key at all in ~/.ssh. Used only to tell two failures apart in the
# error message: "you have no key" reads very differently from "you have a key
# GitHub does not recognise", and they need different fixes.
_vxo_has_any_ssh_key() {
    local f
    for f in "$HOME"/.ssh/id_*; do
        [[ -f "$f" && "$f" != *.pub ]] && return 0
    done
    return 1
}

# Called from install.sh before the first stage runs. Exits the installer on
# failure; nothing has been modified at that point.
vxo_require_github_ssh() {
    if [[ "${VXO_SKIP_SSH_CHECK:-0}" == "1" ]]; then
        log_warn "--skip-ssh-check: not verifying GitHub SSH. Repos will be cloned over HTTPS"
        log_warn "and private VortexNTNU repos will fail. This flag is for automated testing."
        return 0
    fi

    if ! have ssh; then
        die "The ssh client is missing. Install it and re-run:
    sudo apt install openssh-client"
    fi

    log_info "Checking GitHub SSH access"

    if _vxo_github_ssh_works; then
        log_ok "GitHub SSH authentication works"
        return 0
    fi

    _vxo_ssh_gate_failed
}

_vxo_ssh_gate_failed() {
    local diagnosis
    if _vxo_has_any_ssh_key; then
        diagnosis="You have an SSH key in ~/.ssh, but GitHub does not accept it. Either it was
  never added to your account, or the wrong key is being offered."
    else
        diagnosis="There is no SSH key in ~/.ssh at all."
    fi

    cat >&2 <<EOF

${C_BOLD}${C_RED}  GitHub SSH access is required, and it is not working.${C_RESET}

  ${diagnosis}

  This installer clones your Neovim config and eight VortexNTNU workspace
  repositories over SSH. Several of them are private, so there is no useful
  install to do without a key. Nothing on this machine has been changed.

  Set the key up by following GitHub's guide, which covers generating a key,
  adding it to the agent, and registering it on your account:

    ${C_CYAN}${VXO_GITHUB_SSH_DOC}${C_RESET}

  Verify it yourself with:

    ${C_BOLD}ssh -T git@github.com${C_RESET}

  You are ready when that prints "Hi <username>! You've successfully
  authenticated". Then run this installer again.

EOF

    die "GitHub SSH precondition not met."
}

# ─────────────────────────── remotes ───────────────────────────

# True when git clones should use SSH remotes rather than HTTPS.
#
# The preflight gate guarantees SSH works for every real install, so this is
# simply true. It stays a function because --skip-ssh-check (test harnesses,
# containers with no key) is the one path that has to clone over HTTPS.
vxo_use_ssh_remotes() {
    [[ "${VXO_SKIP_SSH_CHECK:-0}" != "1" ]]
}

# ─────────────────────────── git identity ───────────────────────────

vxo_git_config() {
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

    # core.editor covers commit messages; sequence.editor is the separate one
    # `git rebase -i` uses for the todo list. Both are set explicitly because
    # git prefers them over $EDITOR, so leaving one unset means half your git
    # editing happens somewhere else.
    #
    # `-f` keeps nvim in the foreground; `--wait` does the same for VS Code.
    # Without them git sees the editor exit instantly and treats the message as
    # empty, aborting the commit.
    if [[ "${VXO_EDITOR:-nvim}" == "nvim" ]]; then
        run git config --global core.editor "nvim -f"
        run git config --global sequence.editor "nvim -f"
    else
        run git config --global core.editor "code --wait"
        run git config --global sequence.editor "code --wait"
    fi

    log_ok "git identity configured"
}
