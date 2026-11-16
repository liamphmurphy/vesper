# ADR: A microVM runner backend

Status: Proposed (2026-11-16). Not started. A spike (below) decides whether to
build it. Nothing here is measured yet: performance claims are expectations to
test, and they are marked as such.

## Context

The runner's only isolating backend is Docker (`RUNNER_BACKEND=docker`,
`server/internal/config/config.go:160`). On a Mac that means Docker Desktop or
OrbStack, and both are a problem for this goal:

- **Licensing.** Docker Desktop needs a paid subscription in organisations over
  250 employees or $10M revenue; OrbStack needs a paid licence for commercial
  use. The engine itself (Moby/dockerd) is Apache-2.0; the desktop apps are the
  licensed part.
- **Memory.** One long-lived Linux VM holds every container. Docker Desktop
  rarely gives memory back to macOS. OrbStack does, and that is the main thing
  its closed-source VM tuning buys.
- **Isolation.** Every turn container shares the VM's kernel and the runner's
  engine, which is root on that host (`docs/dev/plan.md:292`). The hardening
  is therefore spread through the code: `CapDrop ALL` and `no-new-privileges`
  on turns (`runner/docker.go:443`), a proxy that rebuilds every container an
  agent creates (`runner/docker_proxy.go`, ADR
  [test-environments.md](test-environments.md)), a separate `agents` network,
  and a note that containers may still reach the host's loopback through
  `host.docker.internal` (`docs/guide.md:406`,
  `agentapi/transport.go:342`).
- **Rejected for platform reasons, not design reasons.** The test-environments
  ADR called Sysbox (Docker inside the turn) "the cleanest isolation" and
  rejected it because Docker Desktop and OrbStack on macOS can't run it. A VM
  per run gives the same thing on any Mac.

The goal: **bundle the runtime Vesper's hardening needs, with no Docker on the
host**. Memory should return to the OS when work ends, isolation should be a
VM per run, and every current feature should keep working. On a Mac it ships
as **one DMG**: drag Vesper to Applications, open it, done; no Docker, no
checkout folder, no server to point the app at (section 9).

### Non-goals

- **Windows.** People use WSL2; the Linux driver covers it where WSL exposes
  `/dev/kvm` (Windows 11 with nested virtualisation; to be verified).
- **Intel Macs.** Apple silicon only.
- **Signed, notarised distribution.** The first users build the DMG and run it
  themselves (see [Development setup](#development-setup) and section 9).
- **Replacing the Docker backend.** It stays, as the fallback where there is
  no hardware virtualisation (cloud VMs without nested virtualisation, most
  Kubernetes pods).

## Decision (proposed)

### 1. One microVM per run

A run gets one lightweight Linux VM for its whole life. A turn is a process
tree inside it, started by a guest agent, and killed with its cgroup when the
turn ends, so a turn still can't leave processes behind for the next one (the
property today's container-per-turn gives, `runner/docker.go:205`). The VM is
suspended when the run goes idle and destroyed when the run is cleaned up.

Other workloads follow the same rule:

| Workload | VM |
|---|---|
| Agent turns (incl. delegated runs) | The run's VM |
| Dev workspace | One long-lived VM per workspace, two persistent disks (`/workspace`, `/home/node`) |
| Playground | One VM per playground; its services and processes are containers inside it |
| Sign-ins, model listings, usage probes | A shared utility VM, or a warm pool of small VMs (they are short and latency-sensitive) |
| Image builds | A builder VM running BuildKit |

Per-turn VMs were considered and rejected: they add boot latency for little
security, because the workspace carries state from turn to turn anyway.

Memory then comes back to the host when a VM exits. The only long-lived cases
are idle chats (until `RUNNER_CHAT_IDLE_TTL_S`) and dev workspaces; those need
a balloon or suspend policy, which is far simpler than OrbStack's general
problem because Vesper knows what is running.

### 2. One backend, two thin VM drivers

`microvm` is a single implementation of `Backend` (`runner/backend.go:43`) and
of the capability interfaces the Docker backend implements today
(`ServiceBackend`, `PlaygroundBackend`, `ProxyBackend`, `DevWorkspaceBackend`,
`LoginStarter`, `ModelLister`, `UsageProber`, `HostFolders`, `CacheBackend`).
Everything above the VM is shared; only VM lifecycle is per platform.

```go
// Driver is the only platform-specific layer.
type Driver interface {
    Boot(ctx context.Context, spec VMSpec) (VM, error) // kernel, rootfs, disks, vCPU/memory, vsock
    Restore(ctx context.Context, state string) (VM, error)
}

type VM interface {
    Dial(port uint32) (net.Conn, error)    // host → guest over vsock
    Listen(port uint32) (net.Listener, error) // guest → host over vsock
    SetMemoryTarget(bytes uint64) error    // balloon
    Suspend(ctx context.Context, state string) error
    Stop(ctx context.Context) error
}
```

| Platform | Driver | Why |
|---|---|---|
| macOS | Virtualization.framework through [Code-Hex/vz](https://github.com/Code-Hex/vz) (Go bindings; also used by Lima) | Stays in Go, no Swift helper. vsock, virtio-blk, virtiofs, traditional memory balloon, save/restore of VM state |
| Linux | [Cloud Hypervisor](https://github.com/cloud-hypervisor/cloud-hypervisor) | Rust, small device model, virtiofs (needed for host folders), balloon, hybrid vsock over a unix socket |

Both are arm64 on the development machine, so both boot the same guest
kernel, rootfs and guest agent; device differences show up immediately.

### 3. A guest agent we own

A small static Go binary is the guest's init. It speaks a Vesper protocol over
vsock: exec with a TTY and resize, stdout/stderr streaming, signals, exit
status, file copy in and out (outbox, video files, `OpenWorkspaceFile`),
service start/stop with healthchecks and log tails, mounts, and turn cleanup.

Owning it is what keeps the two drivers interchangeable. Apple's
Containerization framework already has a guest init and an exec protocol, but
they are Swift and macOS-only; adopting them would make Linux a second stack.

### 4. A container engine inside the guest

Services (any OCI image with a healthcheck) and Testcontainers expect OCI
containers and the Docker Engine API. The guest image runs dockerd (Apache-2.0)
and the turn gets its socket directly:

- **The VM is the boundary.** An agent may be root in its guest; escaping
  needs a hypervisor bug, not a container bug. The proxy's rebuild of every
  create body (`runner/docker_proxy.go:443-489`) is no longer what keeps the
  host safe. A thin guest-side policy can keep the turn label and per-turn
  cleanup the proxy provides today.
- **Things the proxy can't allow become possible:** BuildKit, Ryuk, compose
  builds, non-upgraded attach streams (test-environments ADR, Consequences).
- **Codex's own sandbox may work again.** Docker blocks the namespaces it needs
  (`docs/guide.md`, "read-only Codex turns rely on the policy hook"); inside a
  VM the turn can be given them. To verify.

Nothing on the host needs Docker installed.

### 5. Networking: no network card, only vsock

The guest has **no virtual NIC**. A dummy interface carries the default route;
iptables in the guest redirects every outbound TCP connection (from turns and
from containers inside the guest) to a forwarder in the guest agent, which
sends the original destination (`SO_ORIGINAL_DST`) and the stream to the host
over vsock. The host checks policy and dials with its own kernel TCP.

```go
// Egress is host-side; every outbound guest connection arrives here.
type Egress interface {
    Dial(ctx context.Context, runID string, network, addr string) (net.Conn, error)
}
```

- **Policy can't be bypassed from inside.** Root in the guest can rewrite its
  iptables; it still only reaches what the host agrees to dial.
- **Expected to be fast.** Both kernels run their own TCP and the host only
  splices sockets; there is no userspace TCP/IP stack in the path (unlike
  gvisor-tap-vsock, which Lima uses). Unmeasured.
- **Policy per run:** the Vesper API and the internet; never the host's
  loopback or LAN, which closes the `host.docker.internal` gap. Optional
  per-run allowlists and a log of hosts each agent reached.
- **Inbound** (playground gateway, dev-workspace PTY, port forwards) uses the
  same vsock path in reverse. The runner no longer joins a playground's Docker
  network (`runner/docker_playground.go:134`, `selfID`).
- **Gaps:** DNS goes through a resolver the guest agent forwards to the host.
  HTTP/3 falls back to TCP. Other UDP and ICMP don't work.

Rejected: a NAT device (vmnet on macOS) is fast but needs the firewall inside
the guest, where a root agent can change it, or host `pf` rules managed by a
privileged helper. Userspace networking (gvisor-tap-vsock) enforces on the
host but is the slowest path.

### 6. Disk: per-run disks and generational cache disks

**Workspace and home.** Each run gets ext4 disk images for its checkout and
home, created as copy-on-write clones of an empty template (`clonefile` on
APFS, reflink on XFS/btrfs, full copy otherwise). Guest root filesystems are
OCI images converted to ext4 once, then cloned per VM.

**Shared caches.** Today the dependency cache (`/cache`,
`runner/docker.go:517`) and the Nix store (`runner/docker_nix.go:18`) are
Docker volumes every turn mounts read-write. Across VMs the obvious substitute,
virtiofs from the host, is slowest for exactly these many-small-file trees.
Instead:

- **Base:** a read-only disk per cache kind (Nix, pnpm, Go modules, Go build,
  OCI layers) at generation N, attached to every VM.
- **Overlay:** a per-VM writable disk; the guest mounts `overlayfs` (base
  below, overlay above). Reads and writes run at block-device speed.
- **Promote:** after runs end, a compactor merges new entries from overlays
  into generation N+1 (for Nix, `nix copy` into the base store). New VMs get
  N+1; old generations are deleted when no VM uses them.
- **Misses between promotions** go to fetch caches on the host, reached
  through egress: a Nix substituter, a `GOPROXY`, an npm registry mirror, and
  an OCI pull-through registry. The last also stops every run's in-guest
  dockerd from pulling `postgres` again.

```go
type CacheStore interface {
    Base(kind CacheKind) (DiskRef, Generation)                // read-only, shared
    NewOverlay(runID string, kind CacheKind) (DiskRef, error) // writable, copy-on-write
    Promote(ctx context.Context, kind CacheKind, overlays []DiskRef) (Generation, error)
}
```

Merging is conflict-free because these caches are keyed by content or input
hash; whether it is *safe* is section 7.

**Host folders** (`RUNNER_HOST_WORKSPACES_DIR`, `docker-compose.workspaces.yml`)
stay on virtiofs: the person's editor needs the real files. Only the opted-in
checkout pays the cost. The uid 1000 → host user mapping (`docs/guide.md:180`)
must be re-verified on both drivers.

### 7. Isolation: trust domains and gates

A VM is only as isolated as what crosses its boundary. Every workload has a
trust domain (user, project, run); the runner maps runs to VMs; anything that
crosses domains goes through an explicit gate:

| Crossing | Gate |
|---|---|
| Network | Host-side egress policy per run (section 5) |
| Caches | Promote only entries verifiable against something outside the run; unverifiable caches stay per project |
| Secrets | Phase two: the host injects credentials at egress; they never enter the VM |
| Host files | Opt-in, working tree only, no hooks |

**Caches.** Promotion is a channel from one run to every later run, so a
malicious run could plant a tampered package. Today's shared volumes have the
same channel with no check (`runner/dependencies.go:24`: "intended for one
trusted user's projects"), so this is an upgrade:

- Nix: promote only store paths with valid signatures from a trusted binary
  cache. Store paths hash their inputs, not their contents, so a path proves
  nothing by itself.
- pnpm, Go modules, OCI layers: verify integrity hashes, `go.sum`/sumdb, and
  digests.
- Go build cache: not verifiable; shared only within one project.

**Secrets.** Provider logins are written into turn containers as files today
(`runner/docker.go`, "delivered as a file below, never through the
environment"), and push credentials live under the home volume. A VM doesn't
change that: the run can read them. Egress can: for allowlisted hosts (GitHub,
model APIs) the host terminates TLS with a per-run CA the guest trusts and adds
the credential, so the guest holds a placeholder. CLIs that read token files
get a placeholder token the host swaps. This is phase two, not part of the
spike.

**Host folders.** The weakest crossing, today as well: a run that writes into
a checkout the person opens can plant things that run on the *host*, such as
`.git/hooks`, `.vscode/tasks.json` and `.envrc`. Options: share only the working
tree and keep `.git` in the VM, set `core.hooksPath` on the host, and at
minimum warn when a host folder is opened.

### 8. The stack leaves Compose

Postgres, SeaweedFS, the API, web and Caddy run as Compose services today, and
the runner is a container holding the host's Docker socket
(`docker-compose.yml:108`, `docker-compose.dev.yml:79`). With no Docker:

- **The runner runs on the host.** It must, to start VMs (on macOS it needs
  the `com.apple.security.virtualization` entitlement and can't sit inside a
  VM). It's the `vesper runner` binary, ad-hoc signed.
- **The rest runs as native processes:** the API and web (already native in
  `make dev`), Postgres from a package manager or bundled binaries, SeaweedFS
  (a single Go binary), started by a `Procfile`/Makefile target. Alternative:
  one long-lived "stack VM" for Postgres and SeaweedFS.
- On a Mac, the desktop app starts and supervises all of it (section 9).

### 9. Packaging: one DMG

**Today** the desktop app is a thin client. It loads a server URL
(`http://localhost:8080` by default, `desktop/src/main.ts:49`), and for a
local stack it asks for a Vesper checkout containing `docker-compose.yml` and
runs `docker compose up -d` there (`desktop/src/main.ts:663`,
`desktop/src/docker.ts:105`). `make desktop-dmg` builds an unsigned arm64 DMG
with electron-builder (`desktop/electron-builder.yml`, `desktop/package.json`).

**Proposed:** the same `make desktop-dmg` builds a DMG whose app carries the
whole local stack. Install is drag to Applications; first launch downloads the
guest images and opens Vesper, already signed in.

#### What `Vesper.app` contains

| In the bundle | What it is | Replaces |
|---|---|---|
| Electron | The window, tabs, notifications (as today) | — |
| Next standalone server | `web` built with `output: "standalone"`, run on Electron's own Node (`ELECTRON_RUN_AS_NODE` or a utility process); includes the arm64 resvg binding the designs routes need | The `web` container |
| `vesper` (darwin/arm64) | API, runner and VM drivers in one process: a new combined mode (for example `vesper app`) that runs `serve` and `runner`, supervises Postgres, and serves the single origin | The `api` and `runner` containers, and Caddy |
| Postgres binaries | Matching the `postgres:17` the stack uses today, with contrib (migrations use `pg_trgm`) | The `postgres` container |
| Guest kernel | Small, versioned with the app | — |

**Not in the bundle: guest root filesystems.** The agent base image carries
the harness CLIs and toolchains and is large. It is downloaded on first launch
(with progress) and versioned separately, so harness CLI updates don't need a
new DMG. Bundling it instead gives an offline install at the cost of a
multi-GB DMG.

**Single origin without Caddy.** `deploy/Caddyfile` routes `/api/*`, `/mcp`,
`/mcp/*` and `/events` to the API, answers 404 for `/internal/*`, and sends the
rest to Next. `vesper app` does the same in Go, with streaming (no buffering)
for SSE and MCP, as Caddy's `flush_interval -1` does.

**Blobs without SeaweedFS.** `blob.Store` is an S3 client
(`server/internal/blob/blob.go:26`). It gains a local-filesystem backend.
`vesper export` lists buckets, so the backend must list them too
(`AGENTS.md`, "Export and import"). Nothing presigns URLs today, so the
filesystem backend needs no URL signing.

#### Where things live

Everything goes under Electron's `userData` directory
(`~/Library/Application Support/<app name>`), next to the `config.json` and
`session.json` the desktop app already writes (`desktop/src/main.ts:776`):

```text
config.json, session.json   desktop settings (as today)
postgres/                   database cluster
blobs/                      object storage
images/                     guest kernels and root filesystems, by version
vm/                         run disks, cache generations, saved VM state
logs/                       vesper, Postgres, Next, guest consoles
```

`SECRETS_KEY` is generated on first launch and kept in the macOS Keychain
(Electron `safeStorage`), not in a file. Uninstalling is deleting the app and
this directory.

#### Signing in

No `VESPER_NO_SIGNIN`: that lets any local process act as the owner. The app
signs its own window in with `vesper sign-in-link` (a one-time, short-lived
link, `server/cmd/vesper/main.go:257`) whenever its session is missing, so
there is no password prompt and other local processes still need a session.
`PUBLIC_URL` stays a loopback address; everything binds to `127.0.0.1` only.

#### Lifecycle

- **Launch:** Electron starts `vesper app`, which starts Postgres, runs
  migrations (as `vesper migrate` does), then serves. Electron waits for
  `/api/v1/health` and loads the UI.
- **Closing the window doesn't stop runs.** Vesper stays in the menu bar while
  runs, playgrounds or dev workspaces are active. An optional login item
  starts it at login.
- **Quit** warns if runs are active, pushes unpushed work to a
  `vesper-checkpoint/...` branch as cleanup does today (`docs/guide.md:170`),
  suspends or stops the VMs, then stops Postgres.
- **Crash:** Electron restarts `vesper app`; the runner's startup recovery
  (`Cleanup`) handles VMs left behind.
- **Upgrade:** a new DMG replaces the app; the data directory stays, and
  migrations run on the next launch. Guest images update on their own.
- **Remote mode stays.** The server URL setting can still point the app at a
  remote Vesper (for example over Tailscale); then it starts nothing locally.

#### Signing the bundle

The builds stay ad-hoc signed (`CSC_IDENTITY_AUTO_DISCOVERY=false` today).
After electron-builder packs the app, a build step signs inside out: `vesper`
with the virtualization entitlement (it's the process that starts VMs), then
the Postgres binaries, then the app. A DMG built on the same Mac has no
quarantine flag and opens directly. One downloaded from elsewhere, even your
own from GitHub, needs `xattr -cr /Applications/Vesper.app` once, as
`desktop/README.md` already documents. Giving it to other people properly
means a Developer ID, the hardened runtime and notarisation: out of scope.

Packaging doesn't depend on the microVM backend: `vesper app` can run the
Docker backend until `microvm` exists, so this can be built in parallel.

## Feature mapping

| Feature | Today | MicroVM backend | Effort |
|---|---|---|---|
| Agent turns, outbox, video files | Container per turn on the run's volumes | Process tree per turn in the run's VM | Port |
| Dev workspace (`docker_dev_workspace.go`) | Long-lived container, tmux + LazyVim PTY | Long-lived VM, PTY over vsock | Port; balloon matters most here |
| Sign-ins, model listings, usage probes | Throwaway containers with the saved login | Utility VM or warm pool | Port |
| Design renderer, images, video, audio | Processes in turns | Same, in the VM | None |
| Turn services (`docker_services.go`) | Sibling containers on the turn network | Containers in the run's VM | Moderate |
| Turn Docker API (`docker_proxy.go`) | Rewriting proxy to the runner's engine | dockerd in the run's VM | Simpler |
| Playgrounds (`docker_playground.go`) | Own network; runner joins it | VM per playground; gateway over vsock | Redesign |
| Nix (`docker_nix.go`) | One daemon, shared store volume | Generational base disk + substituter | Redesign, riskiest |
| Dependency caches (`dependencies.go`) | Shared volume | Generational cache disks | Moderate |
| Host folders | Bind mount | virtiofs | Moderate |
| Image builds | Engine `/build` | BuildKit in a builder VM, or prebuilt rootfs from CI | Moderate |
| Recovery (`Cleanup`) | Containers by `RUNNER_STACK` label | VMs by state directory | Port |

## Performance expectations (unmeasured)

| | Docker (OrbStack) | MicroVM backend |
|---|---|---|
| CPU | Hardware-virtualised | Same |
| Workspace I/O | Virtual block device | Same |
| Exec into a running run | Milliseconds | Same |
| Run cold start | ~0.1–0.3 s container | ~0.3–1 s VM boot; amortised over a run |
| Idle chat resume | Container restart | VM state restore |
| Idle memory | Held by one VM | Returned when VMs exit or suspend |
| Peak memory, many runs | One page cache | A kernel and page cache per VM: possibly *higher* |
| Shared caches | Native volume | Block-speed base + overlay; misses fetched from the host |
| Network throughput | OrbStack's tuned stack | Host-kernel TCP spliced over vsock; to measure |

### Baseline first

Measure the current OrbStack setup before the spike, then the same on the
microVM backend:

- cold and warm turn start;
- `pnpm install` and `go build` with warm caches;
- a Nix tool install;
- Testcontainers starting Postgres;
- download throughput from inside a turn;
- peak and idle host memory at 1, 4 and 8 concurrent runs.

## Alternatives considered

- **A FOSS OrbStack clone.** A general Docker desktop is a multi-year product;
  Vesper uses a fraction of it, and a shared VM keeps the hard memory problem.
- **Colima / Lima, Rancher Desktop, Podman.** FOSS and fine to license, with
  the same Docker backend. They don't return memory well (a fixed-size VM),
  and isolation stays a shared kernel. The cheapest path if this ADR is
  rejected: support Colima and verify loopback delivery and uid mapping.
- **Apple Containerization / `container`.** One VM per container on
  Virtualization.framework, Apache-2.0. Its guest protocol and image handling
  are Swift and macOS-only, so Linux would be a second stack (section 3).
- **libkrun** (one library for macOS HVF and Linux KVM). One driver for both,
  but a C dependency through cgo and less control of the device model. Worth a
  day in the spike as a comparison.
- **Firecracker on Linux.** Faster boot and a smaller attack surface, but no
  virtiofs, so no host folders. A later option for servers.
- **gVisor on Linux.** Cheaper than a VM where there's no KVM; a weaker boundary.
  The Docker backend already covers that case.

## Consequences

- Vesper owns a VM runtime: a guest kernel and rootfs, guest agent, macOS
  release breakage, and VM escape bugs in code it ships.
- Isolation is a VM per run, network policy is enforced on the host, and the
  security model is the table of gates in section 7 instead of hardening
  spread through `docker.go` and `docker_proxy.go`.
- Features the proxy refuses (BuildKit, Ryuk, compose builds) work in turns.
- Memory returns to the host when work ends. Peak use with many concurrent
  runs may be higher than today.
- The Docker backend stays for hosts without hardware virtualisation.
- `RUNNER_BACKEND` gains `microvm` (`config.go:189` accepts only `docker` and
  `fake` today).
- On a Mac, Vesper becomes one DMG with no prerequisites. The desktop app
  stops being only a thin client: it starts and supervises the local stack,
  and the checkout-folder and `docker compose up` flow goes away.

## Development setup

Target: an Apple silicon Mac on macOS 15 or later; M3 or newer for the Linux
driver on the same machine. The first machine is an M5 Pro on macOS 27.1.2.

- **macOS driver, on the Mac.** The runner is a native macOS process. It needs
  ad-hoc signing with one entitlement; no Apple Developer account or
  notarisation:

  ```sh
  go build -o bin/vesper ./server/cmd/vesper
  codesign --sign - --force --entitlements vz.entitlements bin/vesper
  ```

  `vz.entitlements` sets `com.apple.security.virtualization` to true. Every
  `go build` drops the signature, so the Makefile target signs after building.
  Bridged networking (`com.apple.vm.networking`) is restricted by Apple and not
  needed.
- **Linux driver, in Lima on the same Mac.** A Lima VM with `vmType: vz` and
  `nestedVirtualization: true` exposes `/dev/kvm`; Cloud Hypervisor runs inside
  it. Build with `GOOS=linux GOARCH=arm64` on the Mac and test through
  `limactl shell`. This is for correctness only; nesting adds overhead, so
  benchmark the Linux driver on real Linux hardware.
- **Who does it.** A Claude Code session on the Mac can build, boot VMs, read
  guest consoles and iterate without a person relaying results.

## Spike plan

1. **Boot.** Signing in the Makefile, a minimal guest kernel and rootfs, boot
   under vz with a console and a vsock round trip.
2. **Guest agent and egress.** Exec, PTY and file copy over vsock; the
   vsock-only egress; a `microvm` backend that runs a real turn. Measure
   download throughput against the baseline.
3. **Memory.** Concurrent runs, idle suspend and restore, the balloon. Measure
   memory returned to macOS; this is the reason for the work, so prove it early.
4. **Linux driver.** Cloud Hypervisor in nested Lima against the same guest
   agent and image.
5. **Services, then Nix.** Services through in-guest dockerd; then the
   generational Nix store with signature-checked promotion, the hardest cache
   case.
6. **Decide** whether to continue to parity, from the measurements.

### Effort (estimate)

Most of a person's 3–6 months is writing the guest agent, two drivers, the
backend port and the packaging. With an agent writing it on the Mac, the
bottlenecks are hardware feedback, decisions and review:

| | |
|---|---|
| Spike (steps 1–4) | About 1–2 weeks |
| Parity with the Docker backend, stack out of Compose | A further 3–5 weeks |
| One-DMG packaging (section 9), in parallel | About 1–2 weeks |
| Dogfooding and soak | 2+ weeks, alongside fixes |

One bad VM bug (virtiofs speed, the balloon not reclaiming under
Virtualization.framework) can cost a week however fast the code is written.
Independent security review of the guest agent, egress and promotion is
required: they are the sandbox boundary.

## Open questions

- Can several Virtualization.framework VMs attach the same disk image
  read-only at once? The cache design depends on it.
- Does the traditional balloon reclaim enough under Virtualization.framework,
  or is suspend/restore the real memory policy for idle VMs?
- Is in-guest overlayfs over a read-only base fast enough for `/nix/store`,
  and does `nix copy` promotion keep the store database consistent?
- Turn = cgroup in the run's VM, or a container per turn inside it for parity
  with today?
- Native processes for Postgres and SeaweedFS, or a stack VM? Section 9
  assumes native Postgres and a filesystem blob backend.
- Where do arm64 Postgres binaries come from for the bundle (a project build,
  or a maintained distribution), and how are major-version upgrades of the
  bundled cluster handled?
- Download or bundle the guest root filesystem? Section 9 assumes download.
- Does any web feature assume the separate `web` container beyond what the
  Caddyfile routes? `API_INTERNAL_URL` (`web/next.config.ts`,
  `web/lib/api/client.ts`) must point at `vesper app`'s loopback port.
- Does WSL2 with nested virtualisation give the Linux driver a working
  `/dev/kvm`?
- Licences of every bundled component (Code-Hex/vz, Cloud Hypervisor, the
  guest kernel and image, BuildKit) to confirm before adopting.
