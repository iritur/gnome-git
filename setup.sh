#!/usr/bin/env bash
# setup.sh - interactive setup for the machine that builds and publishes:
# VMware guest integration (clipboard, shared folders) and GitHub access for
# publish.sh. Every step reports what it finds first and asks before changing
# anything, so it is safe to re-run; nothing already done is done twice.
#
# usage: setup.sh [--check] [--vmware] [--git] [--github]
#   --check    report the state of every step and change nothing
#   --vmware   only the VMware steps
#   --git      only the git identity step
#   --github   only the GitHub access steps
# With no arguments it walks through everything.

source "$(dirname "$(readlink -f "$0")")/lib.sh"
set +e +u +o pipefail          # a wizard must not die on a probe

CHECK=0; ONLY=""
for a in "$@"; do
    case $a in
        --check) CHECK=1 ;;
        --vmware) ONLY="vmware" ;;
        --git) ONLY="git" ;;
        --github) ONLY="github" ;;
        -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
        *) die "unknown option: $a" ;;
    esac
done

# ------------------------------------------------------------------ prompting
TTY=/dev/tty
{ : < /dev/tty; } 2>/dev/null || TTY=/dev/stdin

ask() {   # ask QUESTION [default y|n] -> 0 for yes
    local q=$1 def=${2:-y} ans hint="[Y/n]"
    [[ $def == n ]] && hint="[y/N]"
    (( CHECK )) && { printf '   would ask: %s\n' "$q"; return 1; }
    while true; do
        printf '\e[1;33m::\e[0m %s %s ' "$q" "$hint" > /dev/stderr
        read -r ans < "$TTY" || return 1
        ans=${ans:-$def}
        case ${ans,,} in y|yes) return 0 ;; n|no) return 1 ;; esac
    done
}

askval() {   # askval PROMPT DEFAULT -> prints the answer
    local q=$1 def=$2 ans
    (( CHECK )) && { printf '%s' "$def"; return 0; }
    printf '\e[1;33m::\e[0m %s [%s]: ' "$q" "$def" > /dev/stderr
    read -r ans < "$TTY"
    printf '%s' "${ans:-$def}"
}

pause() {
    (( CHECK )) && return 0
    printf '\e[1;33m::\e[0m %s' "${1:-Press Enter to continue}" > /dev/stderr
    read -r _ < "$TTY"
}

# Probes must never stop and ask for a password: GIT_TERMINAL_PROMPT and
# BatchMode turn "please authenticate" into a plain failure.
git_probe() { GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/true \
              GIT_SSH_COMMAND='ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new' \
              timeout 25 git ls-remote "$@" >/dev/null 2>&1; }

# repo_visibility SLUG -> public | private-or-missing
repo_visibility() {
    curl -fsS --max-time 15 "https://api.github.com/repos/$1" >/dev/null 2>&1 &&
        printf 'public' || printf 'private-or-missing'
}

ok()   { printf '   \e[1;32mok\e[0m      %s\n' "$*"; }
todo() { printf '   \e[1;33mtodo\e[0m    %s\n' "$*"; }
info() { printf '           %s\n' "$*"; }

run() {   # run a command, echoing it first
    printf '   \e[1;34m->\e[0m %s\n' "$*"
    (( CHECK )) && return 0
    "$@"
}

# ================================================================== VMware
step_vmware() {
    msg "VMware guest integration"
    local virt; virt=$(systemd-detect-virt 2>/dev/null)
    if [[ $virt != vmware ]]; then
        info "not a VMware guest (detected: ${virt:-none}), skipping"
        return 0
    fi
    ok "running under VMware ($(cat /sys/class/dmi/id/product_name 2>/dev/null))"

    # --- open-vm-tools
    if pacman -Q open-vm-tools >/dev/null 2>&1; then
        ok "open-vm-tools installed"
    else
        todo "open-vm-tools is missing"
        ask "Install open-vm-tools?" && run sudo pacman -S --needed --noconfirm open-vm-tools
    fi

    # --- clipboard plugin dependency
    if pacman -Q gtkmm3 >/dev/null 2>&1; then
        ok "gtkmm3 installed (clipboard / drag-and-drop plugin can load)"
    else
        todo "gtkmm3 missing: without it the copy-paste plugin cannot load"
        ask "Install gtkmm3?" && run sudo pacman -S --needed --noconfirm gtkmm3
    fi

    # --- services
    local svc
    for svc in vmtoolsd.service vmware-vmblock-fuse.service; do
        if [[ $(systemctl is-enabled "$svc" 2>/dev/null) == enabled ]] &&
           [[ $(systemctl is-active "$svc" 2>/dev/null) == active ]]; then
            ok "$svc enabled and running"
        else
            local en ac
            en=$(systemctl is-enabled "$svc" 2>/dev/null); ac=$(systemctl is-active "$svc" 2>/dev/null)
            todo "$svc is ${en:-unknown}/${ac:-inactive}"
            ask "Enable and start $svc now?" && run sudo systemctl enable --now "$svc"
        fi
    done

    # --- honest note about the clipboard
    if [[ -d /usr/share/xsessions ]] && compgen -G '/usr/share/xsessions/*.desktop' >/dev/null; then
        info "an Xorg session exists, where VMware copy-paste is most reliable"
    else
        warn "no Xorg session is installed: GNOME 49+ ships Wayland only."
        info "VMware's copy-paste plugin is X11 based. Inside a GNOME Wayland"
        info "session it can still work through XWayland, but it is not certain."
        info "The shared folder below always works, including on this console."
    fi

    # --- shared folder
    msg2 "Shared folder (host <-> guest file copy)"
    local shares; shares=$(vmware-hgfsclient 2>/dev/null)
    if [[ -z $shares ]]; then
        todo "the host exports no shared folder yet"
        info "On the host: VM settings -> Options -> Shared Folders ->"
        info "'Always enabled', then Add and pick a folder."
        ask "Have you added one now, and should I look again?" n && shares=$(vmware-hgfsclient 2>/dev/null)
    fi
    if [[ -n $shares ]]; then
        ok "host shares: $(printf '%s' "$shares" | tr '\n' ' ')"
        if mountpoint -q /mnt/hgfs 2>/dev/null; then
            ok "/mnt/hgfs is mounted"
        else
            todo "/mnt/hgfs is not mounted"
            if ask "Mount the shared folders at /mnt/hgfs?"; then
                run sudo mkdir -p /mnt/hgfs
                run sudo mount -t fuse.vmhgfs-fuse .host:/ /mnt/hgfs -o allow_other
                mountpoint -q /mnt/hgfs && ok "mounted" || warn "mount failed, see the message above"
            fi
        fi
        if grep -q '^\.host:/' /etc/fstab 2>/dev/null; then
            ok "/etc/fstab already mounts it at boot"
        elif ask "Add it to /etc/fstab so it mounts at boot?"; then
            local line='.host:/  /mnt/hgfs  fuse.vmhgfs-fuse  defaults,allow_other,nofail  0  0'
            printf '   \e[1;34m->\e[0m appending to /etc/fstab: %s\n' "$line"
            (( CHECK )) || printf '%s\n' "$line" | sudo tee -a /etc/fstab >/dev/null
        fi
    fi
}

# ================================================================== git identity
step_git() {
    msg "Git identity"
    local n e
    n=$(git config --global user.name 2>/dev/null)
    e=$(git config --global user.email 2>/dev/null)
    if [[ -n $n && -n $e ]]; then
        ok "git commits will be attributed to $n <$e>"
        ask "Change it?" n || return 0
    else
        todo "no global git identity is set"
    fi
    n=$(askval "Your name" "${n:-$USER}")
    e=$(askval "Your email" "${e:-$USER@${HOSTNAME:-$(uname -n)}}")
    run git config --global user.name "$n"
    run git config --global user.email "$e"
}

# ================================================================== GitHub
step_github() {
    msg "GitHub access for publish.sh"

    if (( CHECK )); then
        local k
        k=$(find ~/.ssh -maxdepth 1 -type f -name 'id_*' ! -name '*.pub' 2>/dev/null | head -1)
        [[ -n $k ]] && ok "SSH key: $k" || todo "no SSH key in ~/.ssh"
        if [[ $GG_REMOTE == git@* ]]; then
            info "pushing over SSH, so no password helper is needed"
        elif [[ $(git config --global credential.helper) == store ]]; then
            ok "credential.helper = store (an HTTPS token would be remembered)"
        else
            todo "no credential helper (an HTTPS token would be typed every push)"
        fi
        info "push URL in config.sh:  $GG_REMOTE"
        info "fetch URL for clients:  $GG_REMOTE_URL"
        local slug; slug=$(printf '%s' "$GG_REMOTE" | sed -E 's#^(https://github.com/|git@github.com:)##; s#\.git$##')
        if git_probe "$GG_REMOTE"; then
            ok "$GG_REMOTE is reachable and you can push to it"
        else
            todo "cannot reach $GG_REMOTE"
            if [[ -n $k ]] && git_probe "git@github.com:$slug.git"; then
                info "but git@github.com:$slug.git works: config.sh should use the SSH URL"
            fi
        fi
        if [[ $(repo_visibility "$slug") == public ]]; then
            ok "$slug is public, so pacman on other machines can fetch from it"
        else
            todo "$slug is private (or missing): raw.githubusercontent.com will"
            info "refuse anonymous clients, so pacman elsewhere cannot install from it."
            info "Make it public: https://github.com/$slug/settings -> Danger Zone"
        fi
        return 0
    fi

    # --- which repository
    local slug current
    current=$(printf '%s' "$GG_REMOTE" | sed -E 's#^(https://github.com/|git@github.com:)##; s#\.git$##')
    slug=$(askval "GitHub repository to publish to (user/name)" "$current")
    [[ $slug == */* ]] || { warn "expected the form user/name, got '$slug'"; return 1; }

    # --- SSH or token
    local method=ssh
    if [[ -f ~/.ssh/id_ed25519 || -f ~/.ssh/id_rsa ]]; then
        ok "an SSH key already exists ($(find ~/.ssh -maxdepth 1 -type f -name 'id_*' ! -name '*.pub' 2>/dev/null | head -1))"
    else
        todo "no SSH key in ~/.ssh"
        info "SSH: no password typing after setup, but you must get the public"
        info "     key OUT of this VM and paste it into GitHub."
        info "Token: nothing leaves the VM, you type the token IN once, and it"
        info "     is stored in clear text in ~/.git-credentials."
        ask "Use an SSH key? (answer n for an HTTPS token)" || method=token
    fi

    if [[ $method == ssh ]]; then
        github_ssh "$slug" || return 1
    else
        github_token "$slug" || return 1
    fi
}

github_ssh() {
    local slug=$1 key=~/.ssh/id_ed25519

    if [[ ! -f $key ]]; then
        if ask "Generate an ed25519 key now? (it will ask for a passphrase)"; then
            run ssh-keygen -t ed25519 -C "$USER@${HOSTNAME:-$(uname -n)}" -f "$key"
        else
            info "nothing to do without a key"; return 1
        fi
    fi

    # --- get the public key to the host
    if [[ -f $key.pub ]]; then
        printf '\n   Your public key:\n\n'
        sed 's/^/     /' "$key.pub"
        printf '\n'
        if mountpoint -q /mnt/hgfs 2>/dev/null; then
            local share
            share=$(find /mnt/hgfs -maxdepth 1 -mindepth 1 -type d | head -1)
            if [[ -n $share ]] && ask "Copy it to the shared folder ($share) so you can paste it on the host?"; then
                run cp "$key.pub" "$share/"
                ok "copied to $share/${key##*/}.pub"
            fi
        else
            info "no shared folder mounted; copy the text above by hand, or run"
            info "setup.sh --vmware first to mount one"
        fi
    fi

    info "Add that key at https://github.com/settings/keys (New SSH key, type Authentication)"
    info "and create the empty repository at https://github.com/new named ${slug#*/}"
    pause "Press Enter once the key is added and the repository exists... "

    # --- verify
    msg2 "checking SSH access"
    local out
    out=$(ssh -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1)
    if grep -q 'successfully authenticated' <<<"$out"; then
        ok "${out%%$'\n'*}"
    else
        warn "GitHub did not accept the key:"
        printf '     %s\n' "$out"
        info "the key is probably not added yet; re-run setup.sh --github"
        return 1
    fi

    if git_probe "git@github.com:$slug.git"; then
        ok "git@github.com:$slug.git exists and you can reach it"
    else
        warn "cannot reach git@github.com:$slug.git - create it at https://github.com/new"
        return 1
    fi

    if [[ $(repo_visibility "$slug") != public ]]; then
        warn "$slug is private. You can push to it, but pacman on other machines"
        info "fetches anonymously over https://raw.githubusercontent.com, which"
        info "refuses private repositories. Make it public under"
        info "  https://github.com/$slug/settings  (Danger Zone -> Change visibility)"
        info "Only the built packages live there, no source and no credentials."
        ask "Continue anyway?" || return 1
    else
        ok "$slug is public, so other machines can install from it"
    fi

    write_remote "git@github.com:$slug.git" "$slug"
}

github_token() {
    local slug=$1
    info "Create a fine-grained token at"
    info "  https://github.com/settings/personal-access-tokens/new"
    info "Repository access: only $slug.  Permissions: Contents = Read and write."
    if [[ $(git config --global credential.helper) == store ]]; then
        ok "credential.helper is already 'store'"
    elif ask "Store the token so you only type it once? (plain text in ~/.git-credentials)"; then
        run git config --global credential.helper store
    fi
    pause "Press Enter once the token exists and the repository is created... "
    if git_probe "https://github.com/$slug.git"; then
        ok "https://github.com/$slug.git is reachable"
    else
        warn "cannot reach https://github.com/$slug.git yet"
    fi
    info "The first push will ask for your username and the token as the password."
    write_remote "https://github.com/$slug.git" "$slug"
}

# write_remote GIT-URL SLUG - point config.sh at the chosen repository
write_remote() {
    local url=$1 slug=$2 conf="$GG_ROOT/config.local.sh" raw
    raw="https://raw.githubusercontent.com/$slug/$GG_REMOTE_BRANCH"
    if [[ $GG_REMOTE == "$url" && $GG_REMOTE_URL == "$raw" ]]; then
        ok "config.sh already points at $slug"
        return 0
    fi
    msg2 "pointing config.sh at $slug"
    info "push URL:  $url"
    info "fetch URL: $raw  (what pacman on other machines uses)"
    ask "Write that into $conf?" || return 0
    (( CHECK )) && return 0
    [[ -f $conf ]] && cp -f "$conf" "$conf.bak"
    touch "$conf"
    sed -i '/^GG_REMOTE=/d; /^GG_REMOTE_URL=/d' "$conf"
    { printf 'GG_REMOTE=%s\n' "$url"
      printf 'GG_REMOTE_URL=%s\n' "$raw"; } >> "$conf"
    ok "written to ${conf##*/}, which is never committed"
}

# ===================================================================== main
(( CHECK )) && msg "check mode: reporting only, nothing will be changed"
case $ONLY in
    vmware) step_vmware ;;
    git)    step_git ;;
    github) step_github ;;
    *)      step_vmware; echo; step_git; echo; step_github ;;
esac

echo
msg "Next"
if [[ -z $ONLY ]] || [[ $ONLY == github ]]; then
    info "publish the packages:   $GG_ROOT/publish.sh --dry-run"
    info "then for real:          $GG_ROOT/publish.sh"
fi
info "re-run this any time:   $GG_ROOT/setup.sh --check"
