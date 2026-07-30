# Changelog

All notable changes to this installer are documented here.
Format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Fixed
- CasADi's bundled OSQP would not configure on Ubuntu 26.04. The release ships
  CMake 4, which dropped compatibility with `cmake_minimum_required(VERSION
  <3.5)`, and OSQP still declares one. The build failed at the
  `osqp-external-configure` step with a bare `CMake Error at CMakeLists.txt:2`.
  Fixed by passing `CMAKE_POLICY_VERSION_MINIMUM=3.5` both as a `-D` flag and in
  the environment, because the solvers are built through `ExternalProject_Add`,
  which spawns its own cmake and forwards only the arguments CasADi chose to
  forward. It is passed with `env` rather than exported, so it is not still in
  effect when colcon runs an hour later.
- A failing step in a soft stage no longer runs the steps after it. `run_stage`
  invokes soft stages as `"$fn" || rc=$?`, which suspends `errexit` for the
  entire call tree, so a failed CasADi build went on to run the plugin verifier
  and reported a misleading "will not compile" on top of the real error.
- Removed every `die` from the `cxx-libs` stage. `die` calls `exit`, so from a
  soft stage it would have taken down the whole installer, which is the exact
  opposite of what "soft" promises.

### Changed
- The `git-ssh` stage is now `git-config` and does only git identity. It is a
  hard stage: with SSH checked up front there is nothing left in it that can
  reasonably fail.

### Added
- **GitHub SSH is now a hard precondition.** The installer verifies
  `ssh -T git@github.com` before the first stage runs and exits if it fails,
  having changed nothing. It no longer generates keys, walks you through
  GitHub's settings pages, or silently falls back to HTTPS: the old behaviour
  produced a half-empty workspace and a colcon failure an hour later that looked
  nothing like a missing key. The failure message links GitHub's own guide.
  `--skip-ssh-check` exists for automated testing and nothing else.
- **`cxx-libs` stage: Eigen and CasADi.** Eigen from apt (`libeigen3-dev`),
  deliberately not from source, because a second Eigen under `/usr/local`
  shadows the one every ROS 2 package was compiled against. CasADi built from
  source and pinned in `lib/cxxlibs.sh`, because the apt package ships without
  SUNDIALS (`cvodes`, `idas`), OSQP and qpOASES, and code asking for those
  compiles fine and fails at runtime. The build enables IPOPT plus CasADi's
  bundled SUNDIALS, OSQP and qpOASES, then compiles and runs a program that
  loads all three plugins before the stage counts as done.
- **Neovim becomes the system-wide default editor** when it is the chosen
  editor. "Default editor" is four separate mechanisms on Ubuntu and setting
  only one is why nano keeps reappearing, so all four are covered:
  `$EDITOR`/`$VISUAL`/`$SUDO_EDITOR` (written to `env.sh`),
  `update-alternatives editor` at priority 200 and pinned with `--set`,
  `git core.editor` *and* `sequence.editor` (git prefers these over `$EDITOR`,
  and `rebase -i` uses the latter), and `xdg-mime` associations for 19 text
  types so files open in Neovim from the file manager. The VS Code choice sets
  no environment variables: `code` returns instantly without `--wait`, which
  makes git treat a commit message as empty.
- `env.sh` is now hooked into `~/.profile` as well as `~/.bashrc`, so `$EDITOR`
  is set for login shells and for GUI applications launched from the GNOME
  session, not only for interactive terminals. A `~/.bash_profile`, if one
  exists, gets its own copy, because bash reads it instead of `~/.profile`.
- **YASMIN** for ROS 2: `yasmin`, `yasmin-ros` and `yasmin-viewer` from the ROS
  apt index. A package not yet released for Lyrical is a warning, not a failure.
- Initial release of the VortexNTNU / personal Ubuntu onboarding installer.
- `install.sh` orchestrator with a thirteen-stage pipeline, per-stage checkpointing
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
