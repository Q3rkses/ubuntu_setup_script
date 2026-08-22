# Changelog

All notable changes to this installer are documented here.
Format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed
- **Back to Ubuntu 22.04 and ROS 2 Humble Hawksbill.** The Lyrical Luth / 26.04
  migration is reverted. Lyrical support is not mature enough to put on the
  machines people do mission work on this year — too much of the stack around it
  (drivers, vendor packages, our own dependencies) is still catching up — so the
  installer targets the battle-tested Humble/22.04 pair instead. This is a
  deliberate step back, to be revisited when the newer stack has settled; the
  26.04 entries below stay as they are because they accurately describe the
  releases they were written for.

  `require_ubuntu` now accepts `22.04` and nothing else, the ROS stage installs
  `ros-humble-*` from the ROS 2 apt index (`ros2-apt-source` publishes a jammy
  build, so the codename-derived URL is unchanged), and `.bashrc` sources
  `/opt/ros/humble/setup.bash`.

  What that costs, concretely, and what had to change to make it honest:

  * **GCC is pinned to 12, not 13.** There is no `gcc-13` in the jammy archive
    at all. 12 (12.3.0-1ubuntu1~22.04.3) is the newest it has, jammy's own
    `libstdc++6` comes from that same source package, and it is ABI-compatible
    with the gcc-11-built ROS Humble binaries. `VXO_GCC_VERSION=11` is the
    one-line conservative alternative if a machine ever disagrees: 11 is jammy's
    default and the exact compiler the Humble binaries were built with.
  * **Node.js now comes from NodeSource.** Jammy's `nodejs` is 12.22.9, and
    mason installs bash-language-server, prettier and lemminx as npm packages
    that all require Node >= 18. On a stock 22.04 those installs fail inside
    mason and the language server simply never attaches — the silent failure the
    editor stage has always warned about, except here it happened every time.
    The `editor` stage adds NodeSource's repo (keyring in `/etc/apt/keyrings`,
    `signed-by=`, no `apt-key`) and installs Node 20 LTS from it, guarded so a
    node already >= 18 is left alone and a dry run touches no network. `npm` is
    gone from the dependency list: NodeSource's `nodejs` bundles its own, and the
    archive `npm` depends on the archive `nodejs`, so asking for it would drag
    Node 12 straight back in. If the repo cannot be reached the stage falls back
    to the archive pair with a warning that says which servers will break.
  * **Rounded corners is a different extension on GNOME 42.** 22.04 ships GNOME
    Shell 42, and the Reborn fork (`rounded-window-corners@fxgn`) supports 46+
    only. The stage now picks `rounded-window-corners@yilozt` (40-44) below
    GNOME 46 and Reborn at or above it, and writes each variant's own dconf
    layout — the fork renamed the path, the radius key (`borderRadius` vs
    `border_radius`), the keep-when-maximised key, and moved the border colour
    from a member of the settings dict to a separate top-level `(dddd)` key.
    Writing a member a schema does not declare is stored and then ignored, which
    is a silently inert extension, so each branch stays faithful to its schema.
  * **`ros-humble-yasmin-viewer` does not exist.** `yasmin` and `yasmin-ros` are
    both released for Humble; the web viewer never was. It stays in the package
    list, where the existing "not released for this distro" path degrades it to
    an accurate warning, and the verifier reports it as SKIP instead of failing
    a check nobody can fix. Build it in `~/code/ros2_ws/src` if you need it.
  * **fastfetch, lazygit and Neovim are always upstream now.** None of the three
    is usable from the 22.04 archive (fastfetch and lazygit are absent, neovim is
    0.6.1 and cannot load the config), so the fallback paths those stages already
    carried are the normal paths on this release rather than the exception.

- **Ulauncher replaces wofi as the application launcher, on `Super+F`.** This
  matches the reference machine, where wofi on `Super+R` had already been
  replaced by hand. Ulauncher is not in the Ubuntu archive, so the
  `base-packages` stage adds `ppa:agornostal/ulauncher` — the only PPA this
  installer uses — and degrades to a warning rather than failing the stage if
  Launchpad has no build for the release.

  Three parts have to ship together or the launcher looks broken:

  * `~/.config/ulauncher/settings.json`, seeded before first launch because
    ulauncher rewrites the file on exit.
  * `~/.config/autostart/ulauncher.desktop`, because `ulauncher-toggle` only
    talks to an already-running daemon. Its `Exec` line forces
    `GDK_BACKEND=x11`: ulauncher's window is an override-redirect popup that
    Wayland gives a client no way to position, so the native-Wayland process
    starts and then never appears.
  * the `Super+F` custom keybinding.

  The `shortcuts` stage now also retires superseded launcher bindings: the old
  `wofi-drun` entry on `Super+R`, and any hand-made `ulauncher-toggle` binding
  sitting at a generic slug like `custom0`. Two custom bindings on `<Super>f`
  make GNOME pick one at random, so leaving the hand-made one in place was worse
  than replacing it. `dotfiles/wofi-drun` and `dotfiles/wofi-config/` are gone.

- **The desktop theme is now a question, not a hardcoded value.**
  `--theme=dark-magenta|dark-pink|light`, asked alongside editor and browser and
  recorded in `env.sh` so the verifier checks the theme you actually chose.
  `dark-magenta` is the previous behaviour and stays the default; `light` exists
  because not everyone wants a dark desktop.

- **Input sources lead with English (US) instead of Norwegian.** The first entry
  in the list is the layout you get at the login screen, and every code sample,
  installer prompt and piece of documentation assumes a US layout. Norwegian and
  Japanese are still in the switcher, just not first.

- **The editor stage installs the full prerequisite set from nvimconf's README**,
  not the subset it had been carrying: `fzf`, `python3-full`, `imagemagick`,
  `ghostscript`, `wl-clipboard`, `xclip` and `xdg-utils` join the existing
  node/npm/ripgrep/fd/gdu/lazygit set, each with a note on what breaks without
  it. It also links `fdfind` to `~/.local/bin/fd` — Ubuntu renames the binary to
  avoid a clash, and every fd-aware nvim plugin looks for `fd` and silently
  falls back when it is missing — and warns up front if an interpreter mason
  needs is absent, rather than letting that surface much later as "the language
  server does not attach".

### Fixed
- **The ROS workspace could never build: `vortex_filtering` was never cloned.**
  `ekf_pose_filtering`, `pose_filtering` and `line_filtering` inside vortex-auv
  all `find_package(vortex_filtering)`, and no repository in `VXO_ROS_REPOS`
  provided it. rosdep reported "Cannot locate rosdep definition for
  [vortex_filtering]", colcon then failed at the first of the three and aborted
  the six packages queued behind it. The package ships in `vortexntnu/vortex-vkf`
  — the repository name does not contain the package name, which is why it was
  easy to miss — and vortex-auv's own `dependencies.repos` lists it for exactly
  this reason. It is now cloned with the rest.
- **A compiler segfault in one test file took the whole workspace build down.**
  colcon builds test targets by default, and `vortex_filtering`'s `ukf_test.cpp`
  instantiates the UKF templates in a way that crashes the compiler outright:
  "internal compiler error: Segmentation fault" at `ukf.hpp:252`, on gcc-11 and
  gcc-12 alike, so this is an upstream template bug rather than something the
  toolchain pin can dodge. It burned three and a half minutes before failing,
  took `vortex_filtering` with it, and aborted every package queued behind it —
  including the ones that only needed its library. The workspace build now
  passes `-DBUILD_TESTING=OFF`, with which the same package builds in about six
  seconds and exports the `vortex_filteringConfig.cmake` that
  `ekf_pose_filtering`, `pose_filtering` and `line_filtering` look for. An
  onboarding install owes the user a working workspace, not a test run; anyone
  who wants the tests can build them deliberately and meet the ICE where it
  makes sense to meet it.
- **The Stonefish library was never installed, so the whole simulator set failed
  to build.** `stonefish_ros2` does `find_package(Stonefish REQUIRED 1.5.0)`.
  Stonefish is a plain C++ library, not a ROS package: it is not in the ROS apt
  index, rosdep has no key for it, and nothing in the workspace pulls it in — so
  colcon failed at `stonefish_ros2` with "Could not find a package configuration
  file provided by Stonefish", which then aborted everything queued behind it.
  The ROS stage now builds it from `vortexntnu/stonefish` (the fork
  stonefish_ros2 is developed against, not patrykcieslak's upstream) and installs
  it into `/usr/local` before rosdep and colcon run. It is tracked by branch
  rather than pinned to a commit, unlike CasADi — the reasoning is written out at
  `VXO_STONEFISH_REPO`. A failure here is a warning, not a stage failure: it
  costs the simulator packages and nothing else.
- **One unresolvable rosdep key meant NO dependencies were installed.**
  `rosdep install` resolves every `package.xml` in the tree before it installs
  anything, so a single key it cannot map aborts the run and installs nothing —
  not even the dependencies it did resolve. stim300-driver's `feature/ros2-port`
  branch builds with `ament_cmake` but still declares ROS 1's `roscpp`, a key
  that cannot resolve in any ROS 2 distro, so rosdep bailed every time and the
  workspace was built against whatever happened to be on the machine. The
  failure surfaced much later and looked unrelated: colcon died in
  `vortex_filtering` on `find_package(Gnuplot REQUIRED)`, whose gnuplot and
  Boost keys rosdep would have installed. Known-unresolvable keys now go in
  `VXO_ROS_ROSDEP_SKIP_KEYS` and are passed as `--skip-keys`, each with a
  comment saying which upstream package.xml is wrong and why.
- **A failed colcon build was recorded as a successful stage.** `run_stage` calls
  soft stages as `"$fn" || rc=$?`, which suspends errexit for everything inside
  the call, so a non-zero `_vxo_ros_build` did not end `vxo_ros2`: execution fell
  through to the trailing `rm -f` and the function returned *that* command's
  status. The result was a red "✗ colcon build failed" immediately followed by
  "✓ [ros2] done" and "All applicable stages complete", the stage checkpointed,
  and `--resume` skipping the one stage most likely to need a retry. The build's
  status is now captured and returned, and the `ros_build_skipped` marker is
  cleared only after a build that actually succeeded.
- **The GNOME extension install could hand you an extension that cannot load.**
  `extension-info/?uuid=...&shell_version=N` accepts `shell_version` and then
  ignores it: asking for GNOME 42 still returns a top-level `download_url` for
  the newest build, whose `shell_version_map` may be `['46', ..., '50']`. The
  module's central claim — that it asks the API which release matches *this*
  shell — was false as implemented, and the result unpacked, enabled and
  reported success while the shell refused to load it. The version match is now
  made locally: read `.shell_version_map`, look up this shell's major, and build
  the download URL from that entry's `pk`. No entry means no build, and the
  extension is skipped with a warning that names the shell versions upstream does
  publish, so a version mismatch cannot be mistaken for a network failure.

  The field is `pk`, not `version_tag`. `shell_version_map` entries carry exactly
  `{"pk": N, "version": M}` — there is no `version_tag` member, even though the
  download endpoint spells its query parameter that way and wants the `pk` as its
  value. Reading `.version_tag` returns empty for every extension, which would
  have made the new check skip all of them and install nothing at all.
- **The magenta accent colour was never actually applied.**
  `org.gnome.desktop.interface accent-color` is an enum, and on Ubuntu 26.04 its
  members are blue, teal, green, yellow, orange, red, pink, purple, slate and
  brown. There is no `magenta`. gsettings rejected the write, the installer
  logged a warning nobody read, and the desktop kept whatever accent it already
  had. Ubuntu's magenta is exposed upstream as `pink`, so that is what gets
  written now; the `Yaru-magenta*` GTK and icon variants still carry the magenta
  tint for GTK3 apps.
- **The icon theme and the GTK theme disagreed on light vs dark.** `icon-theme`
  was pinned to `Yaru-magenta` while `gtk-theme` was `Yaru-magenta-dark`. Both
  now come from the same theme table entry, so they cannot drift apart again.

### Added
- **A lock screen extension that exists on GNOME 42.** `lockscreen-studio@pedro.projects`
  publishes builds for GNOME 45 and up only, so on 22.04 it was skipped and the
  release shipped with no lock screen extension at all. The lock screen slot is
  now resolved by shell major the same way rounded corners already was: 45+ keeps
  Lockscreen Studio, anything older gets `blur-my-shell@aunetx`, whose metadata
  covers 3.36 through 50 and whose `lockscreen` component is the part that
  matters here. Blur my Shell blurs the panel, overview, app grid and application
  windows out of the box; the stage writes its `lockscreen` settings and turns
  every other component off, because the desktop stage owns how the desktop
  looks and a live blur behind every window is not free on a laptop GPU.
- **Extension Manager and GNOME Tweaks are verified, not just installed.**
  Both were already in the apps stage's package set; `tests/verify_install.sh`
  now checks for them on a GNOME session. Note the binary that
  `gnome-shell-extension-manager` installs is `extension-manager` — checking for
  `gnome-extensions-manager` by hand comes back empty on a machine that has it.
- **Brave as a browser choice.** `--browser=brave`, alongside chrome, vivaldi
  and firefox, installed from Brave's own apt repo with the vendor keyring in
  `/etc/apt/keyrings` and the architecture taken from `dpkg --print-architecture`
  rather than hardcoded. The dock favourite and the post-install verifier know
  about it too.
- **GNOME monospace font is set to the Nerd Font.** kitty asked for
  JetBrainsMono Nerd Font directly, but `org.gnome.desktop.interface
  monospace-font-name` was left at Ubuntu Mono, so the starship prompt lost every
  icon the moment it ran in GNOME Terminal, Text Editor or anything else reading
  that key. The `desktop` stage now sets it, and only when the font is actually
  on disk, since pointing the key at a missing family hands every monospace app
  a font fontconfig picked at random.
- **The editor stage installs the tools the nvim config actually calls.**
  lazygit, plus gdu, alongside the existing node/npm/ripgrep/fd set. mason
  builds the language servers itself, so that side was already covered, but
  nvimconf enables the snacks lazygit picker and AstroNvim binds `<Leader>gg`
  and `<Leader>tl` to it, and none of that worked without the binary. lazygit is
  not in every Ubuntu archive, so it tries apt first and falls back to the
  upstream release tarball, the same shape as the fastfetch fallback.
- **`boot-splash` stage.** The boot logo is now your terminal splash image
  instead of the manufacturer badge. Ubuntu defaults to the `bgrt` Plymouth
  theme, whose entire purpose is to keep displaying the vendor logo the firmware
  parked in the ACPI BGRT table, which is why a stock install shows a Dell or
  Lenovo mark. This installs a sibling theme with the same spinner,
  `UseFirmwareBackground=false`, and your image as the watermark, then repoints
  the `default.plymouth` alternative and rebuilds the initramfs. The theme gets
  its own image directory rather than reusing the spinner's, because sharing it
  would mean overwriting a file owned by `plymouth-theme-spinner` that apt would
  restore on the next upgrade. Disable with `--no-boot-splash`. The logo the
  firmware itself draws before GRUB belongs to the UEFI and is out of reach from
  Linux; this covers everything from Plymouth onward.
- **`desktop` stage.** Reproduces the GNOME state a reinstall used to discard:
  dark mode and accent colour, the Norwegian/US/Japanese input sources, touchpad
  natural scrolling and pointer speeds, no auto-maximise, no centre-on-open,
  fractional scaling, dock position, and dock favourites derived from the
  choices made during the install. Keybindings were previously the only desktop
  state that survived a reinstall. Every write is guarded, so a key this GNOME
  release does not have is skipped with a note rather than failing the stage.
- **`gnome-extensions` stage.** Installs Rounded Window Corners Reborn and sets
  every window to a 6px radius, configurable with `--rounded-radius=N`. It asks
  extensions.gnome.org which release matches the running shell, compiles the
  schemas, and enables the extension by writing `enabled-extensions` rather than
  calling `gnome-extensions enable`, which cannot work under Wayland because the
  running shell has not scanned the new directory yet. The extension's default
  of skipping libadwaita apps is turned off, so GTK4 windows get the same radius
  as everything else instead of keeping their own 12px.
- **`apps` stage.** clangd, clang-format, clang-tidy, doxygen, lcov, shellcheck,
  shfmt, btop, tmux, imagemagick, gnome-tweaks, gnome-shell-extension-manager,
  fonts-firacode, ibus-mozc, and Docker from Docker's own apt repo with the user
  added to the `docker` group. All apt, no snap and no flatpak: a third
  packaging system means a third updater and a sandbox to fight. `ibus-mozc`
  ships here rather than in `desktop` because configuring the Japanese input
  source without the engine gives a list entry that silently never appears.
- `Super+S` now opens the screenshot UI, and the conflicting `toggle-overview`
  binding is cleared so the two do not both claim it.
- ROS 2 now installs the flake8 and pytest plugin set that `ament_flake8` and
  `ament_pytest` load by name, plus numpy, scipy, matplotlib and pyserial.
  Without the plugins a local lint passes and vortex-ci then fails on the same
  code. Installed as a filtered batch so one renamed package cannot fail the
  whole transaction and take ROS down with it.

### Fixed
- **The verifier now checks that starship and the Nerd Font actually work,**
  not merely that they are present. It renders a real prompt through
  `~/.config/starship.toml` and fails on a parse complaint or an empty result,
  confirms `~/.bashrc` initialises starship, and asks fontconfig for three
  specific codepoints (the plane-15 user icon, the git branch glyph and a
  powerline separator) so a font merely *named* "Nerd Font" cannot pass. The
  bashrc check matches the command loosely, because the rc invokes starship by
  its full path and a literal `starship init bash` never appears.
- **`--dry-run` could not run to completion on the Ubuntu 26.04 it targets.**
  `apt_update_once` is dry-run-skipped, so on a fresh image `/var/lib/apt/lists`
  is empty and every `apt-cache` query comes back negative. `toolchain` read
  that as "gcc-13 does not exist on this release" and called `die`, killing the
  run at the third stage. This matters more than it sounds: a dry run is exactly
  what you do before wiping a working machine.
- `--dry-run` no longer reaches the network. The neovim tarball, the fastfetch
  release lookup and the rustup installer were all invoked with a bare `curl`
  rather than through `run`, so a dry run really downloaded them, and the neovim
  one called `die` when it could not. `rust` additionally asserted that
  `~/.cargo/bin/rustup` existed after an install it had only pretended to do.
- A stage that bailed out in its dependency check was recorded as *done* rather
  than skipped, because the caller returned 0 and `run_stage` reads that as
  success. It would then be skipped by `--resume` having installed nothing.
- With `--only`, the final summary listed every unselected stage as "not
  completed" and told you to re-run all of them. A deliberate one-stage run now
  reports only on the stage it was asked to run.
- The wofi stylesheet failed to parse. GTK rejected `!important` on a colour
  value with `Junk at end of value for background-color` and discarded the whole
  `#entry:drop(active)` rule. Verified fixed against wofi itself.
- `$USER` is no longer read bare under `set -u`. It is set by login shells, and
  the installer routinely runs somewhere that is not one, where the reference is
  an immediate unbound-variable abort rather than a wrong value.
- `boot-splash` re-runs no longer rebuild the initramfs. It converged correctly
  but restaged 127 files and spent 30 to 60 seconds producing a byte-identical
  initramfs, which is not what "re-runs are cheap no-ops" means everywhere else.

### Changed
- CasADi is now pinned by commit SHA rather than by tag, asserted after
  checkout, and the pin is the same commit
  `vortex-auv/scripts/install_casadi.sh` checks out (`refs/tags/3.7.2` resolves
  to exactly `f959d31`). A tag is a movable ref, so matching it alone never
  actually guaranteed everyone built the same source. The apt dependency list is
  now that script's list plus what the enabled solvers additionally need. The
  one deliberate divergence: that script disables IPOPT, OSQP, SUNDIALS and
  qpOASES, which is right for a CI image that only needs CasADi to link and
  wrong on a development machine, where the plugins resolve lazily and a missing
  one surfaces mid-mission rather than at build time.
- Stage order changed. `shortcuts`, `desktop` and `gnome-extensions` now run
  after `browser`, `editor` and `kitty-fastfetch`, because `desktop` only pins
  dock favourites whose `.desktop` file already exists.

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
