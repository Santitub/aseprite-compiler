# syntax=docker/dockerfile:1.7
#
# Builds Aseprite for Linux inside a clean, reproducible environment.
#
# Normally invoked through `./build.sh --docker`. It can also be used
# directly; the result is written to ./output:
#
#   docker buildx build --target export --output type=local,dest=output \
#     --build-arg ASEPRITE_VERSION=latest .
#
# Ubuntu 22.04 is used on purpose: binaries linked against its glibc (2.35)
# run on every mainstream distribution released since 2022.

ARG UBUNTU_VERSION=22.04

# ---------------------------------------------------------------------------
# Toolchain
# ---------------------------------------------------------------------------
FROM ubuntu:${UBUNTU_VERSION} AS toolchain

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git unzip python3 file \
      cmake ninja-build clang g++ pkg-config \
      libx11-dev libxcursor-dev libxi-dev libxrandr-dev \
      libgl1-mesa-dev libfontconfig1-dev \
 && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
FROM toolchain AS build

ARG ASEPRITE_VERSION=latest
ARG BUILD_TYPE=Release
ARG SKIA_TAG=
ARG SKIA_FROM_SOURCE=0
ARG JOBS=

WORKDIR /opt/aseprite-compiler
COPY build.sh ./
COPY scripts/ ./scripts/

# The optional GitHub token only raises the API rate limit; it is mounted
# as a secret so it never ends up in an image layer.
RUN --mount=type=secret,id=github_token,required=false \
    if [ -f /run/secrets/github_token ]; then \
      GITHUB_TOKEN="$(cat /run/secrets/github_token)"; export GITHUB_TOKEN; \
    fi; \
    ./build.sh --yes \
      --version "${ASEPRITE_VERSION}" \
      --build-type "${BUILD_TYPE}" \
      --work-dir /work \
      --output /output \
      --no-archive \
      ${SKIA_TAG:+--skia "${SKIA_TAG}"} \
      ${JOBS:+--jobs "${JOBS}"} \
      $( [ "${SKIA_FROM_SOURCE}" = "1" ] && echo --skia-from-source ) \
 && file /output/*/aseprite

# ---------------------------------------------------------------------------
# Export: only the packaged application, used with `--output type=local`
# ---------------------------------------------------------------------------
FROM scratch AS export
COPY --from=build /output/ /
