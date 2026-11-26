# syntax=docker/dockerfile:1
# Builds the minimal Linux 6.12 LTS arm64 kernel Image for Vesper microVMs.
FROM debian:bookworm-slim AS builder

ARG KERNEL_VERSION=6.12.119
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl xz-utils build-essential bc bison flex \
      libssl-dev libelf-dev python3 kmod \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN curl -fsSL "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${KERNEL_VERSION}.tar.xz" -o kernel.tar.xz \
 && tar -xf kernel.tar.xz \
 && mv "linux-${KERNEL_VERSION}" linux \
 && rm kernel.tar.xz

WORKDIR /src/linux
COPY kernel.fragment.config /tmp/kernel.fragment.config
RUN make ARCH=arm64 defconfig \
 && ./scripts/kconfig/merge_config.sh -m .config /tmp/kernel.fragment.config \
 && make ARCH=arm64 olddefconfig \
 && for opt in MODULES KEXEC KEXEC_FILE CRASH_DUMP HIBERNATION DEVMEM DEVPORT VSOCKETS_LOOPBACK; do \
      if grep -q "^CONFIG_${opt}=" .config; then echo "hardening: CONFIG_${opt} is still on" >&2; exit 1; fi; \
    done \
 && make -j"$(nproc)" ARCH=arm64 Image \
 && cp arch/arm64/boot/Image /tmp/vmlinux \
 && cp .config /tmp/kernel.config

FROM scratch
COPY --from=builder /tmp/vmlinux /vmlinux
COPY --from=builder /tmp/kernel.config /kernel.config
