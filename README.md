# AgentCurtain

**Draw the curtain; keep the GUI session working.**

AgentCurtain is a macOS 26+ menu bar app for unattended GUI-agent sessions. It
dims every physical display, blocks physical keyboard and mouse events at the
HID event tap, and leaves the unlocked WindowServer session rendering normally.
Allowlisted remote-desktop processes and session-layer agent input continue to
work.

[中文说明](README.zh-CN.md) · [Measured findings](docs/FINDINGS.md) ·
[Implementation PRD](docs/PRD-menubar-app.md) ·
[Acceptance matrix](docs/ACCEPTANCE-menubar-app.md)

> AgentCurtain is weaker than the real lock screen. It deters opportunistic
> access; it does not protect against a prepared attacker, a reboot, new input
> hardware, or physical access to storage. The UI deliberately says “curtain”
> and never claims that the Mac is locked or secure.

## What is delivered

`/Applications/AgentCurtain.app` is the single installed runtime and the only
component that needs Accessibility permission. It contains:

- an `NSStatusItem` menu showing open/drawn state and live counters;
- a `kCGHIDEventTap` blocker with deny-before-allow decisions;
- one framebuffer-visible banner window per display;
- BetterDisplay brightness control addressed only by `displayID`;
- a mode-0600 Unix socket at `~/.local/state/curtain/control.sock`;
- an embedded recovery watchdog that restores brightness if the app is killed.

The `curtain` command is a thin, unprivileged socket client. It never creates an
event tap and therefore needs no TCC permission.

## Install

Requirements:

- Apple Silicon and macOS 26 or newer;
- Xcode Command Line Tools;
- BetterDisplay with `betterdisplaycli` installed;
- the Developer ID identity named in the PRD when building from source.

```bash
./install.sh
```

The build signs the main executable, embedded watchdog, and outer app with:

```text
Developer ID Application: LONGBIAO CHEN (HJG65XBC25)
```

Hardened Runtime and a secure timestamp are required. Installation fails rather
than falling back to an ad-hoc signature. The installed app is verified again
under `/Applications`.

On first use, enable **AgentCurtain** in System Settings → Privacy & Security →
Accessibility. Because the designated requirement is based on bundle identifier,
Apple anchor, and Team ID—not `cdhash`—a later signed rebuild keeps the same
authorization.

## Use

Use the menu bar icon, the global shortcuts, or the compatible CLI:

```bash
curtain on
curtain status
curtain off
curtain allow
curtain deny
curtain doctor
```

The existing timed form remains supported:

```bash
curtain on 3600
curtain on --allow-any-injected
```

`--allow-any-injected` is rejected unless the denylist is non-empty. The global
shortcuts are:

- `Ctrl+Opt+Cmd+Shift+L`: draw the curtain;
- `Ctrl+Opt+Cmd+Shift+U`: open it again.

The release shortcut is checked inside the HID callback before the keystroke is
swallowed. `curtain off` only talks to the app socket and never requires
Accessibility permission, including from SSH.

## Configuration

- `~/.config/curtain/allowlist`: allowed executable paths, one per line;
- `~/.config/curtain/denylist`: always denied, with highest priority.

Blank lines and lines beginning with `#` are ignored. `.app` entries resolve to
their exact bundle executable. Non-path rules match an exact executable basename.
PID discovery uses `proc_listallpids` and `proc_pidpath`; it never uses substring
matching such as `pgrep -f`. Matching PIDs refresh every three seconds.

The default denylist contains the three Karabiner components required by the PRD.

## Runtime safety

The draw transition is ordered and rollback-safe:

1. confirm that AgentCurtain has Accessibility permission;
2. read each active display’s brightness by `displayID`;
3. atomically write a mode-0600 recovery file;
4. start the embedded recovery watchdog;
5. set each brightness to zero and read it back;
6. arm the HID event tap and create one banner per screen.

Any failure rolls brightness back. Normal `off`, menu-bar quit, `SIGTERM`, a
timed release, and the release shortcut all restore brightness. `kill -9` cannot
run app cleanup, so the independent embedded watchdog observes process death and
restores from the same recovery file. On a later launch, the app retries any
orphaned restore record.

Display-change notifications rebuild banners and reconcile newly attached
display IDs into the brightness backup before dimming them.

AgentCurtain never calls `pmset displaysleepnow`: display sleep stops framebuffer
composition and blinds GUI agents.

## Developer loop and verification

```bash
./script/build_and_run.sh
./script/build_and_run.sh --verify
./script/build_and_run.sh --install
```

The Codex Run action points to the same script. `--verify` runs Swift tests,
strict signature validation, launches the signed bundle, verifies socket mode
0600, and checks the JSON status response.

While the curtain is drawn, verify real banner rendering on every framebuffer:

```bash
./script/verify_banner_framebuffer.sh
```

This scans the rendered feature color per `CGDirectDisplayID`; a running banner
process or a retained `NSWindow` is not accepted as proof.

Hardware acceptance remains separate. In particular, a real person must press
physical keys and use the mouse to prove the `blocked` counter rises without UI
response. Programmatically injected events cannot prove that HID-layer behavior.
The full requirement-by-requirement checklist is in
[docs/PRD-menubar-app.md](docs/PRD-menubar-app.md#9-验收标准).
