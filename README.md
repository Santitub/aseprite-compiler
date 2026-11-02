# Aseprite Compiler

[Español](README-ES.md)

Scripts to compile [Aseprite](https://github.com/aseprite/aseprite) from its
official source code on Windows, Linux and macOS, for x64 and arm64.

Aseprite is source-available software. Its license lets you compile it for your
own personal use, but not distribute the result. This project automates the
compilation; it does not ship any Aseprite binaries.

| Platform | x64 | arm64 |
|---|---|---|
| Windows 10/11 | yes | yes |
| Linux (glibc 2.35+) | yes | yes |
| macOS | 10.15+ | 11.0+ |

## Quick start

**Windows.** Double-click `build.bat`, or run it from a terminal:

```bat
build.bat
```

**Linux and macOS:**

```sh
./build.sh --install-deps
```

The script downloads the latest release, checks its checksum, builds it, and
puts the result in `output/`:

| Platform | Result |
|---|---|
| Windows | `output/aseprite-<version>-windows-<arch>/aseprite.exe` and a `.zip` |
| Linux | `output/aseprite-<version>-linux-<arch>/aseprite` and a `.tar.gz` |
| macOS | `output/aseprite-<version>-macos-<arch>/Aseprite.app` and a `.dmg` |

On Linux, `install.sh` inside the output folder installs Aseprite into
`~/.local` and adds a desktop entry.

## Requirements

You need about 6 GB of free disk space and 4 GB of RAM. Builds for linux-arm64
and windows-arm64 also compile Skia (no prebuilt package exists for them),
which needs about 12 GB and takes much longer.

### Windows

- Visual Studio 2022 or 2026 (Community or Build Tools) with the **Desktop
  development with C++** workload. For arm64 you also need the
  **MSVC ARM64 build tools** and **C++ Clang tools for Windows** components.
- Git and Python 3, for arm64 only.

`build.bat -InstallDeps` installs all of this with `winget`. CMake and Ninja
are downloaded automatically if they are missing or too old.

### Linux

- clang or g++, CMake 3.20+, Ninja, git, curl, unzip, Python 3
- X11, OpenGL and fontconfig development headers

`./build.sh --install-deps` installs these on Debian/Ubuntu, Fedora, Arch and
openSUSE. On Debian/Ubuntu the manual equivalent is:

```sh
sudo apt-get install -y clang cmake ninja-build git curl unzip python3 \
  libx11-dev libxcursor-dev libxi-dev libxrandr-dev libgl1-mesa-dev libfontconfig1-dev
```

### macOS

- Xcode Command Line Tools (`xcode-select --install`)
- CMake and Ninja (`brew install cmake ninja`)

## Options

| `build.sh` | `build.bat` / `build.ps1` | Description |
|---|---|---|
| `-v, --version TAG` | `-Version TAG` | Aseprite release, e.g. `v1.3.18.6` (default: latest) |
| `-a, --arch ARCH` | `-Arch ARCH` | `x64` or `arm64` (default: this machine) |
| `-s, --skia TAG` | `-SkiaTag TAG` | Override the Skia version |
| `--skia-from-source` | `-SkiaFromSource` | Compile Skia instead of downloading it |
| `-t, --build-type T` | `-BuildType T` | `Release` or `RelWithDebInfo` |
| `-j, --jobs N` | `-Jobs N` | Parallel jobs (default: based on CPU and RAM) |
| `-o, --output DIR` | `-OutputDir DIR` | Output directory |
| `-w, --work-dir DIR` | `-WorkDir DIR` | Downloads and intermediate files |
| `-i, --install-deps` | `-InstallDeps` | Install system dependencies first |
| `--fresh` | `-Fresh` | Discard previous build files |
| `--no-archive` | `-NoArchive` | Skip the `.zip` / `.tar.gz` / `.dmg` |
| `-y, --yes` | `-Yes` | Never ask for confirmation |
| `-l, --list` | `-List` | List recent Aseprite releases |
| `--clean` | `-Clean` | Delete the work and output directories |
| `-d, --docker` | | Build a Linux binary inside Docker |

Run `./build.sh --help` or `build.bat -Help` for the complete reference. Set
`GITHUB_TOKEN` if you hit the GitHub API rate limit.

Downloads and compiled objects are kept in `.work/`. If you run the script
again, it reuses them, so a rebuild only takes a few minutes.

## Building with Docker

With Docker you can build the Linux version without installing anything else,
from any operating system:

```sh
./build.sh --docker
```

The build runs on Ubuntu 22.04, so the binary works on any distribution with
glibc 2.35 or newer. Pass `--arch arm64` to build for ARM. On an x64 machine
this uses emulation and can take several hours.

## GitHub Actions

The `Build` workflow compiles all six targets on GitHub-hosted runners and
uploads the packages to a **draft** release. It never uses the Actions cache
or workflow artifacts.

To use it on your fork:

1. Enable Actions in the **Actions** tab.
2. Open **Build**, click **Run workflow**, and pick a version and targets.
3. Download the packages from the draft release under **Releases**.

The workflow also runs once a day. When Aseprite publishes a new release, it
builds it automatically.

Draft releases are only visible to people with write access to the
repository. **Keep the release as a draft.** If you publish it, you make the
binaries public, and the Aseprite EULA forbids that.

## How it works

1. The script gets the release from the GitHub API. It downloads the
   official `Aseprite-<version>-Source.zip` and checks it against the SHA-256
   digest that GitHub publishes. For releases without a source package, it
   clones the tag instead.
2. It reads the Skia version that the release expects from
   `laf/misc/skia-tag.txt`, so it never has to guess. Then it downloads the
   matching prebuilt package from
   [aseprite/skia](https://github.com/aseprite/skia/releases). If there is no
   package for the platform, `scripts/build-skia.py` compiles Skia, fetching
   only the 11 dependencies that Aseprite links.
3. It configures CMake with the options from the upstream
   [INSTALL.md](https://github.com/aseprite/aseprite/blob/main/INSTALL.md) and
   builds with Ninja. It caps the number of parallel jobs based on available
   memory, to avoid out-of-memory failures.
4. It packages the binary with its `data` folder, `icudtl.dat`, the EULA, and
   a `BUILD-INFO.txt`. On macOS it bundles the icons, applies an ad-hoc
   signature (Apple Silicon needs one), and builds a `.dmg`.

## Troubleshooting

**"Visual Studio ... was not found"**: install the C++ workload, or run
`build.bat -InstallDeps`.

**Path errors on Windows**: use a short work directory, e.g.
`build.bat -WorkDir C:\asebuild`.

**The compiler is killed, or the build stops with no error (Linux)**: you ran
out of memory. Use fewer jobs, e.g. `--jobs 2`.

**"App is damaged" on macOS**: macOS blocks apps that come from another
machine. Run `xattr -cr Aseprite.app`. This does not happen with apps you
build yourself.

**HTTP 403 from the GitHub API**: you hit the rate limit. Set
`GITHUB_TOKEN` to a personal access token.

## License

The scripts in this repository are released under the MIT license.

Aseprite is © Igara Studio S.A. Its
[EULA](https://github.com/aseprite/aseprite/blob/main/EULA.txt) only allows
you to compile it for personal use, and you may not distribute it to third
parties. This project is not affiliated with or endorsed by Igara Studio. If
you use Aseprite, consider [buying it](https://www.aseprite.org/): that funds
its development.
