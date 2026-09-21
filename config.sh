# config.sh - paths and knobs for the gnome-git toolkit.
# Sourced by lib.sh. Every variable can also be overridden from the
# environment (e.g. GG_SRC=/srv/gnome ./build.sh), or set for good in
# config.local.sh next to this file, which is never committed.
#
# The directory that contains these scripts is the toolkit root (GG_ROOT).
# Put the whole directory on the SCSI drive so that sources, PKGBUILDs,
# the dependency cache and the built package repo all travel together.

# Where your GNOME git checkouts live (one directory per project, e.g.
# $GG_SRC/gnome-shell, $GG_SRC/glib ...). Bare clones (name.git) and one
# level of sub-directories ($GG_SRC/GNOME/glib) are found as well.
# fetch.sh clones whatever is missing, so an empty directory is a fine start.
# Point this somewhere else in config.local.sh if your checkouts already exist.
: "${GG_SRC:=$GG_ROOT/src}"

# Clones of the official Arch packaging repos (one per pkgbase).
: "${GG_PKGBUILDS:=$GG_ROOT/pkgbuilds}"

# Hand-maintained PKGBUILD directories that replace the official one for a
# pkgbase (overrides/<pkgbase>/PKGBUILD). Use when Arch's patches no longer
# apply to main, or when a package is not packaged from git upstream.
: "${GG_OVERRIDES:=$GG_ROOT/overrides}"

# Local pacman repository with the packages built from git.
: "${GG_REPO:=$GG_ROOT/repo}"
: "${GG_REPO_NAME:=gnome-git}"

# Snapshot of all official Arch packages needed to build/install the modules
# (dependency closure), turned into a second local repo for offline builds.
: "${GG_DEPS:=$GG_ROOT/pkgcache}"
: "${GG_DEPS_NAME:=gnome-git-deps}"

# Cargo registry cache for Rust modules (loupe, snapshot, papers ...), so that
# they can be built offline.
: "${GG_CARGO_HOME:=$GG_ROOT/cargo-home}"

: "${GG_LOGS:=$GG_ROOT/logs}"
: "${GG_STATE:=$GG_ROOT/state}"
: "${GG_MODULES:=$GG_ROOT/modules.list}"

# Scratch space on the BUILD machine (fast local disk): makepkg source
# mirrors, generated PKGBUILDs, build trees, ccache.
: "${GG_WORK:=${XDG_CACHE_HOME:-$HOME/.cache}/gnome-git}"

# Upstream locations.
: "${GG_ARCH_PKG_URL:=https://gitlab.archlinux.org/archlinux/packaging/packages}"
: "${GG_GNOME_URL:=https://gitlab.gnome.org/GNOME}"

# Packaging branches to prefer over the repo's default branch, highest
# priority first. Arch stages the next GNOME release on "gnome-unstable"
# while "main" still carries the previous stable series, and we build the
# development code, so that branch is the one whose metadata matches.
# A branch is only used when its pkgver is NEWER than the default branch's.
: "${GG_PKGBUILD_BRANCHES:=gnome-unstable}"

# Remote package repository (publish.sh). The packages are published as plain
# files in a git branch, not as release assets, because GitHub rewrites
# characters in asset names and 18 of our packages carry an epoch ("gjs-2:...").
# Set these in config.local.sh, or let setup.sh write them for you.
: "${GG_REMOTE:=}"
: "${GG_REMOTE_BRANCH:=arch}"
# What pacman on the other machine talks to. raw.githubusercontent serves any
# file in the branch with no extra setup; GitHub Pages works the same way if
# you enable it for the branch (https://<user>.github.io/<repo>/$arch).
: "${GG_REMOTE_URL:=}"
: "${GG_PUBLISH:=$GG_ROOT/publish}"

# Git ref built when a module line does not name one.
: "${GG_DEFAULT_REF:=main}"

# Parallelism for the build machine.
: "${GG_JOBS:=$(nproc)}"

# Personal settings live here and are never committed: paths, the remote
# repository, GG_JOBS, anything above. Created by setup.sh, or by hand.
[[ -r $GG_ROOT/config.local.sh ]] && source "$GG_ROOT/config.local.sh"
