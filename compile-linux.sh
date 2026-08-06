#!/usr/bin/env bash
# compile-linux.sh — Native Linux build of POS CLI + GUI
#
# Detects the host Ubuntu (or Debian) version, installs the matching
# dependency packages, then builds:
#   release/linux/<distro>-<version>/posd
#   release/linux/<distro>-<version>/pos-qt
#
# Supported hosts:
#   Ubuntu 18.04 / 20.04 / 22.04 / 24.04 / 26.04 (+ newer)
#   Debian 10+ (best-effort package set)
#
# Usage:
#   ./compile-linux.sh
#   SKIP_APT=1 ./compile-linux.sh          # skip apt installs
#   BUILD_GUI=0 ./compile-linux.sh         # CLI only
#   BUILD_CLI=0 ./compile-linux.sh         # GUI only
#   CLEAN_FIRST=1 ./compile-linux.sh       # clean before build
#   USE_UPNP=- ./compile-linux.sh          # disable UPnP (default)
#   USE_QRCODE=1 ./compile-linux.sh
#   JOBS=4 ./compile-linux.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

JOBS="${JOBS:-$(nproc 2>/dev/null || echo 2)}"
BUILD_CLI="${BUILD_CLI:-1}"
BUILD_GUI="${BUILD_GUI:-1}"
SKIP_APT="${SKIP_APT:-0}"
USE_UPNP="${USE_UPNP:--}"
USE_QRCODE="${USE_QRCODE:-0}"
STRIP_BINARIES="${STRIP_BINARIES:-1}"
CLEAN_FIRST="${CLEAN_FIRST:-0}"

RELEASE_ROOT="$ROOT/release/linux"
LOG_DIR="${LOG_DIR:-$RELEASE_ROOT/logs}"
BUILD_STAMP="${BUILD_STAMP:-$(date +%Y%m%d-%H%M%S)}"
LOG_FILE="${LOG_FILE:-$LOG_DIR/compile-linux-${BUILD_STAMP}.log}"
ERRORS_FILE="${ERRORS_FILE:-$LOG_DIR/compile-linux-${BUILD_STAMP}.errors.txt}"

# Filled by detect_os()
OS_ID=""
OS_VERSION_ID=""
OS_CODENAME=""
OS_PRETTY=""
RELEASE_TAG=""
RELEASE_DIR=""
CXX_STD="-std=c++17"
EXTRA_APT_PKGS=()
WARN_NOTES=()

ts() { date '+%Y-%m-%d %H:%M:%S'; }

log()  { printf '\n[%s] ==> %s\n' "$(ts)" "$*"; }
warn() { printf '[%s] WARNING: %s\n' "$(ts)" "$*" >&2; }
die()  {
    printf '[%s] ERROR: %s\n' "$(ts)" "$*" >&2
    if [[ -n "${LOG_FILE:-}" && -d "$(dirname "$LOG_FILE")" ]]; then
        printf '[%s] ERROR: %s\n' "$(ts)" "$*" >> "$LOG_FILE" 2>/dev/null || true
        write_error_extract "$LOG_FILE" "$ERRORS_FILE" || true
        printf '[%s] Full build log: %s\n' "$(ts)" "$LOG_FILE" >&2
        printf '[%s] Error extract:  %s\n' "$(ts)" "${ERRORS_FILE:-}" >&2
    fi
    exit 1
}

write_error_extract() {
    local src="${1:-$LOG_FILE}"
    local dest="${2:-$ERRORS_FILE}"
    [[ -f "$src" ]] || return 0
    mkdir -p "$(dirname "$dest")"
    {
        echo "=== POS Linux build — error extract ==="
        echo "Generated: $(date -Is)"
        echo "Source log: $src"
        echo
        echo "--- matching lines (error / undefined reference / make fail) ---"
        grep -nE \
            'error:|undefined reference|collect2:|fatal error:|^\[.*\] ERROR:|make(\[[0-9]+\])?: \*\*\*|Project ERROR:' \
            "$src" 2>/dev/null | tail -n 200 || echo "(no matching error lines found)"
        echo
        echo "--- last 80 lines of full log ---"
        tail -n 80 "$src" 2>/dev/null || true
    } > "$dest"
}

# Run apt-get as root or via sudo.
apt_run() {
    if [[ ${EUID} -eq 0 ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get "$@"
    else
        sudo DEBIAN_FRONTEND=noninteractive apt-get "$@"
    fi
}

apt_install() {
    local pkgs=("$@")
    local missing=()
    local p
    for p in "${pkgs[@]}"; do
        if ! dpkg -s "$p" >/dev/null 2>&1; then
            missing+=("$p")
        fi
    done
    if ((${#missing[@]})); then
        log "Installing missing packages: ${missing[*]}"
        apt_run update --allow-releaseinfo-change -qq \
            || apt_run update --allow-releaseinfo-change \
            || warn "apt-get update had errors; trying install anyway"
        apt_run install -y "${missing[@]}"
    else
        log "All required apt packages already installed"
    fi
}

detect_os() {
    if [[ ! -f /etc/os-release ]]; then
        die "Cannot detect OS: /etc/os-release not found"
    fi
    # shellcheck source=/dev/null
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VERSION_ID="${VERSION_ID:-unknown}"
    OS_CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-unknown}}"
    OS_PRETTY="${PRETTY_NAME:-$OS_ID $OS_VERSION_ID}"

    RELEASE_TAG="${OS_ID}-${OS_VERSION_ID}"
    RELEASE_DIR="$RELEASE_ROOT/${RELEASE_TAG}"

    case "$OS_ID" in
        ubuntu)
            case "$OS_VERSION_ID" in
                18.04)
                    # g++-7 C++17 is incomplete; prefer g++-8 when available
                    EXTRA_APT_PKGS+=(g++-8)
                    WARN_NOTES+=("Ubuntu 18.04: using g++-8 when available for C++17")
                    ;;
                20.04|22.04|24.04|26.04)
                    ;;
                *)
                    WARN_NOTES+=("Ubuntu ${OS_VERSION_ID} is not explicitly tested; using 22.04+ package set")
                    ;;
            esac
            ;;
        debian)
            WARN_NOTES+=("Debian detected — using Ubuntu-compatible package names (best effort)")
            ;;
        linuxmint|pop|elementary|zorin)
            WARN_NOTES+=("${OS_ID} detected — treating as Ubuntu ${OS_VERSION_ID}")
            ;;
        *)
            die "Unsupported distribution '${OS_ID}'. This script targets Ubuntu (18.04–26.04)."
            ;;
    esac
}

# Package list tuned per Ubuntu series.
collect_packages() {
    local pkgs=(
        build-essential
        pkg-config
        libssl-dev
        libdb++-dev
        libboost-all-dev
    )

    if [[ "$USE_UPNP" != "-" ]]; then
        pkgs+=(libminiupnpc-dev)
    fi
    if [[ "$USE_QRCODE" == "1" ]]; then
        pkgs+=(libqrencode-dev)
    fi

    if [[ "$BUILD_GUI" == "1" ]]; then
        case "$OS_ID-$OS_VERSION_ID" in
            ubuntu-18.04|ubuntu-20.04)
                pkgs+=(
                    qt5-default
                    qtbase5-dev
                    qtbase5-dev-tools
                    qttools5-dev-tools
                    libqt5gui5
                    libqt5core5a
                    libqt5dbus5
                )
                ;;
            *)
                # 22.04+ dropped qt5-default
                pkgs+=(
                    qtbase5-dev
                    qtbase5-dev-tools
                    qttools5-dev-tools
                    libqt5gui5
                    libqt5core5a
                    libqt5dbus5
                    qtchooser
                )
                ;;
        esac
    fi

    pkgs+=("${EXTRA_APT_PKGS[@]}")
    printf '%s\n' "${pkgs[@]}"
}

select_compiler() {
    if [[ "$OS_ID" == "ubuntu" && "$OS_VERSION_ID" == "18.04" ]]; then
        if command -v g++-8 >/dev/null 2>&1; then
            export CC="${CC:-gcc-8}"
            export CXX="${CXX:-g++-8}"
            log "Using compiler: $CXX (C++17)"
            return
        fi
        warn "g++-8 not found; falling back to default g++ (C++17 support may be incomplete)"
    fi
    export CC="${CC:-gcc}"
    export CXX="${CXX:-g++}"
    log "Using compiler: $CXX"
    "$CXX" --version | head -n 1 || true
}

find_qmake() {
    local candidates=(
        "${QMAKE:-}"
        qmake
        qmake-qt5
        /usr/lib/qt5/bin/qmake
        /usr/lib/x86_64-linux-gnu/qt5/bin/qmake
        /usr/bin/qmake
    )
    local c
    for c in "${candidates[@]}"; do
        [[ -n "$c" ]] || continue
        if command -v "$c" >/dev/null 2>&1 || [[ -x "$c" ]]; then
            local ver
            ver="$("$c" -query QT_VERSION 2>/dev/null || true)"
            if [[ "$ver" == 5.* ]]; then
                echo "$c"
                return 0
            fi
        fi
    done
    for c in qmake qmake-qt5 /usr/lib/qt5/bin/qmake; do
        if command -v "$c" >/dev/null 2>&1; then
            echo "$c"
            return 0
        fi
    done
    return 1
}

clean_tree() {
    log "Cleaning previous build artifacts"
    if [[ -f "$ROOT/src/makefile.unix" ]]; then
        make -C "$ROOT/src" -f makefile.unix clean || true
        make -C "$ROOT/src/leveldb" clean || true
    fi
    if [[ -f "$ROOT/Makefile" ]]; then
        make -C "$ROOT" clean || true
    fi
    rm -f "$ROOT/src/posd" "$ROOT/pos-qt" || true
}

build_cli() {
    log "Building CLI (posd) for ${OS_PRETTY}"
    cd "$ROOT/src"

    # Ensure leveldb is rebuilt with the selected compiler
    if [[ ! -f leveldb/libleveldb.a ]] || [[ "$CLEAN_FIRST" == "1" ]]; then
        make -C leveldb clean || true
        make -C leveldb -j"$JOBS" libleveldb.a libmemenv.a \
            CC="$CC" CXX="$CXX" \
            OPT="-O2 ${CXX_STD}"
    fi

    make -f makefile.unix -j"$JOBS" \
        USE_UPNP="$USE_UPNP" \
        CC="$CC" \
        CXX="$CXX" \
        "CXXFLAGS=${CXX_STD} -DOPENSSL_SUPPRESS_DEPRECATED -Wno-deprecated-declarations -Wno-deprecated-copy" \
        posd

    [[ -f "$ROOT/src/posd" ]] || die "CLI build finished but src/posd was not produced"
    mkdir -p "$RELEASE_DIR"
    cp -f "$ROOT/src/posd" "$RELEASE_DIR/posd"
    if [[ "$STRIP_BINARIES" == "1" ]]; then
        strip "$RELEASE_DIR/posd" || warn "strip failed for posd"
    fi
    log "CLI installed: $RELEASE_DIR/posd"
    ls -lh "$RELEASE_DIR/posd"
}

build_gui() {
    log "Building GUI (pos-qt) for ${OS_PRETTY}"
    cd "$ROOT"

    local qmake_bin
    qmake_bin="$(find_qmake)" || die "qmake (Qt5) not found. Install qtbase5-dev / qt5-default."
    log "Using qmake: $qmake_bin ($("$qmake_bin" -query QT_VERSION 2>/dev/null || echo unknown))"

    # Drop stale Makefile so qmake regenerates with current flags
    rm -f Makefile

    local qmake_args=(
        "USE_UPNP=$USE_UPNP"
        "QMAKE_CC=$CC"
        "QMAKE_CXX=$CXX"
    )
    if [[ "$USE_QRCODE" == "1" ]]; then
        qmake_args+=("USE_QRCODE=1")
    fi

    "$qmake_bin" pos-qt.pro "${qmake_args[@]}"
    make -j"$JOBS"

    [[ -f "$ROOT/pos-qt" ]] || die "GUI build finished but ./pos-qt was not produced"
    mkdir -p "$RELEASE_DIR"
    cp -f "$ROOT/pos-qt" "$RELEASE_DIR/pos-qt"
    if [[ "$STRIP_BINARIES" == "1" ]]; then
        strip "$RELEASE_DIR/pos-qt" || warn "strip failed for pos-qt"
    fi
    log "GUI installed: $RELEASE_DIR/pos-qt"
    ls -lh "$RELEASE_DIR/pos-qt"
}

write_release_readme() {
    local cxx_ver
    cxx_ver="$("$CXX" --version 2>/dev/null | head -n1 || echo unknown)"
    cat > "$RELEASE_DIR/README.txt" <<EOF
POS Linux build
===============
Built:     $(date -Is)
Host:      ${OS_PRETTY}
Distro:    ${OS_ID} ${OS_VERSION_ID} (${OS_CODENAME})
Arch:      $(uname -m)
Compiler:  ${CXX} (${cxx_ver})
USE_UPNP:  ${USE_UPNP}
USE_QRCODE:${USE_QRCODE}

Binaries in this folder are linked against libraries from this OS release.
They are intended to run on the same Ubuntu/Debian series (or newer with
compatible glibc). A build from Ubuntu 24.04 will NOT run on 18.04/20.04.

To build for another Ubuntu version, run ./compile-linux.sh on that host
(or inside a matching Docker/container image).

Files:
  posd     - command-line daemon / RPC wallet
  pos-qt   - Qt graphical wallet
EOF
}

print_summary() {
    log "Build complete for ${RELEASE_TAG}"
    echo
    echo "Output directory: $RELEASE_DIR"
    if [[ "$BUILD_CLI" == "1" && -f "$RELEASE_DIR/posd" ]]; then
        ls -lh "$RELEASE_DIR/posd"
    fi
    if [[ "$BUILD_GUI" == "1" && -f "$RELEASE_DIR/pos-qt" ]]; then
        ls -lh "$RELEASE_DIR/pos-qt"
    fi
    echo
    echo "Log:    $LOG_FILE"
    if ((${#WARN_NOTES[@]})); then
        echo "Notes:"
        local n
        for n in "${WARN_NOTES[@]}"; do
            echo "  - $n"
        done
    fi
}

setup_logging() {
    mkdir -p "$LOG_DIR" "$RELEASE_DIR"
    : > "$LOG_FILE"
    ln -sfn "$(basename "$LOG_FILE")" "$LOG_DIR/compile-linux-latest.log"
    ln -sfn "$(basename "$ERRORS_FILE")" "$LOG_DIR/compile-linux-latest.errors.txt"

    # Mirror stdout/stderr to the log file for the rest of the script
    exec > >(tee -a "$LOG_FILE") 2>&1

    echo "================================================================"
    echo " POS compile-linux.sh"
    echo " Started:     $(date -Is)"
    echo " Log file:    $LOG_FILE"
    echo " Errors file: $ERRORS_FILE"
    echo " ROOT:        $ROOT"
    echo " RELEASE_DIR: $RELEASE_DIR"
    echo " OS:          $OS_PRETTY ($OS_ID $OS_VERSION_ID)"
    echo " JOBS:        $JOBS"
    echo " BUILD_CLI:   $BUILD_CLI"
    echo " BUILD_GUI:   $BUILD_GUI"
    echo " SKIP_APT:    $SKIP_APT"
    echo " USE_UPNP:    $USE_UPNP"
    echo " USE_QRCODE:  $USE_QRCODE"
    echo " Host:        $(uname -a 2>/dev/null || true)"
    echo "================================================================"
    echo
}

main() {
    detect_os
    setup_logging

    local n
    for n in "${WARN_NOTES[@]}"; do
        warn "$n"
    done

    log "Detected Linux: ${OS_PRETTY} -> release tag '${RELEASE_TAG}'"

    if [[ "$SKIP_APT" != "1" ]]; then
        if ! command -v apt-get >/dev/null 2>&1; then
            die "apt-get not found; set SKIP_APT=1 if dependencies are already installed"
        fi
        local pkgs=()
        mapfile -t pkgs < <(collect_packages)
        apt_install "${pkgs[@]}"
    else
        log "SKIP_APT=1 — not installing packages"
    fi

    select_compiler

    if [[ "$CLEAN_FIRST" == "1" ]]; then
        clean_tree
    fi

    if [[ "$BUILD_CLI" == "1" ]]; then
        build_cli
    else
        log "BUILD_CLI=0 — skipping CLI"
    fi

    if [[ "$BUILD_GUI" == "1" ]]; then
        build_gui
    else
        log "BUILD_GUI=0 — skipping GUI"
    fi

    write_release_readme
    print_summary
}

main
