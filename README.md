# gnome-git: latest GNOME from your git checkouts, as Arch packages

Source: <https://github.com/iritur/gnome-git>

Builds the GNOME stack from the git checkouts on the SCSI drive into a local
pacman repository, using the **official Arch PKGBUILDs** re-pointed at your
sources. Dependencies are resolved by pacman, the result installs and
upgrades like any other Arch package, and the drive carries everything needed
so that fetching (this machine) and building (the powerful one) are separate
steps.

## Why this approach

| Option | What it is | Verdict |
|---|---|---|
| **Official Arch PKGBUILDs + local repo** (this toolkit) | Arch already builds nearly every GNOME package from `gitlab.gnome.org` git at a pinned commit. Re-point the source at your checkout, derive `pkgver` from git, build with `makepkg`, serve from a `file://` repo listed above `core`/`extra`. | Simplest and most stable: pacman does all dependency work, GDM/systemd/portals integrate as on stock Arch, rollback is `pacman -Syuu` after removing the repo, and you inherit Arch's patches and packaging fixes for free. |
| AUR `*-git` packages | Community PKGBUILDs tracking main. | Same mechanism but uneven quality and coverage; many are stale or depend on each other's `-git` variants. The official PKGBUILDs are maintained daily by the Arch GNOME packagers, so they are the better base. Use `overrides/` if you want to drop a specific AUR PKGBUILD in. |
| JHBuild | Classic GNOME "build everything into a prefix" tool. | Builds into `~/jhbuild`, not integrated with pacman, running a full session from a prefix is fragile (GDM, systemd user units, portals). GNOME no longer recommends it. Good only for a nested `gnome-shell --nested` dev loop. |
| BuildStream + `gnome-build-meta` (what GNOME OS uses) | Reproducible, sandboxed build of the whole OS including the freedesktop-sdk base. | Produces a GNOME OS image or sysroot, not packages for your Arch install. Without the GNOME remote cache the first build compiles the entire SDK (many hours, tens of GB) and it does not use your checkouts directly. Right for testing GNOME OS in a VM, wrong for "run it on my Arch". |
| Flatpak / `flatpak-builder` with the nightly SDK | Official way to build and run *apps* from git. | Does not cover the shell, session, settings daemon or GDM. Fine to add later for individual apps. |

## Layout on the drive

```
/mnt/gnome/gnome/              GG_SRC: your GNOME checkouts (one per project),
                               fetch.sh clones missing ones and helper repos here
/mnt/gnome/gnome-git/          GG_ROOT: this toolkit
  config.sh modules.list       paths and module list (edit these)
  fetch.sh build.sh install.sh lib.sh
  pkgbuilds/                   clones of the official Arch packaging repos
  overrides/                   hand-maintained PKGBUILDs that win over pkgbuilds/
  pkgcache/                    dependency closure = local repo [gnome-git-deps]
  repo/                        built packages       = local repo [gnome-git]
  cargo-home/                  crate cache for Rust modules (offline builds)
  logs/  state/                build logs, last built commit per module
```

Paths are set in `config.sh`; bare `name.git` clones and one level of
sub-directories under `GG_SRC` are found automatically.

## One-time setup (both machines)

1. Mount the drive at the **same path** on both machines, by label:
   ```
   LABEL=dev7-gnome  /mnt/gnome  ext4  rw,relatime,nofail,x-systemd.device-timeout=5  0 2
   ```
   Your user must own the files (same uid on both machines, or `chown -R`).
   The `file://` repo path is written into `pacman.conf`, so the path matters.
2. Run the scripts from `/mnt/gnome/gnome-git` (they locate everything
   relative to themselves).
3. Build machine: `sudo pacman -S --needed base-devel git ccache` and a user
   with sudo rights (pacman installs dependencies during the build).

## Leaving packages out of the installed system

`exclude.list` names packages that are built but never installed, as shell
globs. `install.sh --all`, the installer published for other machines, and
`publish.sh --lean` all honour it. The defaults drop API documentation and the
Help manual (about 106 MB), the GTK and libadwaita demos (gtk4-demo,
gtk4-widget-factory, gtk4-print-editor, gtk4-node-editor), the vte sample
terminals, and `gvfs-dnssd`. That is 37 of 155 packages, and `--lean` shrinks
a publish from 306 MB to 190 MB.

Two notes on things that look like they should be excludable but are not.
`tinysparql` depends on avahi outright and desktop search needs tinysparql, so
avahi arrives unless you give up search; installing it does not start it, and
`systemctl mask avahi-daemon.service avahi-daemon.socket` keeps it quiet.
Glade, xterm and Qt are not runtime dependencies of anything built here: they
appear on the build machine only, pulled in by libpeas and vte at build time,
and never reach the machine that runs GNOME.

## First-time setup of this machine

`setup.sh` walks through everything the build/publish machine needs, asking
before each change and reporting what is already in place, so it is safe to
re-run:

```bash
./setup.sh --check     # report only, change nothing
./setup.sh             # walk through every step
./setup.sh --vmware    # only the VMware steps
./setup.sh --github    # only the GitHub access steps
```

It covers VMware guest integration (the clipboard plugin's `gtkmm3`
dependency, the `vmtoolsd` and `vmware-vmblock-fuse` services, and mounting
the host's shared folders at `/mnt/hgfs`), your git identity, and GitHub
access for `publish.sh`, either an SSH key or an HTTPS token. For SSH it
prints the public key and offers to drop it in the shared folder so you can
paste it on the host, then verifies the key and the repository before writing
the URLs into `config.sh`.

Note on copy-paste: VMware's plugin is X11 based and GNOME 49 and later ship
Wayland sessions only, so there is no Xorg session to fall back to. It can
still work through XWayland, but the shared folder is the dependable route,
and on a text console it is the only one.

## Publishing to a personal remote repository

`publish.sh` pushes the built packages to a git branch so other Arch machines
can install them with pacman and build nothing:

```bash
./publish.sh --dry-run     # what would be published
./publish.sh               # push to GG_REMOTE (config.sh)
./publish.sh --sign        # sign every package and the database first
./publish.sh --url         # just print the pacman.conf snippet
```

Packages are published as plain files in a branch (default `arch`), laid out as
`<branch>/x86_64/`, not as GitHub release assets: GitHub rewrites characters in
asset names and 18 of these packages carry an epoch (`gjs-2:1.90.0-...`), which
pacman looks up by exact filename. Each publish force-pushes one snapshot
commit, so old package blobs do not pile up in the history forever.

On the other machine, `publish.sh` leaves a ready-made installer at the root of
the branch:

```bash
curl -fLO https://raw.githubusercontent.com/iritur/pkgs/arch/install-gnome-git.sh
less install-gnome-git.sh        # read before running
bash install-gnome-git.sh --all  # register the repo and install everything
bash install-gnome-git.sh --remove   # unregister it again
```

It writes the repository above `[core]` in `/etc/pacman.conf`, so these
packages win over the Arch ones, and keeps a backup next to it.

The machine holding the drive can switch to the published repo too, with
`install.sh --remote`, which is useful once the drive is unplugged.

Unsigned by default: `SigLevel = Optional TrustAll` means pacman trusts
whatever that URL serves. The transport is HTTPS, so the trust is in the GitHub
account. `publish.sh --sign` signs the packages and the database with your GPG
key instead; importing and locally signing that key is then a prerequisite on
every client.

## Workflow

**On this machine (online):**
```bash
./fetch.sh                # sources + PKGBUILDs + dependency closure + crates
./fetch.sh check          # table: every module has a source, a PKGBUILD, a git URL, a ref
```
Individual steps: `./fetch.sh sources`, `pkgbuilds`, `deps`, `cargo`.
Restrict to modules or tiers: `./fetch.sh sources gnome-shell mutter`, `./fetch.sh core`.

**On the build machine:**
```bash
./build.sh                # everything in modules.list, in order
./build.sh core           # one tier; or: ./build.sh mutter gnome-shell
./build.sh --from gnome-shell   # resume a run
./build.sh --force gtk4   # rebuild even if the commit is unchanged
./build.sh --gen-only     # just generate PKGBUILDs into ~/.cache/gnome-git/pkg
./build.sh --list         # what would be built, and why, marked with *
```
The build installs each package before building the next so later modules
compile against the git versions of earlier ones. Modules whose commit has
not changed since the last successful build are skipped. If the system repos
are unreachable it switches to the offline dependency cache automatically
(`--offline` forces it). Test suites are skipped (`--check` runs them).

**On the machine that runs GNOME** (the build machine, or any Arch machine
with the drive mounted at the same path):
```bash
./install.sh              # registers [gnome-git] above core/extra, pacman -Syu
./install.sh --all        # also installs every built package
./install.sh --with-deps  # also registers the offline dependency cache
./install.sh --remove     # back to stock: then sudo pacman -Syuu
```
Repository order does not decide upgrades. `pacman -Syu` installs the highest
version it can see, wherever it comes from, and order only breaks ties. That
matters here because GNOME tags releases on the stable branch, so `git
describe` on main yields `51.beta.r162`, which sorts below the `51.0` Arch
ships: without help, a plain `-Syu` would quietly replace these builds with
Arch's. `GG_EPOCH_BUMP` (on by default) raises the epoch of every package we
build, which puts it above any release. Turning it off means the newest
version wins on its own, whoever built it.

## How a package is generated

For each module `build.sh` copies the official PKGBUILD (or `overrides/<pkgbase>`) and appends:

- `source=()` with every `git+https://…/<name>.git` entry that has a matching
  checkout under `GG_SRC` rewritten to `git+file:///…#commit=<sha>`. The
  module's own repo gets the commit resolved from `ref`; helper repos (gvdb,
  libgnome-volume-control, …) get the revision the module's meson wrap file
  asks for, because `arch-meson` enforces it. Checksums of rewritten git
  sources become `SKIP`; local patches keep theirs.
- `pkgver()` producing `49.beta.r120.gabc1234` from `git describe --tags`.
- Version constraints on packages that this module list builds are removed
  (`mutter>=49.0` becomes `mutter`), because git versions such as
  `49.alpha.r12` sort below `49.0`.
- `makedepends+=()` from `extra-deps.list`, for dependencies upstream main
  needs before Arch lists them (arch-meson turns every optional feature on).
- A `prepare()` wrapper that, after Arch's own `prepare()`, populates git
  submodules and meson wrap-git subprojects that are still empty from the
  checkouts on the drive (nautilus's libgxdp, gnome-desktop's qrcodegen, …).
  `fetch.sh check` lists the helper checkouts that are missing.
- Lenient patching: Arch's patches are mostly backports already in main, so
  `git apply`, `git cherry-pick` and `patch -i` that do not apply are skipped
  with a `gnome-git:` warning in the log instead of failing the build. A
  cherry-pick whose subject line is already in the history is skipped too,
  because merged backports come back with a different commit id and would
  otherwise be applied twice. `GG_STRICT_PATCHES=1` restores strict behaviour.
- Wrappers that absorb the drift between Arch's released version and main:
  `arch-meson`/`meson setup` retry without the `-D` options meson rejects,
  `_pick` skips files upstream no longer builds, and `tsconfig.json` gets the
  explicit `rootDir` TypeScript 6 demands. Every one logs a `gnome-git:` line.
- Rust: PKGBUILDs and meson files pin `CARGO_HOME` inside the build tree and
  expect `prepare()` to fill it from the network. That path is symlinked to the
  crate cache on the drive instead, because meson starts cargo itself and never
  sees a shell wrapper. Only wraps the system cannot satisfy are populated, so
  gjs no longer clones all of glib into its build tree.

While a build runs, the terminal's title bar shows what is compiling, as
`[12/92] mutter - building`, and ends on a summary like `gnome-git: 91/92 ok`.
GNOME Console binds its tab title to VTE's window-title and Ptyxis reads the
same property, so both show it in the header; so do gnome-terminal and xterm.
It is written to `/dev/tty`, so it still works when you redirect the output to
a file. `GG_TITLE=0` turns it off.

The commit is resolved from `origin/<ref>` first, so a checkout that was only
`git fetch`ed (not pulled) still builds the newest commit. `fetch.sh sources`
fast-forwards clean checkouts. LTO is disabled (`GG_LTO=1` to enable): it
roughly doubles link-time memory, which is how gtk4 got OOM-killed.

## When something fails

- Logs: `logs/<pkgbase>.log` (script output) and `logs/<pkgbase>-…-build.log` (makepkg).
- Status per module is printed at the end and saved to `state/last-build.txt`.
- `no-git-source`, or a PKGBUILD that no longer matches upstream's build
  system (gnome-user-docs moved to meson): add `overrides/<pkgbase>/PKGBUILD`
  with a `git+https://gitlab.gnome.org/GNOME/<repo>.git` source.
- "Dependency X not found": upstream main grew a dependency. Add it to
  `extra-deps.list`, re-run `fetch.sh deps` when building offline.
- "no checkout for submodule/wrap": clone the repo `fetch.sh check` names
  into `GG_SRC` (or run `fetch.sh sources`). Meson wrap subprojects are
  populated with their `patch_directory` overlay, as meson would do.
- A git library breaks the ABI of a stock package (libmanette vs webkitgtk):
  `build.sh --remove <pkgbase>` drops it from the repo and reinstalls the
  stock version, then comment it out in `modules.list`.
- "An entry for X already existed" from repo-add means the same version was
  built twice. That is normal after a packaging change, and harmless: the old
  package file is replaced. What is NOT harmless is pacman then refusing to
  install it, which is why a rebuild of an unchanged commit bumps `pkgrel` to
  `1.1`, `1.2` and so on. Without that the corrected package sits in the repo
  and never reaches the system.
- A dropped option ("gnome-git: meson does not know option X") is usually an
  option upstream RENAMED, not one it removed. Check `meson.options` in the
  checkout and set the new name in `extra-opts.list`; gom's `enable-gtk-doc`
  became `docs`, and without it no documentation was built for its docs
  package to install.
- "no matching package named X" from cargo means the crate cache is behind the
  lockfiles, which happens whenever sources are updated. `fetch.sh check`
  reports it per module; `fetch.sh cargo` fixes it. Re-run it after every
  `fetch.sh sources`, or just run `fetch.sh` with no arguments.
- An empty `logs/<pkgbase>-*-build.log` next to a failed build means a wrapper
  died before printing. makepkg runs `prepare`, `pkgver`, `build` and `package`
  with `errexit`, `errtrace` and an ERR trap that calls `exit 4`. Because of
  `errtrace` that trap is inherited by command substitutions, so a failing
  command inside `x=$(...)` exits the shell from within the subshell and the
  captured output is never printed. `set +e` does not help. Anything allowed to
  fail must therefore either end in `|| true` *inside* the substitution, or run
  with the trap disarmed (`trap -p ERR` saved, `trap - ERR`, restore before
  returning) the way the meson retry wrapper does.
- Wrong pkgbase name in `modules.list`: `fetch.sh pkgbuilds` fails to clone
  it; check the real name with `pacman -Si <package> | grep -i base`.

## Caveats

- The `[platform]` tier rebuilds glib, gtk, libsoup and friends from main. It
  is what "full featured latest GNOME" requires, but it is also where a bad
  upstream commit breaks unrelated software. Build `core` and `apps` only
  (leave `[platform]` to Arch stable) if you want less exposure; pin a tag or
  branch per module in `modules.list` (`gtk4 gtk 4.20.1`) for stability.
- Both machines should be kept `pacman -Syu` current. The dependency cache
  makes the build machine self-sufficient, but if it is months behind the
  fetch machine, mixing new libraries into an old system will hurt.
- Rust modules (loupe, snapshot, papers, gnome-tour…) need `cargo` on the fetch
  machine for `fetch.sh cargo`; otherwise they need network on the build machine.
- Debug packages and LTO are disabled (`!debug`, `!lto`) to save space, time
  and memory. `GG_LTO=1` re-enables LTO; lower `GG_JOBS` if links still get
  OOM-killed.
- First full build of the list takes several hours even on a fast machine;
  later runs rebuild only what changed, and ccache speeds up the rest.
- No package signing: the repos use `SigLevel = Optional TrustAll`
  (`PackageRequired` for the dependency cache, which holds Arch-signed files).
