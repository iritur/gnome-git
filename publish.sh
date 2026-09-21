#!/usr/bin/env bash
# publish.sh - push the built packages to a personal remote repository so that
# other Arch machines can install them with pacman, without building anything.
#
# The packages go into a git branch as plain files. GitHub release assets would
# be the obvious choice, but GitHub rewrites characters in asset names and 18 of
# our packages carry an epoch (gjs-2:1.90.0-...), which pacman looks up by exact
# filename. Git preserves names, so a branch it is.
#
# usage: publish.sh [options]
#   --sign            sign every package and the database with your GPG key
#   --lean            leave out what exclude.list names (docs, demos, ...)
#   --dry-run         show what would be published, push nothing
#   --url             just print the pacman.conf snippet for the other machine
#   -h, --help
#
# One-time setup: create the repository (https://github.com/iritur/pkgs) and
# make sure "git push" to it works from this machine.

source "$(dirname "$(readlink -f "$0")")/lib.sh"
need_cmd git

SIGN=0 DRY=0 LEAN=0
for a in "$@"; do
    case $a in
        --sign) SIGN=1 ;;
        --dry-run) DRY=1 ;;
        --lean) LEAN=1 ;;
        --url) printf '[%s]\nSigLevel = %s\nServer = %s/$arch\n' \
                   "$GG_REPO_NAME" \
                   "$( (( SIGN )) && echo 'Required DatabaseOptional' || echo 'Optional TrustAll')" \
                   "$GG_REMOTE_URL"; exit 0 ;;
        -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
        *) die "unknown option: $a" ;;
    esac
done

[[ -f $GG_REPO/$GG_REPO_NAME.db.tar.zst ]] || die "no local repo at $GG_REPO (nothing built yet)"
mapfile -t pkgs < <(find "$GG_REPO" -maxdepth 1 -name '*.pkg.tar.*' ! -name '*.sig' | sort)
(( ${#pkgs[@]} )) || die "no packages in $GG_REPO"

if (( LEAN )); then
    # drop excluded packages from the published set entirely; pacman only ever
    # sees what the database lists, so the database has to be rebuilt without them
    keep=(); dropped=0
    for f in "${pkgs[@]}"; do
        b=${f##*/}; b=${b%-*-*-*}          # strip -pkgver-pkgrel-arch
        if is_excluded "$b"; then dropped=$(( dropped + 1 )); else keep+=("$f"); fi
    done
    msg2 "--lean: leaving out $dropped packages named by exclude.list"
    pkgs=("${keep[@]}")
fi

# raw.githubusercontent refuses files over 100 MB
for f in "${pkgs[@]}"; do
    (( $(stat -c %s "$f") > 100000000 )) &&
        warn "larger than 100 MB, raw.githubusercontent will refuse it: ${f##*/}"
done

msg "publishing ${#pkgs[@]} packages ($(du -sh "$GG_REPO" | cut -f1)) to $GG_REMOTE [$GG_REMOTE_BRANCH]"

# ------------------------------------------------------------------- signing
if (( SIGN )); then
    need_cmd gpg
    msg "signing packages (GPG may ask for your passphrase once per key unlock)"
    for f in "${pkgs[@]}"; do
        [[ -f $f.sig ]] && continue
        msg2 "signing ${f##*/}"
        gpg --detach-sign --no-armor --yes "$f" || die "signing failed for ${f##*/}"
    done
    repo-add -q -s -R "$GG_REPO/$GG_REPO_NAME.db.tar.zst" "${pkgs[@]}" ||
        die "could not sign the database"
fi

# --------------------------------------------------------------- work clone
mkdir -p "$(dirname "$GG_PUBLISH")"
if [[ ! -d $GG_PUBLISH/.git ]]; then
    msg2 "cloning $GG_REMOTE"
    rm -rf "$GG_PUBLISH"
    if ! git clone -q --depth 1 --branch "$GG_REMOTE_BRANCH" "$GG_REMOTE" "$GG_PUBLISH" 2>/dev/null; then
        # branch (or repository) still empty
        git init -q -b "$GG_REMOTE_BRANCH" "$GG_PUBLISH"
        git -C "$GG_PUBLISH" remote add origin "$GG_REMOTE"
    fi
else
    git -C "$GG_PUBLISH" remote set-url origin "$GG_REMOTE"
fi

arch=$(uname -m)
dest="$GG_PUBLISH/$arch"
mkdir -p "$dest"

# ------------------------------------------------------------- stage content
msg2 "staging packages into $arch/"
declare -A want=()
copy_if_newer() {   # copy_if_newer SRC DESTNAME
    want[$2]=1
    [[ -f $dest/$2 && ! $1 -nt $dest/$2 ]] && return 0
    cp -f "$1" "$dest/$2"
}
for f in "${pkgs[@]}"; do
    [[ -f $f ]] || continue
    copy_if_newer "$f" "${f##*/}"
    [[ -f $f.sig ]] && copy_if_newer "$f.sig" "${f##*/}.sig"
done

# pacman asks for <repo>.db and <repo>.files; in the local repo those are
# symlinks, and git would store the link, so copy the real content instead.
dbsrc="$GG_REPO"
if (( LEAN )); then
    dbsrc="$GG_WORK/leandb"
    rm -rf "$dbsrc"; mkdir -p "$dbsrc"
    msg2 "building a database for the ${#pkgs[@]} published packages"
    repo-add -q "$dbsrc/$GG_REPO_NAME.db.tar.zst" "${pkgs[@]}" >/dev/null 2>&1 ||
        die "could not build the lean database"
fi
for kind in db files; do
    src="$dbsrc/$GG_REPO_NAME.$kind.tar.zst"
    [[ -f $src ]] || continue
    copy_if_newer "$src" "$GG_REPO_NAME.$kind.tar.zst"
    copy_if_newer "$src" "$GG_REPO_NAME.$kind"
    if [[ -f $src.sig ]]; then
        copy_if_newer "$src.sig" "$GG_REPO_NAME.$kind.tar.zst.sig"
        copy_if_newer "$src.sig" "$GG_REPO_NAME.$kind.sig"
    fi
done

# drop packages that are no longer in the local repo, so the published set
# matches what was actually built
for f in "$dest"/*; do
    [[ -f $f ]] || continue
    b=${f##*/}
    [[ -n ${want[$b]:-} ]] || { msg2 "removing stale $b"; rm -f "$f"; }
done

siglevel="Optional TrustAll"
(( SIGN )) && siglevel="Required DatabaseOptional"

# turn exclude.list globs into one anchored regex for the remote installer
exclude_re=$(sed 's/#.*//; s/[[:space:]]//g' "$GG_ROOT/exclude.list" 2>/dev/null |
             grep -v '^$' | sed 's/[.]/\\./g; s/[*]/.*/g; s/^/^/; s/$/$/' | paste -sd'|')
[[ -n $exclude_re ]] || exclude_re='^$'
msg2 "installer will skip: $(printf '%s' "$exclude_re" | tr '|' ' ')"

# ---------------------------------------------------- installer for other PCs
cat > "$GG_PUBLISH/install-gnome-git.sh" <<INSTALLER
#!/usr/bin/env bash
# Registers this package repository with pacman and installs GNOME from it.
# Nothing is built: every package was compiled from GNOME git elsewhere.
#
#   ./install-gnome-git.sh            add the repo, upgrade what is installed
#   ./install-gnome-git.sh --all      also install every package in the repo
#   ./install-gnome-git.sh --remove   unregister the repo again
set -euo pipefail

REPO=$GG_REPO_NAME
URL="$GG_REMOTE_URL"
SIGLEVEL="$siglevel"
# packages never installed here (built, but not wanted on a desktop)
EXCLUDE_RE='$exclude_re'
CONF=/etc/pacman.conf
B="# >>> \$REPO >>>"
E="# <<< \$REPO <<<"

strip_block() {
    awk -v b="\$B" -v e="\$E" '
        \$0 == b { skip = 1 }
        skip    { if (\$0 == e) { skip = 0; eat = 1 }; next }
        eat && \$0 == "" { eat = 0; next }
        { eat = 0; print }' "\$CONF"
}

if [[ \${1:-} == --remove ]]; then
    strip_block | sudo tee "\$CONF.new" >/dev/null && sudo mv "\$CONF.new" "\$CONF"
    sudo pacman -Sy
    echo "Removed [\$REPO]. Run 'sudo pacman -Syuu' to go back to the Arch versions."
    exit 0
fi

echo "==> registering [\$REPO] in \$CONF (backup: \$CONF.\$REPO.bak)"
sudo cp "\$CONF" "\$CONF.\$REPO.bak"
block=\$(printf '%s\n[%s]\nSigLevel = %s\nServer = %s/\$arch\n%s\n' "\$B" "\$REPO" "\$SIGLEVEL" "\$URL" "\$E")
# placed above core/extra so these packages win over the Arch ones
strip_block | awk -v top="\$block" '
    /^\[/ && \$0 != "[options]" && !done { print top; print ""; done = 1 }
    { print }' | sudo tee "\$CONF.new" >/dev/null
sudo mv "\$CONF.new" "\$CONF"
sudo pacman -Sy

if [[ \${1:-} == --all ]]; then
    echo "==> installing from [\$REPO], leaving out docs, demos and samples"
    sudo pacman -Syu
    # same exclusions as the build machine's exclude.list
    mapfile -t want < <(pacman -Slq "\$REPO" | grep -vE "\$EXCLUDE_RE")
    echo "    \${#want[@]} packages"
    sudo pacman -S --needed "\${want[@]}"
else
    echo "==> upgrading the packages you already have"
    sudo pacman -Syu
fi

cat <<MSG

Done. To run the desktop:
  sudo pacman -S --needed networkmanager
  sudo systemctl enable --now NetworkManager gdm
MSG
INSTALLER
chmod +x "$GG_PUBLISH/install-gnome-git.sh"

cat > "$GG_PUBLISH/README.md" <<READDME
# $GG_REPO_NAME

GNOME built from git (gitlab.gnome.org main branches) as Arch Linux packages,
using the official Arch PKGBUILDs re-pointed at those checkouts.

Updated: $(date -u '+%Y-%m-%d %H:%M UTC') - ${#pkgs[@]} packages.

## Install on another Arch machine

    curl -fLO $GG_REMOTE_URL/install-gnome-git.sh
    less install-gnome-git.sh      # read it before running it
    bash install-gnome-git.sh --all

Or register it by hand in \`/etc/pacman.conf\`, above \`[core]\` and \`[extra]\`
so these packages take precedence:

    [$GG_REPO_NAME]
    SigLevel = $siglevel
    Server = $GG_REMOTE_URL/\$arch

Then \`sudo pacman -Syu\`.

## Going back to stock Arch

    bash install-gnome-git.sh --remove
    sudo pacman -Syuu

## Caveats

These are development snapshots of GNOME, rebuilt whenever the upstream code
moves. They are not tested the way Arch tests its packages, and $( (( SIGN )) || printf 'they are
unsigned, so pacman is told to trust the repository ("TrustAll"); the transport
is HTTPS, but the trust is in this GitHub account' )$( (( SIGN )) && printf 'they are signed with
the publisher GPG key, which you must import and locally sign first' ).
READDME

# --------------------------------------------------------------------- push
count=$(find "$dest" -type f | wc -l)
size=$(du -sh "$GG_PUBLISH" --exclude=.git | cut -f1)
if (( DRY )); then
    msg "dry run: $count files, $size would go to $GG_REMOTE [$GG_REMOTE_BRANCH]"
    git -C "$GG_PUBLISH" status --short | head -20
    exit 0
fi

msg2 "committing $count files ($size)"
git -C "$GG_PUBLISH" add -A
if git -C "$GG_PUBLISH" diff --cached --quiet; then
    msg "nothing changed since the last publish"
else
    git -C "$GG_PUBLISH" -c user.name="${GIT_AUTHOR_NAME:-gnome-git}" \
        -c user.email="${GIT_AUTHOR_EMAIL:-gnome-git@localhost}" \
        commit -q -m "$GG_REPO_NAME: ${#pkgs[@]} packages, $(date -u '+%Y-%m-%d %H:%M UTC')"
fi

# One snapshot commit per publish: old package blobs would otherwise pile up in
# the history forever and the repository would grow without bound.
msg2 "force-pushing a single snapshot commit to $GG_REMOTE_BRANCH"
tree=$(git -C "$GG_PUBLISH" write-tree)
snap=$(git -C "$GG_PUBLISH" -c user.name="${GIT_AUTHOR_NAME:-gnome-git}" \
          -c user.email="${GIT_AUTHOR_EMAIL:-gnome-git@localhost}" \
          commit-tree "$tree" -m "$GG_REPO_NAME: ${#pkgs[@]} packages, $(date -u '+%Y-%m-%d %H:%M UTC')")
git -C "$GG_PUBLISH" reset -q --hard "$snap"
git -C "$GG_PUBLISH" push -q --force origin "HEAD:$GG_REMOTE_BRANCH" ||
    die "push failed; check that $GG_REMOTE exists and that you can push to it"

msg "published"
cat <<MSG

On the other Arch machine:

  curl -fLO $GG_REMOTE_URL/install-gnome-git.sh
  bash install-gnome-git.sh --all

or add this to /etc/pacman.conf above [core]:

  [$GG_REPO_NAME]
  SigLevel = $siglevel
  Server = $GG_REMOTE_URL/\$arch

MSG
