#!/usr/bin/env bash
#
# install-jt-binaries.sh
#
# Initial-install helper for the repositories that jtupdate manages.
# It first verifies that the required build dependencies (commands and
# pkg-config modules) are present, and refuses to clone anything if they are
# not.  For each repo it then clones the checkout into <base-dir>/<slug> and
# builds it with `make -j<JOBS>`.  Once everything is built, all installs are
# run inside a single elevated pass, so doas/sudo asks for the password only
# once.  Every prompt happens in the terminal this script runs in.  jtgreeter
# is intentionally not installed.
#
# Usage:
#   ./install-jt-binaries.sh [--check] [--base-dir DIR]
#
# Environment:
#   JTUPDATE_BASE_DIR   checkout root (default: $HOME/jtupdate/repos)
#   JOBS                make parallelism (default: 2)

set -u

BASE_DIR="${JTUPDATE_BASE_DIR:-$HOME/jtupdate/repos}"
JOBS="${JOBS:-2}"
CHECK_ONLY=0

usage() {
    cat <<'EOF'
Usage: install-jt-binaries.sh [--check] [--base-dir DIR]

Clones and builds the binaries managed by jtupdate, then installs them all
in one elevated pass (a single password prompt).  jtgreeter is not installed.

Options:
  --check          list every required build dependency and its status, then
                   exit without cloning, building, or installing anything
  --base-dir DIR   where checkouts live (default: $HOME/jtupdate/repos)
  -h, --help       show this help

Environment:
  JTUPDATE_BASE_DIR   same as --base-dir
  JOBS                make parallelism (default: 2)
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --check)
            CHECK_ONLY=1
            shift
            ;;
        --base-dir)
            BASE_DIR="${2:?--base-dir needs a directory}"
            shift 2
            ;;
        --base-dir=*)
            BASE_DIR="${1#*=}"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "error: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

# name|slug|url  -- jtgreeter deliberately omitted.
REPOS=(
    "JTLab|JTLab|https://github.com/arch-user-sudo/JTLab.git"
    "jtspeedtest|jtspeedtest|https://github.com/arch-user-sudo/jtspeedtest.git"
    "jtnetworks|jtnetworks|https://github.com/arch-user-sudo/jtnetworks.git"
    "jtlabwc|jtlabwc|https://github.com/arch-user-sudo/jtlabwc.git"
    "jtupdate|jtupdater|https://github.com/arch-user-sudo/jtupdater.git"
    "jtsettings|jtsettings|https://github.com/arch-user-sudo/jtsettings.git"
    "jtwpi|jtwpi|https://github.com/arch-user-sudo/jtwpi.git"
    "jtpolkit|jtpolkit|https://github.com/arch-user-sudo/jtpolkit.git"
)

# Build dependencies, checked before anything is cloned so a missing package
# cannot leave half a checkout tree behind.
REQUIRED_COMMANDS=(
    git make gcc cc pkg-config wayland-scanner python3
)

# pkg-config modules the managed Makefiles link against.  Optional feature
# toggles (XWayland, Vulkan) are off by default, so their modules are omitted.
REQUIRED_MODULES=(
    # wayland / cairo UI stack shared by most repos
    wayland-client wayland-cursor wayland-server wayland-protocols
    cairo pangocairo pango xkbcommon glib-2.0 gio-2.0 gdk-pixbuf-2.0
    # JTLab
    librsvg-2.0 libpipewire-0.3 libsoup-3.0
    # jtspeedtest
    libcurl
    # jtnetworks
    libnm
    # jtlabwc
    libinput pixman-1 libdrm egl gbm glesv2 lcms2 libudev libseat
    libdisplay-info libliftoff harfbuzz
    # jtwpi
    gtk+-3.0 gtk-layer-shell-0
    # jtpolkit
    polkit-agent-1 polkit-gobject-1
)

missing_commands=()
for c in "${REQUIRED_COMMANDS[@]}"; do
    command -v "$c" >/dev/null 2>&1 || missing_commands+=("$c")
done

missing_modules=()
if command -v pkg-config >/dev/null 2>&1; then
    for m in "${REQUIRED_MODULES[@]}"; do
        pkg-config --exists "$m" 2>/dev/null || missing_modules+=("$m")
    done
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
    echo "build dependency check"
    echo
    echo "commands:"
    for c in "${REQUIRED_COMMANDS[@]}"; do
        if command -v "$c" >/dev/null 2>&1; then
            printf '  [ok]      %s\n' "$c"
        else
            printf '  [MISSING] %s\n' "$c"
        fi
    done

    echo
    echo "pkg-config modules:"
    if command -v pkg-config >/dev/null 2>&1; then
        for m in "${REQUIRED_MODULES[@]}"; do
            if pkg-config --exists "$m" 2>/dev/null; then
                printf '  [ok]      %s\n' "$m"
            else
                printf '  [MISSING] %s\n' "$m"
            fi
        done
    else
        echo "  [skipped] pkg-config is not installed"
    fi

    echo
    if [ "${#missing_commands[@]}" -eq 0 ] && [ "${#missing_modules[@]}" -eq 0 ]; then
        echo "all required build dependencies are present."
        exit 0
    fi
    echo "some required build dependencies are missing." >&2
    exit 1
fi

if [ "${#missing_commands[@]}" -gt 0 ] || [ "${#missing_modules[@]}" -gt 0 ]; then
    echo "error: missing build dependencies; nothing has been cloned." >&2
    if [ "${#missing_commands[@]}" -gt 0 ]; then
        echo >&2
        echo "missing commands:" >&2
        printf '  - %s\n' "${missing_commands[@]}" >&2
    fi
    if [ "${#missing_modules[@]}" -gt 0 ]; then
        echo >&2
        echo "missing pkg-config modules (install the dev packages that provide them):" >&2
        printf '  - %s\n' "${missing_modules[@]}" >&2
    fi
    exit 1
fi

if command -v doas >/dev/null 2>&1; then
    PRIV=(doas)
elif command -v sudo >/dev/null 2>&1; then
    PRIV=(sudo)
else
    echo "error: neither doas nor sudo is available" >&2
    exit 1
fi

echo "checkout root : $BASE_DIR"
echo "privileges    : ${PRIV[0]}"
echo

mkdir -p "$BASE_DIR"

failed=()
ready_dirs=()
ready_names=()

# Phase 1: clone and build everything as the normal user.  No password is
# needed here, so a long build can never expire an elevated session.
for entry in "${REPOS[@]}"; do
    IFS='|' read -r name slug url <<<"$entry"
    dir="$BASE_DIR/$slug"

    echo
    echo "=== $name ($slug) ==="

    if [ -d "$dir/.git" ]; then
        echo "--> already cloned, skipping clone"
    elif [ -e "$dir" ]; then
        echo "error: $dir exists but is not a git checkout" >&2
        failed+=("$name (checkout exists)")
        continue
    else
        echo "--> cloning $url"
        if ! git clone --progress "$url" "$dir"; then
            echo "error: clone failed for $name" >&2
            failed+=("$name (clone)")
            continue
        fi
    fi

    echo "--> building"
    if ! make -C "$dir" -j"$JOBS"; then
        echo "error: build failed for $name" >&2
        failed+=("$name (build)")
        continue
    fi

    ready_dirs+=("$dir")
    ready_names+=("$name")
done

# Phase 2: install everything in one elevated process.  A single doas/sudo
# invocation means exactly one password prompt for the whole batch.
installed=()
if [ "${#ready_dirs[@]}" -gt 0 ]; then
    echo
    echo "=== installing ${#ready_dirs[@]} repo(s) (one password prompt) ==="

    statusdir="$(mktemp -d)"
    trap 'rm -rf "$statusdir"' EXIT

    # The install commands run under one root shell.  HOME is preserved so
    # repos that install dotfiles target this account, matching jtupdate's
    # elevated install behaviour.  Each result is written to a status file so
    # the summary below stays accurate.
    if "${PRIV[@]}" env HOME="$HOME" STATUSDIR="$statusdir" bash -c '
        rc=0
        i=0
        for d in "$@"; do
            printf "\n--> installing %s\n" "$d"
            if make -C "$d" install; then
                : > "$STATUSDIR/$i.ok"
            else
                echo "error: install failed: $d" >&2
                : > "$STATUSDIR/$i.fail"
                rc=1
            fi
            i=$((i + 1))
        done
        exit $rc
    ' _ "${ready_dirs[@]}"; then
        for i in "${!ready_dirs[@]}"; do
            installed+=("${ready_names[$i]}")
        done
    else
        for i in "${!ready_dirs[@]}"; do
            if [ -f "$statusdir/$i.ok" ]; then
                installed+=("${ready_names[$i]}")
            else
                failed+=("${ready_names[$i]} (install)")
            fi
        done
    fi
fi

echo
echo "================= summary ================="
if [ "${#installed[@]}" -gt 0 ]; then
    printf 'installed: %s\n' "${installed[*]}"
fi
if [ "${#failed[@]}" -gt 0 ]; then
    printf 'failed   : %s\n' "${failed[*]}"
    exit 1
fi
echo "all done"
