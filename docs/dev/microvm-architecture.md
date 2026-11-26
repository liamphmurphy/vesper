# Architecture & Build-Out Spec: macOS MicroVM Runner & Self-Contained Vesper.app

Status: Accepted for build-out on Apple Silicon macOS (2026-11-16). Supersedes
`docs/dev/microvm-runner.md`.

Workflow note: Developed and tested natively on bare-metal Apple Silicon macOS
(starting on an M5 Pro Mac) using Antigravity (`agy`) outside Vesper against the
build-out branch before merging to `main`. Performance numbers in this document
remain expectations to verify against the OrbStack baseline during Slices 1–3.

## Context

The runner's only isolating backend today is Docker (`RUNNER_BACKEND=docker`,
`server/internal/config/config.go:160`). On a Mac that means Docker Desktop or
OrbStack, and both create three problems for Vesper:

- **Licensing.** Docker Desktop requires a paid subscription in organisations
  over 250 employees or $10M revenue; OrbStack requires a paid licence for
  commercial use. The engine itself (Moby/`dockerd`) is Apache-2.0; the
  macOS desktop apps are the licensed wrappers.
- **Memory.** One long-lived Linux VM holds every container. Docker Desktop
  rarely returns freed guest memory to macOS. OrbStack does, and that is the
  main capability its closed-source VM tuning buys.
- **Isolation.** Every turn container, `StartServices` database, and
  Testcontainer shares one Linux VM kernel and one root-equivalent `dockerd`
  (`docs/dev/plan.md:292`). Hardening is therefore spread across the runner:
  `CapDrop ALL` and `no-new-privileges` on turns (`runner/docker.go:443`), an
  849-line proxy that rebuilds every `HostConfig` body an agent sends
  (`runner/docker_proxy.go`, ADR [test-environments.md](test-environments.md)),
  a separate `agents` network, a shared read-write `/cache` volume
  (`runner/docker.go:517`), and a gap where containers still reach the host's
  loopback, LAN, and tailnet via `host.docker.internal`
  (`docs/guide.md:406`, `server/internal/agentapi/transport.go:342`).
- **Rejected previously for platform reasons, not design reasons.** The
  test-environments ADR called Sysbox (Docker inside the turn) "the cleanest
  isolation" and rejected it only because Docker Desktop and OrbStack on macOS
  cannot run it. A hardware-virtualised microVM per run delivers a stronger
  hypervisor boundary on every Apple Silicon Mac.

The goal: **bundle the runtime Vesper's hardening needs with no Docker
prerequisite on the host**. Every run gets hardware VM isolation, host-enforced
egress, zero-promotion caches, and host-side git credentials; memory returns to
macOS when work ends or goes idle; every current feature keeps working; and on
macOS Vesper ships as **one DMG** (`Vesper.app`: drag to Applications, open it,
done — no Docker, no checkout folder, no separate server).

### Scope & non-goals

- **macOS Apple Silicon (`darwin/arm64`) only for v1.** Requires macOS 15 or
  newer (primary dev/test machine is an M5 Pro).
- **Deferred (seams kept clean, not built in v1):**
  - Linux `Cloud Hypervisor` driver (and Windows 11 WSL2 where nested `/dev/kvm`
    is exposed).
  - Opt-in **headless macOS guest VMs** (Phase 2, for native `xcodebuild`,
    SwiftPM, and `electron-builder` macOS builds; see section 2).
- **Intel Macs.** Not supported.
- **Signed, notarised distribution.** Outside scope; builds use inside-out
  ad-hoc signing (`xattr -cr /Applications/Vesper.app` when downloaded).
- **Removing the Docker backend.** `RUNNER_BACKEND=docker` stays as the fallback
  where hardware virtualisation is unavailable (cloud VMs without nested
  virtualisation, most Kubernetes pods), alongside `fake` for tests.

## Decisions

### 1. One microVM per run & cold-boot memory lifecycle

A run gets one lightweight Linux VM for its whole lifetime. Each turn is a
process tree started by a guest agent inside a dedicated cgroup v2 and killed
atomically via `cgroup.kill` when the turn ends, so a turn still cannot leave
background daemons behind for the next one (preserving the invariant of
today's container-per-turn model, `runner/docker.go:205`). Meanwhile, the
frequent helper calls to `Backend.Start` (`prepare.go`, `git_batch.go`,
`repomap.go`, `codechanges.go`, `checkpoint.go`) execute over `vsock` in ~1–3 ms
without rebooting.

Per-turn VMs were considered and rejected: booting a VM on every `Backend.Start`
call adds latency across helper steps for minimal security gain, because the
run's persistent workspace disk already carries state from turn to turn.

| Workload | VM ownership & isolation |
|---|---|
| Agent turns (incl. delegated worktree runs) | The run's Linux microVM (dedicated `cgroup` per turn) |
| Dev workspace (`docker_dev_workspace.go`) | One long-lived Linux VM per workspace; persistent disks (`workspace.ext4`, `home.ext4`, plus `nix.ext4` holding a writable `/nix` served by an in-guest nix-daemon) + balloon |
| Playground (`playgrounds.go`) | One Linux VM per playground; services and spec processes run inside it; **no `home.ext4` mounted** so playgrounds never see harness logins (`docs/dev/playgrounds.md:28`) |
| Sign-ins, model listings, usage probes | A shared short-lived utility VM (or warm pool of tiny VMs; latency-sensitive) |
| Host-authenticated git push/fetch (`push_staging.go`) | Isolated bare repository on the host (or a clean utility VM); **`git:pat` never enters a run VM** |
| Cache generation compaction & image builds | Host pull-through proxy + trusted builder/compactor VM (never untrusted run VMs) |

#### Memory lifecycle: cold-boot over `saveMachineStateTo`

`Virtualization.framework`'s `saveMachineStateTo` / `restoreMachineStateFrom`
was evaluated and **dropped for Linux VMs in v1**:

1. Today's Docker runner holds **zero RAM state** between chat turns: turn
   services and proxy containers stop when a turn exits (`test-environments.md`),
   and harness sessions resume from files on `/workspace` and `/home/node`.
2. Saving VM state writes multi-gigabyte `.vzvmsave` files per idle chat, severs
   active `vsock` connections on restore, and conflicts with
   `VZVirtioFileSystemDeviceConfiguration` (`virtiofs`) under
   `validateSaveRestoreSupport()` when host folders are attached.

Instead, v1 uses a simpler two-tier memory policy:

1. **Warm inter-turn window (e.g. 5–10 minutes after a turn):** Immediately after
   each turn exits, the guest agent runs `sync && echo 3 > /proc/sys/vm/drop_caches`
   and inflates `virtio_balloon` (`VZVirtioTraditionalMemoryBalloonDevice` with
   `CONFIG_MEMORY_BALLOON=y` and `VIRTIO_BALLOON_F_FREE_PAGE_HINT`). Without
   active reclamation, 4–8 concurrent VMs configured with `RUNNER_MEMORY_MB=8192`
   (`config.go:196`) would retain tens of gigabytes of dead Linux page cache.
2. **Idle chats (past warm window) & app quit:** Cleanly shut down the Linux VM
   while keeping `workspace.ext4` and `home.ext4` on disk, and cold-boot in
   ~200–300 ms on the next message. Host RAM drops to zero with no `.vzvmsave`
   disk bloat.
3. **Spare VM:** the runner keeps `RUNNER_VM_SPARES` (default 1, `0` turns it
   off) VMs booted ahead of new runs, on fresh disks under `spares/`, ballooned
   down to `IdleMemoryMB` (192 MiB). A new run's first `EnsureWorkspace` renames
   a spare's directory to the run's and takes its VM, then boots a replacement.
   A run with a host-folder workspace (its share is fixed at boot), or a spare
   booted with older cache EROFS drives, boots its own VM as before. Spares
   aren't runner slots; `ActiveVMCount` includes them.

`Suspend` / `Restore` remains an optional `Driver` capability for Phase 2
(specifically valuable for macOS guests, where `saveMachineStateTo` avoids a
6–12 s `launchd` boot).

### 2. Backend surface, `Backend.Isolates()`, `Driver` interface & future seams

`microvm` implements `Backend` (`runner/backend.go:43`) and all capability
interfaces the Docker backend implements today: `ServiceBackend`,
`PlaygroundBackend`, `ProxyBackend`, `DevWorkspaceBackend` (`DevPTY`),
`LoginStarter` (`LoginProcess`), `ModelLister`, `UsageProber`, `HostFolders`,
`CacheBackend`, and `NixManifestProcess` (`runner/testenv.go:148`).

#### Prerequisite: eliminate hardcoded `== "docker"` isolation checks

Currently nine sites across the server, OpenAPI schema, and web UI treat any
backend other than `"docker"` as unisolated host `fake` mode. Before `microvm`
runs real turns, replace those checks with `config.IsolatesBackend(name)` /
`Backend.Isolates() bool`:

- `server/internal/config/config.go:180-195`: accept `"microvm"` in
  `RUNNER_BACKEND` validation and default `RUNNER_MCP_URL` appropriately.
- `server/cmd/vesper/main.go:186, 201, 410, 415, 424, 459`: `RequireHarnessKey`,
  `srv.Usage.Queued`, `workflows.Catalog.RequireKey`, and `planModels()`.
- `server/internal/runner/runner.go:1618`, `chat_images.go:219`,
  `chat_suggestions.go:140`: `ContainerSandbox`.
- `server/internal/runner/push_staging.go:95`: `isolatesGit()`.
- `api/openapi.yaml:8101` (`RunnerInfo.backend` enum `[docker, microvm, fake]`),
  regenerated via `make gen` into `server/internal/api/api.gen.go` and
  `web/lib/api/schema.d.ts`.
- `web/components/domain/dispatch-dialog.tsx:244, 248`: check isolating
  backends rather than `backend === "docker"`.

#### `Driver` & `VM` interface

```go
// Driver is the hypervisor-specific layer.
type Driver interface {
    Boot(ctx context.Context, spec VMSpec) (VM, error)
}

type VMSpec struct {
    RunID     string
    Boot      BootConfig // union: LinuxBoot (v1) or MacOSBoot (Phase 2)
    Disks     []DiskAttachment
    Shares    []VirtioFSShare
    CPUs      int
    MemoryMB  int64
    VsockPort uint32
}

type LinuxBoot struct {
    KernelPath string
    Cmdline    string
    InitrdPath string // optional; direct rootfs mount avoids initramfs overhead
}

type VM interface {
    Dial(port uint32) (net.Conn, error)       // host -> guest over vsock
    Listen(port uint32) (net.Listener, error) // guest -> host over vsock
    SetMemoryTarget(bytes uint64) error       // virtio balloon
    Stop(ctx context.Context) error
}
```

- **macOS (`darwin/arm64`):** `driver_darwin.go` (`//go:build darwin`) wraps
  Apple's `Virtualization.framework` via [Code-Hex/vz](https://github.com/Code-Hex/vz)
  (MIT, Go bindings also used by Lima), keeping the entire runner in Go with
  no separate Swift daemon. Provides `VZVirtioSocketDevice`, `VZVirtioBlockDevice`,
  `VZVirtioFileSystemDevice` (`virtiofs`), and `VZVirtioTraditionalMemoryBalloonDevice`.
- **Tests everywhere:** Everything above `Driver` (guest agent, vsock protocol,
  egress, synthetic DNS, cache manager, lifecycle) stays OS-neutral and tests
  against an in-memory `Driver` on Linux CI and macOS alike.

#### Future seams kept clean (not built in v1)

1. **Linux server parity (`Cloud Hypervisor`):** Keeping the vsock protocol and
   Linux guest image independent of `vz` means a `driver_linux.go` driving
   `cloud-hypervisor` (hybrid vsock over Unix socket, `virtiofs`, balloon)
   drops in later with zero changes to `microvm` or the guest image.
2. **Headless macOS guest VMs:** built; see [macOS guest VMs (`mac`)](#macos-guest-vms-mac)
   below.

#### macOS guest VMs (`mac`)

Personas build and test the Apple-platform parts of a repository (`macos/`,
`xcodebuild`, `make mac-test`) in a macOS guest VM, which they reach from their
Linux run VM with `mac COMMAND`. The harness, git, Docker and services all stay
in the Linux VM; the macOS VM only receives files and runs commands.

- **Lazy start.** Nothing macOS boots for a turn. Each turn's egress gets the
  run's broker handler at `mac.vesper.internal` (`198.18.0.5`) and
  `VESPER_MACOS=1`; the macOS VM boots on the run's first `mac` call
  (`runner.MacOSGuests`), serves the run's later calls, and stops after
  `RUNNER_MACOS_IDLE_TTL_S` (default 600) without one. Each call that reuses a
  booted VM pings its agent first; a VM that stopped answering (the guest shut
  down or crashed, or the agent stopped listening) is stopped and replaced by a
  fresh boot, unless another call is still using it, in which case this call
  fails with "stopped answering". Booting is bounded end to end: waiting for
  the guest agent (3 min), the first root command (1 min) and stopping a VM
  (30 s; a stop still blocked in Virtualization.framework then finishes in the
  background), so one bad guest can't hang later calls. A run's macOS disk (APFS
  clone of the golden `disk.img` and `nvram.bin`, plus its own machine
  identifier: Apple requires two running VMs not to share one) outlives the VM,
  so `.build` and DerivedData stay warm until the run's workspace is removed.
- **Two slots.** Apple's kernel allows 2 macOS VMs per Mac
  (`RUNNER_MACOS_VMS`, 0–2, default 2; 0 turns `mac` off). A call that finds
  both busy evicts the least recently used idle one; when both are in use it
  waits and says so ("all 2 macOS VMs are busy…"). macOS VMs are never spares.
- **Sync, not share.** The Linux workspace is an ext4 disk macOS can't mount,
  so `mac` mirrors the git checkout it runs in: it sends a manifest of the
  tracked and non-ignored untracked files (path, size, mode, mtime), the host
  answers which differ from the last sync it recorded, and only those go over
  as a tar, extracted by the build user. Files the last sync of that checkout
  had and this one doesn't are deleted; ignored files (build output) are never
  touched on either side. Changes made in the macOS VM come back only with
  `mac --pull PATH`.
- **API** (`guestproto/mac.go`, client in `internal/macclient`, CLI
  `cmd/vesper-mac` installed as `/usr/local/bin/mac` in the rootfs):
  `POST /v1/start` (NDJSON status), `/v1/sync/plan`, `/v1/sync/upload`,
  `/v1/exec` and `/v1/pull` (guestproto stdout/stderr/exit frames). Hanging up
  an exec kills its process group in the guest. `/v1/agent-log` (`mac
  --agent-log`) returns the end of the guest agent's own log
  (`/var/log/vesper-guest-agent.log`) and the start of the guest's newest
  kernel panic report (`/Library/Logs/DiagnosticReports`,
  `/private/var/db/PanicReporter`), read through the agent's file ops so it
  works when commands don't; a boot whose first command fails carries both in
  its error, read before the VM is stopped (or, if that command
  took the agent down, as read when the VM booted, which holds what earlier
  boots of the run's disk wrote).
- **Guest agent.** `vesper-guest-agent` cross-compiles to `darwin/arm64`
  (`CGO_ENABLED=0`) and runs as the LaunchDaemon `dev.vesper.guest-agent`: no
  init, cgroups, networking, Docker or Nix; a process group is the unit of
  cleanup. It accepts vsock connections from the host (CID 2) only, so a build
  command can't reach the root-run agent. Every command runs as the image's
  user (`RUNNER_MACOS_USER`, default `admin`) except one fixed root command at
  boot that makes `/opt/vesper/workspace` and looks the user's ids up.
  It logs every request and each command's start, finish and connection
  errors to `/var/log/vesper-guest-agent.log` (read with `mac --agent-log`).
  When its vsock listener fails 20 times in a row it logs that and exits, so launchd (`KeepAlive`)
  restarts it instead of leaving a live process that refuses the host.
- **Trust.** The macOS VM has no NIC and no egress listeners: no network, no
  harness, no OAuth token, no git credential, no API. Its inputs are the run's
  own files and the commands its persona runs. SwiftPM packages that need
  fetching therefore fail there (Vesper's `macos/` package has none).
- **Golden image.** `make mac-golden` (wrapping `deploy/microvm/macos-golden.sh`)
  installs `tart` via Homebrew if missing, pulls a Tart image with
  Xcode (`ghcr.io/cirruslabs/macos-golden-gate-xcode` by default), installs the
  agent and its LaunchDaemon with `tart exec` (the image must run the Tart
  Guest Agent), shuts it down and copies `disk.img`,
  `nvram.bin` and `config.json` (Tart's layout, which `microvm.LoadMacOSImage`
  reads) into `<data dir>/vm/macos-golden` (`RUNNER_MACOS_IMAGE_DIR`). Vesper
  turns `mac` on at start when that image loads. Nothing is redistributed: the
  person pulls and modifies their own copy. Runs keep their own disk clone, so
  a new image reaches only new runs.
- **Sizing:** `RUNNER_MACOS_CPUS` (default 4) and `RUNNER_MACOS_MEMORY_MB`
  (default 8192, fixed: macOS guests have no balloon driver).

### 3. Guest agent (`vesper-guest-agent`)

A small static Go binary (`CGO_ENABLED=0 GOOS=linux GOARCH=arm64`) serves as the
Linux guest's `/sbin/init` (PID 1), with Linux-specific mounts, cgroups, and
iptables behind `//go:build linux`. Owning the agent keeps drivers portable and
avoids coupling to Apple's macOS-only Swift Containerization protocol.

At boot (~50–100 ms in Go PID 1), the agent:
1. Mounts `proc`, `sysfs`, `devtmpfs`, `devpts`, `cgroup2`, immutable `EROFS` `/`
   with an ephemeral scratch upper layer, `workspace.ext4` at `/workspace`,
   `home.ext4` at `/home/node`, shared `EROFS` cache bases + scratch overlays,
   and any `virtiofs` host folder.
2. Brings up `lo` and `dummy0` (`10.255.255.1/30`, default route), applies
   `iptables` rules, starts the non-loopback DNS stub and vsock TCP forwarder,
   and launches `dockerd` backed by its own scratch disk (`/var/lib/docker`).
3. Listens on `AF_VSOCK` (`VMADDR_CID_ANY`) for host RPCs and reaps orphaned
   child processes as PID 1. Every listener drops connections from any CID
   but the host's (2), and the kernel has no vsock loopback
   (`CONFIG_VSOCKETS_LOOPBACK=n`), so a turn can't reach the root-run agent.

Vsock RPC surface covers:
- **Process execution (`Start`):** command argv, env, relative working dir,
  atomic write of `ExecSpec.Files` owned by `uid 1000`, multiplexed stdout/stderr
  streaming, optional PTY + `TIOCSWINSZ` resize (dev workspaces and interactive
  logins), `SIGINT` / `SIGKILL`, exit code + cgroup `memory.events` `oom_kill`
  inspection (matching `runner/docker.go:759`), and `cgroup.kill` teardown.
- **File operations:** `ReadOutbox`, `RemoveOutbox`, `ReadVideoFiles`,
  `OpenWorkspaceFile`, plus post-turn OAuth rotation readback (`keepRefreshedLogins`
  parity, `docker.go:772`) and `~/.nix-profile/manifest.json` readback
  (`readNixManifest`, `docker.go:795`).
- **Maintenance:** service/container status & log tails, `drop_caches` trigger.

### 4. In-guest container engine (`dockerd`) & turn-to-turn integrity

Services (any OCI image with a healthcheck) and Testcontainers expect OCI
containers and the Docker Engine API. Inside each run VM (and playground VM), the
guest boots `dockerd` + `containerd` + `runc` + `BuildKit` (Apache-2.0) and sets
`DOCKER_HOST` to the guest's own socket:

- **The VM is the host boundary.** Escaping requires a hypervisor bug, not a
  container or proxy bug. The host no longer needs the 849-line `HostConfig`
  rewriter in `runner/docker_proxy.go:440-495` to protect the Mac.
- **Same Docker API as the Docker backend:** turns get the guard's allowlist
  (below), so classic builds (`DOCKER_BUILDKIT=0`) and no Ryuk
  (`TESTCONTAINERS_RYUK_DISABLED`), as before. Unlocking BuildKit means
  inspecting its session and gRPC streams first.
- **Codex's own sandbox works again:** Docker on the host blocked the user
  namespaces Codex needs (`docs/guide.md`, "read-only Codex turns rely on the
  policy hook"); inside a microVM, turns can be granted unprivileged user
  namespaces.

#### Closing the turn-to-turn `docker.sock` risk inside a run VM

Giving `uid 1000` raw access to `/var/run/docker.sock` makes `uid 1000`
equivalent to `root` inside that VM (`docker run -v /:/host ...`). That cannot
escape to macOS, **but** Vesper runs trusted post-turn scripts in the same run
(`git` bundling in `push_staging.go`, `git_batch.go`, `checkpoint.go`, plus
reading back OAuth credentials in `docker.go:772`) and runs subsequent turns in
the same VM. Three controls preserve turn-to-turn integrity from day 1:

1. **Locked-down guest kernel:** Built with `CONFIG_MODULES=n`, `CONFIG_KEXEC=n`,
   `CONFIG_HIBERNATION=n`, and `/dev/mem` / `/dev/kmem` disabled — even guest
   `root` cannot patch the running kernel.
2. **Immutable rootfs & a per-turn Docker guard:** `/` is mounted from a
   read-only `EROFS` block device (`overlayfs` upper state on a
   per-turn/resettable layer), and `/var/lib/docker` lives on its own scratch
   block device. Turns never see `dockerd`'s socket: each turn gets its own
   guard socket (`/run/vesper-docker/<key>.sock`,
   `cmd/vesper-guest-agent/docker_guard.go`) that ports the Docker backend's
   turn proxy: an allowlist of Engine endpoints, container creates rebuilt
   without privileges, host namespaces, devices or SecurityOpt beyond
   `no-new-privileges`, binds only from `/workspace` or the turn's own files
   under `/tmp` (resolved through symlinks), and calls scoped to objects
   carrying the turn's label. Closing the turn removes everything with that
   label: those containers run outside the turn's cgroup. `/workspace` and
   `/tmp` are mounted `nosuid,nodev`, so root in a container can't leave a
   setuid binary for the turn.
3. **Just-in-time OAuth injection & wipe:** `~/.claude/.credentials.json`,
   `~/.codex/auth.json`, and Antigravity auth files are injected immediately
   before the harness launches, read back for token refresh immediately after
   it exits, and **unlinked from `$HOME` before turn cleanup returns**.
   Harness session state stays in the run's `home.ext4`, so the next turn can
   resume it: Claude Code's `~/.claude/projects` and Codex's `~/.codex/sessions`
   lie outside the swept files. For Antigravity every entry under `~/.gemini`
   is unlinked except its conversation state
   (`antigravity-cli/{conversations,brain,implicit,annotations,conversation_summaries.db}`,
   `agySweepPaths`); if `~/.gemini` can't be listed, all of it goes.

### 5. Networking: NIC-less guest, host `Egress`, synthetic DNS & `dockerd` routing

The guest has **no virtual NIC** (`VZVirtioNetworkDeviceConfiguration` is
omitted). Every outbound TCP stream leaves the VM over `vsock` to host
`Egress.Dial`:

```go
// Egress runs on the host; every outbound guest connection arrives here.
type Egress interface {
    Dial(ctx context.Context, runID string, network, addr string) (net.Conn, error)
}
```

#### Solving the `dockerd`, DNS, and CDN traps

A naive `iptables -t nat -A OUTPUT -j REDIRECT` + `SO_ORIGINAL_DST` breaks in
three concrete ways with in-guest `dockerd` and HTTPS hosts. All five rules below
are part of the v1 design:

1. **`dummy0` + `OUTPUT` & `PREROUTING` exclusions:** `dummy0` holds
   `10.255.255.1/30` and the default route. `iptables -t nat` **excludes**
   `127.0.0.0/8`, `10.255.255.0/30`, and `dockerd` bridge CIDRs (`172.16.0.0/12`)
   so turn processes still talk directly to Testcontainers and `StartServices`
   containers inside the same VM. All other outbound TCP in `OUTPUT` (turns)
   and `PREROUTING` on `docker0`/`br-*` (containers, with `route_localnet=1`
   ordered ahead of `DOCKER` chains) redirects to the guest agent's TCP
   forwarder (`SO_ORIGINAL_DST`), which streams over `vsock` to host `Egress`.
2. **Non-loopback DNS stub (`10.255.255.1:53`):** `dockerd` strips
   `127.0.0.x` entries from container `/etc/resolv.conf` and falls back to
   `8.8.8.8:53` over UDP — which blackholes when UDP is not forwarded. Therefore
   the guest agent binds its DNS resolver on **`10.255.255.1:53`**, sets both
   `/etc/resolv.conf` and `/etc/docker/daemon.json` (`"dns": ["10.255.255.1"]`),
   and redirects any stray `:53` UDP/TCP packets in `OUTPUT` + `PREROUTING` to
   `10.255.255.1:53`. `AAAA` queries return `NODATA` in v1 so all
   `SO_ORIGINAL_DST` lookups are IPv4. Guest IPv6 stays on so `::1` keeps
   working for tools that bind `localhost`, but it fails closed: interfaces
   carry only link-local addresses and there is no IPv6 route out, so a v6
   connect gets `ENETUNREACH`; v4-mapped addresses (`::ffff:a.b.c.d`) are IPv4
   on the wire and take the same redirect to host `Egress`.
3. **Synthetic DNS (`198.18.0.0/15`) + TLS SNI verification:** If the guest
   received real CDN IPs, `SO_ORIGINAL_DST` could not tell an allowed domain
   from another domain behind the same Cloudflare/Fastly/CloudFront IP. Instead,
   the DNS resolver hands out **per-VM synthetic IPs from `198.18.0.0/15`**
   (RFC 2544) mapped 1:1 to queried FQDNs. Host `Egress` maps the synthetic IP
   back to the exact hostname (verifying TLS ClientHello SNI matches on `:443`),
   enforces domain policy, resolves via the host resolver, and checks every
   resolved IP against the deny list before connecting. Raw IP dials outside
   `198.18.0.0/15` are also checked directly against the deny list (or blocked
   when strict domain allowlisting is enabled).
4. **Host `Egress` deny list & in-process `/mcp`:** Host `Egress` unconditionally
   rejects:
   - Loopback (`127.0.0.0/8`, `::1`)
   - Private RFC1918 LAN (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`)
   - Link-local & cloud metadata (`169.254.0.0/16`, `fe80::/10`)
   - **Tailscale CGNAT (`100.64.0.0/10`)**
   - IPv6 ULA (`fc00::/7`), multicast, and broadcast ranges.

   `RUNNER_MCP_URL` (`http://api.vesper.internal/mcp`) resolves to a reserved
   synthetic IP that host `Egress` pipes directly to Vesper's in-process
   `MCPHandler` over `vsock` without dialing host loopback — allowing
   `DisableLocalhostProtection: true` (`agentapi/transport.go:342`) to be
   retired once Docker host-gateway support is no longer required.
5. **Inbound vsock:** Playground gateway traffic and dev-workspace PTYs run in
   reverse (host → guest over `vsock`). The runner serves playgrounds on
   `127.0.0.1:8090–8094` (`playgrounds.go:78`), no longer joins a playground's
   Docker network (`runner/docker_playground.go:134`, `selfID`), and `$PLAYGROUND_URL`
   inside a chat turn routes through `Egress` into the host's playground gateway
   so probe injection, routes, and `PLAYGROUND_TOKEN` behave identically to
   [playgrounds.md](playgrounds.md).

- **Performance expectation (unmeasured):** Both kernels run native TCP with
  socket splicing on the host and no userspace TCP/IP stack (unlike
  `gvisor-tap-vsock` used by Lima).
- **Gaps:** HTTP/3 falls back cleanly to TCP/TLS; arbitrary UDP and ICMP (`ping`)
  do not work.
- **Rejected alternatives:** `vmnet` NAT is fast but requires firewalling inside
  the guest (where guest root can change it) or privileged host `pf` rules;
  userspace networking (`gvisor-tap-vsock`) enforces on the host at a steep
  throughput cost.

### 6. Storage: APFS clones, `EROFS` images & zero-promotion caches

#### Per-run & root disks

- **Workspace and home:** Each run gets sparse `workspace.ext4` and `home.ext4`
  images cloned from clean templates via `clonefile(2)` on APFS (<1 ms, zero
  extra blocks until written).
- **Immutable shared images as `EROFS` (`mkfs.erofs -zlz4hc`):** Guest rootfs
  (`agent-base.erofs`) and shared cache base generations use mainline Linux
  `EROFS` (`CONFIG_EROFS_FS=y`) rather than `ext4`. `Virtualization.framework`
  safely shares one `VZDiskImageStorageDeviceAttachment(url, readOnly: true)`
  file across many concurrent VMs when the filesystem has no journal replay to
  attempt; `EROFS` is read-only by format, random-access LZ4-compressed (~50%
  smaller first-launch download), and boots cleanly across 8+ VMs at once.

#### Inverted cache architecture (no upward promotion from run VMs)

The original proposal considered having run VMs write cache misses to a
per-VM `ext4` overlay disk and promoting them upward into Base Generation $N+1$
(via `nix copy` or overlay compaction) with signature verification. That upward
channel was **rejected** as both fragile and risky:

- `deploy/agent-base/Dockerfile:53` sets `auto-optimise-store = true`, which
  creates hardlinks into `/nix/store/.links/`. Across `overlayfs` lower/upper
  layers, hardlinks cause full file copy-ups or `EXDEV` failures, while
  `/nix/var/nix/db/db.sqlite` immediately copies up and diverges per VM.
- Trusting `db.sqlite` signatures in a guest overlay is unsafe unless the host
  re-serializes every directory tree to NAR and recomputes hashes; any miss in
  verifier logic turns into a cross-project supply-chain attack.

**v1 uses strictly downward caches:**

```go
type CacheStore interface {
    Base(kind CacheKind) (DiskRef, Generation)                 // read-only EROFS, shared across VMs
    NewScratchOverlay(runID string, kind CacheKind) DiskRef    // writable ext4, deleted when run ends
    // No upward Promote(overlays): misses populate the host's pull-through cache,
    // and a trusted host compactor emits Generation N+1 from host-verified data only.
}
```

1. Every run VM mounts Generation $N$ `EROFS` base disk(s) read-only beneath a
   disposable per-VM `ext4` upper layer via `overlayfs`. Reads and writes run
   at block-device speed, and **when the run ends its overlay is deleted**.
2. Cache misses inside the VM hit **host-side pull-through proxies** over
   `vsock` (`cache.vesper.internal`):
   - Nix HTTP binary cache substituter (proxying `https://cache.nixos.org` etc.
     and verifying upstream ed25519 signatures on the host).
   - `GOPROXY` (verifying against `sum.golang.org` / module zip hashes).
   - npm registry tarball cache (verifying integrity SRI digests).
   - OCI pull-through registry mirror (so in-guest `dockerd` pulls `postgres`
     once on the host instead of once per run VM).
3. Periodically when idle, a **host compactor** builds Generation $N+1$
   `EROFS` strictly from the host's own verified pull-through store, swaps the
   pointer for newly booted VMs, and deletes Generation $N$ once its last VM
   exits.
4. **Unverifiable build caches (`GOCACHE`):** Never shared across projects; each
   project gets its own per-project cache disk (or per-run only).

#### Host folders (`RUNNER_HOST_WORKSPACES_DIR`)

Opt-in host checkouts (`docker-compose.workspaces.yml`) use
`VZVirtioFileSystemDeviceConfiguration` (`virtiofs`) so the person's local
editor sees real files immediately. Only opted-in checkouts pay `virtiofs`
overhead; `uid 1000` ↔ macOS host user ownership mapping (`docs/guide.md:180`)
must be verified under `Code-Hex/vz`.

Because a run writing to a host folder can plant host-executed files
(`.git/hooks`, `.vscode/tasks.json`, `.envrc`), Vesper must enforce safe hook
protections (warning when opening a host folder in the UI, setting
`core.hooksPath=/dev/null` on host-opened operations, and optionally keeping
`.git` metadata inside the VM while syncing the working tree later).

### 7. Trust domains & security gates

A VM is only as isolated as what crosses its boundary. Every workload belongs to
a trust domain (user, project, run), and every crossing passes an explicit gate:

| Crossing | Gate |
|---|---|
| **Network** | NIC-less VM → guest `iptables` + `10.255.255.1:53` DNS → `198.18.0.0/15` synthetic IP + TLS SNI check → host `Egress` blocking loopback, RFC1918 LAN, IMDS (`169.254/16`), Tailscale (`100.64/10`), ULA, multicast; `/mcp` routed in-process |
| **Caches** | Strictly downward `EROFS` generations built only from host pull-through verified stores; disposable per-VM overlays deleted on exit; `GOCACHE` scoped per project |
| **Git credentials (`git:pat`, `git:ssh`)** | **Never enter the run VM.** Fetches of `https://github.com/` and `git@github.com:` remotes go through the host's read-only proxy with the PAT (an SSH key alone reaches public repositories only). `BundleScript` (`runner/push_staging.go:45`) runs unauthenticated inside the VM; `.lazyagents/push/<id>.bundle` streams out over `vsock`; `PushBundleScript` (`push_staging.go:65`) runs with `$GH_TOKEN` in a clean bare repository on the host (or utility VM) |
| **Provider logins / API keys** | v1: injected into `$HOME` right before turn start, rotated tokens read back at exit, and files **unlinked immediately** before turn cleanup finishes. Phase 2: per-run CA + TLS termination in host `Egress` swaps dummy placeholders in the VM for real credentials kept in Keychain/host memory |
| **Host files (`HostFolders`)** | Opt-in per workspace, `virtiofs` scoped to that checkout only, hook protections + UI warning |

### 8. Leaving Compose & 9. Packaging: one DMG (`Vesper.app`)

**Today**, Postgres, SeaweedFS, the API, web, and Caddy run as Compose services,
and the runner container holds the host's Docker socket (`docker-compose.yml:108`,
`docker-compose.dev.yml:79`). The desktop app (`desktop/src/main.ts:49, 663`) is
a thin client pointed at `http://localhost:8080` that asks for a Vesper
checkout containing `docker-compose.yml` and runs `docker compose up -d`
(`desktop/src/docker.ts:105`). `make mac-dmg` builds an unsigned arm64 DMG
via `make mac-dmg` (`macos/Makefile`).

**Target:** `vesper` must run natively on macOS to hold
`com.apple.security.virtualization`, and `make mac-dmg` builds a
**self-contained `Vesper.app`** carrying the whole local stack. Install is drag
to Applications; first launch downloads `agent-base.erofs` (with progress) and
opens Vesper, already signed in.

#### What `Vesper.app` contains

| Component in bundle | What it is | Replaces |
|---|---|---|
| **Mac shell** | Window, native tabs, notifications, menu bar tray (`macos/`; was Electron, see native-mac-app.md) | Thin client only |
| **Next standalone server** | `web` built with `output: "standalone"` + `.next/static` + `public`, run via `ELECTRON_RUN_AS_NODE=1` (or utility process), preserving arm64 `@resvg/resvg-js` and `./public/fonts/designs/*.ttf` (`web/next.config.ts:8-10`); `API_INTERNAL_URL` pointed at `vesper app`'s loopback port | The `web` container |
| **`vesper app` (`darwin/arm64`)** | Combined mode running `serve`, `runner`, `microvm` (`vz`) driver, Postgres supervisor, and single-origin HTTP mux in one process | `api`, `runner`, `Caddyfile` |
| **Postgres 17 binaries (`darwin/arm64`)** | Relocatable `initdb` + `postgres` + `contrib` (`pg_trgm` is the sole extension in `server/migrations/00040_baseline.sql:19`), listening **only on a Unix domain socket** (`-k <userData>/postgres/run -h ""`) to avoid `:5432` conflicts and TCP SSRF | The `postgres` container |
| **Linux `arm64` guest kernel** | Minimal custom `Image` (`CONFIG_MODULES=n`, `EROFS`, `overlayfs`, `virtio_*`, `cgroup2`, `iptables`, `userns`), versioned with the app | — |

- **Not in the DMG: `agent-base.erofs`.** Kept out of the DMG so harness CLI
  updates (`claude`, `codex`, `agy`) ship without rebuilding the app bundle;
  downloaded to `images/` on first launch with progress and checksum
  verification.
- **Single origin without Caddy:** `deploy/Caddyfile` routes `/api/*`, `/mcp`,
  `/mcp/*`, and `/events` to Go, returns `404` for external `/internal/*`, and
  proxies the rest to the web container. `vesper app` serves `/api/*`, `/mcp*`,
  `/events` **in-process** (zero extra loopback proxy hop or SSE/MCP buffering),
  rejects external `/internal/*` with `404`, serves the UI's static build itself
  (a real file, else `index.html`, so client routes load; `server/cmd/vesper/static.go`),
  and points `DESIGN_WORKER_URL` at the design worker, a node process it starts
  on `127.0.0.1:<port>/internal/designs` (`web/design-worker`).
- **Blobs without SeaweedFS:** `blob.Store` (`server/internal/blob/blob.go:26`)
  gains a local-directory backend (`BLOB_DIR=<userData>/blobs`). I verified
  `server/` uses **zero** presigned URLs, so storing `<bucket>/<key>` with
  atomic temp-file rename + content-type sidecars and implementing `ListBuckets`
  over top-level directories satisfies `vesper export` / `vesper import`
  (`TestEveryTableIsExportedOrExcluded` in `server/internal/transfer`) with no
  S3 server running.

#### Where data lives (`~/Library/Application Support/Vesper/`)

Next to `config.json` and `session.json` (`desktop/src/main.ts:776`):

```text
config.json, session.json   desktop settings & tab state (as today)
postgres/                   Unix-socket Postgres 17 data cluster + socket dir
blobs/                      local-filesystem object buckets
images/                     guest kernels and agent-base.erofs by version
vm/                         per-run disks, EROFS cache generations, pull-through cache
logs/                       vesper, Postgres, Next, guest serial consoles
```

- `SECRETS_KEY` is generated on first launch and stored in the macOS Keychain via
  Electron `safeStorage`, never in a plaintext file.
- Uninstalling is deleting `Vesper.app` and this directory.

#### Signing in & local security

- **Never `VESPER_NO_SIGNIN=1`:** that lets any local process act as the owner.
  Instead, Electron invokes `vesper sign-in-link -code` (`server/cmd/vesper/main.go:290`)
  when its `persist:vesper` session lacks a cookie and redeems it automatically.
- All local HTTP listeners (`vesper app`, Next internal server, playground
  gateway `playgrounds.go:78`) bind strictly to `127.0.0.1`, and `PUBLIC_URL`
  stays a loopback address.

#### Desktop lifecycle & signing

- **Launch:** Electron checks/generates Keychain `SECRETS_KEY`, spawns Next
  standalone and `vesper app` (which initializes/starts Unix-socket Postgres,
  runs migrations, cleans stale VM state, ensures `agent-base.erofs`), polls
  `/api/v1/health`, redeems a sign-in link if needed, and loads the UI.
- **Background tray:** Closing all windows leaves Vesper in the macOS menu bar
  while runs, playgrounds, or dev workspaces are active (optional login item).
- **Playground screenshots (`Send to chat`):** Register
  `session.setDisplayMediaRequestHandler` via `desktopCapturer` in
  `desktop/src/main.ts` so `getDisplayMedia()` (`docs/dev/playgrounds.md:100`)
  captures playground tabs (`desktop/src/routing.ts:48`) inside Electron.
- **Quit:** Warns if runs are active, checkpoints unpushed work to
  `vesper-checkpoint/...` (`docs/guide.md:170`), shuts down VMs, stops Postgres,
  and exits cleanly.
- **Crash recovery:** Electron restarts `vesper app`; runner startup `Cleanup`
  reaps orphaned VM state directories.
- **Upgrades:** Dragging a new DMG over `Vesper.app` keeps `userData` intact and
  applies SQL migrations on next boot. Bundled Postgres stays on 17.x across
  minor updates; future Postgres major bumps include `pg_upgrade` or an
  automatic `vesper export` / re-init / `vesper import` migration step.
- **Remote mode preserved:** Pointing Server URL at a remote host (such as a
  homelab NixOS box over Tailscale) skips starting any local stack.
- **Inside-out ad-hoc signing (`CSC_IDENTITY_AUTO_DISCOVERY=false`):** After
  `electron-builder` packs the app:
  1. Sign `vesper` with `deploy/microvm/vz.entitlements`
     (`com.apple.security.virtualization` = true, **without** `--options runtime`
     when ad-hoc signed).
  2. Ad-hoc sign bundled Postgres Mach-O binaries/dylibs.
  3. Ad-hoc sign the outer `Vesper.app` bundle.
  Local builds launch directly; DMGs downloaded from elsewhere require
  `xattr -cr /Applications/Vesper.app` once (`macos/README.md`).

## Feature mapping

| Feature | Docker backend today | MicroVM backend (`darwin/arm64`) |
|---|---|---|
| Agent turns, outbox, video files | Container per turn on run volumes | Process tree in dedicated cgroup v2 in run VM; `cgroup.kill` + `drop_caches` on exit |
| Dev workspace (`docker_dev_workspace.go`) | Long-lived container, tmux + LazyVim PTY | Long-lived VM, PTY over `vsock`; persistent `nix.ext4` + in-guest nix-daemon; balloon reclaims idle memory |
| Sign-ins, model listings, usage probes | Throwaway containers with saved login | Shared short-lived utility VM or warm pool |
| Design renderer, images, video, audio | Processes inside turn containers | Same, inside run VM; streamed out over `vsock` |
| Turn services (`docker_services.go`) | Sibling containers on turn network | Containers via in-guest `dockerd` + loopback-excluded bridge |
| Turn Docker API (`docker_proxy.go`) | 849-line rewriting proxy on host engine | Real `dockerd` in run VM behind a per-turn guard with the same rules |
| Playgrounds (`docker_playground.go`) | Own network; runner joins via `selfID` | Dedicated VM (no `home.ext4`); gateway forwards HTTP over `vsock` |
| Nix (`docker_nix.go`) | Shared RW store volume + `nix-daemon` | Read-only `EROFS` base + disposable overlay + host Nix substituter proxy |
| Dependency caches (`dependencies.go`) | Shared RW `/cache` volume | Read-only `EROFS` bases + host `GOPROXY`/npm/OCI pull-through + per-project `GOCACHE` |
| Host folders (`HostFolders`) | Docker bind mount | `virtiofs` share (`VZVirtioFileSystemDeviceConfiguration`) + hook safeguards |
| Image builds / updates | Engine `/build` | CI-built `agent-base.erofs` (downloaded on first launch) or builder VM |
| Recovery (`Cleanup`) | Containers/volumes by `RUNNER_STACK` | State directory scan + stale VM teardown |

## Performance expectations & baseline

| Metric | Docker (OrbStack) | MicroVM backend (expected, unmeasured) |
|---|---|---|
| CPU | Hardware-virtualised | Same |
| Workspace I/O | Virtual block device | Same (`ext4` on APFS clone) |
| Exec into running run | Milliseconds | ~1–3 ms (`vsock` RPC) |
| Run cold start | ~0.1–0.3 s container | ~0.2–0.4 s direct Linux kernel boot; amortised across run |
| Idle chat resume | Container restart | ~0.2–0.4 s cold boot (empty RAM until needed) |
| Idle memory | Held by shared VM | 0 MB after idle shutdown; reclaimed via balloon between rapid turns |
| Peak memory, N concurrent runs | One Linux kernel/page cache | N kernels/page caches: **likely higher unless ballooned aggressively** |
| Shared caches | Native RW volume | Block-speed `EROFS` + `overlayfs`; misses over `vsock` from host mirror |
| Network throughput | OrbStack's tuned stack | Host-kernel TCP spliced over `vsock`; **must be measured** |

### Baseline first (before/during Slices 1–3)

Measure current OrbStack on the target Mac first, then compare `microvm` on the
exact same suite:
1. Cold turn start and warm second-turn start.
2. `pnpm install` and `go build` with warm caches.
3. A `nix profile install` package run.
4. Testcontainers starting `postgres:17-alpine`.
5. Large download throughput from inside a turn over `vsock` egress.
6. Peak and idle macOS RSS (`footprint` / Activity Monitor) at **1, 4, and 8
   concurrent runs**.

## Alternatives considered

- **Phase A intermediate (`vesper app` + bundled Postgres/blobs still calling
  OrbStack):** Keeps Compose out of the stack quickly, but keeps the OrbStack
  licence dependency and container-level isolation limits; skipped in favour of
  building `microvm` directly on this branch.
- **A FOSS OrbStack clone / Colima / Lima / Podman / Rancher Desktop:** Solves
  licensing while keeping a shared Linux kernel VM and weak host memory return.
- **Apple `Containerization` / `container`:** Apache-2.0, one VM per container on
  `Virtualization.framework`, but Swift and macOS-only guest protocol blocks
  sharing one backend/guest design with Linux servers later.
- **`libkrun`:** Single library across macOS HVF and Linux KVM, but adds a C/cgo
  dependency and hides low-level device control. Still worth a 1-day check if
  `Code-Hex/vz` hits an unexpected block-device or balloon issue.
- **`Cloud Hypervisor` / `Firecracker` / `gVisor` on Linux:** Deferred with the
  Linux driver; `Firecracker` still lacks `virtiofs` for `HostFolders`.

## Consequences & licensing

- **Owning a runtime:** Vesper takes ownership of the guest kernel config,
  `agent-base.erofs` build pipeline, `vesper-guest-agent`, and `vz` macOS release
  compatibility, plus hypervisor/egress security review before default rollout.
- **Clear security boundary:** Isolation is hardware VM-per-run, network policy
  is host-side with synthetic DNS, caches cannot flow upward between projects,
  and `git:pat` never enters run VMs.
- **Turn ergonomics improve:** BuildKit, Ryuk, compose builds, and Codex's own
  sandbox work inside runs.
- **`RUNNER_BACKEND` gains `microvm`:** Docker and fake remain untouched for
  hosts without virtualisation and CI/tests.
- **Licensing to keep clean in CI/DMG build:**
  - `Code-Hex/vz`: MIT.
  - `dockerd` / `containerd` / `runc` / `BuildKit`: Apache-2.0.
  - PostgreSQL: PostgreSQL License.
  - Linux kernel (`GPL-2.0-only`) & Debian/GNU packages in `agent-base.erofs`
    (GPL/LGPL): keep kernel `.config`/build scripts in this repo and publish
    reproducible image build manifests + source archive pointers alongside
    releases.

## Bare-metal macOS (`agy`) build-out plan

Build and verify sequentially on Apple Silicon using bare-metal `agy` against
this branch (build + sign helper on macOS:
`go build -o bin/vesper ./server/cmd/vesper && codesign --sign - --force --entitlements deploy/microvm/vz.entitlements bin/vesper`).

- **Slice 0 — Backend isolation seam & local `blob.Store`:**
  Implement `Backend.Isolates()` / `config.IsolatesBackend` across all 9
  hardcoded `"docker"` checks, add `microvm` to `config.go` + `api/openapi.yaml`
  (`make gen`), and add `BLOB_DIR` local-directory support to `blob.Store` with
  `transfer` export/import round-trip tests.
- **Slice 1 — Kernel, `EROFS` rootfs, PID 1 guest agent & `vz` boot:**
  Record the OrbStack baseline numbers. Build minimal `linux/arm64` kernel
  (`CONFIG_EROFS_FS=y`, `CONFIG_OVERLAY_FS=y`, `CONFIG_VIRTIO_BALLOON=y` with
  free-page reporting, `CONFIG_VIRTIO_VSOCKETS=y`, `CONFIG_CGROUPS=y`, netfilter,
  userns, `CONFIG_MODULES=n`) and convert `deploy/agent-base` to `EROFS`. Sign
  and boot via `Code-Hex/vz`, proving serial console + `vsock` exec round-trip.
- **Slice 2 — Full `Backend` turns & NIC-less synthetic-DNS `Egress`:**
  Wire `Start` (env, files, TTY resize, stdout/stderr, `SIGINT`/`SIGKILL`, cgroup
  OOM + teardown), outbox/video/workspace streaming, OAuth/Nix-manifest readback
  + immediate `$HOME` credential unlink, `dummy0` + `10.255.255.1:53` DNS +
  `198.18.0.0/15` synthetic-IP `Egress` blocking loopback/LAN/IMDS/Tailscale +
  in-process `/mcp`. Run a real Vesper turn and measure throughput against baseline.
- **Slice 3 — Memory reclaim & concurrency:**
  Run 1, 4, and 8 concurrent VMs; implement post-turn `drop_caches` +
  `virtio_balloon` free-page reclaim and warm-TTL shutdown + cold-boot resume;
  verify macOS RSS returns cleanly in Activity Monitor / `footprint`.
- **Slice 4 — In-guest `dockerd`, downward `EROFS` caches, `virtiofs` & host git push:**
  Enable `dockerd` inside the VM (`StartServices` + `TurnDocker` + rootfs
  integrity guard + loopback/bridge iptables exclusions + non-loopback container
  DNS), stand up host pull-through mirrors (Nix substituter, `GOPROXY`, npm,
  OCI) + background `EROFS` Generation $N+1$ compactor + per-project `GOCACHE`,
  wire `virtiofs` `HostFolders`, and move `PushBundleScript` execution onto the
  host over `vsock`.
- **Slice 5 — Playgrounds, Dev Workspaces & Utility VM:**
  Port `PlaygroundBackend` (separate VM without `home.ext4`, reverse `vsock`
  gateway, `127.0.0.1` ports, `$PLAYGROUND_URL` via `Egress`), `DevWorkspaceBackend`
  (long-lived VM + `vsock` tmux PTY), and utility VM (`LoginStarter`,
  `ModelLister`, `UsageProber`).
- **Slice 6 — `vesper app` & self-contained `Vesper.dmg`:**
  Build `vesper app` (single-origin mux + Unix-socket Postgres 17 supervisor),
  wire Electron stack supervision, Keychain `SECRETS_KEY`, automatic
  `sign-in-link`, menu bar tray lifecycle, `session.setDisplayMediaRequestHandler`,
  first-launch `agent-base.erofs` downloader, and inside-out DMG signing via
  `make mac-dmg`.

## Remaining open questions

- Does `VZVirtioTraditionalMemoryBalloonDevice` + `VIRTIO_BALLOON_F_FREE_PAGE_HINT`
  reclaim guest page cache quickly enough on current macOS kernels, or should
  warm inter-turn TTLs stay aggressive (e.g. 60–120 s) so cold shutdown does the
  heavy lifting? (Measure in Slice 3.)
- For `HostFolders` over `virtiofs`, what is the cleanest uid mapping and `.git`
  isolation UX so host editors stay fast without exposing `.git/hooks`?
- Which `darwin/arm64` Postgres 17 binary distribution (or reproducible build)
  is cleanest to vendor in `Vesper.app`, and should major upgrades run bundled
  `pg_upgrade` or `vesper export` → re-init → `vesper import`?
- Exact timing/heuristics for the background host `EROFS` cache compactor (on
  idle after misses vs threshold bytes).
