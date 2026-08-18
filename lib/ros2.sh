#!/usr/bin/env bash
# lib/ros2.sh: ROS 2 Lyrical Luth and the Vortex workspace.
#
# This is the installer's isolated failure domain and always runs last. A colcon
# build can take the better part of an hour and can fail for reasons that have
# nothing to do with the rest of the setup, so install.sh runs this stage in
# "soft" mode: it may fail without costing the user their dotfiles or editor.
# Re-run it on its own with:  ./install.sh --only=ros2
#
# Lyrical Luth pairs with Ubuntu 26.04 "Resolute" and nothing else. There is
# deliberately no release-to-distro mapping and no Humble fallback here.
#
# SCOPE: Ubuntu 26.04 only.

[[ -n "${_VXO_ROS2_SOURCED:-}" ]] && return 0
_VXO_ROS2_SOURCED=1

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

VXO_ROS_DISTRO="lyrical"
VXO_ROS_REQUIRED_RELEASE="26.04"
VXO_ROS_SETUP="/opt/ros/${VXO_ROS_DISTRO}/setup.bash"
VXO_ROS_WS="$HOME/code/ros2_ws"

# Extra ROS packages beyond ros-lyrical-desktop, written without the
# "ros-<distro>-" prefix so the distro is named in exactly one place.
#
# yasmin is the finite state machine library Vortex builds mission logic on.
# yasmin-ros adds the ROS 2 integration (action/service/topic states), and
# yasmin-viewer is the web UI that draws the running state machine, which is the
# fastest way to see why a mission is stuck.
VXO_ROS_EXTRA_PACKAGES=(
    yasmin
    yasmin-ros
    yasmin-viewer
)

# Python packages the workspace needs beyond ros-<distro>-desktop.
#
# The flake8 plugins are not optional extras: ament_flake8 loads whichever of
# them are installed, so a machine missing them passes a lint check that
# vortex-ci then fails on for the same code. Same argument for the pytest
# plugins, which ament_pytest's own test decorators import by name.
#
# The scientific set (numpy, scipy, matplotlib) is separate: it is what the
# controller and navigation nodes import at runtime, and what the analysis
# scripts in the workspace plot with. python3-serial is the stim300 driver's
# transport.
#
# Deliberately apt, not pip. These end up on the same import path as the
# apt-installed ROS packages that depend on them, and a pip copy in
# ~/.local/lib shadowing an apt one is a genuinely nasty class of bug to debug
# inside a colcon build.
VXO_ROS_PYTHON_DEV=(
    python3-argcomplete
    python3-mypy

    python3-flake8-blind-except
    python3-flake8-builtins
    python3-flake8-class-newline
    python3-flake8-comprehensions
    python3-flake8-deprecated
    python3-flake8-docstrings
    python3-flake8-import-order
    python3-flake8-quotes

    python3-pytest-cov
    python3-pytest-mock
    python3-pytest-repeat
    python3-pytest-rerunfailures
    python3-pytest-timeout

    python3-numpy
    python3-scipy
    python3-matplotlib
    python3-serial
)

# repo|branch. Add a line here to add a package to the workspace.
VXO_ROS_REPOS=(
    "vortexntnu/vortex-auv|development"
    "vortexntnu/vortex-msgs|main"
    "vortexntnu/vortex-utils|main"
    "vortexntnu/vortex-ci|main"
    "vortexntnu/stonefish_ros2|main"
    "vortexntnu/vortex-stonefish-interface|main"
    "vortexntnu/vortex-stonefish-sim|main"
    "vortexntnu/stim300-driver|feature/ros2-port"
)

# ─────────────────────────── apt repo + packages ───────────────────────────

_vxo_ros_locales() {
    apt_install locales
    # Process substitution, not a pipe: `grep -q` exits early and SIGPIPEs the
    # writer, which `set -o pipefail` would report as a failure.
    if grep -qiE '^en_US\.utf-?8$' < <(locale -a 2>/dev/null); then
        log_skip "en_US.UTF-8 locale already generated"
    else
        run sudo locale-gen en_US en_US.UTF-8
        run sudo update-locale LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
    fi
    export LANG=en_US.UTF-8
}

_vxo_ros_apt_source() {
    if pkg_installed ros2-apt-source; then
        log_skip "ros2-apt-source already installed"
        return 0
    fi

    apt_install software-properties-common curl
    run sudo add-apt-repository -y universe

    local version
    version="$(curl -fsSL https://api.github.com/repos/ros-infrastructure/ros-apt-source/releases/latest 2>/dev/null \
        | grep -F '"tag_name"' | head -1 | awk -F'"' '{print $4}')" || true

    if [[ -z "$version" ]]; then
        die "could not determine the latest ros-apt-source release. GitHub's API may be rate-limiting this network; retry later with: ./install.sh --only=ros2"
    fi

    local codename
    codename="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-${VERSION_CODENAME}}")"
    [[ -n "$codename" ]] || die "could not read the Ubuntu codename from /etc/os-release"

    local url="https://github.com/ros-infrastructure/ros-apt-source/releases/download/${version}/ros2-apt-source_${version}.${codename}_all.deb"
    local tmp; tmp="$(mktemp -d)"

    log_info "installing ros2-apt-source ${version} for ${codename}"
    run curl -fsSL -o "$tmp/ros2-apt-source.deb" "$url" \
        || { rm -rf "$tmp"; die "could not download $url"; }
    run sudo dpkg -i "$tmp/ros2-apt-source.deb" || run sudo apt-get -f install -y
    rm -rf "$tmp"

    # New apt source, so the cached "already updated" flag no longer applies.
    _VXO_APT_UPDATED=0
    log_ok "ROS 2 apt source configured"
}

_vxo_ros_packages() {
    apt_update_once
    apt_install ros-dev-tools
    log_info "upgrading packages against the new ROS apt source (this can take a while)"
    run sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
    apt_install "ros-${VXO_ROS_DISTRO}-desktop"
    apt_install python3-colcon-common-extensions python3-rosdep python3-vcstool
    _vxo_ros_python_dev
    _vxo_ros_extra_packages

    # Post-condition, and only meaningful after a real install. A dry run
    # installs nothing, so $VXO_ROS_SETUP is legitimately absent and asserting
    # it here ends every `--dry-run` on a red failure for work that was
    # deliberately not done. Same guard, same reason, as lib/toolchain.sh's
    # _vxo_apt_available and lib/rust.sh's rustup post-condition.
    if [[ "${VXO_DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] would install ros-${VXO_ROS_DISTRO}-desktop and verify $VXO_ROS_SETUP"
        return 0
    fi

    [[ -f "$VXO_ROS_SETUP" ]] \
        || die "ROS 2 packages installed but $VXO_ROS_SETUP is missing. The apt source may point at the wrong distro."
    log_ok "ROS 2 ${VXO_ROS_DISTRO} installed"
}

# The flake8/pytest/scientific Python set. Installed one filtered batch at a
# time rather than as a single apt_install call: Ubuntu occasionally renames or
# drops one of the smaller flake8 plugins between releases, and a single missing
# package name would otherwise fail the whole transaction and take ROS down with
# it. A plugin that no longer exists is worth a warning, not a failed install.
_vxo_ros_python_dev() {
    local pkg available=() missing=()

    for pkg in "${VXO_ROS_PYTHON_DEV[@]}"; do
        if _vxo_ros_apt_available "$pkg"; then
            available+=("$pkg")
        else
            missing+=("$pkg")
        fi
    done

    if ((${#available[@]} > 0)); then
        apt_install "${available[@]}"
    fi

    if ((${#missing[@]} > 0)); then
        log_warn "not in the archive for Ubuntu $(ubuntu_release), skipped: ${missing[*]}"
        log_warn "ament_flake8 and ament_pytest load whichever plugins are present, so local"
        log_warn "lint results may differ from vortex-ci for the missing ones."
    fi
}

# YASMIN and anything else in VXO_ROS_EXTRA_PACKAGES.
#
# These are released into the ROS 2 apt index rather than built from source, so
# they get security updates with everything else and do not lengthen the colcon
# build. A package that has not been released for this distro yet is a warning,
# not a failure: the rest of the ROS install is still perfectly usable.
_vxo_ros_extra_packages() {
    local pkg full missing=() want=()

    for pkg in "${VXO_ROS_EXTRA_PACKAGES[@]}"; do
        full="ros-${VXO_ROS_DISTRO}-${pkg}"
        if _vxo_ros_apt_available "$full"; then
            want+=("$full")
        else
            missing+=("$full")
        fi
    done

    if ((${#want[@]} > 0)); then
        apt_install "${want[@]}"
        log_ok "extra ROS packages installed: ${want[*]}"
    fi

    if ((${#missing[@]} > 0)); then
        log_warn "not released for ${VXO_ROS_DISTRO}, skipped: ${missing[*]}"
        log_warn "Build them from source in $VXO_ROS_WS/src if you need them now."
    fi
}

# apt candidate exists for a package name?
_vxo_ros_apt_available() {
    [[ "${VXO_DRY_RUN:-0}" == "1" ]] && return 0
    local cand
    cand="$(apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ {print $2}')"
    [[ -n "$cand" && "$cand" != "(none)" ]]
}

# ─────────────────────────── workspace ───────────────────────────

_vxo_ros_workspace_dirs() {
    run mkdir -p "$VXO_ROS_WS/src"
    log_ok "workspace at $VXO_ROS_WS"
}

_vxo_ros_clone_repos() {
    local base via
    # SSH is a verified precondition of every real install, so this is SSH unless
    # the run used --skip-ssh-check. The declare -F guard keeps this module
    # sourceable on its own, without ssh_github.sh.
    if declare -F vxo_use_ssh_remotes >/dev/null && vxo_use_ssh_remotes; then
        base="git@github.com:"; via="SSH"
    else
        base="https://github.com/"; via="HTTPS"
    fi
    log_info "cloning ${#VXO_ROS_REPOS[@]} workspace repos over $via"

    local entry slug branch name url failed=0
    for entry in "${VXO_ROS_REPOS[@]}"; do
        IFS='|' read -r slug branch <<<"$entry"
        name="${slug##*/}"
        url="${base}${slug}.git"
        # One repo failing must not abandon the other seven.
        git_sync "$url" "$VXO_ROS_WS/src/$name" "$branch" \
            || { log_warn "could not fetch $slug ($branch)"; failed=$((failed + 1)); }
    done

    if ((failed > 0)); then
        log_warn "$failed of ${#VXO_ROS_REPOS[@]} repos could not be fetched."
        if [[ "$via" == "SSH" ]]; then
            log_warn "Your key authenticates to GitHub, so this is probably a permissions"
            log_warn "problem: ask in #software to be added to the VortexNTNU organisation."
        else
            log_warn "These repos are private and need SSH. Re-run without --skip-ssh-check."
        fi
    fi
}

_vxo_ros_utility_scripts() {
    local src="$VXO_DOTFILES/ros2_utility_scripts"
    local dest="$VXO_ROS_WS/utility_scripts"

    [[ -d "$src" ]] || { log_warn "no vendored utility scripts at $src"; return 0; }

    run mkdir -p "$dest"
    local f
    for f in "$src"/*; do
        [[ -f "$f" ]] || continue
        install_file "$f" "$dest/$(basename "$f")" 0755
    done
    log_ok "utility scripts installed to $dest"
}

# The managed .bashrc already sources the workspace, but --only=ros2 on a machine
# whose .bashrc predates this installer would otherwise leave it unsourced.
_vxo_ros_bashrc_hook() {
    # Matched loosely on purpose: the managed .bashrc writes the path as
    # "${VXO_ROS_WS:-$HOME/code/ros2_ws}/install/setup.bash", so a literal
    # "code/ros2_ws/install/setup.bash" never matches and this "fallback" block
    # would fire on every normal install, sourcing ROS twice.
    if grep -qE 'ros2_ws.*install/setup\.bash' "$HOME/.bashrc" 2>/dev/null; then
        log_skip ".bashrc already sources the workspace"
        return 0
    fi
    ensure_block "$HOME/.bashrc" "ros2-workspace" "$(cat <<EOF
if [ -f "$VXO_ROS_SETUP" ]; then
    . "$VXO_ROS_SETUP"
fi
if [ -f "$VXO_ROS_WS/install/setup.bash" ]; then
    . "$VXO_ROS_WS/install/setup.bash"
fi
EOF
)"
}

# ─────────────────────────── rosdep + build ───────────────────────────

_vxo_ros_rosdep() {
    if [[ -f /etc/ros/rosdep/sources.list.d/20-default.list ]]; then
        log_skip "rosdep already initialised"
    else
        run sudo rosdep init || log_warn "rosdep init reported a problem, continuing anyway"
    fi

    run rosdep update || log_warn "rosdep update failed, so dependency resolution may be incomplete"

    log_info "resolving workspace dependencies with rosdep"
    run rosdep install --from-paths "$VXO_ROS_WS/src" --ignore-src -y \
        --rosdistro "$VXO_ROS_DISTRO" \
        || log_warn "rosdep could not satisfy every dependency, so the build may fail below"
}

_vxo_ros_build() {
    local log="$VXO_LOG_DIR/colcon-build.log"
    log_info "building the workspace with colcon (this is the long part)"
    log_info "  live log: $log"

    if [[ "${VXO_DRY_RUN:-0}" == "1" ]]; then
        log_skip "[dry-run] colcon build --symlink-install --cmake-args -DCMAKE_BUILD_TYPE=Release"
        return 0
    fi

    # ROS setup scripts reference unbound variables, so `set -u` has to come off
    # for the duration. A subshell keeps that (and the ROS env) out of the
    # installer's own shell.
    set +e
    (
        set +eu
        # shellcheck disable=SC1090
        . "$VXO_ROS_SETUP"
        cd "$VXO_ROS_WS" || exit 1
        colcon build --symlink-install --cmake-args -DCMAKE_BUILD_TYPE=Release 2>&1
    ) | tee "$log"
    local rc=${PIPESTATUS[0]}
    set -e

    if ((rc != 0)); then
        log_error "colcon build failed (exit $rc). Last 30 lines:"
        tail -n 30 "$log" >&2 || true
        log_error "Full build log: $log"
        log_error "Fix the cause, then re-run just this stage: ./install.sh --only=ros2"
        return "$rc"
    fi

    [[ -f "$VXO_ROS_WS/install/setup.bash" ]] \
        || log_warn "build succeeded but $VXO_ROS_WS/install/setup.bash is missing"
    log_ok "workspace built"
}

# ─────────────────────────── entrypoint ───────────────────────────

vxo_ros2() {
    if [[ "${VXO_ROS:-0}" != "1" ]]; then
        log_skip "ROS 2 was not selected"
        stage_abort "ROS 2 not requested"
        return 0
    fi

    local release; release="$(ubuntu_release)"
    if [[ "$release" != "$VXO_ROS_REQUIRED_RELEASE" ]]; then
        # This is not an error. It is an expected, documented skip, and logging
        # it in red makes a perfectly good install look like it failed.
        log_warn "ROS 2 ${VXO_ROS_DISTRO^} requires Ubuntu ${VXO_ROS_REQUIRED_RELEASE}; this machine runs ${release}."
        log_warn "Everything else in the install is unaffected and complete."
        stage_abort "Skipping ROS 2. On Ubuntu ${VXO_ROS_REQUIRED_RELEASE}, run: ./install.sh --only=ros2"
        return 0
    fi

    _vxo_ros_locales
    _vxo_ros_apt_source
    _vxo_ros_packages
    _vxo_ros_workspace_dirs
    _vxo_ros_clone_repos
    _vxo_ros_utility_scripts
    _vxo_ros_bashrc_hook

    # --skip-ros-build stops here: ROS and the workspace sources are installed,
    # but rosdep resolution and the 30-60 minute colcon build are left for later.
    # Used by the container test harness, and handy when you want the toolchain
    # now and the build overnight.
    if [[ "${VXO_SKIP_ROS_BUILD:-0}" == "1" ]]; then
        # Marker so verify_install.sh can tell "deliberately not built" apart from
        # "the build failed". On disk both look identical: a missing
        # install/setup.bash.
        [[ "${VXO_DRY_RUN:-0}" == "1" ]] || touch "$VXO_STATE_DIR/ros_build_skipped"
        log_warn "--skip-ros-build: stopping before rosdep and colcon."
        log_warn "Finish it later with: ./install.sh --only=ros2"
        stage_abort "ROS 2 installed but not built"
        return 0
    fi

    _vxo_ros_rosdep
    _vxo_ros_build

    # The workspace is built now; clear any stale skip marker.
    rm -f "$VXO_STATE_DIR/ros_build_skipped"
}
