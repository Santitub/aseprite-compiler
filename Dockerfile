# ============================================================================
# DOCKERFILE PARA COMPILAR ASEPRITE
# Autor: Santitub
# Descripción: Compila Aseprite desde código fuente usando multi-stage build
# ============================================================================

# ----------------------------------------------------------------------------
# ARGUMENTOS DE CONFIGURACIÓN
# ----------------------------------------------------------------------------
ARG UBUNTU_VERSION=22.04
# Sin valor por defecto - debe proporcionarse desde build.sh
ARG ASEPRITE_VERSION
ARG SKIA_VERSION
ARG GCC_VERSION=11

# ============================================================================
# STAGE 1: BUILDER - Compilación de Aseprite
# ============================================================================
FROM ubuntu:${UBUNTU_VERSION} AS builder

# Re-declarar ARGs después del FROM (necesario en Docker)
ARG ASEPRITE_VERSION
ARG SKIA_VERSION
ARG GCC_VERSION

# Validar que se proporcionaron las versiones
RUN if [ -z "$ASEPRITE_VERSION" ]; then \
        echo "ERROR: ASEPRITE_VERSION no especificada" && exit 1; \
    fi && \
    if [ -z "$SKIA_VERSION" ]; then \
        echo "ERROR: SKIA_VERSION no especificada" && exit 1; \
    fi

# Metadatos de la imagen
LABEL maintainer="tu-email@ejemplo.com" \
      description="Builder para Aseprite ${ASEPRITE_VERSION}" \
      aseprite.version="${ASEPRITE_VERSION}" \
      skia.version="${SKIA_VERSION}"

# Evitar prompts interactivos durante la instalación
ENV DEBIAN_FRONTEND=noninteractive

# Directorio de trabajo principal
WORKDIR /build

# ----------------------------------------------------------------------------
# Instalación de dependencias (en una sola capa optimizada)
# ----------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Herramientas básicas
    git \
    wget \
    curl \
    unzip \
    ca-certificates \
    # Python
    python3 \
    python3-pip \
    # Compilación
    build-essential \
    cmake \
    ninja-build \
    gcc-${GCC_VERSION} \
    g++-${GCC_VERSION} \
    pkg-config \
    # Dependencias gráficas X11
    libx11-dev \
    libxcursor-dev \
    libxi-dev \
    libxrandr-dev \
    libgl1-mesa-dev \
    libglu1-mesa-dev \
    # GTK para diálogos nativos
    libgtk-3-dev \
    # Fuentes y texto
    libfontconfig1-dev \
    libharfbuzz-dev \
    libfreetype6-dev \
    # Formatos de imagen
    libpng-dev \
    libgif-dev \
    libjpeg-dev \
    libtiff-dev \
    libwebp-dev \
    # Red y compresión
    libcurl4-openssl-dev \
    libssl-dev \
    zlib1g-dev \
    # Limpieza de caché en la misma capa
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# ----------------------------------------------------------------------------
# Descarga de Skia (motor gráfico)
# ----------------------------------------------------------------------------
RUN echo "Descargando Skia ${SKIA_VERSION}..." && \
    wget -q --show-progress -O skia.zip \
    "https://github.com/aseprite/skia/releases/download/${SKIA_VERSION}/Skia-Linux-Release-x64.zip" \
    && mkdir -p skia \
    && unzip -q skia.zip -d skia \
    && rm skia.zip

# ----------------------------------------------------------------------------
# Clonación de Aseprite
# ----------------------------------------------------------------------------
RUN echo "Clonando Aseprite ${ASEPRITE_VERSION}..." && \
    git clone \
    --depth 1 \
    --branch ${ASEPRITE_VERSION} \
    --recursive \
    --shallow-submodules \
    https://github.com/aseprite/aseprite.git

# ----------------------------------------------------------------------------
# Compilación de Aseprite
# ----------------------------------------------------------------------------
WORKDIR /build/aseprite/build

RUN cmake \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CXX_COMPILER=g++-${GCC_VERSION} \
    -DCMAKE_C_COMPILER=gcc-${GCC_VERSION} \
    -DLAF_BACKEND=skia \
    -DSKIA_DIR=/build/skia \
    -DSKIA_LIBRARY_DIR=/build/skia/out/Release-x64 \
    -DSKIA_LIBRARY=/build/skia/out/Release-x64/libskia.a \
    -G Ninja \
    .. \
    && ninja aseprite

# ============================================================================
# STAGE 2: RUNTIME - Imagen final ligera
# ============================================================================
FROM ubuntu:${UBUNTU_VERSION} AS runtime

# Re-declarar ARG para usarlo en este stage
ARG ASEPRITE_VERSION

# Metadatos
LABEL maintainer="tu-email@ejemplo.com" \
      description="Aseprite - Editor de Pixel Art" \
      version="${ASEPRITE_VERSION}"

ENV DEBIAN_FRONTEND=noninteractive

# ----------------------------------------------------------------------------
# Solo dependencias de runtime (sin herramientas de compilación)
# ----------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Librerías gráficas runtime
    libx11-6 \
    libxcursor1 \
    libxi6 \
    libxrandr2 \
    libgl1-mesa-glx \
    libglu1-mesa \
    # GTK para diálogos nativos (File > Open, etc.)
    libgtk-3-0 \
    # Fuentes y texto
    libfontconfig1 \
    libharfbuzz0b \
    libfreetype6 \
    # Formatos de imagen runtime
    libpng16-16 \
    libgif7 \
    libjpeg8 \
    libtiff5 \
    libwebp7 \
    # Red
    libcurl4 \
    # Limpieza
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# ----------------------------------------------------------------------------
# Copiar artefactos desde el builder
# ----------------------------------------------------------------------------
COPY --from=builder /build/aseprite/build/bin/aseprite /usr/local/bin/
COPY --from=builder /build/aseprite/data /usr/local/share/aseprite/data

# ----------------------------------------------------------------------------
# Configuración del usuario y permisos
# ----------------------------------------------------------------------------
RUN useradd -m -s /bin/bash aseprite \
    && mkdir -p /home/aseprite/.config/aseprite \
    && chown -R aseprite:aseprite /home/aseprite

# Cambiar al usuario no-root
USER aseprite
WORKDIR /home/aseprite

# Variable de entorno para recursos
ENV ASEPRITE_DATA=/usr/local/share/aseprite/data

# Healthcheck básico
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD test -x /usr/local/bin/aseprite || exit 1

# Punto de entrada
ENTRYPOINT ["aseprite"]
CMD []