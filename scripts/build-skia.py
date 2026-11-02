#!/usr/bin/env python3
"""Build the Aseprite fork of Skia from source.

Pre-built Skia packages are only published for Windows x64/x86,
macOS x64/arm64 and Linux x64. This script covers every other target
(Linux arm64, Windows arm64) and produces the same directory layout as
the official packages, so the result can be passed to CMake through
SKIA_DIR / SKIA_LIBRARY_DIR exactly like a pre-built package.

Only the third-party dependencies that Aseprite actually links are
fetched (about 550 MB instead of several GB for a full gclient sync).

Usage:
    build-skia.py --tag m124-08a5439a6b --arch arm64 --dest /path/to/skia

Requirements: git, python3 (>= 3.8), ninja, and a C++ toolchain:
    Linux   clang / clang++
    macOS   Xcode command line tools
    Windows Visual Studio 2022+ (C++ workload) and LLVM (clang-cl)
"""

from __future__ import annotations

import argparse
import concurrent.futures
import io
import os
import platform
import re
import shutil
import subprocess
import sys
import time
import urllib.request
import zipfile

SKIA_REPO = "https://github.com/aseprite/skia.git"
MARKER = ".aseprite-compiler-complete"

# Third-party dependencies required by the `skia` and `modules` targets
# with the configuration used by Aseprite (verified with `gn desc`).
REQUIRED_DEPS = (
    "dng_sdk",
    "expat",
    "freetype",
    "harfbuzz",
    "icu",
    "libjpeg-turbo",
    "libpng",
    "libwebp",
    "piex",
    "wuffs",
    "zlib",
)

COMMON_GN_ARGS = (
    "is_debug=false",
    "is_official_build=true",
    "skia_use_system_expat=false",
    "skia_use_system_icu=false",
    "skia_use_system_libjpeg_turbo=false",
    "skia_use_system_libpng=false",
    "skia_use_system_libwebp=false",
    "skia_use_system_zlib=false",
    "skia_use_freetype=true",
    "skia_use_harfbuzz=true",
    "skia_pdf_subset_harfbuzz=true",
    "skia_use_system_freetype2=false",
    "skia_use_system_harfbuzz=false",
)


def log(msg: str) -> None:
    print(f"[skia] {msg}", flush=True)


def fail(msg: str) -> None:
    print(f"[skia] error: {msg}", file=sys.stderr, flush=True)
    sys.exit(1)


def run(cmd, cwd=None, retries: int = 1) -> None:
    code = 0
    for attempt in range(1, retries + 1):
        code = subprocess.run(cmd, cwd=cwd).returncode
        if code == 0:
            return
        if attempt < retries:
            delay = 5 * attempt
            log(f"command failed (attempt {attempt}/{retries}), retrying in {delay}s: {' '.join(cmd)}")
            time.sleep(delay)
    fail(f"command failed with exit code {code}: {' '.join(cmd)}")


def host_os() -> str:
    if sys.platform.startswith("win"):
        return "windows"
    if sys.platform == "darwin":
        return "macos"
    if sys.platform.startswith("linux"):
        return "linux"
    fail(f"unsupported host platform: {sys.platform}")
    return ""


def host_arch() -> str:
    machine = platform.machine().lower()
    if host_os() == "windows":
        # platform.machine() reports the emulated architecture when Python
        # runs under x64 emulation on Windows on ARM.
        machine = (os.environ.get("PROCESSOR_ARCHITEW6432")
                   or os.environ.get("PROCESSOR_ARCHITECTURE")
                   or machine).lower()
    if machine in ("x86_64", "amd64", "x64"):
        return "x64"
    if machine in ("aarch64", "arm64"):
        return "arm64"
    fail(f"unsupported host architecture: {machine}")
    return ""


def download(url: str, retries: int = 5) -> bytes:
    last_error = None
    for attempt in range(1, retries + 1):
        try:
            with urllib.request.urlopen(url, timeout=120) as response:
                return response.read()
        except Exception as exc:  # noqa: BLE001 - network errors are varied
            last_error = exc
            log(f"download failed (attempt {attempt}/{retries}): {exc}")
            time.sleep(3 * attempt)
    fail(f"unable to download {url}: {last_error}")
    return b""


def clone_skia(tag: str, dest: str) -> None:
    if os.path.isfile(os.path.join(dest, "DEPS")):
        log(f"reusing Skia checkout in {dest}")
        return
    if os.path.exists(dest):
        shutil.rmtree(dest)
    log(f"cloning Skia {tag}")
    run(["git", "-c", "advice.detachedHead=false", "-c", "core.longpaths=true", "clone",
         "--quiet", "--depth", "1", "--branch", tag, SKIA_REPO, dest], retries=3)


def parse_deps(skia_dir: str) -> dict:
    scope: dict = {}
    with open(os.path.join(skia_dir, "DEPS"), encoding="utf-8") as fh:
        exec("def Var(x): return vars[x]\n" + fh.read(), scope)  # noqa: S102 - trusted upstream file
    return scope["deps"]


def fetch_dep(skia_dir: str, path: str, spec: str) -> str:
    repo, commit = spec.split("@", 1)
    target = os.path.join(skia_dir, path)
    if os.path.isdir(os.path.join(target, ".git")):
        head = subprocess.run(["git", "rev-parse", "HEAD"], cwd=target,
                              capture_output=True, text=True)
        if head.returncode == 0 and head.stdout.strip() == commit:
            return f"{path} (up to date)"
    if os.path.exists(target):
        shutil.rmtree(target)
    os.makedirs(target)
    run(["git", "init", "--quiet"], cwd=target)
    run(["git", "config", "core.longpaths", "true"], cwd=target)
    run(["git", "fetch", "--quiet", "--depth", "1", repo, commit], cwd=target, retries=3)
    run(["git", "-c", "advice.detachedHead=false", "checkout", "--quiet", "--force", "FETCH_HEAD"],
        cwd=target)
    return path


def sync_deps(skia_dir: str) -> None:
    selected = {}
    for path, spec in parse_deps(skia_dir).items():
        if isinstance(spec, str) and path.startswith("third_party/externals/"):
            if path.rsplit("/", 1)[-1] in REQUIRED_DEPS:
                selected[path] = spec
    missing = set(REQUIRED_DEPS) - {p.rsplit("/", 1)[-1] for p in selected}
    if missing:
        fail(f"DEPS file does not list: {', '.join(sorted(missing))}")
    log(f"fetching {len(selected)} third-party dependencies")
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        futures = [pool.submit(fetch_dep, skia_dir, p, s) for p, s in sorted(selected.items())]
        for future in concurrent.futures.as_completed(futures):
            log(f"  {future.result()}")


def fetch_gn(skia_dir: str) -> str:
    exe = "gn.exe" if host_os() == "windows" else "gn"
    gn_path = os.path.join(skia_dir, "bin", exe)
    if os.path.isfile(gn_path):
        return gn_path
    with open(os.path.join(skia_dir, "bin", "fetch-gn"), encoding="utf-8") as fh:
        match = re.search(r"rev\s*=\s*'([0-9a-f]+)'", fh.read())
    if not match:
        fail("unable to find the gn revision in bin/fetch-gn")
    os_name = {"windows": "windows", "macos": "mac", "linux": "linux"}[host_os()]
    cpu = {"x64": "amd64", "arm64": "arm64"}[host_arch()]
    if os_name == "windows" and cpu == "arm64":
        # There is no native gn package for Windows on ARM; the x64 build
        # runs transparently under the built-in x64 emulation.
        cpu = "amd64"
    url = ("https://chrome-infra-packages.appspot.com/dl/gn/gn/"
           f"{os_name}-{cpu}/+/git_revision:{match.group(1)}")
    log(f"downloading gn ({os_name}-{cpu})")
    with zipfile.ZipFile(io.BytesIO(download(url))) as archive:
        archive.extract(exe, os.path.join(skia_dir, "bin"))
    os.chmod(gn_path, 0o755)
    return gn_path


def gn_string(value: str) -> str:
    return '"' + value.replace("\\", "/") + '"'


def find_llvm(win_vc: str) -> str:
    candidates = [os.environ.get("LLVM_DIR", "")]
    for base in (os.environ.get("ProgramW6432", ""), os.environ.get("ProgramFiles", "")):
        if base:
            candidates.append(os.path.join(base, "LLVM"))
    clang = shutil.which("clang-cl")
    if clang:
        candidates.append(os.path.dirname(os.path.dirname(clang)))
    # Clang shipped with Visual Studio ("C++ Clang tools for Windows").
    llvm_arch = "ARM64" if host_arch() == "arm64" else "x64"
    candidates += [os.path.join(win_vc, "Tools", "Llvm", llvm_arch),
                   os.path.join(win_vc, "Tools", "Llvm", "x64"),
                   os.path.join(win_vc, "Tools", "Llvm")]
    for candidate in candidates:
        if candidate and os.path.isfile(os.path.join(candidate, "bin", "clang-cl.exe")):
            return os.path.abspath(candidate)
    fail("LLVM (clang-cl) not found. Install LLVM from https://github.com/llvm/llvm-project/releases, "
         "or the 'C++ Clang tools for Windows' Visual Studio component, or pass --llvm-dir")
    return ""


def find_win_vc() -> str:
    if os.environ.get("VCINSTALLDIR"):
        return os.environ["VCINSTALLDIR"].rstrip("\\/")
    vswhere = os.path.join(os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)"),
                           "Microsoft Visual Studio", "Installer", "vswhere.exe")
    if os.path.isfile(vswhere):
        out = subprocess.run([vswhere, "-latest", "-products", "*", "-property", "installationPath"],
                             capture_output=True, text=True)
        lines = out.stdout.strip().splitlines()
        if lines and os.path.isdir(os.path.join(lines[0], "VC")):
            return os.path.join(lines[0], "VC")
    fail("Visual Studio with the C++ workload was not found (or pass --win-vc)")
    return ""


def version_key(value: str) -> list:
    return [int(x) for x in re.findall(r"\d+", value)]


def gn_args(target_os: str, arch: str, llvm_dir: str, win_vc: str, macos_min: str) -> list:
    args = list(COMMON_GN_ARGS)
    args.append(f'target_cpu="{arch}"')
    if target_os == "windows":
        clang_root = os.path.join(llvm_dir, "lib", "clang")
        versions = sorted((d for d in os.listdir(clang_root) if d[:1].isdigit()), key=version_key)
        if not versions:
            fail(f"no clang resource directory found in {clang_root}")
        args += [
            "is_trivial_abi=false",
            'cc="clang"',
            'cxx="clang++"',
            f"clang_win={gn_string(llvm_dir)}",
            f'clang_win_version="{versions[-1]}"',
            f"win_vc={gn_string(win_vc)}",
            'extra_cflags=["-MT"]',
        ]
    elif target_os == "macos":
        args += [
            f'extra_cflags=["-stdlib=libc++", "-mmacosx-version-min={macos_min}"]',
            'extra_cflags_cc=["-frtti"]',
        ]
    else:
        args += ['cc="clang"', 'cxx="clang++"']
    return args


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--tag", required=True, help="Skia tag, e.g. m124-08a5439a6b")
    parser.add_argument("--arch", choices=("x64", "arm64"), default=None,
                        help="target CPU (default: host CPU)")
    parser.add_argument("--dest", required=True, help="output directory")
    parser.add_argument("--jobs", type=int, default=0, help="parallel jobs (default: ninja default)")
    parser.add_argument("--ninja", default=os.environ.get("NINJA", "ninja"), help="ninja executable")
    parser.add_argument("--llvm-dir", default="", help="LLVM install dir (Windows only)")
    parser.add_argument("--win-vc", default="", help="Visual Studio VC dir (Windows only)")
    parser.add_argument("--macos-min", default="", help="minimum macOS version")
    opts = parser.parse_args()

    target_os = host_os()
    arch = opts.arch or host_arch()
    dest = os.path.abspath(opts.dest)
    out_dir = os.path.join(dest, "out", f"Release-{arch}")
    marker = os.path.join(out_dir, MARKER)

    if os.path.isfile(marker):
        with open(marker, encoding="utf-8") as fh:
            if fh.read().strip() == opts.tag:
                log(f"Skia {opts.tag} ({arch}) already built in {out_dir}")
                return

    ninja = shutil.which(opts.ninja) or (opts.ninja if os.path.isfile(opts.ninja) else None)
    if not ninja:
        fail("ninja not found in PATH (use --ninja)")
    if not shutil.which("git"):
        fail("git not found in PATH")

    llvm_dir = win_vc = ""
    if target_os == "windows":
        win_vc = os.path.abspath(opts.win_vc) if opts.win_vc else find_win_vc()
        llvm_dir = os.path.abspath(opts.llvm_dir) if opts.llvm_dir else find_llvm(win_vc)
        log(f"MSVC: {win_vc}")
        log(f"LLVM: {llvm_dir}")
    macos_min = opts.macos_min or ("11.0" if arch == "arm64" else "10.15")

    clone_skia(opts.tag, dest)
    sync_deps(dest)
    gn = fetch_gn(dest)

    args = gn_args(target_os, arch, llvm_dir, win_vc, macos_min)
    log("gn args: " + " ".join(args))
    run([gn, "gen", out_dir, f"--script-executable={sys.executable}", "--args=" + " ".join(args)],
        cwd=dest)

    cmd = [ninja, "-C", out_dir]
    if opts.jobs > 0:
        cmd += ["-j", str(opts.jobs)]
    cmd += ["skia", "modules"]
    log(f"compiling Skia ({arch}); this usually takes 20-60 minutes")
    run(cmd, cwd=dest)

    lib = "skia.lib" if target_os == "windows" else "libskia.a"
    if not os.path.isfile(os.path.join(out_dir, lib)):
        fail(f"{lib} was not produced in {out_dir}")
    with open(marker, "w", encoding="utf-8") as fh:
        fh.write(opts.tag + "\n")
    log(f"done: {out_dir}")


if __name__ == "__main__":
    main()
