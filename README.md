# Aseprite Compiler 🖥️

Este proyecto proporciona un contenedor Docker para compilar **Aseprite**, un popular editor de píxeles. El Dockerfile está configurado para compilar Aseprite desde su repositorio oficial, manejar todas las dependencias necesarias y exportar el binario resultante junto con sus recursos.

Este repositorio también incluye un script automatizado para construir la imagen Docker, copiar los archivos resultantes a tu máquina local y eliminar la imagen Docker si ya no se necesita.

## 🚀 Descripción

Aseprite es una herramienta de código abierto para crear y animar gráficos de píxeles. Si bien puedes compilar Aseprite manualmente en tu sistema, este proyecto facilita el proceso utilizando un contenedor Docker, asegurando un entorno limpio y fácil de reproducir en cualquier máquina compatible con Docker.

## 🌟 Características

- **Compilación automatizada**: Compila Aseprite desde su repositorio oficial utilizando Docker.
- **Dependencias preinstaladas**: Todas las dependencias necesarias para la compilación de Aseprite están preinstaladas en la imagen.
- **Compilación optimizada**: Usa `buildx` para crear una imagen de compilación eficiente y optimizada.
- **Exportación automática**: Copia el binario compilado y los recursos de Aseprite a tu máquina local.
- **Eliminación opcional de la imagen**: Te pregunta si deseas eliminar la imagen Docker después de completar el proceso para liberar espacio.

## 🛠️ Requisitos

- [Docker](https://www.docker.com/get-started) (preferiblemente con soporte para `buildx`)
- Conexión a Internet (para clonar el repositorio y descargar las dependencias)

## 📥 Instalación

### 1. Clonación del Repositorio

Clona este repositorio en tu máquina local:

```bash
git clone https://github.com/santitub/aseprite-compiler.git
cd aseprite-compiler
````

### 2. Construcción de la Imagen Docker

Usa el script `build.sh` para construir la imagen Docker y extraer los archivos. El script también te permitirá eliminar la imagen si ya no la necesitas.

* Asegúrate de que el script sea ejecutable:

```bash
chmod +x build.sh
```

### 3. Ejecuta el Script

Ejecuta el script para compilar Aseprite y copiar los archivos a tu máquina local:

```bash
./build.sh
```

El script realizará las siguientes acciones:

1. **Construcción de la imagen Docker**: Usará `docker buildx` para compilar Aseprite.
2. **Copia de archivos**: Extraerá el binario y los recursos de Aseprite y los copiará a tu máquina local.
3. **Eliminación de la imagen**: Te preguntará si deseas eliminar la imagen Docker una vez completado el proceso.

Después de ejecutar el script, encontrarás los siguientes archivos en tu máquina local:

* `./output/aseprite`: El binario de Aseprite.
* `./aseprite_share`: Los recursos necesarios para ejecutar Aseprite.

## 🧹 Uso

### 1. Compilar Aseprite

Puedes compilar Aseprite ejecutando el script `build.sh` como se explicó anteriormente. Esto construirá la imagen Docker, copiará los archivos resultantes y te permitirá eliminar la imagen Docker si lo deseas.

### 2. Eliminar la Imagen Docker

Si decides eliminar la imagen después de la compilación, el script te preguntará si quieres hacerlo. En caso de que decidas eliminarla, el script ejecutará el comando:

```bash
docker rmi aseprite
```
