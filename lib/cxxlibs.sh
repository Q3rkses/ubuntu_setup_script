#!/usr/bin/env bash
# lib/cxxlibs.sh: the C++ maths libraries, Eigen and CasADi.
#
# Sourced by install.sh. Provides: vxo_cxx_libs.
#
# The two are handled differently on purpose.
#
# EIGEN comes from apt. It is header-only, 3.4.0 is the current stable release,
# and it is the exact build every ROS 2 package in the archive was compiled
# against. Installing a second Eigen into /usr/local is actively harmful: CMake
# finds it first, half your ROS packages then compile against one Eigen while
# their dependencies were built against another, and the resulting ODR
# violations show up as inexplicable segfaults instead of build errors.
#
# CASADI is built from source. The apt package (libcasadi-dev 3.7.0+ds2) works
# and even carries IPOPT, but Debian strips the vendored solvers, so it ships
# without SUNDIALS (no cvodes, no idas), without OSQP and without qpOASES. Code
# that asks for one of those compiles fine and then dies at RUNTIME with a
# "plugin not found" error, which is a miserable thing to debug an hour into a
# mission test. Building from source with the bundled solvers enabled avoids the
# whole class of problem.
#
# RELATIONSHIP TO vortex-auv/scripts/install_casadi.sh. That script is the
# reference for WHICH CasADi to build, and this module now pins the same commit
# it does, asserted by SHA rather than by tag so a retagged release cannot move
# under us. The version is identical: refs/tags/3.7.2 resolves to exactly
# f959d31, the commit that script checks out.
#
# It deliberately diverges on ONE axis. install_casadi.sh passes WITH_IPOPT=OFF,
# WITH_OSQP=OFF, WITH_SUNDIALS=OFF and WITH_QPOASES=OFF, which is the right call
# for a CI image that only needs CasADi to link. On a development machine it is
# the wrong default, for the reason spelled out above: the plugins are resolved
# lazily at runtime, so asking for cvodes or osqp compiles cleanly and then dies
# in the middle of a mission test. This module turns all four ON and then
# compiles and *runs* a program that loads them, so a missing plugin fails here
# instead of an hour later. The apt dependency list is the script's, extended
# with what the enabled solvers additionally need.
#
# This is why the stage is soft: the build is long and is the most likely thing
# in the whole installer to fail on an odd machine. When it does, you keep your
# dotfiles, your editor and your shell. Re-run it on its own with:
#   ./install.sh --only=cxx-libs

[[ -n "${_VXO_CXXLIBS_SOURCED:-}" ]] && return 0
_VXO_CXXLIBS_SOURCED=1

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# The one place the CasADi version is written down. Bump deliberately: everyone
# who runs the installer after you gets this exact release.
VXO_CASADI_VERSION="3.7.2"

# The commit refs/tags/3.7.2 points at, and the exact commit
# vortex-auv/scripts/install_casadi.sh checks out. Asserted after checkout: a
# tag is a movable ref, so matching the tag alone would not actually guarantee
# everyone builds the same source.
VXO_CASADI_COMMIT="f959d3175a444d763e4eda4aece48f4c5f4a6f90"

VXO_CASADI_REPO="https://github.com/casadi/casadi.git"
VXO_CASADI_PREFIX="/usr/local"
VXO_CASADI_SRC="${XDG_CACHE_HOME:-$HOME/.cache}/vortex-onboarding/casadi"

# Written after a successful install so a re-run is a fast no-op rather than
# another twenty minutes of compiling. Records the version, so bumping
# VXO_CASADI_VERSION above correctly triggers a rebuild.
VXO_CASADI_STAMP="$VXO_STATE_DIR/casadi_built_version"

# Build dependencies. IPOPT and its MUMPS linear solver come from apt because
# they are large, stable, and packaged properly. SUNDIALS, OSQP and qpOASES are
# built from CasADi's own bundled copies instead: CasADi pins versions it is
# tested against, and mixing a system SUNDIALS with CasADi's expectations is a
# known source of build failures.
# The first block is vortex-auv/scripts/install_casadi.sh's list verbatim, so a
# machine set up here can build what CI builds. The second block is what the
# solvers this module additionally enables need, and is the only reason the two
# lists differ.
VXO_CASADI_BUILD_DEPS=(
    build-essential
    cmake
    git
    pkg-config
    libblas-dev
    liblapack-dev
    libopenblas-dev
    libgfortran5
    libeigen3-dev
    libboost-dev

    # For WITH_IPOPT: IPOPT itself, its MUMPS linear solver, and the Fortran
    # compiler SUNDIALS and MUMPS both want.
    gfortran
    coinor-libipopt-dev
    libmumps-seq-dev
)

vxo_cxx_libs() {
    _vxo_install_eigen
    _vxo_install_casadi
}

# ─────────────────────────── eigen ───────────────────────────

_vxo_install_eigen() {
    apt_update_once
    apt_install libeigen3-dev

    if [[ "${VXO_DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] would verify the Eigen headers"
        return 0
    fi

    local hdr=/usr/include/eigen3/Eigen/src/Core/util/Macros.h
    if [[ ! -f "$hdr" ]]; then
        log_warn "libeigen3-dev is installed but $hdr is missing"
        return 0
    fi

    local w m p
    w="$(awk '/define EIGEN_WORLD_VERSION/ {print $3}' "$hdr")"
    m="$(awk '/define EIGEN_MAJOR_VERSION/ {print $3}' "$hdr")"
    p="$(awk '/define EIGEN_MINOR_VERSION/ {print $3}' "$hdr")"
    log_ok "Eigen ${w}.${m}.${p} at /usr/include/eigen3 (CMake: find_package(Eigen3))"

    # A source-installed Eigen in /usr/local wins the CMake search and silently
    # replaces the one ROS was built against. Worth saying out loud, because the
    # symptom (random segfaults in unrelated packages) never points here.
    if [[ -d "$VXO_CASADI_PREFIX/include/eigen3" ]]; then
        log_warn "A second Eigen exists at $VXO_CASADI_PREFIX/include/eigen3."
        log_warn "It shadows the apt one and can break ROS 2 builds in confusing ways."
        log_warn "Remove it unless you know you need it: sudo rm -rf $VXO_CASADI_PREFIX/include/eigen3"
    fi
}

# ─────────────────────────── casadi ───────────────────────────

_vxo_install_casadi() {
    if _vxo_casadi_current; then
        log_skip "CasADi $VXO_CASADI_VERSION already built and installed"
        return 0
    fi

    _vxo_casadi_warn_apt_copy

    if [[ "${VXO_DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] would build CasADi $VXO_CASADI_VERSION from source"
        log_info "[dry-run]   with IPOPT, SUNDIALS (cvodes/idas), OSQP and qpOASES"
        log_info "[dry-run]   into $VXO_CASADI_PREFIX"
        return 0
    fi

    apt_update_once
    apt_install "${VXO_CASADI_BUILD_DEPS[@]}"

    # Explicit `|| return`, and no `die` anywhere below this point. Two traps
    # here, both of which bit during development:
    #
    #  1. This is a SOFT stage, and run_stage invokes soft stages as
    #     `"$fn" || rc=$?`. That suspends errexit for the whole call tree, so a
    #     failing step does not stop the ones after it unless it is checked.
    #     Without these, a failed build ran the verifier anyway and reported a
    #     confusing "will not compile" on top of the real error.
    #  2. `die` calls exit, which from a soft stage takes down the entire
    #     installer, costing the user every stage after this one. A build
    #     failure here must cost nothing but this stage.
    _vxo_casadi_fetch || return 1
    _vxo_casadi_build || return 1
    _vxo_casadi_verify || return 1
}

# True when the installed CasADi is already the pinned version.
_vxo_casadi_current() {
    [[ "${VXO_DRY_RUN:-0}" == "1" ]] && return 1
    [[ -f "$VXO_CASADI_STAMP" ]] || return 1
    [[ "$(cat "$VXO_CASADI_STAMP" 2>/dev/null)" == "$VXO_CASADI_VERSION" ]] || return 1
    # The stamp is only trustworthy while the library it describes is still there.
    [[ -f "$VXO_CASADI_PREFIX/lib/libcasadi.so" ]]
}

# The apt package installs to /usr/lib/<triplet>, ours to /usr/local/lib. Both
# can be present at once, and which one a build picks up comes down to CMake
# search order. Warn rather than remove: apt packages that depend on
# libcasadi-dev would be uninstalled along with it.
_vxo_casadi_warn_apt_copy() {
    if pkg_installed libcasadi-dev; then
        log_warn "The apt package libcasadi-dev is installed and lacks SUNDIALS and OSQP."
        log_warn "It can shadow the source build. Remove it once nothing else needs it:"
        log_warn "  sudo apt remove libcasadi-dev"
    fi
}

_vxo_casadi_fetch() {
    log_info "fetching CasADi $VXO_CASADI_VERSION"
    run mkdir -p "$(dirname "$VXO_CASADI_SRC")"

    # Tags are immutable, so an existing checkout at the right tag needs no
    # network at all. git_sync is not used here: it tracks branches, and this
    # deliberately pins a tag.
    if [[ -d "$VXO_CASADI_SRC/.git" ]]; then
        run git -C "$VXO_CASADI_SRC" fetch --quiet --tags --depth 1 origin "$VXO_CASADI_VERSION" \
            || log_warn "could not refresh tags, using the existing checkout"
    else
        if ! run git clone --quiet --depth 1 --branch "$VXO_CASADI_VERSION" \
                "$VXO_CASADI_REPO" "$VXO_CASADI_SRC"; then
            log_error "could not clone CasADi $VXO_CASADI_VERSION from $VXO_CASADI_REPO"
            return 1
        fi
    fi

    if ! run git -C "$VXO_CASADI_SRC" checkout --quiet "$VXO_CASADI_VERSION"; then
        log_error "CasADi tag $VXO_CASADI_VERSION not found in the checkout"
        return 1
    fi

    # Tags are movable refs. Verifying the SHA is what actually makes this a pin,
    # and is what keeps this module and vortex-auv's install_casadi.sh building
    # provably identical source.
    local head
    head="$(git -C "$VXO_CASADI_SRC" rev-parse HEAD 2>/dev/null || true)"
    if [[ "$head" != "$VXO_CASADI_COMMIT" ]]; then
        log_error "CasADi tag $VXO_CASADI_VERSION resolves to ${head:-nothing}, expected $VXO_CASADI_COMMIT."
        log_error "The upstream tag has moved. Verify the new commit and update"
        log_error "VXO_CASADI_COMMIT in lib/cxxlibs.sh deliberately, rather than around this check."
        return 1
    fi
    log_ok "CasADi source pinned at $VXO_CASADI_COMMIT (tag $VXO_CASADI_VERSION)"

    # SUNDIALS, OSQP and qpOASES live in external_packages as submodules. Without
    # this the WITH_BUILD_* flags below silently produce a CasADi with exactly
    # the plugins we are building from source to get.
    log_info "fetching bundled solvers (SUNDIALS, OSQP, qpOASES)"
    run git -C "$VXO_CASADI_SRC" submodule update --init --recursive --depth 1 \
        || log_warn "submodule checkout reported a problem; some solvers may be missing"
}

_vxo_casadi_build() {
    local build="$VXO_CASADI_SRC/build"
    local jobs; jobs="$(_vxo_build_jobs)"
    local log="$VXO_LOG_DIR/casadi-build.log"

    log_info "building CasADi with $jobs parallel jobs (10 to 20 minutes)"
    log_info "  live log: $log"

    run rm -rf "$build"
    run mkdir -p "$build"

    # Ubuntu 26.04 ships CMake 4, which removed compatibility with
    # cmake_minimum_required(VERSION <3.5). The bundled OSQP still declares one,
    # so the build dies at the osqp-external configure step with a bare
    # "CMake Error at CMakeLists.txt:2".
    #
    # This has to be BOTH a -D flag and an environment variable. The solvers are
    # built through ExternalProject_Add, which spawns a fresh cmake for each one
    # and forwards only the arguments CasADi chose to forward. The -D covers the
    # top-level project, the environment reaches the children.
    #
    # Passed with `env` rather than exported: an export would still be set when
    # the ROS 2 stage runs colcon an hour later, quietly relaxing the policy
    # check for every package in the workspace. Scope it to the two commands
    # that actually need it.
    local policy=(env CMAKE_POLICY_VERSION_MINIMUM=3.5)

    # WITH_<solver> enables the plugin; WITH_BUILD_<solver> tells CasADi to
    # compile its bundled copy rather than look for a system one.
    if ! run "${policy[@]}" cmake -S "$VXO_CASADI_SRC" -B "$build" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$VXO_CASADI_PREFIX" \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DWITH_IPOPT=ON \
        -DWITH_SUNDIALS=ON -DWITH_BUILD_SUNDIALS=ON \
        -DWITH_OSQP=ON -DWITH_BUILD_OSQP=ON \
        -DWITH_QPOASES=ON -DWITH_BUILD_QPOASES=ON \
        -DWITH_LAPACK=ON \
        -DWITH_PYTHON=OFF \
        -DWITH_EXAMPLES=OFF; then
        log_error "CasADi cmake configuration failed. Full output: $VXO_LOG_FILE"
        return 1
    fi

    # The ExternalProject solvers are configured during the BUILD step, not the
    # configure step, so the policy override is needed here too.
    set +e
    "${policy[@]}" cmake --build "$build" --parallel "$jobs" 2>&1 | tee "$log"
    local rc=${PIPESTATUS[0]}
    set -e

    if ((rc != 0)); then
        log_error "CasADi build failed (exit $rc). Last 30 lines:"
        tail -n 30 "$log" >&2 || true
        log_error "Full build log: $log"
        log_error "Re-run just this stage with: ./install.sh --only=cxx-libs"
        return "$rc"
    fi

    if ! run sudo cmake --install "$build"; then
        log_error "CasADi install into $VXO_CASADI_PREFIX failed"
        return 1
    fi
    run sudo ldconfig
}

# Compilers are memory hungry. One job per core is right on a workstation and a
# reliable way to invoke the OOM killer on an 8 GB laptop with 16 threads, so cap
# by available memory at roughly 1 GB per job.
_vxo_build_jobs() {
    local cores mem_gb jobs
    cores="$(nproc 2>/dev/null || echo 2)"
    mem_gb="$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 4)"
    ((mem_gb < 1)) && mem_gb=1
    jobs="$cores"
    ((jobs > mem_gb)) && jobs="$mem_gb"
    ((jobs < 1)) && jobs=1
    printf '%s' "$jobs"
}

# Compile and run a real program. The plugins are loaded lazily at runtime, so
# "it linked" proves nothing about whether cvodes and osqp are actually there.
_vxo_casadi_verify() {
    local tmp; tmp="$(mktemp -d)"

    cat >"$tmp/check.cpp" <<'EOF'
#include <casadi/casadi.hpp>
#include <Eigen/Dense>
#include <iostream>
int main() {
    casadi::SX x = casadi::SX::sym("x", 2);
    casadi::SXDict nlp{{"x", x}, {"f", pow(x(0) - 1, 2) + pow(x(1) - 2, 2)}};
    casadi::nlpsol("s", "ipopt", nlp);
    casadi::SX t = casadi::SX::sym("t");
    casadi::integrator("i", "cvodes", casadi::SXDict{{"x", t}, {"ode", -t}}, 0, 1);
    casadi::conic("q", "osqp", casadi::SpDict{{"h", casadi::Sparsity::dense(1, 1)}});
    Eigen::Matrix2d m;
    m << 1, 2, 3, 4;
    if (m.determinant() != -2) return 1;
    std::cout << casadi::CasadiMeta::version() << std::endl;
    return 0;
}
EOF

    log_info "verifying CasADi plugins (ipopt, cvodes, osqp) and Eigen"

    local out rc=0
    if ! g++ -std=c++17 "$tmp/check.cpp" \
            -I"$VXO_CASADI_PREFIX/include" -I/usr/include/eigen3 \
            -L"$VXO_CASADI_PREFIX/lib" -lcasadi \
            -o "$tmp/check" 2>>"$VXO_LOG_FILE"; then
        rm -rf "$tmp"
        log_error "CasADi installed but a test program will not compile. See $VXO_LOG_FILE"
        return 1
    fi

    # libmumps-seq-dev, despite the name, links libscalapack-openmpi, so
    # constructing the ipopt solver above pulls in a full Open MPI runtime.
    # Open MPI's hwloc dependency has a GPU-topology backend ("gl") that probes
    # the X server's NV-CONTROL extension whenever DISPLAY is set, and on a
    # GNOME/Xwayland session that connect() can block forever instead of
    # erroring out — hanging this check (and any real program that constructs
    # an ipopt solver) with no output and no timeout. HWLOC_COMPONENTS=-gl
    # disables that backend; nothing here uses GPU topology.
    out="$(HWLOC_COMPONENTS=-gl timeout 60 "$tmp/check" 2>&1)" || rc=$?
    rm -rf "$tmp"

    if ((rc == 124)); then
        log_error "CasADi's ipopt solver hung for 60s instead of returning (rc=124)."
        log_error "This usually means HWLOC_COMPONENTS=-gl above did not take effect."
        return 1
    fi

    if ((rc != 0)); then
        log_error "CasADi is installed but the plugin check failed:"
        printf '%s\n' "$out" >&2
        return 1
    fi

    printf '%s\n' "$VXO_CASADI_VERSION" >"$VXO_CASADI_STAMP"
    log_ok "CasADi $(printf '%s' "$out" | tail -1) installed to $VXO_CASADI_PREFIX"
    log_ok "plugins verified: ipopt, cvodes, osqp"
}
