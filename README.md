# Aseprite Compiler 🖥️

Este proyecto proporciona un contenedor Docker para compilar **Aseprite**, un popular editor de píxeles. El Dockerfile está configurado para compilar Aseprite desde su repositorio oficial, manejar todas las dependencias necesarias y exportar el binario resultante junto con sus recursos.

> ⚠️ **Compatibilidad del binario:** El binario generado solo es compatible con **Linux**.
> 🧪 **Versión testeada:** Este proyecto fue probado únicamente con **Aseprite v1.3.14**.
> 💻 **Compatibilidad del contenedor:** Puedes construir la imagen Docker desde **cualquier sistema operativo** que soporte Docker (Linux, macOS, Windows), pero el binario final solo funcionará en sistemas Linux.

## 🚀 Descripción

Aseprite es una herramienta de código abierto para crear y animar gráficos de píxeles. Si bien puedes compilar Aseprite manualmente, este proyecto simplifica el proceso mediante Docker, garantizando un entorno limpio y reproducible.

## 🌟 Características

* ✅ **Compilación automatizada**: Compila Aseprite desde su repositorio oficial utilizando Docker.
* 📦 **Dependencias incluidas**: Todas las dependencias necesarias están preinstaladas en la imagen.
* ⚡ **Compilación optimizada**: Utiliza `buildx` para una compilación más eficiente.
* 📁 **Exportación de archivos**: Copia automáticamente el binario y los recursos a tu máquina.
* 🧹 **Limpieza opcional**: Permite eliminar la imagen Docker al finalizar para liberar espacio.

## 🛠️ Requisitos

* [Docker](https://www.docker.com/get-started) (con soporte opcional para `buildx`)
* Conexión a Internet para clonar el repositorio y descargar dependencias

> 📌 **Nota importante:** El binario generado (`aseprite`) solo puede ejecutarse en sistemas **Linux**. Si estás en macOS o Windows, puedes compilar la imagen, pero no ejecutar directamente el binario resultante en tu sistema operativo.

## 📥 Instalación

### 1. Clonar el Repositorio

```bash
git clone https://github.com/santitub/aseprite-compiler.git
cd aseprite-compiler
```

### 2. Hacer Ejecutable el Script

```bash
chmod +x build.sh
```

### 3. Ejecutar la Compilación

```bash
./build.sh
```

El script realiza:

1. **Compilación** con Docker (`buildx`).
2. **Extracción** del binario y recursos.
3. **Opción de eliminar** la imagen Docker una vez finalizado.

Los archivos generados se ubicarán en:

* `./output/aseprite`: Binario de Aseprite para Linux.
* `./aseprite_share`: Archivos de recursos necesarios para ejecutar Aseprite.

## 🧹 Limpieza

Si decides eliminar la imagen Docker después de compilar, el script ejecutará:

```bash
docker rmi aseprite
