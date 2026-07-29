# Changelog

All notable changes to this installer are documented here.
Format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- Initial release of the VortexNTNU / personal Ubuntu onboarding installer.
- `install.sh` orchestrator with a twelve-stage pipeline, per-stage checkpointing
  in `~/.local/state/vortex-onboarding/install_state`, and `--resume` /
  `--only=STAGE` recovery.
- Interactive prompts for name, profile, editor, browser, ROS 2 and, on the
  personal profile, a custom terminal splash image. Every one of them can also
  be supplied as a flag for unattended runs.
- `--dry-run` mode that prints every privileged command without executing it.
- GNOME keyboard shortcuts: workspace switching on `Super+1..4`, move-window-to-
  workspace on `Super+Shift+1..4`, `Super+Return` for Kitty, `Super+Q` to close,
  `Super+R` for the Wofi launcher. A full `dconf` backup is taken before any
  write.
- Managed `.bashrc` and `.bash_aliases` with lazy-loaded NVM and conda, guarded
  ROS 2 and Cargo sourcing, the starship prompt and the `rcd` ranger helper.
- ble.sh for inline autosuggestions from history, with a restrained highlighting
  scheme: command words stay uncoloured, and only errors, strings, variables and
  real directories get a colour.
- Kitty with the Catppuccin Mocha theme, plus fastfetch with a profile-dependent
  splash logo. The Vortex mark for the vortex profile, the GT3 RS sticker for
  personal.
- JetBrainsMono Nerd Font, `fzf`, `ripgrep`, `fd`, `ranger`, `wofi`, `starship`.
- GCC and G++ pinned to 13 via `update-alternatives`.
- Editor choice: Neovim, built from the official release tarball with the
  `Q3rkses/nvimconf` config and a headless `Lazy sync`, or VS Code.
- Browser choice: Chrome, Vivaldi or Firefox, all from the vendor's official apt
  repository, no snaps.
- Desktop wallpaper on the personal profile: a GNOME slideshow of four Porsche
  911 GT3 RS backgrounds, rotating every 30 minutes, registered in Settings →
  Appearance. `--wallpaper=slideshow|static|none`. The vortex profile leaves the
  existing wallpaper untouched.
- Rust via `rustup` on the personal profile.
- ROS 2 Lyrical Luth on Ubuntu 26.04, with the eight Vortex repositories cloned
  into `~/code/ros2_ws/src` and built with `colcon`. `--skip-ros-build` installs
  ROS and clones the workspace but stops before `rosdep` and `colcon`.
- `tests/verify_install.sh` post-install verification suite.
- `tests/docker/` container harness that runs the installer on a real
  `ubuntu:26.04` image.

### Fixed during development
- `require_ubuntu` keyed off `lsb_release`, which isn't installed on minimal
  Ubuntu images, so the installer refused to run on valid systems. It now reads
  `/etc/os-release`.
- A `trap ... RETURN` in the Nerd Font install set a global RETURN trap that
  fired again in the calling function, where `$tmp` no longer existed. Under
  `set -u` that killed the stage. Cleanup is explicit now.
- `--dry-run` checkpointed stages it had only pretended to run, so a later
  `--resume` skipped the whole install.
- Under `set -o pipefail`, `cmd | grep -q` can report failure on a successful
  match when `grep` exits early and the writer takes SIGPIPE. That was breaking
  the package and font checks, which silently defeated idempotency.
- The ROS workspace guard in `.bashrc` used a literal grep that could never
  match the managed file, so ROS was sourced twice on every shell.

### Decisions worth recording
- **Ubuntu 26.04 only, stock GNOME only.** There's deliberately no distro
  detection and no window-manager logic anywhere in this repo.
- **ROS 2 is Lyrical only.** There's no Humble fallback. The stage aborts on its
  own if the host isn't 26.04, leaving the rest of the install intact.
- **GCC 13, pinned explicitly.** "Newest available" isn't reproducible across
  two installs done a month apart.
- **No snaps** for Firefox, VS Code or anything else. Vendor apt repos only, so
  updates never conflict between two package managers.
- **The workspace moved** from `~/vscopium/ros2_ws` to `~/code/ros2_ws`.
