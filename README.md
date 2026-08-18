<div align="center">

<img src="assets/logos/vortex.png" width="140" alt="VortexNTNU">

# Ubuntu Onboarding Installer

**Fresh Ubuntu ISO to a fully configured development environment, in one command.**

Ubuntu 26.04 · stock GNOME · ROS 2 Lyrical Luth

</div>

---

## Before you start

| # | You need | How to check |
|---|---|---|
| 1 | **Ubuntu 26.04**, freshly installed | `lsb_release -r` prints `26.04` |
| 2 | **An account with sudo** | `sudo true` succeeds |
| 3 | **A working GitHub SSH key** | `ssh -T git@github.com` greets you by username |
| 4 | **Membership of the `vortexntnu` GitHub org** | you can open [vortex-auv](https://github.com/vortexntnu/vortex-auv) |
| 5 | **Time and a stable connection** | 20 to 30 minutes, or 60 to 90 with ROS 2 |
| 6 | **Nothing precious in your home directory** | existing files are backed up rather than deleted, but don't test that on your only copy |

The installer verifies 1 and 3 before it changes anything and refuses to run if
either is missing.

**Don't have Ubuntu yet?** Follow the wiki guide first:
[Getting started (Software)](https://vortex.a2hosted.com/index.php/Getting_started_(Software)).
It covers the bootable USB, shrinking Windows, partitioning and dual boot.
Repartitioning a disk wrongly loses data and this installer cannot help with
that part.

> [!IMPORTANT]
> Ubuntu 26.04 only. ROS 2 Lyrical Luth pairs with 26.04 "Resolute", so on any
> other release the installer stops instead of half working.

<details>
<summary><b>Why the SSH key is your problem and not the installer's</b></summary>

The installer does not create your key. It checks that you have a working one
and stops if you don't.

Everything worth installing here lives behind a `git@github.com` remote and
several Vortex repositories are private. An installer that shrugged and cloned
over HTTPS would hand you a half-empty workspace and a build that fails an hour
later for reasons that look nothing like the actual cause.

Your key works when this prints your username:

```bash
ssh -T git@github.com
# Hi <your-username>! You've successfully authenticated, but GitHub does not provide shell access.
```

If it doesn't, follow
[GitHub's SSH guide](https://docs.github.com/en/authentication/connecting-to-github-with-ssh)
start to finish. Org membership is separate: a key that authenticates fine still
cannot clone a repository you have no access to, which shows up as skipped repos
near the end of the ROS 2 stage.

</details>

---

## Quick start

```bash
sudo apt update && sudo apt install -y git
git clone https://github.com/Q3rkses/ubuntu_setup_script.git ~/ubuntu_setup_script
cd ~/ubuntu_setup_script
./install.sh
```

Answer the questions, then leave it running. It asks for your sudo password once,
at the start. The `colcon build` at the end is the slow part.

### What it asks

| Question | Options | Effect |
|---|---|---|
| Full name | free text | `git config user.name`, welcome banner |
| Profile | `vortex` / `personal` | vortex always installs ROS 2; personal adds Rust and lets you pick your own splash image |
| ROS 2? | yes / no | personal profile only |
| Editor | `nvim` / `vscode` | nvim pulls in the full custom config and becomes your system editor |
| Browser | `chrome` / `brave` / `vivaldi` / `firefox` | installed from the vendor's own apt repo |
| Splash image | path or URL | personal profile only |
| Git email | free text, optional | `git config user.email` |

### Unattended

Every prompt has a flag, so it works over SSH or in CI:

```bash
./install.sh --name "Ada Lovelace" --profile=vortex \
             --editor=nvim --browser=brave --yes
```

<details>
<summary><b>All flags</b></summary>

```
--name "First Last"        Full name (git config + welcome banner)
--email you@example.com    Git email
--profile=vortex|personal  Which profile to install
--ros / --no-ros           Install ROS 2 (personal profile only)
--skip-ros-build           Install ROS 2 but stop before rosdep and colcon
--skip-ssh-check           Skip the SSH precondition, clone over HTTPS
                           (automated testing only)
--editor=nvim|vscode       Editor to install
--browser=chrome|brave|vivaldi|firefox
--logo=PATH|URL            Personal-profile fastfetch splash image
--wallpaper=slideshow|static|none
                           Desktop wallpaper (personal profile)
--no-boot-splash           Leave the Plymouth boot theme alone
--rounded-radius=N         Window corner radius in pixels (default 6, 0 = off)
--yes, -y                  Non-interactive: accept defaults, never prompt
--resume                   Skip stages already recorded as complete
--dry-run                  Print what would happen; change nothing
--only=STAGE[,STAGE...]    Run only these stages (e.g. --only=ros2)
--list-stages              Print stage names and their completion status
--help, -h                 Help
```

</details>

---

## What it installs

Seventeen stages, in this order. Every stage is idempotent, so re-running is
safe, and checkpointed, so a failure never costs you the stages before it.

| # | Stage | What it does |
|---|---|---|
| 1 | `apt-upgrade` | `apt update && apt upgrade` |
| 2 | `base-packages` | Build tooling, CLI essentials, JetBrainsMono Nerd Font, starship, wofi |
| 3 | `toolchain` | GCC/G++ 13, pinned and made default |
| 4 | `cxx-libs` | Eigen from apt, CasADi built from source with IPOPT, SUNDIALS, OSQP and qpOASES |
| 5 | `apps` | clangd, clang-format/tidy, shellcheck, btop, tmux, Docker, gnome-tweaks, ibus-mozc |
| 6 | `git-config` | Git name, email, default branch, rebase on pull, editor |
| 7 | `bashrc` | Managed `.bashrc`, aliases, ble.sh autosuggestions, NVM, `~/code/ros2_ws` |
| 8 | `kitty-fastfetch` | Kitty with Catppuccin Mocha, fastfetch splash with a real image logo |
| 9 | `boot-splash` | Plymouth theme showing your logo instead of the vendor badge |
| 10 | `editor` | Neovim from the official tarball, or VS Code from Microsoft's repo |
| 11 | `browser` | Chrome, Brave, Vivaldi or Firefox from the vendor's apt repo |
| 12 | `shortcuts` | GNOME keybindings, static 4 workspaces |
| 13 | `desktop` | Dark mode, magenta accent, input sources, touchpad, dock, monospace font |
| 14 | `gnome-extensions` | Rounded window corners at 6px |
| 15 | `wallpaper` | GT3 RS slideshow (personal profile) |
| 16 | `rust` | rustup stable, rust-analyzer, clippy, rustfmt (personal profile) |
| 17 | `ros2` | ROS 2 Lyrical, YASMIN, the eight Vortex repos, rosdep and colcon |

Two orderings are load-bearing. `desktop` pins dock favourites and only pins
entries whose `.desktop` file exists, so it follows `browser`, `editor` and
`kitty-fastfetch`. `boot-splash` reuses whatever image fastfetch resolved, so it
follows `kitty-fastfetch`.

### Things worth knowing up front

- **The Nerd Font is not optional.** Without it the fastfetch splash, the
  starship prompt and Neovim's status line render as rows of ▯ boxes. The
  `desktop` stage also points GNOME's monospace font at it, so the prompt keeps
  its icons in GNOME Terminal and Text Editor, not just in Kitty.
- **GCC is pinned to 13,** not "newest", because two people installing a month
  apart would otherwise get different compilers. Bump the constant in
  `lib/toolchain.sh` deliberately.
- **No snap, no flatpak.** Everything is apt, from the archive or a vendor repo.
  If something you want is missing, prefer the apt package, then `cargo install`.
- **Docker comes from Docker's repo,** not `docker.io`, which omits the compose
  and buildx plugins. You are added to the `docker` group, effective next login.
- **Choosing `nvim` makes it your editor everywhere:** `$EDITOR`, `$VISUAL`,
  `$SUDO_EDITOR`, `update-alternatives`, `git core.editor` and `sequence.editor`,
  and Nautilus double-click associations. Setting only one of those is why nano
  keeps coming back.
- **Your GNOME settings are backed up first.** `shortcuts` and `desktop` both
  dump `/org/gnome/` to `~/.local/state/vortex-onboarding/backups/` before
  writing anything.

### Keyboard shortcuts

| Shortcut | Action |
|---|---|
| `Super` + `1` … `4` | Switch to workspace 1 to 4 |
| `Super` + `Shift` + `1` … `4` | Move the window to workspace 1 to 4 |
| `Super` + `Enter` | New Kitty terminal |
| `Super` + `Q` | Close the focused window |
| `Super` + `R` | Wofi launcher |
| `Super` + `↑` / `↓` | Maximise / unmaximise |
| `Super` + `S` | Screenshot and screencast UI |

Restore your old bindings with:

```bash
dconf load /org/gnome/ < ~/.local/state/vortex-onboarding/backups/dconf-gnome-<timestamp>.ini
```

### Shell aliases

| Command | Does |
|---|---|
| `cb <pkg>` | `colcon build --packages-up-to <pkg>` with testing on |
| `ct <pkg>` | `colcon test` for a package, console output direct |
| `s` | `source install/setup.bash` |
| `rcd` | `ranger`, but your shell ends up in the directory you chose |
| `ll`, `la`, `l` | the usual `ls` variants |

ble.sh gives you inline autosuggestions from history: a grey suggestion ahead of
the cursor, `→` or `End` to accept, `Alt+F` for one word. `Tab` opens a
navigable menu instead of a plain column dump.

---

<details>
<summary><b>The longer why, for anyone changing this repo</b></summary>

#### CasADi is built from source, Eigen is not

Eigen comes from apt (`libeigen3-dev`) because it is the exact build every ROS 2
package in the archive was compiled against. A second Eigen in `/usr/local` wins
the CMake search and leaves half your packages compiled against one version and
their dependencies against another, which shows up as random segfaults rather
than build errors. The stage warns if it finds a stray copy.

CasADi is built from source because Debian strips the vendored solvers out of
the apt package:

| In the apt build | Missing from it |
|---|---|
| `nlpsol_ipopt`, `sqpmethod`, `scpgen`, `qrsqp` | `conic_osqp`, `conic_qpoases` |
| `conic_qrqp`, `conic_ipqp` | `integrator_cvodes`, `integrator_idas` (SUNDIALS) |
| `integrator_rk`, `integrator_collocation` | the HSL linear solvers |

Plugins resolve lazily, so code asking for `cvodes` or `osqp` compiles against
the apt build perfectly and then dies at runtime, typically an hour into a
mission test. This stage enables IPOPT plus CasADi's bundled SUNDIALS, OSQP and
qpOASES, then compiles and runs a program that loads all three before calling
the stage done. Budget 10 to 20 minutes.

The pin matches `vortex-auv/scripts/install_casadi.sh` by commit SHA rather than
tag, since a tag is a movable ref. It diverges on one axis: that script passes
`WITH_IPOPT=OFF`, `WITH_OSQP=OFF`, `WITH_SUNDIALS=OFF` and `WITH_QPOASES=OFF`,
which is right for a CI image that only needs CasADi to link and wrong for a
development machine, for the reason above.

#### Firefox needs an apt pin

On modern Ubuntu `apt install firefox` pulls a transitional package that
installs the snap. Mozilla's repo is therefore paired with a pin that outranks
it. Chrome, Brave and Vivaldi have no snap in the archive but get the same
vendor-repo treatment for consistency.

#### Wofi on GNOME is a compromise

Wofi is built for `wlr-layer-shell`, a protocol GNOME Shell does not implement
and has no plans to. It detects this and falls back to drawing as an ordinary
window, so it works but appears in the window list and takes no exclusive
keyboard grab. Every popular launcher in this family (`anyrun`, `sherlock`,
`fuzzel`, `tofi`) has the same dependency and will not draw at all on GNOME. A
launcher that renders as a normal window, such as `onagre`, is the option that
actually fits this desktop.

#### The rounded corners extension takes three extra steps

A plain unzip does not work. The stage asks the extension site which release
matches your shell, because extensions are pinned to a GNOME Shell major version
and "latest" is frequently one that silently refuses to load. It compiles the
schemas, since an extension whose schemas are uncompiled throws on its first
settings read. And it enables the extension through `gsettings` rather than
`gnome-extensions enable`, because under Wayland the running shell has not
scanned the new directory yet.

It also turns off the extension's "skip libadwaita apps" default, which would
otherwise leave GTK4 apps at their own 12px and everything else at yours.

#### The boot splash needs an initramfs rebuild

Ubuntu's default Plymouth theme is `bgrt`, which exists to keep displaying the
vendor logo the firmware parked in an ACPI table, which is why a stock boot shows
a Dell or Lenovo badge. This stage installs a sibling theme with
`UseFirmwareBackground=false` and your image as the watermark.

It gets its own image directory rather than reusing the spinner's, because
overwriting `watermark.png` means apt restores it on the next upgrade. And the
initramfs must be rebuilt, since Plymouth starts before the root filesystem is
mounted and reads the theme from there. Changing the alternative without
rebuilding changes nothing visible, which is the easiest way to conclude the
whole thing failed.

The logo the firmware paints between the power button and GRUB lives in UEFI
flash and nothing done from inside Linux can change it. Undo the rest with:

```bash
sudo update-alternatives --auto default.plymouth
sudo update-initramfs -u
```

#### Syntax highlighting is deliberately restrained

The rule is to colour only what tells you something you didn't already know:
errors and bad paths red, quoted strings yellow, expansions mauve, real
directories blue and underlined, comments dim, the inline suggestion grey.
Command words stay uncoloured. ble.sh's stock theme paints commands brown,
builtins red and executables green, so nearly every line starts green and the
colour tells you nothing. Delete the `ble-face` lines from `~/.blerc` to go back
to stock.

Startup time is protected too: NVM and conda lazy-load as stub functions that
replace themselves on first call, and ROS, Cargo and colcon sourcing is guarded
by existence checks. An interactive shell stays around 200 ms instead of ~1 s.

#### ROS 2 runs last on purpose

It is a 30 to 60 minute compile against a large dependency tree and the stage
most likely to fail. Everything else is installed and checkpointed by then, so
you only re-run this one. Build log:
`~/.local/state/vortex-onboarding/logs/colcon-build.log`.

YASMIN, the state machine library mission logic is written against, comes from
the ROS apt index (`ros-lyrical-yasmin`, `-yasmin-ros`, `-yasmin-viewer`) rather
than the workspace, so it gets security updates and does not lengthen your
colcon build. The viewer draws the running state machine and is the fastest way
to see why a mission is stuck.

Repositories cloned into `~/code/ros2_ws/src`:

| Repository | Branch |
|---|---|
| `vortex-auv` | `development` |
| `vortex-msgs` | `main` |
| `vortex-utils` | `main` |
| `vortex-ci` | `main` |
| `stonefish_ros2` | `main` |
| `vortex-stonefish-interface` | `main` |
| `vortex-stonefish-sim` | `main` |
| `stim300-driver` | `feature/ros2-port` |

</details>

---

## When something fails

```bash
./install.sh --list-stages     # what's done, what isn't
./install.sh --resume          # carry on, skipping completed stages
./install.sh --only=ros2       # retry one stage
./install.sh --dry-run         # see what it would do, change nothing
```

Logs, backups and state all live under `~/.local/state/vortex-onboarding/`.

The `cxx-libs`, `shortcuts`, `kitty-fastfetch`, `wallpaper`, `editor`, `browser`,
`rust` and `ros2` stages are **soft**: a failure is reported and the run
continues. An unsupported Ubuntu release or a broken SSH key is the opposite and
stops the installer before it changes anything.

---

## Verifying your install

**Log out and log back in first.** GNOME shortcuts and your new shell
environment only apply to a fresh session. This is the single most common reason
someone reports the shortcuts didn't work.

```bash
cd ~/ubuntu_setup_script
./tests/verify_install.sh
```

Every applicable row should say `PASS`; rows for the profile you didn't choose
say `SKIP`.

Then confirm the things a script cannot press keys for:

- [ ] **`Super` + `Enter`** opens Kitty, showing the fastfetch splash with the
      logo as a real image, not ASCII art and not ▯ boxes
- [ ] The prompt is starship with icons: distro logo, directory, git branch
- [ ] **`Super` + `2`** switches workspace, **`Super` + `Shift` + `3`** moves a
      window, **`Super` + `Q`** closes one, **`Super` + `R`** opens Wofi
- [ ] `nvim` opens with your config and no error banner
- [ ] `gcc --version` reports 13.x
- [ ] Your browser launches from the Activities overview
- [ ] Personal profile: the background is a GT3 RS and `cargo --version` works
- [ ] With ROS: `ros2 doctor` is clean and `ros2 run demo_nodes_cpp talker`
      prints messages
- [ ] With ROS: `python3 -c "import yasmin, yasmin_ros"` and
      `ros2 run yasmin_viewer yasmin_viewer_node` both work
- [ ] CasADi resolves the plugins the apt build lacks:

      ```bash
      cat > /tmp/c.cpp <<'EOF'
      #include <casadi/casadi.hpp>
      #include <Eigen/Dense>
      int main() {
          casadi::SX t = casadi::SX::sym("t");
          casadi::integrator("i", "cvodes", casadi::SXDict{{"x", t}, {"ode", -t}}, 0, 1);
          casadi::conic("q", "osqp", casadi::SpDict{{"h", casadi::Sparsity::dense(1, 1)}});
          Eigen::Matrix2d m; m << 1, 2, 3, 4;
          return m.determinant() == -2 ? 0 : 1;
      }
      EOF
      g++ -std=c++17 /tmp/c.cpp -I/usr/include/eigen3 -lcasadi -o /tmp/c && /tmp/c && echo OK
      ```

### What it should look like

Kitty on first launch, and the same window with ble.sh suggesting from history
(grey text ahead of the cursor) above the Tab completion menu:

![Kitty with the fastfetch splash](assets/screenshots/terminal-fastfetch.png)
![ble.sh suggestions and completion menu](assets/screenshots/terminal-completions.png)

Neovim: dashboard, editing with LSP diagnostics, the file picker, and the
outline plus TODO comments.

![Neovim dashboard](assets/screenshots/nvim/dashboard.png)
![Editing a file](assets/screenshots/nvim/editor.png)
![File picker](assets/screenshots/nvim/filepicker_with_border.png)
![Aerial outline and todo-comments](assets/screenshots/nvim/extras.png)

---

## Repository layout

```
onboarding/
├── install.sh                 entrypoint and stage orchestration
├── lib/
│   ├── common.sh              logging, checkpointing, idempotency helpers
│   ├── prompts.sh             argument parsing and interactive Q&A
│   ├── base.sh                apt upgrade, base packages, font, starship
│   ├── toolchain.sh           GCC 13
│   ├── cxxlibs.sh             Eigen (apt) and CasADi (source build)
│   ├── apps.sh                dev tools, Docker, GNOME front-ends, input methods
│   ├── ssh_github.sh          GitHub SSH precondition and git identity
│   ├── shortcuts.sh           GNOME keybindings
│   ├── desktop.sh             appearance, input sources, pointer, dock
│   ├── extensions.sh          GNOME extensions (rounded window corners)
│   ├── bashrc.sh              shell configuration and ble.sh
│   ├── kitty_fastfetch.sh     terminal and splash
│   ├── plymouth.sh            boot splash theme
│   ├── wallpaper.sh           desktop background (personal profile)
│   ├── nvim.sh                editor (Neovim or VS Code)
│   ├── browser.sh             Chrome / Brave / Vivaldi / Firefox
│   ├── rust.sh                rustup (personal profile)
│   └── ros2.sh                ROS 2 Lyrical (deferred to last)
├── dotfiles/                  the actual .bashrc, aliases, kitty, fastfetch, blerc
├── assets/                    logos, wallpapers, README screenshots
├── tests/verify_install.sh    post-install verification
├── tests/docker/              container test harness
└── CHANGELOG.md
```

---

## Testing changes

```bash
./tests/docker/run.sh                    # 26.04, vortex profile
./tests/docker/run.sh --profile personal
./tests/docker/run.sh --shell            # poke around inside instead
```

It runs the installer on a real Ubuntu image, covering apt, the GCC pin,
dotfiles, the editor, the browser, rustup and the ROS 2 apt setup. It cannot
cover the GNOME stages, because a container has no session bus, so `shortcuts`
and `wallpaper` abort there by design. Test those on real hardware or in a VM.
