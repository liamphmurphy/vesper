# syntax=docker/dockerfile:1
# Converts vesper/agent-base into a bootable Linux arm64 microVM rootfs.
ARG BASE_IMAGE=vesper/agent-base:latest
FROM ${BASE_IMAGE}

USER root

# Guest init, transparent NAT/DNS egress, ext4 tools, and full in-guest dockerd support.
RUN apt-get update && apt-get install -y --no-install-recommends \
      iptables iproute2 e2fsprogs procps uidmap kmod \
 && rm -rf /var/lib/apt/lists/*

# Replace Docker CLI-only install from agent-base with full static Docker Engine
# binaries (dockerd, containerd, runc, containerd-shim-runc-v2, docker-init, docker-proxy).
ARG DOCKER_VERSION=29.10.0
RUN arch="$(uname -m)" \
 && curl -fsSL "https://download.docker.com/linux/static/stable/${arch}/docker-${DOCKER_VERSION}.tgz" \
    | tar -xz -C /usr/local/bin --strip-components=1

# Ensure standard mount points and UID 1000 directories exist in the immutable EROFS image.
RUN mkdir -p /dev /proc /sys /tmp /run /mnt \
      /workspace /home/node /cache/nix /cache/gomod /cache/npm /cache/oci \
      /var/lib/docker /var/run /etc/docker \
 && chmod 1777 /tmp \
 && chown 1000:1000 /workspace /home/node

COPY vesper-guest-agent /sbin/init
# `mac`: runs a command in the run's macOS guest VM (cmd/vesper-mac).
COPY mac /usr/local/bin/mac
RUN chmod 0755 /sbin/init /usr/local/bin/mac
