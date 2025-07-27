<h1 align="center">🧰 Aseprite Compiler (Docker)</h1>

<p align="center">
  Una forma fácil, rápida y legal de compilar <strong>Aseprite</strong> desde su código fuente oficial usando Docker 🐳
</p>

---

## 📌 Acerca del Proyecto

Este proyecto proporciona un contenedor Docker preconfigurado para **compilar Aseprite** (un popular editor de pixel art) desde su [repositorio oficial](https://github.com/aseprite/aseprite). La idea es simplificar el proceso de compilación, evitando conflictos de dependencias o instalaciones manuales.

> ⚠️ **Importante:** Este proyecto **no distribuye Aseprite compilado**. El binario generado está sujeto a la licencia EULA de Aseprite y solo puede ser usado **personalmente**. **Redistribuirlo está prohibido**.

---

## ✨ Características

- 🔧 **Compilación automatizada** desde el código fuente original
- 🐧 **Binario compatible con Linux** (aunque compiles desde macOS o Windows)
- 📦 **Todas las dependencias incluidas** en la imagen Docker
- ⚡ **Compilación reproducible y aislada** con Docker Buildx
- 🧼 **Opción de limpieza** para liberar espacio tras la compilación

---

## 📋 Requisitos

- [Docker](https://www.docker.com/get-started) (con soporte opcional para `buildx`)
- Acceso a Internet (para clonar y descargar dependencias)
- Sistema operativo: cualquier sistema con Docker (Linux, macOS, Windows)

> 🐧 **Nota:** El binario generado solo funcionará en sistemas **Linux**.

---

## 🚀 Instrucciones de Uso

### 1️⃣ Clona el Repositorio

```bash
git clone https://github.com/santitub/aseprite-compiler.git
cd aseprite-compiler

2️⃣ Da Permisos al Script

chmod +x build.sh

3️⃣ Ejecuta la Compilación

./build.sh

✅ El proceso realiza:

1. Construcción de una imagen Docker con todas las dependencias.


2. Clonación del repositorio oficial de Aseprite.


3. Compilación de Aseprite dentro del contenedor.




---

📂 Archivos Generados

Los archivos de salida se colocan en:

./output/aseprite → Binario compilado (solo uso personal, no redistribuir)

./aseprite_share/ → Recursos requeridos por Aseprite al ejecutarse


> ⚠️ Importante: No debes subir ni compartir estos archivos. Están sujetos a la EULA de Aseprite.




---

🧹 Limpieza Opcional

Para liberar espacio en disco, puedes eliminar la imagen Docker generada con:

docker rmi aseprite


---

⚖️ Licencia y Aviso Legal

🧑‍⚖️ Este proyecto está bajo la licencia MIT, solo para el código del contenedor/script.

❗ No estás autorizado a redistribuir el binario de Aseprite compilado mediante este script.

🔗 Aseprite es un software con código fuente disponible, pero con una licencia restrictiva (EULA) respecto a su distribución.

🧾 Este proyecto no está afiliado ni respaldado por Igara Studio S.A.



---

<p align="center"><sub>Desarrollado con ❤️ por <a href="https://github.com/santitub">Santitub</a></sub></p>
```