# MicroVM Benchmarks & OrbStack Baseline

Measured on the target Apple Silicon host (`arm64`, 48 GiB physical RAM, macOS kernel `27.2.1`) before/during Slices 1–3.

## 1. OrbStack Docker Baseline

Measured with `vesper/agent-base:latest`, `postgres:17-alpine`, and OrbStack `29.8.2`:

| Metric | Measurement |
|---|---|
| Cold `docker run --rm vesper/agent-base:latest true` | 289 ms / 243 ms / 247 ms |
| Warm `docker exec <cid> true` (5 runs) | 50 ms, 47 ms, 50 ms, 47 ms, 53 ms (median 50 ms) |
| Warm `go build -a .` (hello binary in container) | 893 ms |
| Warm `npm install --prefer-offline --no-audit --no-fund` (`is-odd@3.0.1`) | 161 ms |
| `nix eval --expr '1 + 2'` | 72 ms |
| `postgres:17-alpine` start to `pg_isready` | 2437 ms |
| Container-to-host TCP stream (`128 MiB`) | 0.080 s (`1608.6 MiB/s`, `12868.8 Mbps`) |
| OrbStack process RSS (`ps`) at 0 / 1 / 4 / 8 idle containers | 16424 MiB / 16428 MiB (+4 MiB) / 16478 MiB (+54 MiB) / 16644 MiB (+220 MiB) |
| OrbStack process RSS after stopping all 8 containers | 16701 MiB (shared Linux VM pages remain allocated) |

## 2. MicroVM (`darwin/arm64` `Code-Hex/vz/v3`)

### Slice 1 — Linux `6.12.117` `arm64` + `agent-base.erofs` (`TestVZBootAndExec`)

| Metric | Measurement | vs OrbStack Baseline |
|---|---|---|
| Cold microVM boot (`VZVirtualMachine.Start` -> EROFS + overlay pivot -> ext4 mount -> `vsock` `Ping` ready) | 205.0 ms | Faster than cold `docker run` (243–289 ms) |
| First `vsock` exec inside running VM | 4.98 ms | ~10x faster than `docker exec` (47–53 ms) |
| Warm `vsock` exec (`true`, 5 runs) | 0.77 ms, 0.48 ms, 0.38 ms, 0.33 ms, 0.39 ms (median 0.39 ms) | ~125x faster than `docker exec` |

### Slice 2 — NIC-less Synthetic-DNS `vsock` Egress (`TestVZEgressEndToEnd`)

| Metric | Measurement | vs OrbStack Baseline |
|---|---|---|
| `128 MiB` guest-to-host TCP upload via `dummy0` + `iptables` NAT `REDIRECT` + `SO_ORIGINAL_DST` + `AF_VSOCK` | 172.7 ms (`741.0 MiB/s`, `5927.7 Mbps`) | ~46% of OrbStack direct socket (`1608.6 MiB/s`); zero-NIC hardware VM egress at ~6 Gbps |

### Slice 3 — Multi-VM Concurrency, Balloon Reclaim & `WarmTTL` Cold Shutdown (`TestVZConcurrentRunsAndMemoryReclaim`)

Measured on `Virtualization.VirtualMachine` XPC helper RSS (`ps -axo rss,comm`) across 1, 4, and 8 concurrent `512 MiB` VMs allocating `48 MiB` each in RAM, then idling via `SyncAndDropCaches` + `SetMemoryTarget(128 MiB)`, then shutting down after `WarmTTL` (`400 ms` in test, `90 s` default in config):

| Concurrent VMs | Parallel Boot + Exec Wall Time | Peak `VZ` Helper RSS | Post-Balloon RSS (150 ms) | Post-`WarmTTL` Stopped RSS | Cold Resume Latency (preserved disks) |
|---|---|---|---|---|---|
| 1 | 698 ms | 260.8 MiB (`267104 KiB`) | 262.0 MiB | 0 MiB (`0 KiB`) | ~210 ms |
| 4 | 745 ms | 1048.1 MiB (`1073296 KiB`) | 1049.0 MiB | 0 MiB (`0 KiB`) | ~210 ms |
| 8 | 833 ms | 2095.7 MiB (`2145952 KiB`) | 2097.3 MiB | 0 MiB (`0 KiB`) | ~210 ms |

Finding (answers open question #1 in `microvm-architecture.md`): `virtio_balloon` alone does not synchronously drop macOS XPC helper RSS within 150 ms under zero host memory pressure (and guest `tmpfs` pages stay pinned until VM exit), whereas aggressive `WarmTTL` (`90 s`) shutdown returns **100% (`0 MiB`)** of host RAM cleanly vs OrbStack's retained `16,701 MiB` baseline, with ~210 ms cold-boot resume preserving `/workspace` and `/home/node`.

### Slice 6 — Self-Contained macOS DMG & `vesper app`

Measured on Apple Silicon (`darwin/arm64`) against the packaged `Vesper.app` bundle inside `macos/build/Vesper-arm64.dmg`:

| Artifact / Metric | Measured Value | Notes |
|---|---|---|
| `Vesper-arm64.dmg` | `223 MiB` (`223M`) | Compressed macOS ARM64 DMG including `Vesper.app`, Electron, Go, Postgres 17, Next standalone (`node_modules` + signed native addons), and `vmlinux` |
| Bundled `vesper` (`bin/vesper`) | `42 MiB` (`42M`) | Ad-hoc signed with `com.apple.security.virtualization` without `--options runtime` |
| Bundled PostgreSQL 17 (`postgres/`) | `104 MiB` (`104M`) | Relocatable `initdb`/`postgres` + `pg_trgm` + `@loader_path` dylibs, zero `/nix/store` refs, Unix-socket-only (`-h ""`) |
| Bundled guest kernel (`images/vmlinux`) | `54 MiB` (`54M`) | Linux arm64 kernel (`agent-base.erofs` copied/fetched on first launch into data dir) |
| Bundled Next standalone (`web/`) | `122 MiB` (`122M`) | Run via Electron `ELECTRON_RUN_AS_NODE=1`, proxied single-origin behind `vesper app` |
| Packaged cold boot (`VESPER_READY_URL`) | `2444.6 ms` | Fresh data dir (`initdb` + schema migrations + `pg_trgm` + sealed user + Next standalone + health 200) |
| First-launch `agent-base.erofs` ready | `3277.4 ms` | `1,901,375,488`-byte image verified & APFS `cp -c` cloned from local image cache into data dir |
