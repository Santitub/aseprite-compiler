FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    git \
    python3 \
    python3-pip \
    wget \
    curl \
    build-essential \
    cmake \
    ninja-build \
    gcc-11 \
    g++-11 \
    pkg-config \
    && rm -rf /var/lib/apt/lists/*

RUN apt-get update && apt-get install -y \
    libx11-dev \
    libxcursor-dev \
    libxi-dev \
    libgl1-mesa-dev \
    libfontconfig1-dev \
    libharfbuzz-dev \
    libfreetype6-dev \
    libpng-dev \
    libgif-dev \
    libjpeg-dev \
    libtiff-dev \
    libwebp-dev \
    libcurl4-openssl-dev \
    libssl-dev \
    zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

RUN apt-get update && apt-get install -y \
    unzip \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

RUN git clone --recursive https://github.com/aseprite/aseprite.git

WORKDIR /build

RUN wget -O Skia-Linux-Release-x64.zip "https://github.com/aseprite/skia/releases/download/m124-08a5439a6b/Skia-Linux-Release-x64.zip" && \
    mkdir -p skia && \
    cd skia && \
    unzip ../Skia-Linux-Release-x64.zip && \
    cd .. && \
    rm Skia-Linux-Release-x64.zip

RUN mkdir -p aseprite/build

WORKDIR /build/aseprite/build

RUN cmake \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CXX_COMPILER=g++-11 \
    -DCMAKE_C_COMPILER=gcc-11 \
    -DLAF_BACKEND=skia \
    -DSKIA_DIR=/build/skia \
    -DSKIA_LIBRARY_DIR=/build/skia/out/Release-x64 \
    -DSKIA_LIBRARY=/build/skia/out/Release-x64/libskia.a \
    -G Ninja \
    ..

RUN ninja aseprite

RUN mkdir -p /usr/local/bin && \
    mkdir -p /usr/local/share/aseprite

RUN cp /build/aseprite/build/bin/aseprite /usr/local/bin/ && \
    cp -r /build/aseprite/data /usr/local/share/aseprite/

ENV ASEPRITE_USER_FOLDER=/tmp/aseprite
RUN mkdir -p /tmp/aseprite

# Aquí creamos la carpeta /output, copiamos el binario y cambiamos el WORKDIR
RUN mkdir -p /output && cp /build/aseprite/build/bin/aseprite /output/

WORKDIR /output