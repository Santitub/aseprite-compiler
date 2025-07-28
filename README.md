<h1 align="center">🧰 Aseprite Compiler (Docker)</h1>

<p align="center">
  An easy, fast, and legal way to compile <strong>Aseprite</strong> from its official source code using Docker 🐳
</p>

---

## 📌 About the Project

This project provides a preconfigured Docker container to **compile Aseprite** (a popular pixel art editor) from its [official repository](https://github.com/aseprite/aseprite). The idea is to simplify the compilation process, avoiding dependency conflicts or manual installations.

> ⚠️ **Important:** This project **does not distribute a compiled version of Aseprite**. The generated binary is subject to Aseprite's EULA license and can only be used **personally**. **Redistribution is prohibited**.

---

## ✨ Features

- 🔧 **Automated compilation** from the original source code  
- 🐧 **Linux-compatible binary** (even if you compile from macOS or Windows)  
- 📦 **All dependencies included** in the Docker image  
- ⚡ **Reproducible and isolated compilation** with Docker Buildx  
- 🧼 **Cleanup option** to free up space after compilation  

---

## 📋 Requirements

- [Docker](https://www.docker.com/get-started) (with optional `buildx` support)  
- Internet access (to clone and download dependencies)  
- Operating System: any system with Docker (Linux, macOS, Windows)

> 🐧 **Note:** The generated binary will only work on **Linux** systems.

---

## 🚀 Usage Instructions

### 1️⃣ Clone the Repository

```bash
git clone https://github.com/santitub/aseprite-compiler.git

cd aseprite-compiler
```

---

2️⃣ Give Permissions to the Script

```
chmod +x build.sh
```
---

3️⃣ Run the Compilation

```
./build.sh
```

✅ The process automatically performs:

1. Building a Docker image with all necessary dependencies.


2. Cloning the official Aseprite repository.


3. Compiling the binary inside the Docker container.



> 🔐 Note: The generated binary is for personal use only. Redistribution is prohibited under Aseprite’s EULA.




---

📂 Generated Files

The output files are placed in:

./output/aseprite → Compiled binary (personal use only, do not redistribute)

./aseprite_share/ → Resources required by Aseprite to run

> ⚠️ Important: You must not upload or share these files. They are subject to Aseprite’s EULA.




---

🧹 Optional Cleanup

To free up disk space, you can remove the generated Docker image with:

docker rmi aseprite


---

⚖️ License and Legal Notice

❗ You are not allowed to redistribute the Aseprite binary compiled using this script.

🔗 Aseprite is a software with source code available, but with a restrictive license (EULA) regarding its distribution.

🧾 This project is not affiliated with or endorsed by Igara Studio S.A.


---

<p align="center"><sub>Made with ❤️ by <a href="https://github.com/santitub">Santitub</a></sub></p>
