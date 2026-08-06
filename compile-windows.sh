#!/usr/bin/env bash
# Cross-compile POSCoin Windows CLI (posd.exe) and GUI (pos-qt.exe) on Ubuntu 22.04.
# See doc/build-windows.txt for the manual step-by-step guide.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_PLATFORM="${TARGET_PLATFORM:-i686}"
DEPSDIR="${DEPSDIR:-/usr/${TARGET_PLATFORM}-w64-mingw32}"
PREFIX_HOST="${TARGET_PLATFORM}-w64-mingw32"
JOBS="${JOBS:-$(nproc)}"
DIST_DIR="${ROOT_DIR}/dist/windows"
BUILD_TMP="${BUILD_TMP:-/tmp/poscoin-win-deps}"
SKIP_QT="${SKIP_QT:-0}"

OPENSSL_VER="1.1.1w"
OPENSSL_DIR="${DEPSDIR}/openssl-${OPENSSL_VER}"
BDB_VER="6.0.20"
BDB_DIR="${DEPSDIR}/db-${BDB_VER}"
BOOST_VER="1_70_0"
BOOST_DIR="${DEPSDIR}/boost_${BOOST_VER}"
QT_VER="5.15.2"
QT_DIR="${DEPSDIR}/qt-${QT_VER}"

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || return 1
}

sudo_run() {
  if [[ ${EUID} -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

check_ubuntu() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    log "Host: ${PRETTY_NAME:-unknown} (${VERSION_ID:-?})"
    if [[ "${ID:-}" != "ubuntu" ]]; then
      warn "This script is written for Ubuntu 22.04; continuing anyway."
    elif [[ "${VERSION_ID:-}" != "22.04" ]]; then
      warn "Recommended host is Ubuntu 22.04 (found ${VERSION_ID}). Continuing."
    fi
  else
    warn "Cannot detect OS release; continuing."
  fi
}

ensure_packages() {
  local pkgs=(
    build-essential curl wget git pkg-config autoconf automake libtool
    cmake python3 unzip zip
    "g++-mingw-w64-${TARGET_PLATFORM}"
    mingw-w64 mingw-w64-tools
    libz-mingw-w64-dev
  )
  local missing=()
  for p in "${pkgs[@]}"; do
    if ! dpkg -s "$p" >/dev/null 2>&1; then
      missing+=("$p")
    fi
  done

  if ! need_cmd "${PREFIX_HOST}-g++"; then
    missing+=("g++-mingw-w64-${TARGET_PLATFORM}")
  fi

  if ((${#missing[@]})); then
    log "Installing missing packages: ${missing[*]}"
    sudo_run apt-get update
    sudo_run DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
  else
    log "Required apt packages already installed."
  fi

  # Prefer POSIX threading model
  if [[ -x /usr/bin/${PREFIX_HOST}-g++-posix ]]; then
    sudo_run update-alternatives --set "${PREFIX_HOST}-g++" "/usr/bin/${PREFIX_HOST}-g++-posix" || true
  fi
  if [[ -x /usr/bin/${PREFIX_HOST}-gcc-posix ]]; then
    sudo_run update-alternatives --set "${PREFIX_HOST}-gcc" "/usr/bin/${PREFIX_HOST}-gcc-posix" || true
  fi

  need_cmd "${PREFIX_HOST}-g++" || die "MinGW g++ (${PREFIX_HOST}-g++) not found"
  need_cmd "${PREFIX_HOST}-gcc" || die "MinGW gcc (${PREFIX_HOST}-gcc) not found"
  log "Using: $(${PREFIX_HOST}-g++ --version | head -1)"
}

ensure_dirs() {
  sudo_run mkdir -p "${DEPSDIR}" "${BUILD_TMP}" "${DIST_DIR}"
  mkdir -p "${ROOT_DIR}/src/obj" "${ROOT_DIR}/src/obj/zerocoin"
}

download() {
  local url="$1" out="$2"
  if [[ -f "$out" ]]; then
    log "Already downloaded: $out"
    return 0
  fi
  log "Downloading $url"
  curl -fL --retry 3 --retry-delay 2 -o "$out" "$url"
}

build_openssl() {
  if [[ -f "${OPENSSL_DIR}/include/openssl/ssl.h" && -f "${OPENSSL_DIR}/lib/libssl.a" ]]; then
    log "OpenSSL already installed at ${OPENSSL_DIR}"
    return 0
  fi
  log "Building OpenSSL ${OPENSSL_VER} for ${PREFIX_HOST}"
  local src="${BUILD_TMP}/openssl-${OPENSSL_VER}"
  local tarball="${BUILD_TMP}/openssl-${OPENSSL_VER}.tar.gz"
  download "https://www.openssl.org/source/openssl-${OPENSSL_VER}.tar.gz" "$tarball"
  rm -rf "$src"
  tar xzf "$tarball" -C "${BUILD_TMP}"
  pushd "$src" >/dev/null
  if [[ "${TARGET_PLATFORM}" == "x86_64" ]]; then
    ./Configure mingw64 --cross-compile-prefix=${PREFIX_HOST}- --prefix="${OPENSSL_DIR}" no-shared no-asm
  else
    ./Configure mingw --cross-compile-prefix=${PREFIX_HOST}- --prefix="${OPENSSL_DIR}" no-shared no-asm
  fi
  make -j"${JOBS}"
  sudo_run make install_sw
  popd >/dev/null
}

build_bdb() {
  if [[ -f "${BDB_DIR}/include/db_cxx.h" || -f "${BDB_DIR}/build_unix/db_cxx.h" ]]; then
    if [[ -f "${BDB_DIR}/lib/libdb_cxx.a" || -f "${BDB_DIR}/build_unix/libdb_cxx.a" ]]; then
      log "Berkeley DB already installed at ${BDB_DIR}"
      return 0
    fi
  fi
  log "Building Berkeley DB ${BDB_VER} for ${PREFIX_HOST}"
  local src="${BUILD_TMP}/db-${BDB_VER}"
  local tarball="${BUILD_TMP}/db-${BDB_VER}.tar.gz"
  download "https://download.oracle.com/berkeley-db/db-${BDB_VER}.tar.gz" "$tarball" \
    || download "http://download.oracle.com/berkeley-db/db-${BDB_VER}.tar.gz" "$tarball"
  rm -rf "$src"
  tar xzf "$tarball" -C "${BUILD_TMP}"
  # atomic.h patch for modern compilers
  if grep -q 'atomic_compare_exchange' "${src}/src/dbinc/atomic.h" 2>/dev/null; then
    true
  fi
  # Common mingw/gcc fix for dbinc/atomic.h
  if [[ -f "${src}/src/dbinc/atomic.h" ]]; then
    sed -i 's/__atomic_compare_exchange/__sync_bool_compare_and_swap/g' "${src}/src/dbinc/atomic.h" || true
    # Prefer classic inline asm fallback used by many coin forks
    if ! grep -q 'WIN32' "${src}/src/dbinc/atomic.h"; then
      true
    fi
  fi
  mkdir -p "${src}/build_unix"
  pushd "${src}/build_unix" >/dev/null
  ../dist/configure \
    --host="${PREFIX_HOST}" \
    --enable-mingw \
    --enable-cxx \
    --disable-shared \
    --disable-replication \
    --prefix="${BDB_DIR}"
  make -j"${JOBS}"
  sudo_run make install
  # Also keep build_unix libs visible for legacy makefile paths
  sudo_run mkdir -p "${BDB_DIR}/build_unix"
  sudo_run cp -a "${BDB_DIR}/lib/"* "${BDB_DIR}/build_unix/" 2>/dev/null || true
  sudo_run cp -a "${BDB_DIR}/include/"* "${BDB_DIR}/build_unix/" 2>/dev/null || true
  popd >/dev/null
}

build_boost() {
  if [[ -d "${BOOST_DIR}/boost" && -d "${BOOST_DIR}/stage/lib" ]]; then
    if ls "${BOOST_DIR}/stage/lib/"libboost_system* >/dev/null 2>&1; then
      log "Boost already installed at ${BOOST_DIR}"
      return 0
    fi
  fi
  log "Building Boost ${BOOST_VER} for ${PREFIX_HOST}"
  local src="${BUILD_TMP}/boost_${BOOST_VER}"
  local tarball="${BUILD_TMP}/boost_${BOOST_VER}.tar.bz2"
  download "https://archives.boost.io/release/1.70.0/source/boost_${BOOST_VER}.tar.bz2" "$tarball" \
    || download "https://sourceforge.net/projects/boost/files/boost/1.70.0/boost_${BOOST_VER}.tar.bz2/download" "$tarball"
  rm -rf "$src"
  tar xjf "$tarball" -C "${BUILD_TMP}"
  pushd "$src" >/dev/null
  ./bootstrap.sh
  cat > user-config.jam <<EOF
using gcc : mingw : ${PREFIX_HOST}-g++ :
    <rc>${PREFIX_HOST}-windres
    <archiver>${PREFIX_HOST}-ar
;
EOF
  ./b2 -j"${JOBS}" --user-config=user-config.jam \
    toolset=gcc-mingw target-os=windows threadapi=win32 \
    architecture=x86 address-model=$([[ ${TARGET_PLATFORM} == x86_64 ]] && echo 64 || echo 32) \
    link=static runtime-link=static threading=multi \
    variant=release \
    --layout=tagged \
    --with-system --with-filesystem --with-program_options \
    --with-thread --with-chrono \
    stage
  sudo_run mkdir -p "${BOOST_DIR}"
  sudo_run cp -a boost stage "${BOOST_DIR}/"
  popd >/dev/null
}

build_qt() {
  if [[ "${SKIP_QT}" == "1" ]]; then
    warn "SKIP_QT=1 — not building Qt / GUI"
    return 0
  fi
  if [[ -x "${QT_DIR}/bin/${PREFIX_HOST}-qmake-qt5" ]] || [[ -x "${QT_DIR}/bin/qmake" ]]; then
    log "Qt already installed at ${QT_DIR}"
    return 0
  fi
  # Prefer distro mingw Qt if available
  if need_cmd "${PREFIX_HOST}-qmake-qt5"; then
    log "Using system ${PREFIX_HOST}-qmake-qt5"
    return 0
  fi

  log "Building Qt ${QT_VER} for ${PREFIX_HOST} (this can take a long time)"
  local src="${BUILD_TMP}/qt-everywhere-src-${QT_VER}"
  local tarball="${BUILD_TMP}/qt-everywhere-src-${QT_VER}.tar.xz"
  download "https://download.qt.io/official_releases/qt/5.15/${QT_VER}/single/qt-everywhere-src-${QT_VER}.tar.xz" "$tarball" \
    || download "https://download.qt.io/archive/qt/5.15/${QT_VER}/single/qt-everywhere-src-${QT_VER}.tar.xz" "$tarball"
  rm -rf "$src"
  tar xJf "$tarball" -C "${BUILD_TMP}"
  pushd "$src" >/dev/null
  ./configure \
    -prefix "${QT_DIR}" \
    -release -static -opensource -confirm-license \
    -xplatform win32-g++ \
    -device-option CROSS_COMPILE=${PREFIX_HOST}- \
    -opengl desktop \
    -no-pch -no-icu -no-glib -no-sql-sqlite \
    -skip qt3d -skip qtactiveqt -skip qtandroidextras -skip qtcanvas3d \
    -skip qtcharts -skip qtconnectivity -skip qtdatavis3d -skip qtdeclarative \
    -skip qtdoc -skip qtgamepad -skip qtgraphicaleffects -skip qtlocation \
    -skip qtmacextras -skip qtmultimedia -skip qtnetworkauth -skip qtpurchasing \
    -skip qtquickcontrols -skip qtquickcontrols2 -skip qtremoteobjects -skip qtscript \
    -skip qtscxml -skip qtsensors -skip qtserialbus -skip qtserialport -skip qtspeech \
    -skip qtvirtualkeyboard -skip qtwayland -skip qtwebchannel -skip qtwebengine \
    -skip qtwebglplugin -skip qtwebsockets -skip qtwebview -skip qtwinextras \
    -skip qtx11extras -skip qtxmlpatterns \
    -nomake examples -nomake tests \
    -openssl-linked OPENSSL_PREFIX="${OPENSSL_DIR}"
  make -j"${JOBS}"
  sudo_run make install
  popd >/dev/null
}

verify_dep_links() {
  log "Verifying dependency paths under ${DEPSDIR}"
  local ok=1
  [[ -f "${OPENSSL_DIR}/include/openssl/ssl.h" ]] || { warn "Missing OpenSSL headers"; ok=0; }
  [[ -f "${OPENSSL_DIR}/lib/libssl.a" || -f "${OPENSSL_DIR}/libssl.a" ]] || { warn "Missing libssl.a"; ok=0; }
  [[ -d "${BOOST_DIR}/boost" ]] || { warn "Missing Boost headers"; ok=0; }
  ls "${BOOST_DIR}/stage/lib/"libboost_system* >/dev/null 2>&1 || { warn "Missing Boost libraries"; ok=0; }
  [[ -f "${BDB_DIR}/include/db_cxx.h" || -f "${BDB_DIR}/build_unix/db_cxx.h" ]] || { warn "Missing db_cxx.h"; ok=0; }
  [[ -f "${BDB_DIR}/lib/libdb_cxx.a" || -f "${BDB_DIR}/build_unix/libdb_cxx.a" ]] || { warn "Missing libdb_cxx.a"; ok=0; }
  [[ "$ok" -eq 1 ]] || die "Dependency verification failed. See messages above."
  log "Dependency links OK."
}

build_cli() {
  log "Building Windows CLI (posd.exe)"
  pushd "${ROOT_DIR}/src" >/dev/null
  make -f makefile.linux-mingw clean || true
  make -f makefile.linux-mingw -j"${JOBS}" \
    DEPSDIR="${DEPSDIR}" \
    TARGET_PLATFORM="${TARGET_PLATFORM}" \
    OPENSSL_DIR="${OPENSSL_DIR}" \
    BOOST_DIR="${BOOST_DIR}" \
    BDB_DIR="${BDB_DIR}" \
    USE_UPNP=-
  [[ -f posd.exe ]] || die "posd.exe was not produced"
  "${PREFIX_HOST}-strip" posd.exe || true
  cp -f posd.exe "${DIST_DIR}/posd.exe"
  popd >/dev/null
  log "CLI: ${DIST_DIR}/posd.exe"
  file "${DIST_DIR}/posd.exe" || true
}

find_qmake() {
  if [[ -x "${QT_DIR}/bin/qmake" ]]; then
    echo "${QT_DIR}/bin/qmake"
  elif need_cmd "${PREFIX_HOST}-qmake-qt5"; then
    command -v "${PREFIX_HOST}-qmake-qt5"
  elif need_cmd qmake; then
    command -v qmake
  else
    return 1
  fi
}

build_gui() {
  if [[ "${SKIP_QT}" == "1" ]]; then
    return 0
  fi
  local qmake_bin
  if ! qmake_bin="$(find_qmake)"; then
    warn "qmake for MinGW not found — attempting Qt build"
    build_qt
    qmake_bin="$(find_qmake)" || die "Still no qmake after Qt build"
  fi
  log "Building Windows GUI (pos-qt.exe) with ${qmake_bin}"
  pushd "${ROOT_DIR}" >/dev/null
  make distclean >/dev/null 2>&1 || true
  rm -f Makefile Makefile.Debug Makefile.Release
  "${qmake_bin}" \
    -spec win32-g++ \
    "USE_UPNP=-" \
    "USE_QRCODE=0" \
    "BOOST_LIB_SUFFIX=-mt" \
    "BOOST_THREAD_LIB_SUFFIX=_win32-mt" \
    "BOOST_INCLUDE_PATH=${BOOST_DIR}" \
    "BOOST_LIB_PATH=${BOOST_DIR}/stage/lib" \
    "BDB_INCLUDE_PATH=${BDB_DIR}/include" \
    "BDB_LIB_PATH=${BDB_DIR}/lib" \
    "OPENSSL_INCLUDE_PATH=${OPENSSL_DIR}/include" \
    "OPENSSL_LIB_PATH=${OPENSSL_DIR}/lib" \
    "QMAKE_CC=${PREFIX_HOST}-gcc" \
    "QMAKE_CXX=${PREFIX_HOST}-g++" \
    "QMAKE_LINK=${PREFIX_HOST}-g++" \
    "QMAKE_LIB=${PREFIX_HOST}-ar" \
    "QMAKE_RC=${PREFIX_HOST}-windres" \
    pos-qt.pro
  make -j"${JOBS}"
  local exe=""
  for cand in release/pos-qt.exe pos-qt.exe build/pos-qt.exe; do
    if [[ -f "$cand" ]]; then exe="$cand"; break; fi
  done
  [[ -n "$exe" ]] || die "pos-qt.exe was not produced"
  "${PREFIX_HOST}-strip" "$exe" || true
  cp -f "$exe" "${DIST_DIR}/pos-qt.exe"
  popd >/dev/null
  log "GUI: ${DIST_DIR}/pos-qt.exe"
  file "${DIST_DIR}/pos-qt.exe" || true
}

main() {
  log "POSCoin Windows cross-compile"
  check_ubuntu
  ensure_packages
  ensure_dirs
  build_openssl
  build_bdb
  build_boost
  verify_dep_links
  build_cli
  build_gui
  log "Done. Artifacts in ${DIST_DIR}/"
  ls -la "${DIST_DIR}"
}

main "$@"
