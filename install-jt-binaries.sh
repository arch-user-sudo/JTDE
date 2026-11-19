#!/usr/bin/env bash
#
# install-jt-binaries.sh
#
# Initial-install helper for the repositories that jtupdate manages.
# On Arch, Debian/Ubuntu, and Fedora it installs the build dependencies first
# (using pacman, apt, or dnf), then clones each managed repo into
# <base-dir>/<slug>, builds it, and installs everything in one elevated pass.
# The dependency install and all the installs run under a single doas/sudo
# session, so the password is asked for only once.  jtgreeter is not installed.
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

Installs build dependencies (Arch / Debian / Fedora), clones and builds the
binaries managed by jtupdate, then installs them all in one elevated pass
(a single password prompt).  jtgreeter is not installed.

Options:
  --check          list every required build dependency and its status, then
                   exit without installing, cloning, building, or doing anything
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

# Used by --check to report the state of the current machine.
REQUIRED_COMMANDS=(
    git make gcc cc pkg-config wayland-scanner python3
)

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

# Distro detection.  Package families are Arch, Debian, and Fedora; anything
# else is left alone (the build itself will report missing dependencies).
DISTRO_ID="unknown"
DISTRO_LIKE=""
if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO_ID="${ID:-unknown}"
    DISTRO_LIKE="${ID_LIKE:-}"
fi

case " $DISTRO_ID $DISTRO_LIKE " in
    *arch*|*manjaro*|*endeavouros*|*artix*)
        PKG_FAMILY=arch
        PACKAGES=(
            base-devel git pkgconf python libxkbcommon
            wayland wayland-protocols cairo pango glib2 gdk-pixbuf2
            librsvg pipewire libsoup3 curl networkmanager
            libinput pixman libdrm mesa lcms2 systemd-libs seatd
            libdisplay-info libliftoff harfbuzz gtk3 gtk-layer-shell polkit
        )
        ;;
    *debian*|*ubuntu*|*mint*|*pop*)
        PKG_FAMILY=debian
        PACKAGES=(
            build-essential git pkg-config python3 libwayland-dev
            wayland-protocols libcairo2-dev libpango1.0-dev libglib2.0-dev
            libxkbcommon-dev libgdk-pixbuf-2.0-dev librsvg2-dev
            libpipewire-0.3-dev libsoup-3.0-dev libcurl4-openssl-dev
            libnm-dev libinput-dev libpixman-1-dev libdrm-dev libegl-dev
            libgbm-dev libgles2-mesa-dev liblcms2-dev libudev-dev libseat-dev
            libdisplay-info-dev libliftoff-dev libharfbuzz-dev libgtk-3-dev
            libgtk-layer-shell-dev libpolkit-agent-1-dev libpolkit-gobject-1-dev
        )
        ;;
    *fedora*|*rhel*|*centos*|*rocky*|*alma*)
        PKG_FAMILY=fedora
        PACKAGES=(
            gcc make git pkgconf-pkg-config python3 wayland-devel
            wayland-protocols-devel cairo-devel pango-devel glib2-devel
            libxkbcommon-devel gdk-pixbuf2-devel librsvg2-devel pipewire-devel
            libsoup3-devel libcurl-devel NetworkManager-devel libinput-devel
            pixman-devel libdrm-devel mesa-libEGL-devel mesa-libgbm-devel
            mesa-libGLES-devel lcms2-devel systemd-devel libseat-devel
            libdisplay-info-devel libliftoff-devel harfbuzz-devel gtk3-devel
            gtk-layer-shell-devel polkit-devel
        )
        ;;
    *)
        PKG_FAMILY=unknown
        PACKAGES=()
        ;;
esac

if [ "$CHECK_ONLY" -eq 1 ]; then
    echo "build dependency check"
    echo "detected distro : $DISTRO_ID ($PKG_FAMILY)"
    if [ "${#PACKAGES[@]}" -gt 0 ]; then
        echo
        echo "packages this distro would install:"
        printf '  %s\n' "${PACKAGES[@]}"
    else
        echo
        echo "automatic dependency installation is unavailable on this distro."
    fi

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
    missing=0
    for c in "${REQUIRED_COMMANDS[@]}"; do
        command -v "$c" >/dev/null 2>&1 || missing=1
    done
    if command -v pkg-config >/dev/null 2>&1; then
        for m in "${REQUIRED_MODULES[@]}"; do
            pkg-config --exists "$m" 2>/dev/null || missing=1
        done
    fi
    if [ "$missing" -eq 0 ]; then
        echo "all required build dependencies are present."
        exit 0
    fi
    echo "some required build dependencies are missing." >&2
    exit 1
fi

if ! command -v runuser >/dev/null 2>&1; then
    echo "error: runuser not found (needed to build as your normal user)" >&2
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

TARGET_USER="$(id -un)"

# The whole job runs in one elevated shell so the password is asked once.
# Within it, cloning and building are dropped back to the normal user with
# runuser; only dependency installation and `make install` stay privileged.
worker="$(mktemp "${TMPDIR:-/tmp}/install-jt-worker.XXXXXX")"
trap 'rm -f "$worker"' EXIT

cat > "$worker" <<'WORKER'
#!/usr/bin/env bash
set -u

PKG_FAMILY=$1; shift
packages=()
while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
    packages+=("$1")
    shift
done
if [ "$#" -gt 0 ]; then shift; fi
repos=("$@")

run_as_user() {
    runuser -u "$TARGET_USER" -- \
        env HOME="$USER_HOME" USER="$TARGET_USER" LOGNAME="$TARGET_USER" \
        PATH="$USER_PATH" "$@"
}

failures=()
ready_dirs=()
ready_names=()

echo "==> installing build dependencies ($PKG_FAMILY)"
case "$PKG_FAMILY" in
    arch)
        if ! pacman -S --needed --noconfirm "${packages[@]}"; then
            echo "error: dependency installation failed" >&2
            exit 1
        fi
        ;;
    debian)
        if ! apt-get update -qq || \
           ! DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"; then
            echo "error: dependency installation failed" >&2
            exit 1
        fi
        ;;
    fedora)
        if ! dnf install -y "${packages[@]}"; then
            echo "error: dependency installation failed" >&2
            exit 1
        fi
        ;;
    *)
        echo "note: automatic dependency installation is not supported on this" >&2
        echo "      distro; continuing and letting the build report missing deps." >&2
        ;;
esac

# Create the checkout root as the normal user.  Creating it as root leaves it
# unwritable and makes every clone fail with "Permission denied".
run_as_user mkdir -p "$BASE_DIR"

# A previous run may have left the directory owned by root; repair that so
# clones can write into it.
dir_owner="$(stat -c %U "$BASE_DIR" 2>/dev/null || true)"
if [ -n "$dir_owner" ] && [ "$dir_owner" != "$TARGET_USER" ]; then
    echo "--> fixing ownership of $BASE_DIR (was $dir_owner)"
    chown "$TARGET_USER" "$BASE_DIR"
fi

for entry in "${repos[@]}"; do
    IFS='|' read -r name slug url <<<"$entry"
    dir="$BASE_DIR/$slug"

    echo
    echo "=== $name ($slug) ==="

    if [ -d "$dir/.git" ]; then
        echo "--> already cloned, skipping clone"
    elif [ -e "$dir" ]; then
        echo "error: $dir exists but is not a git checkout" >&2
        failures+=("$name (checkout exists)")
        continue
    else
        echo "--> cloning $url"
        if ! run_as_user git clone --progress "$url" "$dir"; then
            echo "error: clone failed for $name" >&2
            failures+=("$name (clone)")
            continue
        fi
    fi

    echo "--> building"
    if ! run_as_user make -C "$dir" -j"$JOBS"; then
        echo "error: build failed for $name" >&2
        failures+=("$name (build)")
        continue
    fi

    ready_dirs+=("$dir")
    ready_names+=("$name")
done

if [ "${#ready_dirs[@]}" -gt 0 ]; then
    echo
    echo "=== installing ${#ready_dirs[@]} repo(s) ==="
    for i in "${!ready_dirs[@]}"; do
        echo "--> installing ${ready_names[$i]}"
        if ! make -C "${ready_dirs[$i]}" install; then
            echo "error: install failed for ${ready_names[$i]}" >&2
            failures+=("${ready_names[$i]} (install)")
        fi
    done
fi

echo
echo "================= summary ================="
if [ "${#failures[@]}" -gt 0 ]; then
    printf 'failed: %s\n' "${failures[*]}" >&2
    exit 1
fi
echo "all done"
WORKER
chmod 644 "$worker"

"${PRIV[@]}" env HOME="$HOME" PATH="$PATH" \
    TARGET_USER="$TARGET_USER" USER_HOME="$HOME" USER_PATH="$PATH" \
    BASE_DIR="$BASE_DIR" JOBS="$JOBS" \
    bash "$worker" "$PKG_FAMILY" "${PACKAGES[@]}" -- "${REPOS[@]}"
