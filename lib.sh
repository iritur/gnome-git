#!/usr/bin/env bash
# lib.sh - shared helpers for the gnome-git toolkit. Sourced, not executed.
set -euo pipefail
shopt -s nullglob

GG_ROOT="${GG_ROOT:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)}"
# shellcheck source=config.sh
source "$GG_ROOT/config.sh"

msg()  { printf '\e[1;32m==>\e[0m \e[1m%s\e[0m\n' "$*"; }
msg2() { printf '  \e[1;34m->\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33m==> WARNING:\e[0m %s\n' "$*" >&2; }
err()  { printf '\e[1;31m==> ERROR:\e[0m %s\n' "$*" >&2; }
die()  { err "$@"; exit 1; }

# gg_title TEXT - put TEXT in the terminal's title bar / tab header.
# GNOME Console binds its tab title to VTE's window-title, and Ptyxis reads
# the same property, so the OSC 0 sequence below shows up in both. Written to
# /dev/tty rather than stdout so it still works when output is redirected;
# probed once, because a session with no controlling terminal has none.
# Set GG_TITLE=0 to turn it off.
gg_title() {
    [[ ${GG_TITLE:-1} == 1 ]] || return 0
    if [[ -z ${_GG_TTY_OK:-} ]]; then
        if { : > /dev/tty; } 2>/dev/null; then _GG_TTY_OK=1; else _GG_TTY_OK=0; fi
    fi
    (( _GG_TTY_OK )) || return 0
    { printf '\033]0;%s\007' "$*" > /dev/tty; } 2>/dev/null
    return 0
}

need_cmd() {
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
    done
}

# read_modules - print every enabled module as: pkgbase repo ref url tier
# modules.list format (whitespace separated, '#' comments, '-' = default):
#   [tier]
#   pkgbase  [repo-name]  [ref]  [clone-url]
read_modules() {
    local line tier=core pkgbase repo ref url rest
    [[ -r $GG_MODULES ]] || die "module list not found: $GG_MODULES"
    while IFS= read -r line || [[ -n $line ]]; do
        line="${line%%#*}"
        [[ -z ${line//[[:space:]]/} ]] && continue
        if [[ $line =~ ^[[:space:]]*\[([A-Za-z0-9_-]+)\] ]]; then
            tier="${BASH_REMATCH[1]}"; continue
        fi
        read -r pkgbase repo ref url rest <<<"$line"
        [[ -z $repo || $repo == - ]] && repo="$pkgbase"
        [[ -z $ref  || $ref  == - ]] && ref="$GG_DEFAULT_REF"
        [[ -z $url  || $url  == - ]] && url="$GG_GNOME_URL/$repo.git"
        printf '%s %s %s %s %s\n' "$pkgbase" "$repo" "$ref" "$url" "$tier"
    done < "$GG_MODULES"
}

# select_modules [--from PKG] [tier|pkgbase ...] - filter read_modules output.
select_modules() {
    local from="" sel=() started=1 m
    while (( $# )); do
        case $1 in
            --from) from="$2"; started=0; shift 2 ;;
            *) sel+=("$1"); shift ;;
        esac
    done
    while read -r m; do
        set -- $m
        if (( ! started )); then
            [[ $1 == "$from" ]] && started=1 || continue
        fi
        if (( ${#sel[@]} )); then
            local hit=0 s
            for s in "${sel[@]}"; do [[ $s == "$1" || $s == "$5" ]] && hit=1; done
            (( hit )) || continue
        fi
        printf '%s\n' "$m"
    done < <(read_modules)
}

# find_src_dir REPO - locate the git checkout for upstream repo name REPO.
find_src_dir() {
    local name=$1 c
    for c in "$GG_SRC/$name" "$GG_SRC/$name.git" "$GG_SRC"/*/"$name" "$GG_SRC"/*/"$name.git"; do
        [[ -d $c ]] || continue
        # must be a repository ROOT (.git dir or file) or a bare repo; a plain
        # subdirectory of a checkout (an uninitialised submodule, say) is not
        # usable as a clone source even though git commands succeed inside it
        if [[ -e $c/.git ]] || [[ -f $c/HEAD && -d $c/objects ]]; then
            printf '%s\n' "$c"; return 0
        fi
    done
    return 1
}

# resolve_ref DIR REF - print the commit sha for REF, preferring the
# remote-tracking branch (fresh after a plain 'git fetch').
resolve_ref() {
    local dir=$1 ref=$2 sha c
    local cands=("refs/remotes/origin/$ref" "refs/heads/$ref" "refs/tags/$ref" "$ref")
    if [[ $ref == "$GG_DEFAULT_REF" ]]; then
        # No ref pinned in modules.list, so the remote decides what "current"
        # means. Ask it first: some projects keep an abandoned branch named
        # main next to the branch they actually develop on (simple-scan's
        # origin/main is years behind its default branch, master).
        cands=(refs/remotes/origin/HEAD "${cands[@]}" refs/heads/master)
    fi
    for c in "${cands[@]}"; do
        if sha=$(git -C "$dir" rev-parse --verify -q "$c^{commit}" 2>/dev/null); then
            printf '%s\n' "$sha"; return 0
        fi
    done
    return 1
}

# srcinfo_ver DIR REF - full version from the .SRCINFO committed at REF.
srcinfo_ver() {
    git -C "$1" show "$2:.SRCINFO" 2>/dev/null | awk '
        $1 == "epoch"  { e = $3 }
        $1 == "pkgver" { v = $3 }
        $1 == "pkgrel" { r = $3 }
        END { if (v == "") exit 1
              printf "%s%s-%s\n", (e != "" ? e ":" : ""), v, (r != "" ? r : 1) }'
}

# pick_pkgbuild_ref DIR - the packaging ref whose metadata matches what we
# build: a branch from GG_PKGBUILD_BRANCHES when its version is newer than
# the repo's default branch, else the default branch.
pick_pkgbuild_ref() {
    local dir=$1 best bv ref v b
    best=$(git -C "$dir" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null) || best=""
    [[ -n $best ]] || best=origin/main
    bv=$(srcinfo_ver "$dir" "$best" 2>/dev/null) || bv=""
    for b in $GG_PKGBUILD_BRANCHES; do
        ref="origin/$b"
        git -C "$dir" rev-parse --verify -q "$ref" >/dev/null 2>&1 || continue
        v=$(srcinfo_ver "$dir" "$ref" 2>/dev/null) || continue
        if [[ -z $bv ]] || (( $(vercmp "$v" "$bv") > 0 )); then best=$ref; bv=$v; fi
    done
    printf '%s\n' "$best"
}

# pkgbuild_dir PKGBASE - override dir if present, else official clone.
pkgbuild_dir() {
    local p=$1
    if [[ -f $GG_OVERRIDES/$p/PKGBUILD ]]; then printf '%s\n' "$GG_OVERRIDES/$p"
    elif [[ -f $GG_PKGBUILDS/$p/PKGBUILD ]]; then printf '%s\n' "$GG_PKGBUILDS/$p"
    else return 1
    fi
}

# srcinfo DIR - print .SRCINFO for the PKGBUILD in DIR.
srcinfo() {
    # Arch packaging repos ship a committed .SRCINFO; use it when current.
    if [[ -f $1/.SRCINFO ]] && git -C "$1" diff --quiet -- PKGBUILD .SRCINFO 2>/dev/null; then cat "$1/.SRCINFO"
    else ( cd "$1" && makepkg --printsrcinfo 2>/dev/null ); fi
}

# git_sources SRCINFO-TEXT - print "basename url" for every git+ source.
git_sources() {
    local e url base
    while IFS= read -r e; do
        url="${e#*::}"; [[ $url == git+* ]] || continue
        url="${url#git+}"; url="${url%%#*}"; url="${url%%\?*}"
        base="${url##*/}"; base="${base%.git}"
        printf '%s %s\n' "$base" "$url"
    done < <(srcinfo_field "$1" source)
}

# srcinfo_field SRCINFO-TEXT FIELD - values of FIELD (all packages merged).
srcinfo_field() {
    printf '%s\n' "$1" | awk -v f="$2" '$1 == f && $2 == "=" && $3 != "" { print $3 }'
}

# checkout_helpers DIR - print "basename url kind" for every git submodule
# (.gitmodules) and every meson wrap-git subproject of a checkout.
checkout_helpers() {
    local dir=$1 url base w
    if [[ -f $dir/.gitmodules ]]; then
        while read -r _ url; do
            base="${url##*/}"; base="${base%.git}"
            printf '%s %s submodule\n' "$base" "$url"
        done < <(git config -f "$dir/.gitmodules" --get-regexp '^submodule\..*\.url$' 2>/dev/null)
    fi
    for w in "$dir"/subprojects/*.wrap; do
        grep -qs '^\[wrap-git\]' "$w" || continue
        url=$(tr -d '\r' < "$w" | sed -n 's/^url *= *//p' | head -1)
        [[ -n $url ]] || continue
        base="${url##*/}"; base="${base%.git}"
        # a [provide] section means "fallback for a system dependency"; no
        # [provide] means the project uses the subproject directly
        if grep -qs '^\[provide\]' "$w"; then printf '%s %s wrap-fallback\n' "$base" "$url"
        else printf '%s %s wrap\n' "$base" "$url"; fi
    done
}

# arch_has_package NAME - true when a repo package with that (lowercased)
# name exists; used to judge whether a fallback wrap is likely needed.
arch_has_package() {
    local n=${1,,} c
    for c in "$n" "lib$n" "${n#lib}" "${n}2" "${n//_/-}"; do
        pacman -Si "$c" >/dev/null 2>&1 && return 0
    done
    return 1
}

# wrap_revision DIR BASENAME - revision a checkout's wrap file pins for a repo.
wrap_revision() {
    local w url base
    for w in "$1"/subprojects/*.wrap; do
        grep -qs '^\[wrap-git\]' "$w" || continue
        url=$(tr -d '\r' < "$w" | sed -n 's/^url *= *//p' | head -1)
        base="${url##*/}"; base="${base%.git}"
        [[ $base == "$2" ]] || continue
        tr -d '\r' < "$w" | sed -n 's/^revision *= *//p' | head -1; return 0
    done
    return 1
}

# extra_deps PKGBASE - extra makedepends from extra-deps.list.
extra_deps() {
    [[ -r $GG_ROOT/extra-deps.list ]] || return 0
    awk -v p="$1" '$1 == p { for (i = 2; i <= NF; i++) if ($i !~ /^#/) print $i; else exit }' "$GG_ROOT/extra-deps.list"
}

# extra_opts PKGBASE - extra meson options from extra-opts.list.
extra_opts() {
    [[ -r $GG_ROOT/extra-opts.list ]] || return 0
    awk -v p="$1" '$1 == p { for (i = 2; i <= NF; i++) if ($i !~ /^#/) print $i; else exit }' "$GG_ROOT/extra-opts.list"
}

# is_excluded NAME - true when NAME matches a pattern in exclude.list.
is_excluded() {
    local name=$1 pat
    [[ -r $GG_ROOT/exclude.list ]] || return 1
    while IFS= read -r pat || [[ -n $pat ]]; do
        pat=${pat%%#*}; pat=${pat//[[:space:]]/}
        [[ -z $pat ]] && continue
        # deliberately unquoted: pat is a glob
        [[ $name == $pat ]] && return 0
    done < "$GG_ROOT/exclude.list"
    return 1
}

# filter_excluded - drop excluded package names read from stdin.
filter_excluded() {
    local n
    while IFS= read -r n; do is_excluded "$n" || printf '%s\n' "$n"; done
}

# strip_ver NAME... - drop version constraints (foo>=1.2 -> foo).
strip_ver() { sed -E 's/[<>=].*$//' ; }

# repo_add DB FILES... - add packages to a local repo db (creates it).
repo_add() {
    local db=$1; shift
    mkdir -p "$(dirname "$db")"
    repo-add -q -R "$db" "$@"
}

# prune_pkg_versions DIR - keep only the newest version of each package file.
prune_pkg_versions() {
    local dir=$1 f name ver arch base
    declare -A best
    for f in "$dir"/*.pkg.tar.*; do
        [[ $f == *.sig ]] && continue
        base="${f##*/}"; base="${base%.pkg.tar.*}"
        arch="${base##*-}"; base="${base%-*}"       # strip arch
        ver="${base##*-}";  base="${base%-*}"       # strip pkgrel
        ver="${base##*-}-$ver"; name="${base%-*}"   # pkgver-pkgrel, name
        if [[ -n ${best[$name]:-} ]]; then
            if (( $(vercmp "$ver" "${best[$name]%%|*}") > 0 )); then
                rm -f "${best[$name]#*|}" "${best[$name]#*|}.sig"
                best[$name]="$ver|$f"
            else
                rm -f "$f" "$f.sig"
            fi
        else
            best[$name]="$ver|$f"
        fi
    done
}

# pacman_conf_options - the [options] section of the system pacman.conf.
pacman_conf_options() {
    awk '/^\[/{ if ($0 != "[options]") exit } { print }' /etc/pacman.conf
}

# write_pacman_conf FILE MODE(online|offline) - build-time pacman.conf that
# knows the local repos. Online mode keeps the system repos as well.
write_pacman_conf() {
    local file=$1 mode=$2 have_deps=0
    [[ -f $GG_DEPS/$GG_DEPS_NAME.db.tar.zst ]] && have_deps=1
    {
        if [[ $mode == online ]]; then
            awk -v repo="$GG_REPO_NAME" -v dir="$GG_REPO" '
                /^\[/ && $0 != "[options]" && !done {
                    printf "[%s]\nSigLevel = Optional TrustAll\nServer = file://%s\n\n", repo, dir; done=1 }
                { print }' /etc/pacman.conf
        else
            pacman_conf_options
            printf '[%s]\nSigLevel = Optional TrustAll\nServer = file://%s\n\n' "$GG_REPO_NAME" "$GG_REPO"
        fi
        if (( have_deps )); then
            printf '[%s]\nSigLevel = PackageRequired DatabaseNever\nServer = file://%s\n' "$GG_DEPS_NAME" "$GG_DEPS"
        fi
    } > "$file"
}

# sudo_keepalive - ask for the password once and keep the ticket fresh.
sudo_keepalive() {
    sudo -v || die "sudo access is required (pacman installs dependencies)"
    ( while kill -0 "$$" 2>/dev/null; do sudo -n true 2>/dev/null; sleep 50; done ) &
    GG_SUDO_PID=$!
    trap 'kill "$GG_SUDO_PID" 2>/dev/null' EXIT
}
