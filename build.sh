#!/usr/bin/env bash
#
# Aseprite build script for Linux and macOS.
#
# Builds Aseprite from the official source code, either natively or inside
# a Docker container (Linux binaries only). Run `./build.sh --help` for the
# full list of options.
#
# Compatible with bash 3.2 (the version shipped with macOS).

set -Eeuo pipefail

readonly SCRIPT_VERSION="4.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME

readonly ASEPRITE_REPO="aseprite/aseprite"
readonly SKIA_REPO="aseprite/skia"
readonly MIN_CMAKE_VERSION="3.20"

# ---------------------------------------------------------------------------
# Defaults (every option can also be set through the environment)
# ---------------------------------------------------------------------------
ASEPRITE_VERSION="${ASEPRITE_VERSION:-latest}"
SKIA_TAG="${SKIA_TAG:-}"
TARGET_ARCH="${TARGET_ARCH:-}"
BUILD_TYPE="${BUILD_TYPE:-Release}"
WORK_DIR="${WORK_DIR:-$SCRIPT_DIR/.work}"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/output}"
JOBS="${JOBS:-}"
USE_DOCKER="${USE_DOCKER:-0}"
INSTALL_DEPS="${INSTALL_DEPS:-0}"
ASSUME_YES="${ASSUME_YES:-0}"
SKIA_FROM_SOURCE="${SKIA_FROM_SOURCE:-0}"
FRESH_BUILD="${FRESH_BUILD:-0}"
CREATE_ARCHIVE="${CREATE_ARCHIVE:-1}"
VERBOSE="${VERBOSE:-0}"

# Resolved at runtime
HOST_OS=""
HOST_ARCH=""
SOURCE_DIR=""
SKIA_DIR=""
SKIA_LIB_DIR=""
PACKAGE_NAME=""
SOURCE_URL=""
SOURCE_SHA256=""
VERSION_NUMBER=""

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
fi

# GitHub Actions log grouping, a no-op elsewhere
in_ci() { [[ -n "${GITHUB_ACTIONS:-}" ]]; }

step()  { if in_ci; then echo "::group::$*"; fi; printf '\n%s==>%s %s%s%s\n' "$C_BLUE" "$C_RESET" "$C_BOLD" "$*" "$C_RESET" >&2; }
endstep() { if in_ci; then echo "::endgroup::"; fi; }
info()  { printf '    %s\n' "$*" >&2; }
ok()    { printf '    %s%s%s\n' "$C_GREEN" "$*" "$C_RESET" >&2; }
warn()  { printf '%swarning:%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; if in_ci; then echo "::warning::$*"; fi; }
debug() { if [[ "$VERBOSE" == "1" ]]; then printf '%s    [debug] %s%s\n' "$C_DIM" "$*" "$C_RESET" >&2; fi; }
die()   { printf '%serror:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; if in_ci; then echo "::error::$*"; fi; exit 1; }

on_error() {
  local code=$? line=$1 cmd=$2
  printf '%serror:%s command failed with exit code %s at line %s:\n    %s\n' \
    "$C_RED" "$C_RESET" "$code" "$line" "$cmd" >&2
  exit "$code"
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

usage() {
  cat <<EOF
Build Aseprite from the official source code.

Usage: $SCRIPT_NAME [options]

Options:
  -v, --version TAG       Aseprite release to build (default: latest), e.g. v1.3.18.6
  -a, --arch ARCH         Target architecture: x64 or arm64 (default: host)
  -s, --skia TAG          Override the Skia tag (default: read from the sources)
      --skia-from-source  Always compile Skia instead of downloading a prebuilt package
  -t, --build-type TYPE   Release or RelWithDebInfo (default: Release)
  -j, --jobs N            Parallel compile jobs (default: based on CPUs and RAM)
  -o, --output DIR        Output directory (default: ./output)
  -w, --work-dir DIR      Directory for downloads and build files (default: ./.work)
  -d, --docker            Build inside Docker (produces a Linux binary)
  -i, --install-deps      Install the required system packages before building
      --fresh             Discard previous build files for this version
      --no-archive        Do not create a .tar.gz / .dmg, keep only the folder
  -y, --yes               Do not ask for confirmation
  -l, --list              List the most recent Aseprite releases and exit
      --clean             Remove the work and output directories and exit
      --verbose           Print additional diagnostic information
  -h, --help              Show this help and exit
      --script-version    Print the version of this script and exit

Environment:
  GITHUB_TOKEN            Optional. Raises the GitHub API rate limit.
  Every option above also has an environment variable equivalent, e.g.
  ASEPRITE_VERSION, TARGET_ARCH, SKIA_TAG, BUILD_TYPE, JOBS, OUTPUT_DIR.

Examples:
  $SCRIPT_NAME                          Build the latest release for this machine
  $SCRIPT_NAME -v v1.3.17 -y            Build a specific release without prompts
  $SCRIPT_NAME --install-deps           Install dependencies, then build
  $SCRIPT_NAME --docker                 Build a Linux binary using Docker

The resulting binary is covered by the Aseprite EULA: it is for personal use
only and must not be redistributed.
EOF
}

# ---------------------------------------------------------------------------
# Generic helpers
# ---------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

confirm() {
  local prompt=$1 reply
  [[ "$ASSUME_YES" == "1" ]] && return 0
  if [[ ! -t 0 ]]; then
    die "$prompt (refusing to continue in non-interactive mode, use --yes)"
  fi
  read -r -p "$prompt [y/N] " reply
  [[ "$reply" =~ ^[YySs]$ ]]
}

# version_ge A B: true when version A >= version B
version_ge() {
  [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -t. -k1,1n -k2,2n -k3,3n | head -n1)" == "$2" ]]
}

retry() {
  local attempts=$1 delay=$2 n=1
  shift 2
  until "$@"; do
    if (( n >= attempts )); then
      return 1
    fi
    warn "attempt $n/$attempts failed, retrying in ${delay}s: $*"
    sleep "$delay"
    n=$((n + 1))
    delay=$((delay * 2))
  done
}

curl_github() {
  # GitHub API request with optional authentication
  local url=$1
  local -a args=(-fsSL --connect-timeout 20 --max-time 120
                 -H "Accept: application/vnd.github+json"
                 -H "X-GitHub-Api-Version: 2022-11-28")
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    args+=(-H "Authorization: Bearer $GITHUB_TOKEN")
  fi
  curl "${args[@]}" "$url"
}

github_api() {
  local path=$1 out
  out="$(retry 4 3 curl_github "https://api.github.com/$path")" || return 1
  printf '%s' "$out"
}

download() {
  local url=$1 dest=$2 tmp="$2.part"
  mkdir -p "$(dirname "$dest")"
  info "downloading $(basename "$dest")"
  debug "$url"
  local -a progress=(-sS)
  if [[ -t 2 ]] && ! in_ci; then progress=(--progress-bar); fi
  if ! retry 4 5 curl -fL --connect-timeout 30 --retry 3 --retry-delay 3 \
        "${progress[@]}" -o "$tmp" "$url"; then
    rm -f "$tmp"
    die "unable to download $url"
  fi
  mv -f "$tmp" "$dest"
}

sha256_of() {
  if have sha256sum; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# json_query EXPRESSION: reads JSON from stdin, evaluates a Python expression
# where `d` is the parsed document. Prints nothing when the value is missing.
json_query() {
  python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    v = eval(sys.argv[1], {"__builtins__": {}}, {"d": d, "next": next, "len": len})
except Exception:
    sys.exit(0)
if v is None:
    sys.exit(0)
if isinstance(v, (list, tuple)):
    print("\n".join(str(x) for x in v))
else:
    print(v)
' "$1"
}

cpu_count() {
  if have nproc; then nproc
  elif have sysctl; then sysctl -n hw.ncpu
  else echo 2
  fi
}

memory_gb() {
  local kb
  if [[ -r /proc/meminfo ]]; then
    kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
    echo $((kb / 1024 / 1024))
  elif have sysctl; then
    echo $(( $(sysctl -n hw.memsize) / 1024 / 1024 / 1024 ))
  else
    echo 4
  fi
}

free_disk_gb() {
  local dir=$1
  while [[ ! -d "$dir" ]]; do dir="$(dirname "$dir")"; done
  df -Pk "$dir" | awk 'NR==2 {print int($4 / 1024 / 1024)}'
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
need_value() {
  [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || die "option $1 requires a value"
}

parse_args() {
  local action=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -v|--version)     need_value "$@"; ASEPRITE_VERSION=$2; shift 2 ;;
      -a|--arch)        need_value "$@"; TARGET_ARCH=$2; shift 2 ;;
      -s|--skia)        need_value "$@"; SKIA_TAG=$2; shift 2 ;;
      --skia-from-source) SKIA_FROM_SOURCE=1; shift ;;
      -t|--build-type)  need_value "$@"; BUILD_TYPE=$2; shift 2 ;;
      -j|--jobs)        need_value "$@"; JOBS=$2; shift 2 ;;
      -o|--output)      need_value "$@"; OUTPUT_DIR=$2; shift 2 ;;
      -w|--work-dir)    need_value "$@"; WORK_DIR=$2; shift 2 ;;
      -d|--docker)      USE_DOCKER=1; shift ;;
      -i|--install-deps) INSTALL_DEPS=1; shift ;;
      --fresh)          FRESH_BUILD=1; shift ;;
      --no-archive)     CREATE_ARCHIVE=0; shift ;;
      -y|--yes)         ASSUME_YES=1; shift ;;
      -l|--list)        action=list; shift ;;
      --clean)          action=clean; shift ;;
      --verbose)        VERBOSE=1; shift ;;
      -h|--help)        usage; exit 0 ;;
      --script-version) echo "$SCRIPT_VERSION"; exit 0 ;;
      *) die "unknown option: $1 (see --help)" ;;
    esac
  done

  case "$BUILD_TYPE" in
    Release|RelWithDebInfo) ;;
    *) die "invalid build type: $BUILD_TYPE (use Release or RelWithDebInfo)" ;;
  esac
  if [[ -n "$JOBS" && ! "$JOBS" =~ ^[1-9][0-9]*$ ]]; then
    die "invalid number of jobs: $JOBS"
  fi
  if [[ "$ASEPRITE_VERSION" != "latest" && "$ASEPRITE_VERSION" != v* ]]; then
    ASEPRITE_VERSION="v$ASEPRITE_VERSION"
  fi

  mkdir -p "$WORK_DIR" "$OUTPUT_DIR"
  WORK_DIR="$(cd "$WORK_DIR" && pwd)"
  OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

  case "$action" in
    list)  list_versions; exit 0 ;;
    clean) clean_all; exit 0 ;;
  esac
}

# ---------------------------------------------------------------------------
# Platform detection
# ---------------------------------------------------------------------------
detect_platform() {
  case "$(uname -s)" in
    Linux)  HOST_OS=linux ;;
    Darwin) HOST_OS=macos ;;
    MINGW*|MSYS*|CYGWIN*) die "use build.bat or build.ps1 on Windows" ;;
    *) die "unsupported operating system: $(uname -s)" ;;
  esac

  case "$(uname -m)" in
    x86_64|amd64)  HOST_ARCH=x64 ;;
    aarch64|arm64) HOST_ARCH=arm64 ;;
    *) die "unsupported CPU architecture: $(uname -m)" ;;
  esac

  # A x86_64 shell under Rosetta 2 reports x86_64 on Apple Silicon
  if [[ "$HOST_OS" == macos && "$HOST_ARCH" == x64 ]] &&
     [[ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" == "1" ]]; then
    HOST_ARCH=arm64
  fi

  case "${TARGET_ARCH:-$HOST_ARCH}" in
    x64|x86_64|amd64)  TARGET_ARCH=x64 ;;
    arm64|aarch64)     TARGET_ARCH=arm64 ;;
    *) die "invalid architecture: $TARGET_ARCH (use x64 or arm64)" ;;
  esac

  if [[ "$USE_DOCKER" == "0" && "$HOST_OS" == linux && "$TARGET_ARCH" != "$HOST_ARCH" ]]; then
    die "cross-compiling on Linux is not supported; use --docker to build for $TARGET_ARCH under emulation"
  fi
}

# ---------------------------------------------------------------------------
# Dependencies
# ---------------------------------------------------------------------------
run_privileged() {
  if [[ "$(id -u)" == "0" ]]; then
    "$@"
  elif have sudo; then
    sudo "$@"
  else
    die "root privileges are required to run: $*"
  fi
}

install_dependencies() {
  step "Installing system dependencies"
  if [[ "$HOST_OS" == macos ]]; then
    if ! xcode-select -p >/dev/null 2>&1; then
      info "installing the Xcode command line tools"
      xcode-select --install || true
      die "finish the Xcode command line tools installation and run this script again"
    fi
    local formula missing_formulae=()
    for formula in cmake ninja; do
      have "$formula" || missing_formulae+=("$formula")
    done
    if [[ ${#missing_formulae[@]} -gt 0 ]]; then
      have brew || die "Homebrew is required to install ${missing_formulae[*]}: https://brew.sh"
      brew install "${missing_formulae[@]}"
    fi
  elif have apt-get; then
    run_privileged apt-get update -qq
    run_privileged env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates curl git unzip python3 cmake ninja-build clang g++ \
      libx11-dev libxcursor-dev libxi-dev libxrandr-dev libgl1-mesa-dev libfontconfig1-dev
  elif have dnf; then
    run_privileged dnf install -y curl git unzip python3 cmake ninja-build clang gcc-c++ \
      libX11-devel libXcursor-devel libXi-devel libXrandr-devel mesa-libGL-devel fontconfig-devel
  elif have pacman; then
    run_privileged pacman -S --needed --noconfirm curl git unzip python cmake ninja clang gcc \
      libx11 libxcursor libxi libxrandr mesa fontconfig
  elif have zypper; then
    run_privileged zypper --non-interactive install curl git unzip python3 cmake ninja clang gcc-c++ \
      libX11-devel libXcursor-devel libXi-devel libXrandr-devel Mesa-libGL-devel fontconfig-devel
  else
    die "unsupported package manager; install the dependencies listed in README.md manually"
  fi
  ok "dependencies installed"
  endstep
}

check_dependencies() {
  step "Checking build requirements"
  local missing=() tool
  for tool in curl git unzip python3 cmake ninja; do
    have "$tool" || missing+=("$tool")
  done
  if [[ "$HOST_OS" == macos ]]; then
    xcode-select -p >/dev/null 2>&1 || missing+=("xcode-command-line-tools")
  elif ! have clang++ && ! have g++; then
    missing+=("clang++ or g++")
  fi
  if [[ ${#missing[@]} -gt 0 ]]; then
    die "missing required tools: ${missing[*]} (run with --install-deps or see README.md)"
  fi

  local cmake_version
  cmake_version="$(cmake --version | awk 'NR==1 {print $3}')"
  version_ge "$cmake_version" "$MIN_CMAKE_VERSION" ||
    die "CMake $MIN_CMAKE_VERSION or newer is required (found $cmake_version)"
  info "cmake   $cmake_version"
  info "ninja   $(ninja --version)"
  info "git     $(git --version | awk '{print $3}')"
  info "python  $(python3 -c 'import platform; print(platform.python_version())')"

  if [[ "$HOST_OS" == linux ]]; then
    local pkg missing_libs=()
    if have pkg-config; then
      for pkg in x11 xcursor xi xrandr gl fontconfig; do
        pkg-config --exists "$pkg" || missing_libs+=("$pkg")
      done
      if [[ ${#missing_libs[@]} -gt 0 ]]; then
        die "missing development libraries: ${missing_libs[*]} (run with --install-deps)"
      fi
    fi
  fi
  ok "all requirements satisfied"
  endstep
}

# ---------------------------------------------------------------------------
# Versions
# ---------------------------------------------------------------------------
list_versions() {
  have python3 || die "python3 is required"
  local json
  json="$(github_api "repos/$ASEPRITE_REPO/releases?per_page=15")" ||
    die "unable to query GitHub releases"
  printf '%sRecent Aseprite releases:%s\n' "$C_BOLD" "$C_RESET"
  printf '%s' "$json" | json_query \
    '[("  %-16s %s%s" % (r["tag_name"], r["published_at"][:10], "  (pre-release)" if r["prerelease"] else "")) for r in d]'
}

resolve_version() {
  step "Resolving Aseprite version"
  local json
  if [[ "$ASEPRITE_VERSION" == "latest" ]]; then
    json="$(github_api "repos/$ASEPRITE_REPO/releases/latest")" ||
      die "unable to determine the latest Aseprite release (set GITHUB_TOKEN if you are rate limited)"
  else
    json="$(github_api "repos/$ASEPRITE_REPO/releases/tags/$ASEPRITE_VERSION")" ||
      die "release $ASEPRITE_VERSION was not found (use --list to see the available releases)"
  fi

  ASEPRITE_VERSION="$(printf '%s' "$json" | json_query 'd["tag_name"]')"
  [[ -n "$ASEPRITE_VERSION" ]] || die "unexpected response from the GitHub API"
  VERSION_NUMBER="${ASEPRITE_VERSION#v}"

  SOURCE_URL="$(printf '%s' "$json" | json_query \
    'next((a["browser_download_url"] for a in d["assets"] if a["name"].endswith("-Source.zip")), None)')"
  SOURCE_SHA256="$(printf '%s' "$json" | json_query \
    'next((a.get("digest") or "" for a in d["assets"] if a["name"].endswith("-Source.zip")), "")')"
  SOURCE_SHA256="${SOURCE_SHA256#sha256:}"

  info "version  $ASEPRITE_VERSION"
  if [[ -n "$SOURCE_URL" ]]; then
    info "source   $(basename "$SOURCE_URL")"
  else
    info "source   git clone (no source package published for this release)"
  fi
  endstep
}

# ---------------------------------------------------------------------------
# Sources
# ---------------------------------------------------------------------------
fetch_sources() {
  step "Fetching Aseprite $ASEPRITE_VERSION sources"
  SOURCE_DIR="$WORK_DIR/src/aseprite-$ASEPRITE_VERSION"
  local marker="$SOURCE_DIR/.aseprite-compiler-complete"

  if [[ -f "$marker" ]]; then
    ok "reusing sources in $SOURCE_DIR"
    endstep
    return
  fi
  rm -rf "$SOURCE_DIR"
  mkdir -p "$SOURCE_DIR"

  if [[ -n "$SOURCE_URL" ]]; then
    local zip
    zip="$WORK_DIR/downloads/$(basename "$SOURCE_URL")"
    if [[ -f "$zip" && -n "$SOURCE_SHA256" && "$(sha256_of "$zip")" != "$SOURCE_SHA256" ]]; then
      warn "cached $(basename "$zip") is corrupt, downloading it again"
      rm -f "$zip"
    fi
    [[ -f "$zip" ]] || download "$SOURCE_URL" "$zip"
    if [[ -n "$SOURCE_SHA256" ]]; then
      local actual
      actual="$(sha256_of "$zip")"
      if [[ "$actual" != "$SOURCE_SHA256" ]]; then
        rm -f "$zip"
        die "checksum mismatch for $(basename "$zip"): expected $SOURCE_SHA256, got $actual"
      fi
      ok "checksum verified (sha256 $actual)"
    fi
    info "extracting"
    unzip -q -o "$zip" -d "$SOURCE_DIR"
  else
    retry 3 5 git -c advice.detachedHead=false clone --quiet --depth 1 --recursive \
      --shallow-submodules --branch "$ASEPRITE_VERSION" \
      "https://github.com/$ASEPRITE_REPO.git" "$SOURCE_DIR" ||
      die "unable to clone Aseprite $ASEPRITE_VERSION"
  fi

  [[ -f "$SOURCE_DIR/CMakeLists.txt" && -f "$SOURCE_DIR/laf/CMakeLists.txt" ]] ||
    die "the Aseprite sources are incomplete"
  touch "$marker"
  ok "sources ready in $SOURCE_DIR"
  endstep
}

# ---------------------------------------------------------------------------
# Skia
# ---------------------------------------------------------------------------
skia_platform_name() {
  case "$HOST_OS" in
    linux) echo Linux ;;
    macos) echo macOS ;;
  esac
}

setup_skia() {
  step "Preparing Skia"
  if [[ -z "$SKIA_TAG" ]]; then
    local tag_file="$SOURCE_DIR/laf/misc/skia-tag.txt"
    [[ -f "$tag_file" ]] || die "$tag_file not found; specify the Skia tag with --skia"
    SKIA_TAG="$(tr -d '[:space:]' < "$tag_file")"
  fi
  [[ "$SKIA_TAG" =~ ^m[0-9]+-[0-9a-f]+$ ]] || die "invalid Skia tag: $SKIA_TAG"
  info "tag      $SKIA_TAG"

  SKIA_DIR="$WORK_DIR/deps/skia-$SKIA_TAG-$HOST_OS-$TARGET_ARCH"
  SKIA_LIB_DIR="$SKIA_DIR/out/Release-$TARGET_ARCH"

  if [[ -f "$SKIA_LIB_DIR/libskia.a" ]]; then
    ok "reusing Skia in $SKIA_DIR"
    endstep
    return
  fi

  local package=""
  if [[ "$SKIA_FROM_SOURCE" == "0" ]]; then
    local json base candidate
    json="$(github_api "repos/$SKIA_REPO/releases/tags/$SKIA_TAG" || true)"
    base="Skia-$(skia_platform_name)-Release-$TARGET_ARCH"
    for candidate in "$base.zip" "$base-libstdc++.zip"; do
      if [[ -n "$json" ]] && printf '%s' "$json" | json_query '[a["name"] for a in d["assets"]]' |
           grep -qxF "$candidate"; then
        package="$candidate"
        break
      fi
    done
  fi

  if [[ -n "$package" ]]; then
    info "package  $package (prebuilt)"
    local zip="$WORK_DIR/downloads/skia-$SKIA_TAG-$package"
    [[ -f "$zip" ]] || download "https://github.com/$SKIA_REPO/releases/download/$SKIA_TAG/$package" "$zip"
    rm -rf "$SKIA_DIR"
    mkdir -p "$SKIA_DIR"
    if ! unzip -q -o "$zip" -d "$SKIA_DIR"; then
      rm -f "$zip"
      die "the Skia package is corrupt, run the script again to download it"
    fi
  else
    info "no prebuilt package for $HOST_OS-$TARGET_ARCH, compiling Skia from source"
    local -a args=(--tag "$SKIA_TAG" --arch "$TARGET_ARCH" --dest "$SKIA_DIR" --ninja "$(command -v ninja)")
    if [[ -n "$JOBS" ]]; then args+=(--jobs "$JOBS"); fi
    python3 "$SCRIPT_DIR/scripts/build-skia.py" "${args[@]}"
  fi

  [[ -f "$SKIA_LIB_DIR/libskia.a" ]] || die "libskia.a not found in $SKIA_LIB_DIR"
  ok "Skia ready in $SKIA_DIR"
  endstep
}

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
default_jobs() {
  local cpus mem jobs
  cpus="$(cpu_count)"
  mem="$(memory_gb)"
  # Roughly 1.5 GB per compiler process keeps the build away from the OOM killer
  jobs=$(( mem * 2 / 3 ))
  (( jobs < 1 )) && jobs=1
  (( jobs > cpus )) && jobs=$cpus
  echo "$jobs"
}

check_disk_space() {
  local needed=6 available
  [[ "$SKIA_FROM_SOURCE" == "1" || "$TARGET_ARCH" == arm64 && "$HOST_OS" == linux ]] && needed=12
  available="$(free_disk_gb "$WORK_DIR")"
  if (( available < needed )); then
    warn "only ${available} GB free in $WORK_DIR, about ${needed} GB are recommended"
    confirm "Continue anyway?" || die "aborted by user"
  fi
}

configure_and_build() {
  step "Configuring Aseprite"
  local build_dir="$WORK_DIR/build/aseprite-$ASEPRITE_VERSION-$HOST_OS-$TARGET_ARCH"
  if [[ "$FRESH_BUILD" == "1" ]]; then
    rm -rf "$build_dir"
  fi
  mkdir -p "$build_dir"

  local -a cmake_args=(
    -S "$SOURCE_DIR" -B "$build_dir" -G Ninja
    -DCMAKE_BUILD_TYPE="$BUILD_TYPE"
    -DLAF_BACKEND=skia
    -DSKIA_DIR="$SKIA_DIR"
    -DSKIA_LIBRARY_DIR="$SKIA_LIB_DIR"
    -DSKIA_LIBRARY="$SKIA_LIB_DIR/libskia.a"
    -DENABLE_TESTS=OFF
    -DENABLE_CCACHE=OFF
  )
  # The source package is not a git checkout; without this the version
  # string would be computed from `git describe` and come out empty.
  if [[ -n "$SOURCE_URL" ]]; then
    cmake_args+=(-DUPDATE_VERSION_WITH_GIT=OFF)
  fi

  if [[ "$HOST_OS" == macos ]]; then
    local osx_arch=arm64 min_version=11.0 sdk
    if [[ "$TARGET_ARCH" == x64 ]]; then osx_arch=x86_64; min_version=10.15; fi
    sdk="$(xcrun --sdk macosx --show-sdk-path)"
    cmake_args+=(
      -DCMAKE_OSX_ARCHITECTURES="$osx_arch"
      -DCMAKE_OSX_DEPLOYMENT_TARGET="$min_version"
      -DCMAKE_OSX_SYSROOT="$sdk"
    )
    if [[ "$TARGET_ARCH" == arm64 ]]; then
      cmake_args+=(-DPNG_ARM_NEON:STRING=on)
    fi
  else
    if have clang && have clang++; then
      cmake_args+=(-DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++)
    fi
    # Skia compiled with libc++ requires Aseprite to use libc++ as well
    if grep -q -- '-stdlib=libc++' "$SKIA_LIB_DIR/args.gn" 2>/dev/null; then
      cmake_args+=(-DCMAKE_CXX_FLAGS=-stdlib=libc++ -DCMAKE_EXE_LINKER_FLAGS=-stdlib=libc++)
    fi
  fi

  debug "cmake ${cmake_args[*]}"
  cmake "${cmake_args[@]}"
  endstep

  [[ -n "$JOBS" ]] || JOBS="$(default_jobs)"
  step "Compiling Aseprite ($JOBS parallel jobs)"
  local start=$SECONDS
  ninja -C "$build_dir" -j "$JOBS" aseprite
  ok "compiled in $(( (SECONDS - start) / 60 ))m $(( (SECONDS - start) % 60 ))s"
  endstep

  BUILD_BIN_DIR="$build_dir/bin"
}

# ---------------------------------------------------------------------------
# Packaging
# ---------------------------------------------------------------------------
write_notice() {
  cat > "$1" <<EOF
Aseprite $ASEPRITE_VERSION ($HOST_OS-$TARGET_ARCH)
Built from https://github.com/$ASEPRITE_REPO on $(date -u '+%Y-%m-%d %H:%M UTC')
Skia: $SKIA_TAG
Build type: $BUILD_TYPE

This build is covered by the Aseprite End-User License Agreement
(EULA.txt). It may only be used for personal purposes and must not be
redistributed. To support the developers, buy Aseprite at
https://www.aseprite.org/
EOF
}

make_icns() {
  # make_icns PREFIX OUTPUT: builds an .icns from data/icons/<prefix><size>.png
  local prefix=$1 output=$2 icons="$SOURCE_DIR/data/icons" iconset
  have iconutil && have sips || return 0
  [[ -f "$icons/${prefix}256.png" ]] || return 0
  iconset="$(mktemp -d)/icon.iconset"
  mkdir -p "$iconset"
  local size
  for size in 16 32 128 256; do
    if [[ -f "$icons/$prefix$size.png" ]]; then
      cp "$icons/$prefix$size.png" "$iconset/icon_${size}x${size}.png"
    else
      sips -z "$size" "$size" "$icons/${prefix}256.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    fi
    sips -z $((size * 2)) $((size * 2)) "$icons/${prefix}256.png" \
      --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$iconset" -o "$output" || warn "unable to create $(basename "$output")"
  rm -rf "$(dirname "$iconset")"
}

package_linux() {
  local dest=$1
  cp "$BUILD_BIN_DIR/aseprite" "$dest/"
  cp -R "$BUILD_BIN_DIR/data" "$dest/"
  if [[ -f "$BUILD_BIN_DIR/icudtl.dat" ]]; then cp "$BUILD_BIN_DIR/icudtl.dat" "$dest/"; fi
  strip "$dest/aseprite" 2>/dev/null || true

  sed -e "s|^Exec=.*|Exec=aseprite %U|" "$SOURCE_DIR/src/desktop/linux/aseprite.desktop" \
    > "$dest/aseprite.desktop" 2>/dev/null || true
  if [[ -f "$SOURCE_DIR/data/icons/ase256.png" ]]; then
    cp "$SOURCE_DIR/data/icons/ase256.png" "$dest/aseprite.png"
  fi

  cat > "$dest/install.sh" <<'EOF'
#!/usr/bin/env bash
# Installs this Aseprite build for the current user (~/.local).
set -euo pipefail
src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
prefix="${PREFIX:-$HOME/.local}"
mkdir -p "$prefix/opt" "$prefix/bin" "$prefix/share/applications" "$prefix/share/icons/hicolor/256x256/apps"
rm -rf "$prefix/opt/aseprite"
cp -R "$src" "$prefix/opt/aseprite"
ln -sf "$prefix/opt/aseprite/aseprite" "$prefix/bin/aseprite"
if [[ -f "$src/aseprite.desktop" ]]; then
  sed "s|^Exec=.*|Exec=$prefix/opt/aseprite/aseprite %U|" "$src/aseprite.desktop" \
    > "$prefix/share/applications/aseprite.desktop"
fi
[[ -f "$src/aseprite.png" ]] && cp "$src/aseprite.png" "$prefix/share/icons/hicolor/256x256/apps/aseprite.png"
command -v update-desktop-database >/dev/null && update-desktop-database "$prefix/share/applications" || true
echo "Aseprite installed in $prefix/opt/aseprite"
echo "Make sure $prefix/bin is in your PATH."
EOF
  chmod +x "$dest/install.sh" "$dest/aseprite"
}

package_macos() {
  local dest=$1 app="$1/Aseprite.app"
  [[ -d "$BUILD_BIN_DIR/Aseprite.app" ]] || die "Aseprite.app was not produced"
  # -L resolves symlinks so the bundle is self-contained
  cp -RL "$BUILD_BIN_DIR/Aseprite.app" "$dest/"
  if [[ -f "$BUILD_BIN_DIR/icudtl.dat" && ! -f "$app/Contents/MacOS/icudtl.dat" ]]; then
    cp "$BUILD_BIN_DIR/icudtl.dat" "$app/Contents/MacOS/"
  fi
  make_icns ase "$app/Contents/Resources/Aseprite.icns"
  make_icns doc "$app/Contents/Resources/Document.icns"
  strip -x "$app/Contents/MacOS/aseprite" 2>/dev/null || true
  xattr -cr "$app" 2>/dev/null || true
  # Apple Silicon refuses to run unsigned binaries; an ad-hoc signature is enough
  codesign --force --deep --sign - "$app" || warn "ad-hoc code signing failed"
}

create_dmg() {
  local src=$1 dmg=$2 staging
  staging="$(mktemp -d)"
  cp -R "$src/Aseprite.app" "$staging/"
  cp "$src/BUILD-INFO.txt" "$src/EULA.txt" "$staging/" 2>/dev/null || true
  ln -s /Applications "$staging/Applications"
  local status=0
  retry 3 5 hdiutil create -quiet -volname "Aseprite $VERSION_NUMBER" -srcfolder "$staging" \
    -fs HFS+ -format UDZO -ov "$dmg" || status=1
  rm -rf "$staging"
  return $status
}

package() {
  step "Packaging"
  PACKAGE_NAME="aseprite-$ASEPRITE_VERSION-$HOST_OS-$TARGET_ARCH"
  local dest="$OUTPUT_DIR/$PACKAGE_NAME"
  rm -rf "$dest"
  mkdir -p "$dest"

  if [[ "$HOST_OS" == macos ]]; then package_macos "$dest"; else package_linux "$dest"; fi
  cp "$SOURCE_DIR/EULA.txt" "$dest/EULA.txt"
  write_notice "$dest/BUILD-INFO.txt"
  ok "application: $dest"

  if [[ "$CREATE_ARCHIVE" == "1" ]]; then
    local archive
    if [[ "$HOST_OS" == macos ]]; then
      archive="$OUTPUT_DIR/$PACKAGE_NAME.dmg"
      if ! create_dmg "$dest" "$archive"; then
        warn "unable to create a disk image, creating a zip archive instead"
        archive="$OUTPUT_DIR/$PACKAGE_NAME.zip"
        (cd "$OUTPUT_DIR" && ditto -c -k --sequesterRsrc --keepParent "$PACKAGE_NAME" "$archive")
      fi
    else
      archive="$OUTPUT_DIR/$PACKAGE_NAME.tar.gz"
      tar -C "$OUTPUT_DIR" -czf "$archive" "$PACKAGE_NAME"
    fi
    (cd "$OUTPUT_DIR" && printf '%s  %s\n' "$(sha256_of "$archive")" "$(basename "$archive")" \
      > "$(basename "$archive").sha256")
    ok "archive:     $archive"
  fi
  endstep
}

# ---------------------------------------------------------------------------
# Docker mode
# ---------------------------------------------------------------------------
build_in_docker() {
  have docker || die "Docker is not installed: https://docs.docker.com/get-docker/"
  local -a docker=(docker)
  if ! docker info >/dev/null 2>&1; then
    if have sudo && sudo -n true 2>/dev/null && sudo docker info >/dev/null 2>&1; then
      docker=(sudo docker)
    elif have sudo; then
      warn "Docker requires elevated privileges; you may be asked for your password"
      warn "add your user to the docker group to avoid this: sudo usermod -aG docker \$USER"
      sudo docker info >/dev/null 2>&1 || die "unable to connect to the Docker daemon"
      docker=(sudo docker)
    else
      die "unable to connect to the Docker daemon (is it running?)"
    fi
  fi

  local platform="linux/amd64"
  [[ "$TARGET_ARCH" == arm64 ]] && platform="linux/arm64"
  if [[ "$TARGET_ARCH" != "$HOST_ARCH" ]]; then
    warn "building for $TARGET_ARCH on a $HOST_ARCH machine uses emulation and can take several hours"
    confirm "Continue?" || die "aborted by user"
  fi

  step "Building Aseprite $ASEPRITE_VERSION in Docker ($platform)"
  local -a args=(
    --platform "$platform"
    --file "$SCRIPT_DIR/Dockerfile"
    --target export
    --output "type=local,dest=$OUTPUT_DIR"
    --build-arg "ASEPRITE_VERSION=$ASEPRITE_VERSION"
    --build-arg "BUILD_TYPE=$BUILD_TYPE"
    --build-arg "SKIA_TAG=$SKIA_TAG"
    --build-arg "SKIA_FROM_SOURCE=$SKIA_FROM_SOURCE"
    --build-arg "JOBS=$JOBS"
    --progress plain
  )
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    args+=(--secret "id=github_token,env=GITHUB_TOKEN")
  fi

  if "${docker[@]}" buildx version >/dev/null 2>&1; then
    "${docker[@]}" buildx build "${args[@]}" "$SCRIPT_DIR"
  else
    DOCKER_BUILDKIT=1 "${docker[@]}" build "${args[@]}" "$SCRIPT_DIR"
  fi
  endstep
  PACKAGE_NAME="aseprite-$ASEPRITE_VERSION-linux-$TARGET_ARCH"
  [[ -d "$OUTPUT_DIR/$PACKAGE_NAME" ]] || die "the Docker build did not produce $PACKAGE_NAME"
  if [[ "$(id -u)" != "0" && "${docker[0]}" == sudo ]]; then
    sudo chown -R "$(id -u):$(id -g)" "$OUTPUT_DIR"
  fi
}

# ---------------------------------------------------------------------------
# Maintenance
# ---------------------------------------------------------------------------
clean_all() {
  info "this removes $WORK_DIR and $OUTPUT_DIR"
  confirm "Delete them?" || die "aborted by user"
  rm -rf "$WORK_DIR" "$OUTPUT_DIR"
  ok "clean"
}

summary() {
  printf '\n%sBuild completed%s\n' "$C_GREEN$C_BOLD" "$C_RESET"
  printf '  Version   %s\n' "$ASEPRITE_VERSION"
  printf '  Target    %s-%s\n' "${HOST_OS/macos/macos}" "$TARGET_ARCH"
  printf '  Output    %s\n' "$OUTPUT_DIR/$PACKAGE_NAME"
  if [[ "$HOST_OS" == macos && "$USE_DOCKER" == "0" ]]; then
    printf '  Run       open "%s/Aseprite.app"\n' "$OUTPUT_DIR/$PACKAGE_NAME"
  else
    printf '  Run       "%s/aseprite"\n' "$OUTPUT_DIR/$PACKAGE_NAME"
  fi
  printf '\n%sPersonal use only. Redistribution is prohibited by the Aseprite EULA.%s\n' "$C_DIM" "$C_RESET"
  if in_ci && [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
      echo "version=$ASEPRITE_VERSION"
      echo "package=$PACKAGE_NAME"
      echo "output_dir=$OUTPUT_DIR"
    } >> "$GITHUB_OUTPUT"
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"
  detect_platform

  printf '%sAseprite build script %s%s  (%s-%s -> %s)\n' \
    "$C_BOLD" "$SCRIPT_VERSION" "$C_RESET" "$HOST_OS" "$HOST_ARCH" "$TARGET_ARCH"

  if [[ "$USE_DOCKER" == "1" ]]; then
    have curl || die "curl is required"
    have python3 || die "python3 is required"
    resolve_version
    build_in_docker
    HOST_OS=linux
    summary
    return
  fi

  if [[ "$INSTALL_DEPS" == "1" ]]; then install_dependencies; fi
  check_dependencies
  resolve_version
  check_disk_space
  fetch_sources
  setup_skia
  configure_and_build
  package
  summary
}

main "$@"
