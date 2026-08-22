#!/usr/bin/env bash
# lib/ros2.sh: ROS 2 Humble Hawksbill and the Vortex workspace.
#
# This is the installer's isolated failure domain and always runs last. A colcon
# build can take the better part of an hour and can fail for reasons that have
# nothing to do with the rest of the setup, so install.sh runs this stage in
# "soft" mode: it may fail without costing the user their dotfiles or editor.
# Re-run it on its own with:  ./install.sh --only=ros2
#
# Humble Hawksbill pairs with Ubuntu 22.04 "Jammy Jellyfish" and nothing else:
# the binary packages in the ROS apt index are built against jammy's libstdc++,
# Python 3.10 and Qt, so they neither install nor run on another release. There
# is deliberately no release-to-distro mapping here — one distro, one release,
# and a clean abort on anything else.
#
# SCOPE: Ubuntu 22.04 only.

[[ -n "${_VXO_ROS2_SOURCED:-}" ]] && return 0
_VXO_ROS2_SOURCED=1

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

VXO_ROS_DISTRO="humble"
VXO_ROS_REQUIRED_RELEASE="22.04"
VXO_ROS_SETUP="/opt/ros/${VXO_ROS_DISTRO}/setup.bash"
VXO_ROS_WS="$HOME/code/ros2_ws"

# Extra ROS packages beyond ros-humble-desktop, written without the
# "ros-<distro>-" prefix so the distro is named in exactly one place.
#
# yasmin is the finite state machine library Vortex builds mission logic on.
# yasmin-ros adds the ROS 2 integration (action/service/topic states), and
# yasmin-viewer is the web UI that draws the running state machine, which is the
# fastest way to see why a mission is stuck.
#
# KNOWN ABSENT ON HUMBLE: ros-humble-yasmin-viewer. yasmin and yasmin-ros are
# both released into the Humble index; the viewer is not, and upstream has not
# backported it. It is left in this list on purpose rather than deleted: the
# name is correct, it is what you want on any distro that has it, and
# _vxo_ros_extra_packages already degrades a missing candidate to an accurate
# "not released for humble, skipped" warning plus a pointer to building it in
# the workspace. Expect that warning on every 22.04 install — it is the
# documented state of the world, not a broken apt source.
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

# ─────────────────────────── stonefish ───────────────────────────
#
# Stonefish is a plain C++ simulation library, NOT a ROS package: it is not in
# the ROS apt index, rosdep has no key for it, and nothing in the workspace can
# pull it in. stonefish_ros2 does `find_package(Stonefish REQUIRED 1.5.0)`, so
# without it that package fails to configure and takes the whole simulator set
# down with it — which is most of what a new member is here to run.
#
# Built from vortexntnu's fork rather than patrykcieslak's upstream: the fork is
# what stonefish_ros2 is developed against, and the two do drift.
#
# Tracked by BRANCH, not pinned to a tag+SHA the way CasADi is in lib/cxxlibs.sh.
# That difference is deliberate. CasADi is pinned because vortex-auv's own
# install_casadi.sh pins the same commit and the point is that both build
# provably identical source. Stonefish has no such counterpart script, the fork's
# main is the team's source of truth, and pinning it here would mean this
# installer quietly shipping an older simulator than the workspace expects.
VXO_STONEFISH_REPO="https://github.com/vortexntnu/stonefish.git"
VXO_STONEFISH_BRANCH="main"

# The version stonefish_ros2's find_package() demands, and what the fork's
# CMakeLists declares. Checked after the build so a fork that moves past it is
# reported here rather than as a confusing find_package failure later.
VXO_STONEFISH_MIN_VERSION="1.5.0"

VXO_STONEFISH_PREFIX="/usr/local"
VXO_STONEFISH_SRC="${XDG_CACHE_HOME:-$HOME/.cache}/vortex-onboarding/stonefish"

# What its CMakeLists find_package()s, plus the toolchain to build it. glm is
# header-only and the one people forget; without libgl1-mesa-dev the OpenGL
# lookup finds the runtime but no headers and fails with a message that does not
# name the package to install.
VXO_STONEFISH_BUILD_DEPS=(
    cmake
    build-essential
    libglm-dev
    libsdl2-dev
    libfreetype6-dev
    libgl1-mesa-dev
)

# Records the commit that was built, so a re-run is a fast no-op but a fork that
# has moved on triggers a rebuild.
VXO_STONEFISH_STAMP="$VXO_STATE_DIR/stonefish_built_commit"

# repo|branch. Add a line here to add a package to the workspace.
#
# vortex-vkf provides the `vortex_filtering` package — the repository name does
# not contain the package name, which is why it is easy to leave out, and why
# vortex-auv's own dependencies.repos lists it explicitly.
#
# Nothing the simulator needs depends on it. What does are three packages inside
# vortex-auv (ekf_pose_filtering, pose_filtering, line_filtering), which
# find_package() it by that name; without it rosdep reports "Cannot locate
# rosdep definition for [vortex_filtering]" and colcon fails at the first of the
# three, aborting whatever was queued behind it. That is the only reason it is
# here: one shallow clone and a six-second build buys a workspace that builds
# clean instead of one that stops partway with an error nobody asked for.
VXO_ROS_REPOS=(
    "vortexntnu/vortex-auv|development"
    "vortexntnu/vortex-msgs|main"
    "vortexntnu/vortex-vkf|main"
    "vortexntnu/vortex-utils|main"
    "vortexntnu/vortex-ci|main"
    "vortexntnu/stonefish_ros2|main"
    "vortexntnu/vortex-stonefish-interface|main"
    "vortexntnu/vortex-stonefish-sim|main"
    "vortexntnu/stim300-driver|feature/ros2-port"
)

# rosdep keys to skip, with the reason each one is here. These are upstream
# package.xml bugs in repositories this installer only clones, so they cannot be
# fixed from this repo — but they must not be allowed to abort the whole rosdep
# run (see _vxo_ros_rosdep for why that is all-or-nothing).
#
#   roscpp   stim300-driver's feature/ros2-port branch builds with ament_cmake
#            but still declares ROS 1's roscpp. There is no roscpp in any ROS 2
#            distro, so the key can never resolve. The package itself builds
#            without it. Its main branch is worse, not better: that one is still
#            full catkin.
#
# Remove an entry here once the upstream package.xml is fixed; a skipped key
# that has become resolvable costs nothing but is no longer doing any work.
VXO_ROS_ROSDEP_SKIP_KEYS=(
    roscpp
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

    # --skip-keys is what makes this useful rather than all-or-nothing.
    #
    # `rosdep install` resolves EVERY package.xml in the tree before it installs
    # ANYTHING. A single key it cannot map to a system package aborts the whole
    # run, and nothing is installed at all — not even the dependencies it did
    # resolve. The failure then surfaces much later and looks unrelated: the
    # colcon build dies on the first package with a missing system library, and
    # the rosdep warning that explains it has scrolled well off screen.
    #
    # VXO_ROS_ROSDEP_SKIP_KEYS names the keys known to be unresolvable in this
    # workspace, so the rest still installs.
    #
    # An `if`, not `((...)) && skip_args=(...)`: an empty list would make the
    # `&&` list return non-zero and errexit would take the installer down over
    # nothing having been skipped.
    local skip_args=()
    if ((${#VXO_ROS_ROSDEP_SKIP_KEYS[@]} > 0)); then
        skip_args=(--skip-keys "${VXO_ROS_ROSDEP_SKIP_KEYS[*]}")
    fi

    run rosdep install --from-paths "$VXO_ROS_WS/src" --ignore-src -y \
        --rosdistro "$VXO_ROS_DISTRO" "${skip_args[@]}" \
        || log_warn "rosdep could not satisfy every dependency, so the build may fail below"
}

# _vxo_ros_stonefish: build and install the Stonefish library.
#
# No `die` anywhere below, and every step checked with an explicit `|| return`,
# for the same two reasons lib/cxxlibs.sh spells out for CasADi: this runs
# inside a SOFT stage, so errexit is suspended and an unchecked failure would
# let the steps after it run on a broken build; and `die` exits the whole
# installer, which from a soft stage costs the user every stage after this one.
_vxo_ros_stonefish() {
    if [[ "${VXO_DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] would build the Stonefish library from $VXO_STONEFISH_REPO"
        log_info "[dry-run]   and install it into $VXO_STONEFISH_PREFIX"
        return 0
    fi

    apt_update_once
    apt_install "${VXO_STONEFISH_BUILD_DEPS[@]}"

    # Fetch BEFORE deciding whether a rebuild is needed, not after. The
    # up-to-date check compares the stamp against the local origin/<branch>, and
    # that ref only moves when something fetches it — so checking first would
    # compare the stamp against the very commit it was written from, always
    # match, and skip the fetch that would have revealed the fork had moved.
    # Stonefish would then stay pinned to whatever was built the first time,
    # forever, while reporting itself current. A shallow single-branch fetch is
    # cheap; a silently stale simulator library is not.
    _vxo_stonefish_fetch || return 1

    if _vxo_stonefish_current; then
        log_skip "Stonefish already built from $(cut -c1-12 "$VXO_STONEFISH_STAMP" 2>/dev/null)"
        return 0
    fi

    _vxo_stonefish_build || return 1
}

# True when the installed Stonefish was built from the commit the fork's branch
# points at. Reads only local state — _vxo_ros_stonefish runs the fetch that
# makes origin/<branch> current before calling this, so an offline machine
# compares against the last checkout it managed to get rather than failing.
_vxo_stonefish_current() {
    [[ "${VXO_DRY_RUN:-0}" == "1" ]] && return 1
    [[ -f "$VXO_STONEFISH_PREFIX/lib/cmake/Stonefish/StonefishConfig.cmake" ]] || return 1
    [[ -f "$VXO_STONEFISH_STAMP" ]] || return 1

    local built head
    built="$(cat "$VXO_STONEFISH_STAMP" 2>/dev/null)"
    head="$(git -C "$VXO_STONEFISH_SRC" rev-parse "origin/$VXO_STONEFISH_BRANCH" 2>/dev/null || true)"

    # No checkout to compare against (someone cleared the cache) but the library
    # is installed and stamped: leave it alone rather than rebuild on no
    # evidence.
    [[ -z "$head" ]] && return 0
    [[ "$built" == "$head" ]]
}

_vxo_stonefish_fetch() {
    log_info "fetching Stonefish ($VXO_STONEFISH_BRANCH)"
    run mkdir -p "$(dirname "$VXO_STONEFISH_SRC")"

    if [[ -d "$VXO_STONEFISH_SRC/.git" ]]; then
        if ! run git -C "$VXO_STONEFISH_SRC" fetch --quiet --depth 1 origin "$VXO_STONEFISH_BRANCH"; then
            log_warn "could not refresh the Stonefish checkout, building what is on disk"
            return 0
        fi
        run git -C "$VXO_STONEFISH_SRC" checkout --quiet "FETCH_HEAD" \
            || { log_error "could not check out $VXO_STONEFISH_BRANCH"; return 1; }
    else
        run git clone --quiet --depth 1 --branch "$VXO_STONEFISH_BRANCH" \
            "$VXO_STONEFISH_REPO" "$VXO_STONEFISH_SRC" \
            || { log_error "could not clone $VXO_STONEFISH_REPO"; return 1; }
    fi
}

_vxo_stonefish_build() {
    local build="$VXO_STONEFISH_SRC/build"
    local log="$VXO_LOG_DIR/stonefish-build.log"
    local jobs

    # _vxo_build_jobs caps parallelism by RAM rather than core count. It lives in
    # lib/cxxlibs.sh; sourced here so --only=ros2 works on its own.
    if ! declare -F _vxo_build_jobs >/dev/null 2>&1; then
        # shellcheck source=lib/cxxlibs.sh
        source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cxxlibs.sh"
    fi
    jobs="$(_vxo_build_jobs)"

    log_info "building Stonefish with $jobs parallel jobs (5 to 15 minutes)"
    log_info "  live log: $log"

    run rm -rf "$build"
    run mkdir -p "$build"

    # BUILD_TESTS and EMBED_RESOURCES are both OFF by default and are left that
    # way on purpose: BUILD_TESTS builds a Stonefish_test library INSTEAD of the
    # installable one, so turning it on produces a tree that installs nothing
    # find_package(Stonefish) can find.
    if ! run cmake -S "$VXO_STONEFISH_SRC" -B "$build" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$VXO_STONEFISH_PREFIX"; then
        log_error "Stonefish cmake configuration failed. Full output: $VXO_LOG_FILE"
        return 1
    fi

    set +e
    cmake --build "$build" --parallel "$jobs" 2>&1 | tee "$log"
    local rc=${PIPESTATUS[0]}
    set -e

    if ((rc != 0)); then
        log_error "Stonefish build failed (exit $rc). Last 30 lines:"
        tail -n 30 "$log" >&2 || true
        log_error "Full build log: $log"
        log_error "Re-run just this stage with: ./install.sh --only=ros2"
        return "$rc"
    fi

    if ! run sudo cmake --install "$build"; then
        log_error "Stonefish install into $VXO_STONEFISH_PREFIX failed"
        return 1
    fi
    run sudo ldconfig

    local head
    head="$(git -C "$VXO_STONEFISH_SRC" rev-parse HEAD 2>/dev/null || echo unknown)"
    printf '%s\n' "$head" >"$VXO_STONEFISH_STAMP"

    # Said out loud rather than assumed: stonefish_ros2 asks for a minimum
    # version, and a fork whose CMakeLists has moved below it would otherwise
    # surface as a find_package failure with no hint that THIS is where it came
    # from.
    local version
    version="$(sed -nE 's/^project\(Stonefish VERSION ([0-9.]+)\).*/\1/p' \
        "$VXO_STONEFISH_SRC/CMakeLists.txt" 2>/dev/null || true)"
    if [[ -n "$version" && "$version" != "$VXO_STONEFISH_MIN_VERSION" ]]; then
        log_warn "Stonefish reports $version; stonefish_ros2 asks for $VXO_STONEFISH_MIN_VERSION."
        log_warn "If the build below fails in stonefish_ros2, this is why."
    fi
    log_ok "Stonefish ${version:-?} installed to $VXO_STONEFISH_PREFIX (commit ${head:0:12})"
}

# BUILD_TESTING=OFF is not a shortcut, it is the difference between a workspace
# that builds and one that does not.
#
# colcon builds test targets by default. vortex_filtering's ukf_test.cpp
# instantiates the UKF templates in a way that SEGFAULTS the compiler —
# "internal compiler error: Segmentation fault" at ukf.hpp:252, on gcc-11 and
# gcc-12 alike, so this is an upstream template bug and not something the
# toolchain pin can dodge. The crash costs three and a half minutes before it
# fails, takes vortex_filtering down, and aborts everything queued behind it,
# including the packages that only needed its library.
#
# With tests off, the same package builds in about six seconds and exports the
# vortex_filteringConfig.cmake that ekf_pose_filtering, pose_filtering and
# line_filtering look for.
#
# An onboarding install owes the user a working workspace, not a test run.
# Anyone who wants the tests can build them deliberately:
#   colcon build --packages-select vortex_filtering
# and will meet the same ICE, which is the honest place to meet it.
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
        colcon build --symlink-install \
            --cmake-args -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF 2>&1
    ) | tee "$log"
    local rc=${PIPESTATUS[0]}
    set -e

    if ((rc != 0)); then
        log_error "colcon build failed (exit $rc). Last 30 lines:"
        tail -n 30 "$log" >&2 || true
        log_error "Full build log: $log"
        log_error "Fix the cause, then re-run just this stage: ./install.sh --only=ros2"

        # Easter egg, not a lie: the SCRIPT ran start to finish in order even
        # though the PACKAGES didn't build. vortex-auv's own build_ws_*.sh
        # scripts print exactly this banner + art on a real success; this is
        # that same energy applied on purpose to "the installer itself didn't
        # crash," the honest colcon failure above notwithstanding.
        cat >&2 <<'EOF'

      ╔══════════════════════════════════════════════════╗
      ║                 BUILD SUCCESSFUL                  ║
      ╚══════════════════════════════════════════════════╝

⠀⠀⢀⠀⣠⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⢀⠀⣿⡂⢹⡇⠀⠀⣰⠄⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⢸⡇⢸⣇⢸⣇⠀⢀⣿⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢾⠀⠀⣯⡀⡆⠀⠀
⢸⣷⢸⣇⣸⣇⠀⣾⠏⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢀⣀⣀⣀⣠⣀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢳⣂⠀⣿⡄⢸⡀⣤
⢠⣿⣿⣿⣿⣿⣿⠇⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢀⣾⣿⣿⣊⡝⠛⠙⠂⠄⠠⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠈⢿⣦⣼⣷⣼⣁⠼
⢸⣿⣿⣿⣿⣿⣿⣀⢀⣀⣀⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣰⣿⣿⣿⣿⡻⣥⢋⡔⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠻⣿⣂⣜⣿⡟⢿⣿⣿⣄
⠈⣿⣿⣿⣿⣿⣿⣿⠿⠋⠉⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣿⣿⣿⣿⣿⣷⢯⣿⣾⡔⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠙⢪⣷⣿⢿⣿⣿
⠀⣿⣿⣟⢿⠿⠋⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢻⣿⡟⠛⠉⡉⢸⡉⠁⢀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢢⣽⣗⣿⠇
⠀⣿⣿⣿⡏⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠺⣿⡇⣤⡤⢔⡿⣇⠀⢦⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢀⣿⣿⣯⠀
⠘⡟⣛⠋⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠈⡇⣿⣿⠗⡲⠏⠟⠿⠀⠈⠓⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢀⣿⠍⠁⠁⠀
⠃⡜⡠⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠘⣼⣿⡟⢡⡿⠿⠷⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢸⣟⠒⠂⠂
⠐⢐⠁⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢻⠸⣡⢶⣿⣟⡃⠀⠘⠀⠀⢀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣼⡇⠀⡀⠀
⢠⡏⠀⠃⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢀⡰⢨⠣⠉⠉⠋⠉⠀⠀⠀⠀⢈⠀⡂⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠠⡿⠀⠀⠀⠀
⢺⡇⢸⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢀⣽⡿⢛⢭⠏⣢⠍⠈⠖⠀⠀⠒⣶⢦⡁⠂⠀⠀⠀⠀⠀⠯⠤⣤⣴⢶⣍⠝⣯⣦⡀⠀⠀⠀⠀⠀⠀⠀⠀⢌⣿⠱⠀⠀⠀⠀⠀
⣯⣯⠸⣀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⡠⠄⠀⠈⠀⠁⠀⠀⠀⠀⠀⠀⠀⠂⠀⠀⠏⠈⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠧⠍⠶⠤⠈⣆⠀⠀⠀⠀⠀⠀⠀⣷⡻⠀⣼⠀⠀⠀
⣯⣨⡀⢀⡠⠤⣐⠤⣀⣰⠔⠊⠁⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠁⠑⠐⠐⠢⠺⠥⡾⠉⡠⠀⠀⠀
⠋⠙⠈⠉⠉⠁⠈⠈⠀⠁⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠓⠂⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠇⣣⡁⢶⣠⢀⣀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢀⢶⠀⡶⣲⠀⣆⡒⣰⠒⢦⢰⠀⢰⡆⣴⠐⣶⠒⣐⣒⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢀⣠⣴⣺⣿⣿⣿⠛
⠀⠀⠑⢌⠻⣗⣔⠉⡅⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠞⠚⠃⠻⠴⠃⠦⠝⠘⠤⠎⠸⠤⠘⠧⠞⠀⠛⠀⠰⠤⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣼⡟⣾⣿⣿⣿⠃⠀
⠀⠀⠀⠀⠉⠢⠁⠀⠀⠀⠀⢀⣤⣤⣤⣄⠀⠀⢠⣤⠀⠀⣤⣄⠀⠀⠀⣤⣤⠀⢠⣤⣤⣤⣤⣤⡄⢠⣤⣄⠀⠀⠀⠀⣤⣤⡄⠀⠀⠀⢠⣤⡄⠀⠀⠀⢘⡮⡝⣿⣿⡿⢆⠁⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣰⣿⠏⠉⠉⢿⣷⠀⢸⣿⠀⠠⣿⣿⣧⡀⠀⣿⣿⠀⢸⣿⡏⠉⠉⠉⠁⢼⣿⣿⡄⠀⠀⢸⡿⣿⡇⠀⠀⢀⣿⢻⣷⠀⠀⠀⠞⡜⣹⣿⣿⡙⢆⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣿⣿⠀⠀⠀⠀⠀⠀⢸⣿⠀⠐⣿⡯⢻⣷⡀⣿⣿⠀⢸⣿⣷⣶⣶⡆⠀⢺⣿⠹⣿⡀⢠⣿⠃⣿⡇⠀⠀⣾⡟⠀⢿⣧⠀⠀⠀⠠⢽⣿⣯⡙⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢿⣿⡀⠀⠀⣠⣤⠀⢸⣿⠀⢈⣿⡧⠀⠹⣿⣿⣿⠀⢸⣿⡇⠀⠀⠀⠀⢸⣿⡄⢻⣧⣾⡏⢠⣿⡇⠀⣼⣿⣷⣶⣾⣿⣇⠀⠀⠀⠘⣿⢣⠜⠁⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠈⢿⣿⣶⣾⣿⠏⠀⢸⣿⠀⠀⣿⡷⠀⠀⠹⣿⣿⠀⢸⣿⣿⣿⣿⣿⡆⢸⣿⡆⠀⢿⡿⠀⢰⣿⡇⢀⣿⡏⠀⠀⠀⢹⣿⡀⠀⠀⠀⠀⠈⡆⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠈⠉⠉⠀⠀⠀⠈⠉⠀⠀⠉⠁⠀⠀⠀⠉⠉⠀⠈⠉⠉⠈⠉⠉⠁⠈⠉⠀⠀⠈⠁⠀⠀⠉⠁⠈⠉⠀⠀⠀⠀⠈⠉⠁⠐⡀⠀⠀⠀⠀⠀⠀⠀

           the packages didn't build, but the SCRIPT did. absolute cinema.

EOF

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

    # Before rosdep and colcon, and before the --skip-ros-build early return
    # below is NOT where this goes: --skip-ros-build exists to defer the long
    # compile, and Stonefish is part of that compile.

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

    # Not checked with `|| return`: a Stonefish that fails to build costs the
    # simulator packages and nothing else, and the rest of the workspace is
    # still worth building. The failure is already logged in red by
    # _vxo_stonefish_build, and colcon will name stonefish_ros2 explicitly.
    _vxo_ros_stonefish || log_warn "continuing without Stonefish; the simulator packages will not build"

    _vxo_ros_rosdep

    # The build's exit status has to be carried out of this function by hand.
    # run_stage calls soft stages as `"$fn" || rc=$?`, and that suspends errexit
    # for everything inside the call — so a non-zero _vxo_ros_build does NOT end
    # vxo_ros2, execution simply falls through to the next line and the function
    # returns that line's status instead. With a bare `rm -f` last, a colcon
    # build that failed was reported as "✓ [ros2] done", checkpointed as
    # complete, and then skipped by --resume: the one stage most likely to fail,
    # recorded as the one that succeeded.
    local build_rc=0
    _vxo_ros_build || build_rc=$?

    # Only on a real build. Clearing the marker after a failure would tell
    # verify_install.sh the workspace was built when it was not.
    ((build_rc == 0)) && rm -f "$VXO_STATE_DIR/ros_build_skipped"

    return "$build_rc"
}
