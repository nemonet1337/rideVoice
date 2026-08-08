# rideVoice: Flutter app + Go backend + Rust crypto core
FROM mcr.microsoft.com/devcontainers/base:bookworm

ARG FLUTTER_VERSION=3.32.0
ENV FLUTTER_HOME=/opt/flutter
ENV PATH="${FLUTTER_HOME}/bin:${FLUTTER_HOME}/bin/cache/dart-sdk/bin:${PATH}"

USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        curl \
        git \
        unzip \
        xz-utils \
        zip \
        libglu1-mesa \
        clang \
        cmake \
        ninja-build \
        pkg-config \
        libgtk-3-dev \
        libssl-dev \
    && rm -rf /var/lib/apt/lists/* \
    && git clone --depth 1 --branch "${FLUTTER_VERSION}" https://github.com/flutter/flutter.git "${FLUTTER_HOME}" \
    && chown -R vscode:vscode "${FLUTTER_HOME}"

USER vscode
RUN flutter config --no-analytics \
    && flutter precache --linux \
    && flutter doctor -v || true
