#!/usr/bin/env bash
# fetch.sh - run on the machine WITH internet. Refreshes everything the build
# machine needs, all of it stored under GG_ROOT (the SCSI drive):
#
#   sources     clone/update the GNOME git checkouts   -> $GG_SRC
#   pkgbuilds   clone/update official Arch PKGBUILDs   -> $GG_PKGBUILDS
#   deps        download the full dependency closure   -> $GG_DEPS (local repo)
#               (--dry-run: only resolve and list, no sudo)
#   cargo       cache crates for Rust modules           -> $GG_CARGO_HOME
#   all         all of the above (default)
#   check       report what is missing / mismatched, no network needed
#
# usage: fetch.sh [step ...] [--] [tier|pkgbase ...]

source "$(dirname "$(readlink -f "$0")")/lib.sh"
need_cmd git makepkg pacman vercmp repo-add

steps=() sel=() DRY=0
for a in "$@"; do
    case $a in
        sources|pkgbuilds|deps|cargo|all|check) steps+=("$a") ;;
        --dry-run) DRY=1 ;;      # deps: resolve and list, download nothing (no sudo)
        --) ;;
        *) sel+=("$a") ;;
    esac
done
(( ${#steps[@]} )) || steps=(all)
[[ " ${steps[*]} " == *" all "* ]] && steps=(sources pkgbuilds deps cargo)

mkdir -p "$GG_SRC" "$GG_PKGBUILDS" "$GG_DEPS" "$GG_LOGS" "$GG_STATE"
mapfile -t modules < <(select_modules "${sel[@]}")
(( ${#modules[@]} )) || die "no modules selected"
failed=()

git_try() {   # git_try DESC CMD... - run a network git command, retry on failure
    local what=$1 try; shift
    for try in 1 2 3 4; do
        "$@" && return 0
        (( try < 4 )) || break
        warn "$what: attempt $try failed, retrying in $((try * 5))s"
        sleep $((try * 5))
    done
    return 1
}

git_update() {   # git_update DIR URL DESC
    local dir=$1 url=$2 what=$3
    if [[ -d $dir ]]; then
        msg2 "updating $what"
        git_try "$what" git -C "$dir" fetch --all --tags --prune -q || return 1
        # keep origin/HEAD on the remote's current default branch: a plain
        # fetch never updates it, and resolve_ref trusts it to decide what
        # "latest" means when modules.list pins no ref
        git -C "$dir" remote set-head origin -a >/dev/null 2>&1 || true
        # fast-forward the checked-out branch when that is safe
        if git -C "$dir" symbolic-ref -q HEAD >/dev/null \
           && git -C "$dir" diff --quiet && git -C "$dir" diff --cached --quiet; then
            git -C "$dir" merge -q --ff-only '@{u}' 2>/dev/null || true
        fi
    else
        msg2 "cloning $what"
        git_try "$what" git clone -q "$url" "$dir" && return 0
        rm -rf "$dir"      # never leave a half clone behind
        return 1
    fi
}

step_sources() {
    msg "Sources -> $GG_SRC"
    local m pkgbase repo ref url tier dir pb base surl
    declare -A seen=()
    for m in "${modules[@]}"; do
        read -r pkgbase repo ref url tier <<<"$m"
        dir=$(find_src_dir "$repo" || printf '%s\n' "$GG_SRC/$repo")
        gg_title "fetch sources: $repo"
        git_update "$dir" "$url" "$repo" || failed+=("source:$repo")
        seen[$repo]=1
        # helper repos: extra git sources of the PKGBUILD, git submodules and
        # meson wrap-git subprojects of the checkout
        pb=$(pkgbuild_dir "$pkgbase") || pb=""
        while read -r base surl kind; do
            [[ -n ${seen[$base]:-} ]] && continue
            seen[$base]=1
            [[ $surl == *flathub* ]] && continue
            [[ $kind == wrap* ]] && arch_has_package "$base" && continue
            dir=$(find_src_dir "$base" || printf '%s\n' "$GG_SRC/$base")
            git_update "$dir" "$surl" "$base (used by $pkgbase)" || failed+=("source:$base")
        done < <({ [[ -n $pb ]] && git_sources "$(srcinfo "$pb")"; checkout_helpers "$dir"; } 2>/dev/null)
    done
}

step_pkgbuilds() {
    msg "Arch PKGBUILDs -> $GG_PKGBUILDS"
    local m pkgbase repo ref url tier
    for m in "${modules[@]}"; do
        read -r pkgbase repo ref url tier <<<"$m"
        # a hand-written override replaces Arch's packaging, and for packages
        # Arch does not have (libgom-2) there is nothing to clone
        if [[ -f $GG_OVERRIDES/$pkgbase/PKGBUILD ]]; then
            msg2 "$pkgbase: using overrides/$pkgbase, no Arch packaging needed"
        elif git_update "$GG_PKGBUILDS/$pkgbase" "$GG_ARCH_PKG_URL/$pkgbase.git" "PKGBUILD $pkgbase"; then
            # build from the branch whose packaging matches the code we build
            ref=$(pick_pkgbuild_ref "$GG_PKGBUILDS/$pkgbase")
            if ! git -C "$GG_PKGBUILDS/$pkgbase" checkout -q --force --detach "$ref" 2>/dev/null; then
                warn "cannot check out $ref for $pkgbase"
            elif [[ $ref != origin/main ]]; then
                msg2 "$pkgbase: using packaging branch ${ref#origin/} ($(srcinfo_ver "$GG_PKGBUILDS/$pkgbase" HEAD))"
            fi
        else
            failed+=("pkgbuild:$pkgbase")
        fi
    done
}

step_deps() {
    msg "Dependency closure -> $GG_DEPS"
    if (( ! DRY )); then
        msg2 "refreshing sync databases (sudo)"
        sudo pacman -Sy >/dev/null || die "pacman -Sy failed"
    fi

    local m pkgbase repo ref url tier dir info deps=() ours=()
    for m in "${modules[@]}"; do
        read -r pkgbase repo ref url tier <<<"$m"
        dir=$(pkgbuild_dir "$pkgbase") || { warn "no PKGBUILD for $pkgbase, skipping its deps"; continue; }
        info=$(srcinfo "$dir") || { warn "cannot parse PKGBUILD for $pkgbase"; continue; }
        mapfile -t -O "${#deps[@]}" deps < <(
            { srcinfo_field "$info" depends; srcinfo_field "$info" makedepends
              srcinfo_field "$info" checkdepends; } | strip_ver)
        mapfile -t -O "${#ours[@]}" ours < <(srcinfo_field "$info" pkgname)
        mapfile -t -O "${#deps[@]}" deps < <(extra_deps "$pkgbase")
    done
    # Soname deps (libfoo.so) resolve to packages that are listed anyway and
    # would make pacman complain about duplicate targets.
    mapfile -t deps < <(printf '%s\n' "${deps[@]}" base-devel git ccache | grep -v '\.so$' | grep -v '^$' | sort -u)

    # Resolve against an EMPTY local database so pacman downloads the whole
    # transitive closure (not only what this machine happens to lack).
    local tmpdb; tmpdb=$(mktemp -d)
    mkdir -p "$tmpdb/local" "$tmpdb/sync"
    cp /var/lib/pacman/sync/*.db "$tmpdb/sync/"

    # Packages built from git by this list are not fetched from Arch: they are
    # removed from the targets and declared present to the resolver, with the
    # exact provides (sonames) the stock package has. GG_DEPS_STOCK=1 keeps
    # them as a fallback for failed builds.
    local assume=() n prov
    if [[ ${GG_DEPS_STOCK:-0} != 1 ]]; then
        mapfile -t deps < <(printf '%s\n' "${deps[@]}" | grep -vxF -f <(printf '%s\n' "${ours[@]}"))
        while read -r n prov; do
            assume+=(--assume-installed "$n=999:999")
            for p in $prov; do
                [[ $p == None ]] && continue
                [[ $p == *=* ]] || p="$p=999:999"
                assume+=(--assume-installed "$p")
            done
        done < <(pacman -Si --dbpath "$tmpdb" "${ours[@]}" 2>/dev/null \
                 | awk '/^Name/{n=$3} /^Provides/{ $1=$2=""; print n, $0 }')
        msg2 "${#ours[@]} packages built from git are excluded (GG_DEPS_STOCK=1 to include)"
    fi
    msg2 "${#deps[@]} targets"

    local cmd out unknown try rc=1
    if (( DRY )); then
        cmd=(pacman -Sp --noconfirm --dbpath "$tmpdb" --logfile "$GG_LOGS/pacman-fetch.log" "${assume[@]}")
    else
        # pacman 7 downloads as root (sandboxed "alpm" user), hence sudo.
        cmd=(sudo pacman -Sw --noconfirm --dbpath "$tmpdb" --cachedir "$GG_DEPS"
             --logfile "$GG_LOGS/pacman-fetch.log" "${assume[@]}")
    fi
    # Names that no repo provides (typos, AUR-only) or that pacman already
    # pulled in through a virtual name ("duplicate target") abort the whole
    # download; drop them and retry.
    for try in 1 2 3 4 5 6 7 8; do
        if out=$("${cmd[@]}" "${deps[@]}" 2>&1 | tee /dev/stderr); then rc=0; break; fi
        mapfile -t unknown < <(printf '%s\n' "$out" | sed -n "s/.*target not found: \(.*\)/\1/p; s/.*error: '\(.*\)': duplicate target/\1/p")
        (( ${#unknown[@]} )) || break
        warn "dropping from targets and retrying: ${unknown[*]}"
        mapfile -t deps < <(printf '%s\n' "${deps[@]}" | grep -vxF -f <(printf '%s\n' "${unknown[@]}"))
    done
    rm -rf "$tmpdb"
    (( rc == 0 )) || die "dependency download failed"
    if (( DRY )); then
        msg2 "would download $(printf '%s\n' "$out" | grep -c 'pkg\.tar') packages"
        return
    fi
    sudo chown -R "$(id -u):$(id -g)" "$GG_DEPS" "$GG_LOGS"

    msg2 "pruning old versions and rebuilding the $GG_DEPS_NAME repo"
    prune_pkg_versions "$GG_DEPS"
    rm -f "$GG_DEPS/$GG_DEPS_NAME".{db,files}*
    find "$GG_DEPS" -maxdepth 1 -name "*.pkg.tar.*" ! -name "*.sig" -print0 | xargs -0 repo-add -q "$GG_DEPS/$GG_DEPS_NAME.db.tar.zst"
    du -sh "$GG_DEPS" | awk '{ print "  -> cache size: " $1 }'
}

step_cargo() {
    msg "Cargo registry cache -> $GG_CARGO_HOME"
    command -v cargo >/dev/null || { warn "cargo not installed; Rust modules will need network when building"; return; }
    local m pkgbase repo ref url tier dir
    for m in "${modules[@]}"; do
        read -r pkgbase repo ref url tier <<<"$m"
        dir=$(find_src_dir "$repo") || continue
        local lock toml out
        while IFS= read -r lock; do
            msg2 "cargo fetch ${lock#$GG_SRC/}"
            CARGO_HOME="$GG_CARGO_HOME" cargo fetch --locked --manifest-path "${lock%Cargo.lock}Cargo.toml" -q \
                || failed+=("cargo:${lock#$GG_SRC/}")
        done < <(git -C "$dir" ls-files -z -- 'Cargo.lock' '**/Cargo.lock' | xargs -0 -I{} printf '%s/{}\n' "$dir")
        # crates whose manifest ships no lockfile (papers/thumbnailer) still
        # have to resolve offline later, so prime the index cache for them too
        while IFS= read -r toml; do
            [[ -f ${toml%Cargo.toml}Cargo.lock ]] && continue
            msg2 "cargo fetch ${toml#$GG_SRC/} (no lockfile)"
            out=$(CARGO_HOME="$GG_CARGO_HOME" cargo fetch --manifest-path "$toml" 2>&1) || {
                # workspace members resolve through their root; not a failure
                grep -q 'workspace' <<<"$out" || failed+=("cargo:${toml#$GG_SRC/}")
            }
            # do not leave a generated lockfile behind in the checkout
            [[ -f ${toml%Cargo.toml}Cargo.lock ]] &&
                git -C "$dir" ls-files --error-unmatch "${toml%Cargo.toml}Cargo.lock" >/dev/null 2>&1 ||
                rm -f "${toml%Cargo.toml}Cargo.lock"
        done < <(git -C "$dir" ls-files -z -- 'Cargo.toml' '**/Cargo.toml' | xargs -0 -I{} printf '%s/{}\n' "$dir")
    done
}

step_check() {
    msg "Checking modules"
    local m pkgbase repo ref url tier dir pb sha state ok=0 bad=0
    printf '%-26s %-9s %-9s %-10s %-8s %s\n' MODULE SOURCE PKGBUILD GIT-SRC REF BUILT
    for m in "${modules[@]}"; do
        read -r pkgbase repo ref url tier <<<"$m"
        local s=missing p=missing g=- r=- b=-
        if dir=$(find_src_dir "$repo"); then
            s=ok
            r=$(resolve_ref "$dir" "$ref" | cut -c1-7) || r=NOREF
        fi
        if pb=$(pkgbuild_dir "$pkgbase"); then
            p=ok; [[ $pb == "$GG_OVERRIDES"/* ]] && p=override
            if git_sources "$(srcinfo "$pb")" | grep -E "^${repo} " >/dev/null; then g=yes; else g=NO; fi
        fi
        [[ -f $GG_STATE/$pkgbase ]] && b=$(cut -c1-7 "$GG_STATE/$pkgbase")
        printf '%-26s %-9s %-9s %-10s %-8s %s\n' "$pkgbase" "$s" "$p" "$g" "$r" "$b"
        if [[ $s == ok && $p != missing && $g == yes && $r != NOREF ]]; then ok=$((ok+1)); else bad=$((bad+1)); fi
    done
    printf '\n%d ready, %d need attention\n' "$ok" "$bad"
    # helper repos (submodules / wrap-git subprojects / extra PKGBUILD sources)
    local -A helper=() ; local base surl kind pb
    for m in "${modules[@]}"; do
        read -r pkgbase repo ref url tier <<<"$m"
        dir=$(find_src_dir "$repo") || continue
        pb=$(pkgbuild_dir "$pkgbase") || pb=""
        while read -r base surl kind; do
            [[ -n ${helper[$base]:-} ]] && continue
            find_src_dir "$base" >/dev/null && continue
            [[ $surl == *flathub* ]] && continue          # flatpak manifests, not builds
            if [[ $kind == wrap* ]]; then
                # a wrap for something Arch packages is a fallback meson never uses
                arch_has_package "$base" && continue
                helper[$base]="$surl (wrap of $pkgbase; needed unless the system provides it)"
            else
                helper[$base]="$surl (${kind:-source} of $pkgbase)"
            fi
        done < <({ [[ -n $pb ]] && git_sources "$(srcinfo "$pb")"; checkout_helpers "$dir"; } 2>/dev/null)
    done
    # a source update can move lockfiles ahead of the crate cache, which only
    # shows up as "no matching package named X" an hour into the build
    local lock stale=() missing cachedir
    cachedir=$(printf '%s\n' "$GG_CARGO_HOME"/registry/cache/*/ 2>/dev/null | head -1)
    if [[ -d $cachedir ]]; then
        for m in "${modules[@]}"; do
            read -r pkgbase repo ref url tier <<<"$m"
            dir=$(find_src_dir "$repo") || continue
            while IFS= read -r lock; do
                missing=$(awk '/^\[\[package\]\]/ { n=""; v=""; next }
                               /^name = / { gsub(/"/, "", $3); n=$3; next }
                               /^version = / { gsub(/"/, "", $3); v=$3; next }
                               /^source = "registry/ { print n "-" v ".crate" }' "$lock" |
                          while read -r c; do [[ -f $cachedir$c ]] || echo x; done | wc -l)
                (( missing )) && stale+=("$pkgbase: $missing crates missing (${lock#$GG_SRC/})")
            done < <(git -C "$dir" ls-files -z -- 'Cargo.lock' '**/Cargo.lock' | xargs -0 -I{} printf '%s/{}\n' "$dir")
        done
    fi
    if (( ${#stale[@]} )); then
        printf '\ncrate cache out of date, run "fetch.sh cargo":\n'
        printf '  %s\n' "${stale[@]}"
    fi
    if (( ${#helper[@]} )); then
        printf '\nmissing helper checkouts (clone into %s, or run: fetch.sh sources):\n' "$GG_SRC"
        for base in "${!helper[@]}"; do printf '  %-24s %s\n' "$base" "${helper[$base]}"; done | sort
    fi
    [[ -f $GG_DEPS/$GG_DEPS_NAME.db.tar.zst ]] && msg2 "deps repo: $(ls "$GG_DEPS"/*.pkg.tar.* 2>/dev/null | wc -l) packages" \
        || msg2 "deps repo: not built yet (fetch.sh deps)"
}

for s in "${steps[@]}"; do gg_title "fetch: $s"; "step_$s"; done
gg_title "gnome-git: fetch done"

if (( ${#failed[@]} )); then
    warn "failed items:"; printf '   %s\n' "${failed[@]}" >&2; exit 1
fi
msg "done"
