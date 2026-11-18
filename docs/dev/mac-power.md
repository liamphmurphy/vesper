# Mac app: sleep, wake and power (LAZYAGENTS-245)

What Vesper.app does when the Mac sleeps, wakes, runs on battery or quits, and
why. Code: `macos/Sources/VesperCore/Model/Power.swift` (decisions, unit
tested) and `macos/Sources/Vesper/Power/PowerController.swift`.

## What Virtualization.framework does across sleep

Status: **from the framework's documented behaviour and our architecture, not
yet measured on a Mac.** The measurements below are a checklist for the first
run on real hardware; update this section with the numbers.

- A `VZVirtualMachine` lives in the `vesper app` process. When macOS sleeps,
  every process stops, the VM's vCPUs included; on wake they continue. The VM
  isn't saved or torn down. There's nothing for the shell to "checkpoint".
- The guest's clock jumps forward by the sleep duration on wake (kvm-clock
  style catch-up on the virtio clock). Timeouts measured inside the guest can
  fire immediately on wake.
- TCP connections from the harness inside the VM to a model provider usually
  don't survive a long sleep: the provider's side times out, and the next read
  in the guest gets a reset. The harness turn then fails (the run goes to
  `failed` or, for a provider limit, `waiting_for_quota`).
- `saveMachineStateTo` / `restoreMachineStateFrom` were evaluated and dropped
  for Linux guests in v1 (`docs/dev/microvm-architecture.md`, "Memory
  lifecycle"): multi-GB save files, severed vsock connections on restore, and
  incompatibility with virtiofs host folders. So "checkpoint the VM on sleep"
  isn't an option in v1.

To measure on a Mac (record results here):

1. Start a ticket run that streams for several minutes. Sleep the Mac
   (` → Sleep`) for 1 minute, wake it. Does the turn continue or fail? What
   does the run log show?
2. Repeat with 10 minutes and with 1 hour.
3. Repeat with "When the Mac sleeps: Pause and resume".
4. Check `logs/vesper-app.log` for vz errors on wake.

## Decision

- **Default: leave runs alone** (`power.onSleep = "keep"`). Short sleeps often
  survive; a failed turn can be retried from the run page, and nothing is lost:
  the workspace disk persists.
- **Opt-in: pause and resume** (`"pause"`). On `NSWorkspace.willSleepNotification`,
  Vesper pauses working ticket/planning runs through the existing
  `POST /runs/{id}/pause` (the server ends the open turn, exit 130, and keeps
  the session). On `didWakeNotification` it resumes only the runs it paused, through
  `POST /runs/{id}/resume`, which starts a new turn with "You were paused;
  continue." in the same harness session. Chat runs can't pause (the API only
  cancels them) and are left alone. A run the person paused by hand stays
  paused. Caveat: macOS gives apps only a moment on sleep; the pause
  requests go to the local server immediately, but if the lid closes mid
  request the pause may land after wake, which is harmless (the resume
  follows).
- **Keep the Mac awake while runs work** (default on): an
  `IOPMAssertion` (`ProcessInfo.beginActivity`, idle system sleep disabled) is held only while some run is
  `starting`, `running`, or in the server's post-run checks. A run waiting on
  the person, on quota, or paused doesn't hold it. It prevents idle sleep;
  closing the lid still sleeps.
- **Battery**: on switching to battery with runs working, one notification
  (per battery session) says how many. There's no low-battery threshold; macOS's own
  low-battery warning applies.
- **Quit**: asks first when runs are working (existing behaviour, now a
  setting, default on).
- **Wake**: Vesper refreshes runs and stack health. If the stack died while
  asleep, auto-restart (bounded: 3 times in 10 minutes) brings it back.

## Not tested without a Mac

Sleep/wake, the power-save blocker's effect, and battery events can't be
exercised on Linux CI. The decisions are unit tested (`macos/Tests/VesperCoreTests/` (SystemLogicTests));
the measurements above are still owed.
