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

_(Slices 2–3 egress throughput and 1/4/8-VM balloon memory benchmarks added as those slices land.)_
