# Container test bed for the onboarding installer.
#
# This proves the parts of the install that don't need a desktop: apt sources,
# package names, the GCC pin, dotfiles, editor, browser repos, rustup, and the
# ROS 2 Humble apt setup. It deliberately cannot test the GNOME stages
# (shortcuts, wallpaper), because there is no session bus in a container. Those
# stages are expected to abort cleanly here. That they abort *cleanly* rather
# than crashing is itself part of what this tests.

ARG UBUNTU_RELEASE=22.04
FROM ubuntu:${UBUNTU_RELEASE}

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8

# Only what's needed to bootstrap: the installer itself pulls the rest, and
# pre-installing its dependencies here would hide bugs where it forgets one.
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
        sudo ca-certificates git locales \
    && rm -rf /var/lib/apt/lists/*

# A non-root user with passwordless sudo. Running the installer as root would be
# unrepresentative: it writes to $HOME, calls sudo explicitly, and the real user
# is never root.
ARG USERNAME=tester
RUN useradd --create-home --shell /bin/bash "${USERNAME}" \
    && echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${USERNAME}" \
    && chmod 0440 "/etc/sudoers.d/${USERNAME}"

USER ${USERNAME}
WORKDIR /home/${USERNAME}/onboarding

CMD ["/bin/bash"]
