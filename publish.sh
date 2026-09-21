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
# One-time setup: run setup.sh, or set GG_REMOTE and GG_REMOTE_URL in
# config.local.sh, create that repository on the host, and make sure that
# "git push" to it works from this machine.

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

[[ -n $GG_REMOTE ]] || die "GG_REMOTE is not set. Run setup.sh, or put it in config.local.sh"
[[ -n $GG_REMOTE_URL ]] || die "GG_REMOTE_URL is not set. Run setup.sh, or put it in config.local.sh"
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
SIGNOTE="Packages are unsigned. \`SigLevel = Optional TrustAll\` tells pacman to
  trust whatever this URL serves. The transport is HTTPS, so the trust is in
  the GitHub account that publishes it."
if (( SIGN )); then
    siglevel="Required DatabaseOptional"
    SIGNOTE="Packages are signed. Import the publisher's GPG key and locally
  sign it (\`pacman-key --lsign-key\`) before installing."
fi

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

# where the toolkit itself lives, if this directory is a checkout of it
project_url=$(git -C "$GG_ROOT" remote get-url origin 2>/dev/null |
              sed -E 's#^git@github\.com:#https://github.com/#; s#\.git$##')

cat > "$GG_PUBLISH/README.md" <<READDME
# $GG_REPO_NAME

GNOME built from the development branches at gitlab.gnome.org, packaged with
the official Arch Linux PKGBUILDs pointed at those checkouts. Install it with
pacman on any x86_64 Arch machine. Nothing is compiled on your side.

**${#pkgs[@]} packages, updated $(date -u '+%Y-%m-%d %H:%M UTC').**

## Before you start

This is unreleased GNOME. It is rebuilt whenever upstream moves, it does not
get the testing Arch gives its own packages, and it can break in ways a stable
desktop does not. A spare machine or a virtual machine is the sensible place
for it. Uninstalling is supported and described at the end.

You need:

- Arch Linux, x86_64.
- An up-to-date system. Run \`sudo pacman -Syu\` and reboot first. These
  packages are linked against current Arch libraries, so on an old install
  pacman will either drag in half the distribution or refuse the transaction.
- Roughly 2 GB free for the packages and their dependencies.

## Install

\`\`\`bash
curl -fLO $GG_REMOTE_URL/install-gnome-git.sh
less install-gnome-git.sh      # it edits pacman.conf and calls sudo; read it
bash install-gnome-git.sh --all
\`\`\`

The script adds this repository to \`/etc/pacman.conf\` above \`[core]\` and
\`[extra]\`, so its packages win over the Arch ones, keeps a backup of the file,
then syncs and installs. Without \`--all\` it only upgrades the GNOME packages
you already have.

To do it by hand instead, put this above \`[core]\` in \`/etc/pacman.conf\`:

\`\`\`
[$GG_REPO_NAME]
SigLevel = $siglevel
Server = $GG_REMOTE_URL/\$arch
\`\`\`

then run \`sudo pacman -Syu\`.

## Getting to a desktop

\`\`\`bash
sudo pacman -S --needed networkmanager
sudo systemctl enable --now NetworkManager gdm
\`\`\`

NetworkManager is only an optional dependency of the control center, so
without it the shell's network menu stays dead. Enabling gdm brings up the
login screen straight away; a reboot is cleaner for the first run.

If the session fails to start, switch to a console with Ctrl+Alt+F2 and read
\`journalctl -b -u gdm\`. \`sudo systemctl disable --now gdm\` returns you to a
text login.

## What is in here

The GNOME platform (glib, gtk4, libadwaita, gobject-introspection and the
rest), the shell and session (mutter, gnome-shell, gdm, gnome-session, the
settings daemon, the control center), the core applications, and the
development tools including Builder. Everything else the system needs, the
kernel, mesa, pipewire, systemd, comes from the official Arch repositories as
ordinary dependencies.

Deliberately left out: API documentation and the help manual, the GTK and
libadwaita demo programs, the vte sample terminals, and \`gvfs-dnssd\`.

## Updating

\`\`\`bash
sudo pacman -Syu
\`\`\`

The repository sits above \`[core]\`, so these builds keep winning even when
Arch ships a numerically newer release.

## Going back to stock Arch

\`\`\`bash
bash install-gnome-git.sh --remove
sudo pacman -Syuu
\`\`\`

The first command unregisters the repository, the second downgrades everything
to the official packages.

## Things worth knowing

- $SIGNOTE
- Version numbers read \`51.0.r2.geb74a99\`: the last tag, the number of commits
  since it, and the commit id. They sort above the matching Arch release.
- Just after an update here, \`raw.githubusercontent.com\` can serve a cached
  package database for a few minutes. If pacman reports 404s on package files,
  wait five minutes and run \`sudo pacman -Syy\`.
${project_url:+
## How these are built

The build tooling is at <$project_url>. It takes the official Arch PKGBUILDs,
repoints their sources at local git checkouts, derives the version from git,
and builds them with makepkg into a pacman repository.}
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
