FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential gcc-arm-linux-gnueabihf git bc bison flex libssl-dev libelf-dev \
      libncurses-dev kmod cpio xz-utils u-boot-tools device-tree-compiler python3 \
      python3-setuptools python3-pyelftools python3-yaml python3-jsonschema swig python3-dev \
      libgnutls28-dev uuid-dev ca-certificates \
      curl openssl dosfstools mtools e2fsprogs fdisk \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /work
