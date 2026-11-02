# Aseprite Compiler

[English](README.md)

Scripts para compilar [Aseprite](https://github.com/aseprite/aseprite) desde su
código fuente oficial en Windows, Linux y macOS, para x64 y arm64.

El código de Aseprite es público, pero su licencia solo permite compilarlo para
uso personal, no distribuir el resultado. Este proyecto automatiza la
compilación y no incluye ningún binario de Aseprite.

| Plataforma | x64 | arm64 |
|---|---|---|
| Windows 10/11 | sí | sí |
| Linux (glibc 2.35+) | sí | sí |
| macOS | 10.15+ | 11.0+ |

## Inicio rápido

**Windows.** Haz doble clic en `build.bat`, o ejecútalo desde una terminal:

```bat
build.bat
```

**Linux y macOS:**

```sh
./build.sh --install-deps
```

El script descarga la última versión, comprueba su checksum, la compila y deja
el resultado en `output/`:

| Plataforma | Resultado |
|---|---|
| Windows | `output/aseprite-<versión>-windows-<arch>/aseprite.exe` y un `.zip` |
| Linux | `output/aseprite-<versión>-linux-<arch>/aseprite` y un `.tar.gz` |
| macOS | `output/aseprite-<versión>-macos-<arch>/Aseprite.app` y un `.dmg` |

En Linux, el `install.sh` de la carpeta de salida instala Aseprite en
`~/.local` y añade una entrada al menú de aplicaciones.

## Requisitos

Necesitas unos 6 GB libres en disco y 4 GB de RAM. Las compilaciones para
linux-arm64 y windows-arm64 también compilan Skia (no hay paquete
precompilado para ellas), lo que requiere unos 12 GB y tarda bastante más.

### Windows

- Visual Studio 2022 o 2026 (Community o Build Tools) con la carga de trabajo
  **Desarrollo para el escritorio con C++**. Para arm64 también hacen falta
  los componentes **Herramientas de compilación de MSVC para ARM64** y
  **Herramientas de Clang de C++ para Windows**.
- Git y Python 3, solo para arm64.

`build.bat -InstallDeps` instala todo esto con `winget`. CMake y Ninja se
descargan solos si faltan o están desactualizados.

### Linux

- clang o g++, CMake 3.20+, Ninja, git, curl, unzip, Python 3
- Cabeceras de desarrollo de X11, OpenGL y fontconfig

`./build.sh --install-deps` las instala en Debian/Ubuntu, Fedora, Arch y
openSUSE. En Debian/Ubuntu, el equivalente manual es:

```sh
sudo apt-get install -y clang cmake ninja-build git curl unzip python3 \
  libx11-dev libxcursor-dev libxi-dev libxrandr-dev libgl1-mesa-dev libfontconfig1-dev
```

### macOS

- Xcode Command Line Tools (`xcode-select --install`)
- CMake y Ninja (`brew install cmake ninja`)

## Opciones

| `build.sh` | `build.bat` / `build.ps1` | Descripción |
|---|---|---|
| `-v, --version TAG` | `-Version TAG` | Versión de Aseprite, p. ej. `v1.3.18.6` (por defecto: la última) |
| `-a, --arch ARCH` | `-Arch ARCH` | `x64` o `arm64` (por defecto: la de este equipo) |
| `-s, --skia TAG` | `-SkiaTag TAG` | Forzar una versión de Skia |
| `--skia-from-source` | `-SkiaFromSource` | Compilar Skia en lugar de descargarla |
| `-t, --build-type T` | `-BuildType T` | `Release` o `RelWithDebInfo` |
| `-j, --jobs N` | `-Jobs N` | Tareas en paralelo (por defecto: según CPU y RAM) |
| `-o, --output DIR` | `-OutputDir DIR` | Carpeta de salida |
| `-w, --work-dir DIR` | `-WorkDir DIR` | Descargas y archivos intermedios |
| `-i, --install-deps` | `-InstallDeps` | Instalar antes las dependencias del sistema |
| `--fresh` | `-Fresh` | Descartar compilaciones anteriores |
| `--no-archive` | `-NoArchive` | No crear el `.zip` / `.tar.gz` / `.dmg` |
| `-y, --yes` | `-Yes` | No pedir nunca confirmación |
| `-l, --list` | `-List` | Listar las últimas versiones de Aseprite |
| `--clean` | `-Clean` | Borrar las carpetas de trabajo y de salida |
| `-d, --docker` | | Compilar un binario de Linux dentro de Docker |

`./build.sh --help` o `build.bat -Help` muestran la referencia completa. Si
llegas al límite de peticiones de la API de GitHub, define `GITHUB_TOKEN`.

Las descargas y los objetos compilados se guardan en `.work/`. Si vuelves a
ejecutar el script, los reutiliza, así que recompilar solo lleva unos minutos.

## Compilar con Docker

Con Docker puedes compilar la versión de Linux sin instalar nada más, desde
cualquier sistema operativo:

```sh
./build.sh --docker
```

La compilación se hace sobre Ubuntu 22.04, así que el binario funciona en
cualquier distribución con glibc 2.35 o posterior. Añade `--arch arm64` para
compilar para ARM. En un equipo x64 esto usa emulación y puede tardar varias
horas.

## GitHub Actions

El workflow `Build` compila los seis destinos en los runners de GitHub y sube
los paquetes a una release en **borrador**. Nunca usa la caché de Actions ni
los artifacts del workflow.

Para usarlo en tu fork:

1. Activa Actions en la pestaña **Actions**.
2. Abre **Build**, pulsa **Run workflow** y elige versión y destinos.
3. Descarga los paquetes de la release en borrador, en **Releases**.

El workflow también se ejecuta una vez al día. Cuando Aseprite publica una
versión nueva, la compila automáticamente.

Las releases en borrador solo las ven las personas con permiso de escritura
en el repositorio. **Deja la release como borrador.** Si la publicas, los
binarios pasan a ser públicos, y la EULA de Aseprite lo prohíbe.

## Cómo funciona

1. El script consulta la versión en la API de GitHub. Descarga el
   `Aseprite-<versión>-Source.zip` oficial y lo comprueba contra el resumen
   SHA-256 que publica GitHub. Si la versión no tiene paquete de código, clona
   la etiqueta.
2. Lee la versión de Skia que espera esa versión de Aseprite en
   `laf/misc/skia-tag.txt`, así que nunca tiene que adivinarla. Después
   descarga el paquete precompilado correspondiente de
   [aseprite/skia](https://github.com/aseprite/skia/releases). Si no existe
   paquete para la plataforma, `scripts/build-skia.py` compila Skia y solo
   descarga las 11 dependencias que enlaza Aseprite.
3. Configura CMake con las opciones del
   [INSTALL.md](https://github.com/aseprite/aseprite/blob/main/INSTALL.md)
   oficial y compila con Ninja. Limita las tareas en paralelo según la memoria
   disponible, para evitar fallos por falta de memoria.
4. Empaqueta el binario con su carpeta `data`, `icudtl.dat`, la EULA y un
   `BUILD-INFO.txt`. En macOS añade los iconos, aplica una firma ad hoc (Apple
   Silicon la necesita) y genera un `.dmg`.

## Solución de problemas

**"Visual Studio ... was not found"**: instala la carga de trabajo de C++, o
ejecuta `build.bat -InstallDeps`.

**Errores de ruta en Windows**: usa una carpeta de trabajo corta, p. ej.
`build.bat -WorkDir C:\asebuild`.

**El compilador muere, o la compilación se para sin error (Linux)**: te has
quedado sin memoria. Usa menos tareas, p. ej. `--jobs 2`.

**"La app está dañada" en macOS**: macOS bloquea las apps que vienen de otro
equipo. Ejecuta `xattr -cr Aseprite.app`. No pasa con las apps que compilas
tú mismo.

**HTTP 403 de la API de GitHub**: has llegado al límite de peticiones. Define
`GITHUB_TOKEN` con un token personal.

## Licencia

Aseprite es © Igara Studio S.A. Su
[EULA](https://github.com/aseprite/aseprite/blob/main/EULA.txt) solo permite
compilarlo para uso personal y prohíbe distribuirlo a terceros. Este proyecto
no está afiliado a Igara Studio ni cuenta con su respaldo. Si usas Aseprite,
plantéate [comprarlo](https://www.aseprite.org/): así se financia su
desarrollo.
