#!/usr/bin/env bash
# build.sh - run on the BUILD machine (works offline once fetch.sh has run).
#
# For every selected module it takes the official Arch PKGBUILD, points its
# git sources at the checkout on the drive, derives pkgver from git, builds
# the package with makepkg, adds it to the local "gnome-git" repo and installs
# it so that the next module builds against it. Dependencies are resolved by
# pacman from the system repos or, offline, from the "gnome-git-deps" cache.
#
# usage: build.sh [options] [tier|pkgbase ...]
#   --from PKG        start with PKG in list order (resume a run)
#   --force           rebuild even when the commit did not change
#   --no-install      only build + add to repo (chain builds then use system deps)
#   --offline         use only the local repos (auto-detected when -Sy fails)
#   --check           run the test suites (default: --nocheck)
#   --stop-on-error   abort at the first failure (default: keep going)
#   --gen-only        only generate PKGBUILDs into $GG_WORK/pkg and list deps
#   --list            show the selection and cached build state
#   --remove PKG..    drop PKG from the repo and reinstall the stock version

source "$(dirname "$(readlink -f "$0")")/lib.sh"

FORCE=0 INSTALL=1 OFFLINE=0 CHECK=0 STOP=0 GEN_ONLY=0 LIST=0 REMOVE=0
sel=()
while (( $# )); do
    case $1 in
        --from) sel+=(--from "$2"); shift 2 ;;
        --force) FORCE=1; shift ;;
        --no-install) INSTALL=0; shift ;;
        --offline) OFFLINE=1; shift ;;
        --check) CHECK=1; shift ;;
        --stop-on-error) STOP=1; shift ;;
        --gen-only) GEN_ONLY=1; shift ;;
        --list) LIST=1; shift ;;
        --remove) REMOVE=1; shift ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) sel+=("$1"); shift ;;
    esac
done

(( EUID != 0 )) || die "run as a normal user (makepkg refuses root)"
need_cmd git makepkg pacman repo-add vercmp
[[ -d $GG_SRC ]] || die "source directory not found: $GG_SRC (is the drive mounted?)"

mapfile -t modules < <(select_modules "${sel[@]}")
(( ${#modules[@]} || REMOVE )) || die "no modules selected"

if (( LIST )); then
    printf '%-26s %-9s %-8s %-8s %s\n' MODULE TIER REF HEAD LAST-BUILT
    for m in "${modules[@]}"; do
        read -r pkgbase repo ref url tier <<<"$m"
        head=-; built=-
        dir=$(find_src_dir "$repo") && head=$(resolve_ref "$dir" "$ref" | cut -c1-7 || echo NOREF)
        [[ -f $GG_STATE/$pkgbase ]] && built=$(cut -c1-7 "$GG_STATE/$pkgbase")
        printf '%-26s %-9s %-8s %-8s %s\n' "$pkgbase" "$tier" "$ref" "$head" "$built"
    done
    exit 0
fi

mkdir -p "$GG_WORK"/{pkg,srcdest,ccache} "$GG_REPO" "$GG_LOGS" "$GG_STATE"

if [[ $(stat -c %u "$GG_SRC") != "$(id -u)" ]]; then
    warn "$GG_SRC is owned by uid $(stat -c %u "$GG_SRC"), you are $(id -u)."
    warn "git will refuse 'dubious ownership'; fix with chown or: git config --global --add safe.directory '*'"
fi

# ---------------------------------------------------------------- makepkg.conf
MAKEPKG_CONF="$GG_WORK/makepkg.conf"
{
    echo 'source /etc/makepkg.conf'
    echo "MAKEFLAGS=\"-j$GG_JOBS\""
    echo "SRCDEST='$GG_WORK/srcdest'"
    echo "PKGDEST='$GG_REPO'"
    echo "LOGDEST='$GG_LOGS'"
    echo "PACKAGER='gnome-git <$USER@${HOSTNAME:-$(uname -n)}>'"
    echo 'PACMAN_AUTH=(sudo)'
    echo 'OPTIONS=("${OPTIONS[@]/#debug/!debug}")'        # no -debug packages
    [[ ${GG_LTO:-0} == 1 ]] || echo 'OPTIONS=("${OPTIONS[@]/#lto/!lto}")'   # LTO: slow, RAM hungry
    if command -v ccache >/dev/null; then
        echo 'BUILDENV=("${BUILDENV[@]/#!ccache/ccache}")'
        echo "export CCACHE_DIR='$GG_WORK/ccache'"
    fi
    echo "export CARGO_HOME='$GG_CARGO_HOME'"
    (( OFFLINE )) && echo 'export CARGO_NET_OFFLINE=true'
} > "$MAKEPKG_CONF"

# ------------------------------------------------------------------ pacman.conf
PACMAN_CONF="$GG_WORK/pacman.conf"
[[ -f $GG_REPO/$GG_REPO_NAME.db.tar.zst ]] || repo-add -q "$GG_REPO/$GG_REPO_NAME.db.tar.zst" >/dev/null 2>&1
sync_repos() {
    write_pacman_conf "$PACMAN_CONF" "$1"
    local out
    if ! out=$(sudo pacman --config "$PACMAN_CONF" -Sy 2>&1); then
        printf '%s\n' "$out" | grep -i error >&2
        return 1
    fi
}
if (( ! GEN_ONLY )); then
    sudo_keepalive
    if [[ -e /var/lib/pacman/db.lck ]]; then
        if pgrep -x pacman >/dev/null; then
            die "another pacman is running (pid $(pgrep -x pacman | head -1)); wait for it to finish"
        fi
        die "stale pacman lock from an interrupted run: sudo rm /var/lib/pacman/db.lck"
    fi
    if (( OFFLINE )); then
        sync_repos offline || die "cannot read local repos"
    elif ! sync_repos online; then
        warn "system repos unreachable, switching to offline mode"
        OFFLINE=1
        echo 'export CARGO_NET_OFFLINE=true' >> "$MAKEPKG_CONF"
        sync_repos offline || die "cannot read local repos"
    fi
    msg "pacman config: $PACMAN_CONF ($( (( OFFLINE )) && echo offline || echo online ))"
    # makepkg needs the base-devel group (fakeroot, gcc, make, patch ...)
    if [[ -n $(pacman -T base-devel) ]] || ! command -v fakeroot >/dev/null; then
        msg2 "installing base-devel"
        sudo pacman --config "$PACMAN_CONF" -S --needed --noconfirm base-devel \
            || die "cannot install base-devel; makepkg needs it"
    fi
fi

# ------------------------------------------------------------------ --remove
if (( REMOVE )); then
    (( ${#sel[@]} )) || die "--remove needs pkgbase names"
    for pkgbase in "${sel[@]}"; do
        d=$(pkgbuild_dir "$pkgbase") || { warn "no PKGBUILD for $pkgbase"; continue; }
        mapfile -t names < <(srcinfo_field "$(srcinfo "$d")" pkgname)
        msg "removing $pkgbase from $GG_REPO_NAME: ${names[*]}"
        repo-remove -q "$GG_REPO/$GG_REPO_NAME.db.tar.zst" "${names[@]}" 2>/dev/null || true
        for n in "${names[@]}"; do rm -f "$GG_REPO/$n"-[0-9]*.pkg.tar.*; done
        rm -f "$GG_STATE/$pkgbase"
        sudo pacman --config "$PACMAN_CONF" -Sy >/dev/null
        mapfile -t inst < <(pacman -Qq "${names[@]}" 2>/dev/null)
        if (( ${#inst[@]} )); then
            msg2 "reinstalling stock: ${inst[*]}"
            sudo pacman --config "$PACMAN_CONF" -S --noconfirm "${inst[@]}"
        fi
    done
    exit 0
fi

# ----------------------------------------------------------- PKGBUILD generation
# All package names produced by our modules; version constraints on these are
# dropped from generated PKGBUILDs because git versions sort unpredictably.
declare -A OURS=()
for m in "${modules[@]}"; do
    read -r pkgbase repo ref url tier <<<"$m"
    d=$(pkgbuild_dir "$pkgbase") || continue
    for n in $(srcinfo_field "$(srcinfo "$d")" pkgname); do OURS[$n]=1; done
done

# gen_pkgbuild PKGBASE REPO SHA -> writes $GG_WORK/pkg/PKGBASE, prints primary dir name
gen_pkgbuild() {
    local pkgbase=$1 repo=$2 sha=$3
    local from dest info line entry name url base dir frag primary="" new=() n
    local rewritten=() i sums sumtype srcroot
    srcroot=$(find_src_dir "$repo") || return 2
    from=$(pkgbuild_dir "$pkgbase") || return 2
    dest="$GG_WORK/pkg/$pkgbase"
    rm -rf "$dest"; mkdir -p "$dest"
    cp -a "$from"/. "$dest"/; rm -rf "$dest/.git" "$dest/.SRCINFO" "$dest/src" "$dest/pkg"
    info=$(srcinfo "$from") || return 3

    while IFS= read -r line; do
        entry="$line" name="" url="$line"
        if [[ $entry == *::* ]]; then name="${entry%%::*}"; url="${entry#*::}"; fi
        if [[ $url != git+* ]]; then new+=("$entry"); continue; fi
        url="${url#git+}"; url="${url%%#*}"; url="${url%%\?*}"
        base="${url##*/}"; base="${base%.git}"
        if ! dir=$(find_src_dir "$base"); then new+=("$entry"); continue; fi
        if [[ $base == "$repo" ]]; then
            frag="#commit=$sha"; primary="${name:-$base}"
        else
            # helper repo: pin what the module's wrap file wants (arch-meson
            # enforces it), else Arch's pin if we have that commit, else HEAD.
            frag=""
            local want
            want=$(wrap_revision "$srcroot" "$base") || want="${line##*#commit=}"
            [[ $want == "$line" ]] && want=""
            if [[ -n $want ]] && git -C "$dir" rev-parse -q --verify "$want^{commit}" >/dev/null 2>&1; then
                frag="#commit=$(git -C "$dir" rev-parse "$want^{commit}")"
            fi
        fi
        new+=("${name:+$name::}git+file://$dir$frag")
        rewritten[${#new[@]}-1]=1
    done < <(srcinfo_field "$info" source)
    [[ -n $primary ]] || return 4

    # Drop version constraints on packages we build ourselves, so that a git
    # version such as 51.alpha.r12 is not rejected against mutter>=51.0.
    # Two guards keep this from eating meson options that happen to share a
    # name with one of our packages ("-D sysprof=enabled" is not a constraint):
    # skip any line carrying a -D option, and require a digit after the
    # operator, which every real version has and no feature value does.
    for n in "${!OURS[@]}"; do
        sed -i -E "/-D/!{ s/(^|[[:space:](\"'])(${n//[.+]/\\&})(>=|<=|>|<|=)[0-9][^\"'[:space:])]*/\1\2/g }" "$dest/PKGBUILD"
    done

    {
        printf '\n# >>> gnome-git: generated by build.sh, do not edit >>>\n'
        printf 'source=('; printf "'%s'\n        " "${new[@]}"; printf ')\n'
        # makepkg checks git sources against the recorded checksum, which can
        # only match the commit Arch packaged: skip it for rewritten sources.
        for sumtype in md5sums sha1sums sha224sums sha256sums sha384sums sha512sums b2sums; do
            mapfile -t sums < <(srcinfo_field "$info" "$sumtype")
            (( ${#sums[@]} == ${#new[@]} )) || continue
            for i in "${!rewritten[@]}"; do sums[i]=SKIP; done
            printf '%s=(' "$sumtype"; printf "'%s'\n        " "${sums[@]}"; printf ')\n'
        done
        printf "_gg_primary='%s'\n" "$primary"
        printf "_gg_src='%s'\n" "$GG_SRC"
        mapfile -t extra < <(extra_deps "$pkgbase")
        (( ${#extra[@]} )) && { printf 'makedepends+=('; printf "'%s' " "${extra[@]}"; printf ')\n'; }
        mapfile -t extra < <(extra_opts "$pkgbase")
        if (( ${#extra[@]} )); then
            printf '_gg_extra_opts=('; printf "'%s' " "${extra[@]}"; printf ')\n'
        else
            printf '_gg_extra_opts=()\n'
        fi
        [[ ${GG_STRICT_PATCHES:-0} == 1 ]] || cat <<'PKG'
# Arch patches are usually backports already merged upstream: apply them when
# they fit, skip them with a warning when they do not (GG_STRICT_PATCHES=1 to
# make failures fatal again).
git() {
    local sha rc
    case $1 in
        apply)
            if command git "$@" --check 2>/dev/null; then command git "$@"; else
                echo "gnome-git: patch does not apply, skipping: ${*: -1}" >&2; fi ;;
        cherry-pick|revert)
            shift; local opts=() subj; while [[ $1 == -* ]]; do opts+=("$1"); shift; done
            for sha in "$@"; do
                # already upstream? Arch backports get rebased when merged, so
                # the sha differs: match the subject line instead
                subj=$(command git log -1 --format=%s "$sha" 2>/dev/null || true)
                if [[ -n $subj ]] && command git log --format=%s HEAD | grep -Fxq "$subj"; then
                    echo "gnome-git: already upstream, skipping: $subj" >&2; continue
                fi
                if ! command git cherry-pick "${opts[@]}" "$sha" 2>/dev/null; then
                    command git cherry-pick --abort 2>/dev/null || command git reset -q --merge
                    echo "gnome-git: commit $sha does not apply, skipping" >&2
                fi
            done ;;
        *) command git "$@" ;;
    esac
}
patch() {
    if [[ " $* " == *" -i "* ]] && ! command patch --dry-run "$@" >/dev/null 2>&1; then
        echo "gnome-git: patch does not apply, skipping: $*" >&2; return 0; fi
    command patch "$@"
}
PKG
        cat <<PKG
_gg_cargo_home_value='$GG_CARGO_HOME'
PKG
        cat <<'PKG'
# True when the system provides a pkg-config module called NAME, or one named
# NAME-<version> (a wrap called "glib" is satisfied by glib-2.0).
_gg_pc_has() {
    pkg-config --exists "$1" 2>/dev/null && return 0
    pkg-config --list-all 2>/dev/null |
        awk -v n="$1" '{ if ($1 == n || index($1, n "-") == 1) { hit = 1; exit } } END { exit !hit }'
}
_gg_find() {
    local c
    for c in "$_gg_src/$1" "$_gg_src/$1.git" "$_gg_src"/*/"$1" "$_gg_src"/*/"$1.git"; do
        [[ -d $c/.git || -f $c/HEAD ]] && { printf '%s\n' "$c"; return 0; }
    done
    return 1
}
# TypeScript 6 fails with TS5011 unless rootDir is explicit, and turns
# deprecated options into errors. Upstream tsconfigs predate that.
_gg_fix_tsconfig() {
    local f="$srcdir/$_gg_primary/tsconfig.json"
    [[ -f $f ]] || return 0
    grep -q '"rootDir"' "$f" && return 0
    grep -q '"src"' "$f" || return 0
    sed -i '0,/"compilerOptions"[[:space:]]*:[[:space:]]*{/s//&\n    "rootDir": ".\/src",\n    "ignoreDeprecations": "6.0",/' "$f" \
        && echo "gnome-git: set rootDir and ignoreDeprecations in tsconfig.json" >&2
}

# Populate git submodules and meson wrap-git subprojects that upstream main
# needs but the Arch PKGBUILD does not provide, from the checkouts on the drive.
_gg_populate() {
    cd "$srcdir/$_gg_primary"
    local key path name url base src rev dir wrap
    if [[ -f .gitmodules ]]; then
        while read -r key path; do
            name=${key#submodule.}; name=${name%.path}
            [[ -n $(ls -A "$path" 2>/dev/null) ]] && continue
            url=$(command git config -f .gitmodules --get "submodule.$name.url" || true)
            [[ -n $url ]] || continue
            base=${url##*/}; base=${base%.git}
            src=$(_gg_find "$base" || true)
            [[ -n $src ]] || { echo "gnome-git: no checkout for submodule $path ($base)" >&2; continue; }
            command git config "submodule.$name.url" "$src"
            command git -c protocol.file.allow=always submodule update --init -- "$path" \
                || echo "gnome-git: submodule $path could not be checked out from $src" >&2
        done < <(command git config -f .gitmodules --get-regexp '^submodule\..*\.path$')
    fi
    for wrap in subprojects/*.wrap; do
        [[ -f $wrap ]] && grep -qs '^\[wrap-git\]' "$wrap" || continue
        name=${wrap##*/}; name=${name%.wrap}
        dir=$(tr -d '\r' < "$wrap" | sed -n 's/^directory *= *//p' | head -1); dir=${dir:-$name}
        [[ -n $(ls -A "subprojects/$dir" 2>/dev/null) ]] && continue
        # wraps are fallbacks: skip when the system already provides the
        # dependency or program (the [provide] section, else the wrap name)
        _gg_pc_has "$name" && continue
        command -v "$name" >/dev/null 2>&1 && continue
        if grep -qs '^\[provide\]' "$wrap"; then
            local found=0 k v
            while IFS='=' read -r k v; do
                k=${k//[[:space:]]/}; v=${v//[[:space:]]/}
                case $k in
                    dependency_names) for v in ${v//,/ }; do pkg-config --exists "$v" 2>/dev/null && found=1; done ;;
                    program_names)    for v in ${v//,/ }; do command -v "$v" >/dev/null && found=1; done ;;
                    "") ;;
                    *) pkg-config --exists "$k" 2>/dev/null && found=1 ;;
                esac
            done < <(tr -d '\r' < "$wrap" | sed -n '/^\[provide\]/,/^\[/{/^\[/d;p}')
            (( found )) && continue
        fi
        url=$(tr -d '\r' < "$wrap" | sed -n 's/^url *= *//p' | head -1); base=${url##*/}; base=${base%.git}
        rev=$(tr -d '\r' < "$wrap" | sed -n 's/^revision *= *//p' | head -1)
        src=$(_gg_find "$base" || true)
        [[ -n $src ]] || { echo "gnome-git: no checkout for wrap $name ($base)" >&2; continue; }
        rmdir "subprojects/$dir" 2>/dev/null || true
        command git clone -q "$src" "subprojects/$dir" || continue
        command git -C "subprojects/$dir" checkout -q "$rev" 2>/dev/null \
            || command git -C "subprojects/$dir" checkout -q "origin/$rev" 2>/dev/null \
            || echo "gnome-git: revision $rev not in $src, using its HEAD" >&2
        # meson overlays patch_directory / applies diff_files; do the same, or
        # the subproject has no meson.build (qrcodegen in gnome-desktop)
        local pdir pfile
        pdir=$(tr -d '\r' < "$wrap" | sed -n 's/^patch_directory *= *//p' | head -1)
        if [[ -n $pdir && -d subprojects/packagefiles/$pdir ]]; then
            cp -a "subprojects/packagefiles/$pdir/." "subprojects/$dir/"
            echo "gnome-git: applied patch_directory $pdir to $dir" >&2
        fi
        for pfile in $(tr -d '\r' < "$wrap" | sed -n 's/^diff_files *= *//p' | tr ',' ' '); do
            [[ -f subprojects/packagefiles/$pfile ]] || continue
            ( cd "subprojects/$dir" && command patch -p1 -i "../packagefiles/$pfile" ) >/dev/null \
                && echo "gnome-git: applied $pfile to $dir" >&2
        done
        echo "gnome-git: subproject $dir populated from $src"
    done
}
# Split-package helper: upstream main renames or drops binaries that Arch's
# file lists still name, which would fail the whole package() with "mv: cannot
# stat". Skip what was not built.
if declare -f _pick >/dev/null; then
    _pick() {
        local p="$1" f d; shift
        for f; do
            [[ -e $f || -L $f ]] || { echo "gnome-git: not built, skipping: $f" >&2; continue; }
            d="$srcdir/$p/${f#$pkgdir/}"
            mkdir -p "$(dirname "$d")"
            mv "$f" "$d"
            rmdir -p --ignore-fail-on-non-empty "$(dirname "$f")" 2>/dev/null || true
        done
    }
fi

# Arch passes meson options for the released version; main adds and removes
# options all the time. Drop the ones meson rejects and retry.
_gg_meson_setup() {
    # makepkg runs build() under errexit with an ERR trap and errtrace, so the
    # trap is inherited by the command substitution below and exits the shell
    # from inside it, before the captured output can be printed. Disarm it for
    # the duration of the retries and restore it before returning, so a real
    # failure still aborts the build at the call site.
    local -
    local _gg_err_trap rc
    _gg_err_trap=$(trap -p ERR)
    trap - ERR
    set +e
    _gg_meson_retry "$@"
    rc=$?
    [[ -n $_gg_err_trap ]] && eval "$_gg_err_trap"
    return $rc
}
_gg_meson_retry() {
    local prog=$1; shift
    local args=("$@") out rc try bad b i keep builddir
    # options Arch has not set for this package yet (see extra-opts.list);
    # anything meson does not know is dropped by the retry loop below
    (( ${#_gg_extra_opts[@]} )) && args+=("${_gg_extra_opts[@]}")
    for try in 1 2 3 4 5 6 7 8; do
        out=$(command "$prog" "${args[@]}" 2>&1); rc=$?
        printf '%s\n' "$out"
        (( rc == 0 )) && return 0
        mapfile -t bad < <(printf '%s\n' "$out" |
            sed -n 's/.*Unknown options\?: *//p' | tr -d '".' | tr ',' '\n' |
            sed 's/^ *//; s/ *$//' | grep -v '^$')
        (( ${#bad[@]} )) || return $rc
        for b in "${bad[@]}"; do
            keep=()
            for ((i = 0; i < ${#args[@]}; i++)); do
                if [[ ${args[i]} == "-D" && ${args[i+1]} == "$b="* ]]; then ((i++)); continue; fi
                [[ ${args[i]} == "-D$b="* ]] && continue
                keep+=("${args[i]}")
            done
            args=("${keep[@]}")
            echo "gnome-git: meson does not know option '$b', dropped" >&2
        done
        # a failed setup leaves a half-configured build directory behind
        builddir=""
        for ((i = ${#args[@]} - 1; i >= 0; i--)); do
            [[ ${args[i]} == -* || ${args[i]} == *=* ]] && continue
            builddir=${args[i]}; break
        done
        [[ -n $builddir && -d $builddir/meson-private ]] && rm -rf "$builddir"
    done
    return 1
}
arch-meson() { _gg_meson_setup arch-meson "$@"; }
meson() {
    if [[ $1 == setup ]]; then shift; _gg_meson_setup meson setup "$@"
    else command meson "$@"; fi
}

# Rust: PKGBUILDs (and meson files such as loupe's src/meson.build) pin
# CARGO_HOME to a path inside the build tree and expect prepare() to fill it
# from the network. Offline that path stays empty, so make it point at the
# crate cache on the drive instead of overriding the variable: meson starts
# cargo itself, with its own CARGO_HOME, and never sees our wrapper.
_gg_cargo_home="$_gg_cargo_home_value"
if [[ -d $_gg_cargo_home ]]; then
    _gg_cargo_link() {
        local ch=$1
        [[ -z $ch || $ch == "$_gg_cargo_home" ]] && return 0
        if [[ -L $ch ]]; then
            return 0
        elif [[ ! -e $ch ]]; then
            mkdir -p "$(dirname "$ch")"
            ln -sfn "$_gg_cargo_home" "$ch" &&
                echo "gnome-git: $ch -> $_gg_cargo_home" >&2
        elif [[ -d $ch && ! -e $ch/registry ]]; then
            # already created as a real directory: share the registry only
            mkdir -p "$ch"
            ln -sfn "$_gg_cargo_home/registry" "$ch/registry" &&
                echo "gnome-git: $ch/registry -> $_gg_cargo_home/registry" >&2
        fi
        return 0
    }
    cargo() {
        if [[ -n ${CARGO_HOME:-} && $CARGO_HOME != "$_gg_cargo_home" ]]; then
            _gg_cargo_link "$CARGO_HOME"
            command cargo "$@"
        else
            CARGO_HOME="$_gg_cargo_home" command cargo "$@"
        fi
    }
    # meson reads the path out of the build files, so link it up front too
    _gg_cargo_prelink() {
        local d
        for d in "$srcdir/build/cargo-home" "$srcdir/cargo-home" \
                 "$srcdir/$_gg_primary/build/cargo-home"; do
            _gg_cargo_link "$d"
        done
    }
fi

if declare -f prepare >/dev/null; then
    eval "_gg_orig_$(declare -f prepare)"
    prepare() {
        declare -f _gg_cargo_prelink >/dev/null && _gg_cargo_prelink
        _gg_orig_prepare; _gg_populate; _gg_fix_tsconfig
    }
else
    prepare() {
        declare -f _gg_cargo_prelink >/dev/null && _gg_cargo_prelink
        _gg_populate; _gg_fix_tsconfig
    }
fi
pkgver() {
    cd "$srcdir/$_gg_primary"
    # every failure has to stay inside the substitution: makepkg runs this with
    # errtrace and an ERR trap, which would otherwise exit from the subshell
    local v
    v=$(git describe --tags --long --abbrev=7 2>/dev/null || true)
    if [[ -n $v ]]; then
        v=$(printf '%s' "$v" | sed 's/^v//; s/\([^-]*-g\)/r\1/; s/-/./g')
    else
        v="0.r$(git rev-list --count HEAD).g$(git rev-parse --short=7 HEAD)"
    fi
    printf '%s\n' "${v//[^[:alnum:].+_]/.}"
}
PKG
        printf '# <<< gnome-git <<<\n'
    } >> "$dest/PKGBUILD"
    printf '%s\n' "$dest"
}

# install_deps PKGDIR - install what pacman says is missing.
install_deps() {
    local info deps missing
    info=$(srcinfo "$1") || return 1
    mapfile -t deps < <({ srcinfo_field "$info" depends; srcinfo_field "$info" makedepends
                          (( CHECK )) && srcinfo_field "$info" checkdepends; } | sort -u)
    (( ${#deps[@]} )) || return 0
    mapfile -t missing < <(pacman -T "${deps[@]}" || true)
    (( ${#missing[@]} )) || return 0
    msg2 "installing ${#missing[@]} dependencies: ${missing[*]}"
    sudo pacman --config "$PACMAN_CONF" -S --needed --asdeps --noconfirm "${missing[@]}"
}

# ------------------------------------------------------------------- main loop
declare -A status=()
start=$(date +%s)
mod_i=0 mod_n=${#modules[@]}
trap 'gg_title "gnome-git: stopped"' INT TERM
pbhash="" old_sha="" old_pbhash="" buildno=0 old_buildno=0
for m in "${modules[@]}"; do
    read -r pkgbase repo ref url tier <<<"$m"
    mod_i=$(( mod_i + 1 ))
    msg "[$mod_i/$mod_n] $pkgbase ($repo @ $ref)"
    gg_title "[$mod_i/$mod_n] $pkgbase"

    if ! dir=$(find_src_dir "$repo"); then
        warn "no checkout for $repo under $GG_SRC"; status[$pkgbase]="no-source"; continue
    fi
    if ! sha=$(resolve_ref "$dir" "$ref"); then
        warn "ref '$ref' not found in $dir"; status[$pkgbase]="bad-ref"; continue
    fi
    pkgdir=$(gen_pkgbuild "$pkgbase" "$repo" "$sha") && rc=0 || rc=$?
    if (( rc )); then
        case $rc in
            2) warn "no PKGBUILD in $GG_PKGBUILDS/$pkgbase or $GG_OVERRIDES/$pkgbase (run fetch.sh pkgbuilds)"; status[$pkgbase]="no-pkgbuild" ;;
            3) warn "PKGBUILD for $pkgbase does not parse"; status[$pkgbase]="bad-pkgbuild" ;;
            4) warn "PKGBUILD for $pkgbase has no git source for '$repo' (tarball based?); add overrides/$pkgbase"; status[$pkgbase]="no-git-source" ;;
        esac
        (( STOP )) && break || continue
    fi
    msg2 "PKGBUILD: $pkgdir (commit ${sha:0:7})"

    # Rebuild when the source commit moved OR when the packaging changed:
    # switching to Arch's gnome-unstable branch rewrites dependencies, split
    # packages and sonames, none of which the commit id reflects.
    pbhash=$(sha256sum "$pkgdir/PKGBUILD" | cut -d' ' -f1)
    buildno=0
    if [[ -f $GG_STATE/$pkgbase ]]; then
        read -r old_sha _ _ old_pbhash old_buildno < "$GG_STATE/$pkgbase"
        if [[ $old_sha == "$sha" ]]; then
            if [[ $old_pbhash == "$pbhash" ]] && (( ! FORCE && ! GEN_ONLY )); then
                msg2 "unchanged since last build (${sha:0:7}), skipping (use --force)"
                status[$pkgbase]="up-to-date"; continue
            fi
            [[ $old_pbhash != "$pbhash" ]] && msg2 "same commit, but the Arch PKGBUILD changed: rebuilding"
            # Same commit means pkgver() produces the same version, so pacman
            # would consider the rebuilt package identical and never install
            # it. Bump pkgrel so the corrected package actually replaces the
            # one on disk (Arch uses the same x.y pkgrel form for rebuilds).
            buildno=$(( ${old_buildno:-0} + 1 ))
            printf '\npkgrel+=".%s"   # gnome-git rebuild of the same commit\n' "$buildno" >> "$pkgdir/PKGBUILD"
            msg2 "rebuild of the same commit: pkgrel gets .$buildno"
        fi
    fi

    if (( GEN_ONLY )); then
        info=$(srcinfo "$pkgdir")
        printf '     deps: %s\n' "$({ srcinfo_field "$info" depends; srcinfo_field "$info" makedepends; } | strip_ver | sort -u | tr '\n' ' ')"
        status[$pkgbase]="generated"; continue
    fi

    log="$GG_LOGS/$pkgbase.log"
    gg_title "[$mod_i/$mod_n] $pkgbase - deps"
    if ! install_deps "$pkgdir" 2>&1 | tee "$log"; then
        err "dependency installation failed for $pkgbase (see $log)"; status[$pkgbase]="deps-failed"
        (( STOP )) && break || continue
    fi

    gg_title "[$mod_i/$mod_n] $pkgbase - building"
    makepkg_args=(--config "$MAKEPKG_CONF" --noconfirm --force --clean --log)
    (( CHECK )) || makepkg_args+=(--nocheck)
    if ! ( cd "$pkgdir" && makepkg "${makepkg_args[@]}" ) 2>&1 | tee -a "$log"; then
        err "build failed for $pkgbase (log: $log)"; status[$pkgbase]="FAILED"
        (( STOP )) && break || continue
    fi

    gg_title "[$mod_i/$mod_n] $pkgbase - installing"
    mapfile -t pkgfiles < <(cd "$pkgdir" && makepkg --config "$MAKEPKG_CONF" --packagelist)
    repo_add "$GG_REPO/$GG_REPO_NAME.db.tar.zst" "${pkgfiles[@]}"
    sudo pacman --config "$PACMAN_CONF" -Sy >/dev/null
    if (( INSTALL )); then
        msg2 "installing ${pkgfiles[*]##*/}"
        sudo pacman --config "$PACMAN_CONF" -U --needed --noconfirm "${pkgfiles[@]}" 2>&1 | tee -a "$log" \
            || warn "install of $pkgbase failed; later modules build against the system version"
    fi
    printf '%s %s %s %s %s\n' "$sha" "$(date -Is)" "${pkgfiles[0]##*/}" "$pbhash" "$buildno" > "$GG_STATE/$pkgbase"
    status[$pkgbase]="ok"
done

# --------------------------------------------------------------------- summary
echo
msg "Summary ($(( ($(date +%s) - start) / 60 )) min)"
{
    for m in "${modules[@]}"; do
        read -r pkgbase _ <<<"$m"
        printf '%-26s %s\n' "$pkgbase" "${status[$pkgbase]:-not-reached}"
    done
} | tee "$GG_STATE/last-build.txt"
bad=0; for s in "${status[@]}"; do [[ $s == ok || $s == up-to-date || $s == generated ]] || bad=$((bad+1)); done
trap - INT TERM
gg_title "gnome-git: $(( mod_n - bad ))/$mod_n ok$( (( bad )) && printf ', %s failed' "$bad" )"
(( GEN_ONLY )) || msg2 "repo: $GG_REPO ($(ls "$GG_REPO"/*.pkg.tar.* 2>/dev/null | wc -l) package files)"
(( bad == 0 )) || { warn "$bad module(s) need attention; logs in $GG_LOGS"; exit 1; }
