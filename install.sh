#!/usr/bin/env bash
# install.sh - run on any Arch machine that should RUN the git build (the
# build machine itself, or another one with the drive mounted at the same
# path). Registers the local repos in /etc/pacman.conf, with "gnome-git"
# ahead of core/extra so its packages always win, then installs/upgrades.
#
# usage: install.sh [--all | --upgrade] [--with-deps] [--remove]
#   --upgrade     (default) pacman -Syu: what is installed switches to git builds
#   --remote      use the published repository (GG_REMOTE_URL) instead of the drive
#   --all         additionally install every package in the gnome-git repo
#   --with-deps   also register the offline dependency cache repo
#   --remove      unregister the repos again (packages stay installed)

source "$(dirname "$(readlink -f "$0")")/lib.sh"
need_cmd pacman sudo

MODE=upgrade WITH_DEPS=0 REMOVE=0 REMOTE=0
for a in "$@"; do
    case $a in
        --all) MODE=all ;;
        --upgrade) MODE=upgrade ;;
        --with-deps) WITH_DEPS=1 ;;
        --remote) REMOTE=1 ;;
        --remove) REMOVE=1 ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) die "unknown option: $a" ;;
    esac
done

CONF=/etc/pacman.conf
B='# >>> gnome-git >>>' E='# <<< gnome-git <<<'
strip_block() {
    awk -v b="$B" -v e="$E" '
        $0 == b { skip = 1 }
        skip    { if ($0 == e) { skip = 0; eat = 1 }; next }
        eat && $0 == "" { eat = 0; next }
        { eat = 0; print }' "$CONF"
}

if (( REMOVE )); then
    strip_block | sudo tee "$CONF.new" >/dev/null && sudo mv "$CONF.new" "$CONF"
    sudo pacman -Sy; msg "repos removed from $CONF"; exit 0
fi

if (( REMOTE )); then
    server="$GG_REMOTE_URL/\$arch"
else
    [[ -f $GG_REPO/$GG_REPO_NAME.db.tar.zst ]] || die "no repo at $GG_REPO (drive not mounted, or nothing built yet)"
    server="file://$GG_REPO"
fi

block_top=$(printf '%s\n[%s]\nSigLevel = Optional TrustAll\nServer = %s\n%s\n' "$B" "$GG_REPO_NAME" "$server" "$E")
block_deps=""
if (( WITH_DEPS )); then
    [[ -f $GG_DEPS/$GG_DEPS_NAME.db.tar.zst ]] || die "no deps repo at $GG_DEPS (run fetch.sh deps)"
    block_deps=$(printf '%s\n[%s]\nSigLevel = PackageRequired DatabaseNever\nServer = file://%s\n%s\n' "$B" "$GG_DEPS_NAME" "$GG_DEPS" "$E")
fi

msg "registering repos in $CONF ($( (( REMOTE )) && echo "remote: $GG_REMOTE_URL" || echo "local: $GG_REPO"), backup: $CONF.gnome-git.bak)"
sudo cp "$CONF" "$CONF.gnome-git.bak"
strip_block | awk -v top="$block_top" -v deps="$block_deps" '
    /^\[/ && $0 != "[options]" && !done { print top; print ""; done=1 }
    { print }
    END { if (deps != "") { print ""; print deps } }' | sudo tee "$CONF.new" >/dev/null
sudo mv "$CONF.new" "$CONF"
sudo pacman -Sy

case $MODE in
    upgrade)
        msg "upgrading installed packages to the git builds"
        sudo pacman -Syu ;;
    all)
        mapfile -t want < <(pacman -Slq "$GG_REPO_NAME" | filter_excluded)
        skipped=$(( $(pacman -Slq "$GG_REPO_NAME" | wc -l) - ${#want[@]} ))
        msg "installing ${#want[@]} packages from $GG_REPO_NAME"
        (( skipped )) && msg2 "$skipped skipped by exclude.list (docs, demos, ...)"
        sudo pacman -Syu
        sudo pacman -S --needed "${want[@]}" ;;
esac

cat <<MSG

Done. Packages from [$GG_REPO_NAME] now take precedence over core/extra.
  * start GNOME:      sudo systemctl enable --now gdm
  * see what is git:  pacman -Sl $GG_REPO_NAME | awk '\$4=="[installed]"'
  * go back to stock: $0 --remove && sudo pacman -Syuu
MSG
