# Aseprite Compiler 🖥️

Este proyecto proporciona un contenedor Docker que automatiza la compilación de [Aseprite](https://www.aseprite.org/), un popular editor de pixel art. El objetivo es simplificar el proceso de compilación desde el código fuente oficial, sin necesidad de configurar manualmente las dependencias en tu sistema operativo.

> ⚠️ **Importante:** Este proyecto **no distribuye Aseprite compilado**. El binario generado dentro del contenedor es solo para **uso personal** y no debe ser redistribuido. Consulta los términos de la [Licencia de Usuario Final (EULA)](https://www.aseprite.org/eula/) de Aseprite para más información.

## 🚀 Descripción

Aseprite es una herramienta ampliamente utilizada para crear y animar gráficos de píxeles. Aunque el código fuente está disponible públicamente, su licencia prohíbe redistribuir binarios compilados. Este proyecto utiliza Docker para automatizar el proceso de compilación, manteniendo un entorno limpio y reproducible.

## 🌟 Características

* ✅ **Compilación automatizada** desde el repositorio oficial de Aseprite.
* 📦 **Dependencias incluidas** en la imagen Docker.
* ⚡ **Compilación optimizada** mediante `buildx`.
* 🐧 **Compatible con Linux**: el binario generado solo funciona en sistemas Linux.

> 📌 Nota: Aunque puedes ejecutar este contenedor desde macOS o Windows, el binario resultante **solo funcionará en Linux**.

## 🛠️ Requisitos

* [Docker](https://www.docker.com/get-started)
* Conexión a Internet (para clonar el repositorio y descargar dependencias)

## 📥 Instalación

### 1. Clonar el Repositorio

```bash
git clone https://github.com/santitub/aseprite-compiler.git
cd aseprite-compiler

2. Hacer Ejecutable el Script

chmod +x build.sh

3. Ejecutar la Compilación

./build.sh

Este script:

1. Construye una imagen Docker con todas las dependencias.


2. Clona y compila Aseprite desde su código fuente.


3. Ejecuta la compilación dentro del contenedor.



> ⚠️ Exportar el binario fuera del contenedor está desactivado por defecto. Si decides extraerlo, recuerda que solo puedes usarlo personalmente y no debes redistribuirlo bajo ninguna circunstancia.



🧹 Limpieza Opcional

Si deseas liberar espacio, puedes eliminar la imagen Docker al finalizar:

docker rmi aseprite

🛡️ Licencia y Aviso Legal

Este proyecto no está afiliado ni respaldado por Igara Studio S.A.

El código fuente de Aseprite está disponible en github.com/aseprite/aseprite

El binario generado no puede ser compartido ni distribuido. Solo el autor original (Igara Studio) puede distribuir versiones compiladas.

Consulta la EULA oficial de Aseprite para más detalles.
