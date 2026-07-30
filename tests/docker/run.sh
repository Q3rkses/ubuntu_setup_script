#!/usr/bin/env bash
# tests/docker/run.sh: run the installer inside a throwaway Ubuntu container.
#
#   ./tests/docker/run.sh                        # 26.04, vortex profile, ROS (no build)
#   ./tests/docker/run.sh --profile personal
#   ./tests/docker/run.sh --shell                # drop into the container instead
#   ./tests/docker/run.sh --full-ros-build       # include rosdep + colcon (slow)
#
# What this proves: apt sources and package names resolve, the GCC 13 pin takes,
# dotfiles install, the editor/browser/rust stages work, and ROS 2 Lyrical's apt
# setup is correct on a real 26.04 userland.
#
# What it cannot prove: the GNOME stages. There is no session bus in a container,
# so `shortcuts` and `wallpaper` abort by design. Verifying that they abort
# cleanly, and don't take the install down, is part of the point. Test those in
# a VM or on real hardware.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

RELEASE="26.04"
PROFILE="vortex"
EDITOR_CHOICE="nvim"
BROWSER_CHOICE="chrome"
SKIP_ROS_BUILD=1
DROP_TO_SHELL=0
KEEP=0

usage() { sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0; }

while (($# > 0)); do
    case "$1" in
        --release)         RELEASE="${2:?}"; shift 2 ;;
        --profile)         PROFILE="${2:?}"; shift 2 ;;
        --editor)          EDITOR_CHOICE="${2:?}"; shift 2 ;;
        --browser)         BROWSER_CHOICE="${2:?}"; shift 2 ;;
        --full-ros-build)  SKIP_ROS_BUILD=0; shift ;;
        --shell)           DROP_TO_SHELL=1; shift ;;
        --keep)            KEEP=1; shift ;;
        -h|--help)         usage ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

IMAGE="vortex-onboarding-test:${RELEASE}"
CONTAINER="vortex-onboarding-test-${RELEASE//./-}-$$"

echo "==> Building $IMAGE (ubuntu:${RELEASE})"
docker build \
    --build-arg "UBUNTU_RELEASE=${RELEASE}" \
    -t "$IMAGE" \
    -f "$REPO_ROOT/tests/docker/Dockerfile" \
    "$REPO_ROOT/tests/docker"

# The repo is mounted read-only: the installer must never need to write into its
# own checkout. If it does, that's a bug and this will surface it.
DOCKER_ARGS=(
    --name "$CONTAINER"
    --mount "type=bind,source=${REPO_ROOT},target=/home/tester/onboarding,readonly"
    --workdir /home/tester/onboarding
)
((KEEP == 0)) && DOCKER_ARGS+=(--rm)

if ((DROP_TO_SHELL == 1)); then
    echo "==> Shell in $CONTAINER (repo mounted read-only at ~/onboarding)"
    exec docker run -it "${DOCKER_ARGS[@]}" "$IMAGE" /bin/bash
fi

INSTALL_FLAGS=(
    --name "Docker Tester"
    --email "tester@example.com"
    --profile="${PROFILE}"
    --editor="${EDITOR_CHOICE}"
    --browser="${BROWSER_CHOICE}"
    --yes
    # A container has no GitHub SSH key, and mounting the host's private key
    # into one would be a genuinely bad idea. The harness therefore takes the
    # documented HTTPS path: public repos clone, private VortexNTNU ones are
    # expected to fail, and the SSH precondition itself has to be tested on a
    # real machine or a VM.
    --skip-ssh-check
)
[[ "$PROFILE" == "personal" ]] && INSTALL_FLAGS+=(--ros)
((SKIP_ROS_BUILD == 1)) && INSTALL_FLAGS+=(--skip-ros-build)

echo "==> Running: ./install.sh ${INSTALL_FLAGS[*]}"
echo

# The flags are passed as real arguments after the `_` placeholder and consumed
# via "$@", NOT interpolated into the script string. Interpolating splits
# --name "Docker Tester" into two words and the installer rejects "Tester" as an
# unknown option.
set +e
docker run "${DOCKER_ARGS[@]}" "$IMAGE" bash -lc '
    set -uo pipefail
    ./install.sh "$@"
    install_rc=$?
    echo
    echo "================= verify_install.sh ================="
    ./tests/verify_install.sh
    verify_rc=$?
    echo
    echo "install exit=$install_rc  verify exit=$verify_rc"
    exit $(( install_rc != 0 ? install_rc : verify_rc ))
' _ "${INSTALL_FLAGS[@]}"
rc=$?
set -e

echo
if ((rc == 0)); then
    echo "==> PASS (ubuntu ${RELEASE}, ${PROFILE} profile)"
else
    echo "==> FAIL (ubuntu ${RELEASE}, ${PROFILE} profile), exit ${rc}"
    echo "    Reproduce interactively with:"
    echo "      ./tests/docker/run.sh --release ${RELEASE} --profile ${PROFILE} --shell"
fi
exit "$rc"
