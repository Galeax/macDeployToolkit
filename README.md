# MacDeployToolkit

## What is it

Application deployment framework for macOS, in the spirit of **PSADT**, driven by Intune.

Intune can install a `.pkg`. What it cannot do is warn the user that an update is about to close Slack, grant them a few deferrals, show a countdown, then close the application and install. That is the sole purpose of this tool.

**The model, in one sentence:** a **per-app signed pkg**, self-contained, that holds **everything** — the `macdeploy` agent, swiftDialog, the manifest and the vendor's payload. The operator chooses the **deployment mode** and any **pre/post scripts** at deployment time.

**No dependency to deploy on the fleet**: swiftDialog travels inside the pkg, there is no configuration profile to lay down, and the agent is removed after each successful installation. The user-facing dialog is rendered by **swiftDialog** (an external, notarized binary), not by a bundled SwiftUI app — the UI is deliberately kept swappable behind a `DialogSpec` indirection.

## Key features

- **Centralized logging** — one per-app log under `/var/log/coreupdate/`, plus a unified log subsystem (`com.coreupdate.deploy`) and an inspectable state file; `macdeploy status --json` is the source of truth.
- **Closing running applications** — macdeploy detects blocking apps itself (libproc, agent side) and closes them with `SIGKILL`. No PPPC profile, no AppleEvent, no TCC authorization.
- **User-facing dialog** — a warning dialog (swiftDialog) with **deferrals**, a **countdown**, an optional **deadline**, and persistence that brings an ignored dialog back to the foreground.
- **Three deployment modes** — `interactive`, `nonInteractive`, `silent`, chosen per deployment; what separates them is visibility, not power.
- **Self-contained signed pkg** — one `build-app-pkg.sh` produces a signed, universal pkg that carries the agent, swiftDialog, the manifest and the payload. Xcode not required.
- **DMG wrapper** — ships apps distributed as a DMG through Intune's `macOSPkgApp`, which `macOSDmgApp` cannot do (it accepts no scripts).
- **Per-app hooks** — `pre/post` install and uninstall scripts, confined to the manifest directory and run as root behind four safeguards.
- **Safe uninstall** — the uninstall plan is a pure, auditable value with an allowlist-by-default path policy, built so a mistake cannot cause a fleet-wide wipe.
- **`--dry-run`** — the full evaluation without root, without executing anything and without consuming a deferral.

## Getting started

### How to use it

On a Mac that has swiftDialog (to embed it) and a **Developer ID Installer** certificate:

```bash
# 1. A manifest describes the application (see "The manifest").
#    2. Build the signed self-contained pkg + the post-install:
export MDT_TEAM_ID=XXXXXXXXXX
Scripts/build-app-pkg.sh -m chrome.json -p ~/Downloads/googlechrome.dmg --mode Interactive
# → .build/apps/<packageKey>/<packageKey>.pkg   (the signed package)
# → .build/apps/<packageKey>/<packageKey>-postinstall.sh   (to paste into Intune)
```

In Intune ("macOS app (PKG)" type): upload the pkg, paste the **postInstallScript**, fill in **Included apps** (bundle id + version of the target app). No preInstallScript, no dependency to deploy.

#### The manifest

```json
{ "packageKey": "internal-tool" }
```

| Field | Default | Role |
|---|---|---|
| `packageKey` | required | Stable identifier. **Carries the deferral counter** — changing it resets it. Never derived from `displayName` |
| `displayName` / `version` / `publisher` | — | — |
| `logName` | derived | Per-app log in `/var/log/coreupdate/` |
| `mode` | `interactive` | `interactive` \| `silent` \| `nonInteractive`. **Just a default** — the deployment's `--mode` wins |
| `blockingApps[]` | `[]` | `bundleIdentifier` and/or `executableName`, `displayName`. A plain string is accepted |
| `deferral.maxDeferrals` | `3` | Number of deferrals |
| `deferral.deferralDays` | — | Sliding window from the first prompt (`-DeferDays`) |
| `deferral.deadline` | — | ISO 8601 cutoff date (`-DeferDeadline`) |
| `deferral.countdownSeconds` | `300` | Dialog countdown, on install |
| `deferral.uninstallCountdownSeconds` | `60` | Same, on uninstall / repair |
| `deferral.persistPromptSeconds` | `60` | Re-display of an ignored dialog. `0` disables |
| `deferral.maxDialogSeconds` | `1200` | Budget of a deferrable dialog before `abandoned` |
| `deferral.forceCloseWhenExhausted` | `true` | Force close (SIGKILL) once the window is exhausted |
| `requirements.respectPresentationMode` | `true` | Do not disturb during a video call |
| `requirements.respectScreenLock` | `true` | Do not close while the user is away |
| `detection` | — | `bundlePath`, `expectedVersion`, `packageIdentifier` |
| `uninstall` | — | `packageIdentifiers`, `paths`, `launchdLabels`, `preservedPaths` |
| `hooks` | — | `preInstall`, `postInstall`, `preUninstall`, `postUninstall` |
| `payload` | — | `file` (confined to the manifest directory), `installLocation`, `bundleName` |
| `ignoredExitCodes` | `[]` | Hook codes treated as successes. Alias `IgnoreExitCodes` |
| `messages.strings` | built-in FR + EN | Partial override accepted |
| `restartAction` | — | `none` \| `recommendRestart` \| `requireRestart` \| `requireLogout` \| `requireShutdown` |

Tokens in the texts: `{name}`, `{version}`, `{apps}`, `{deferrals}`, `{deadline}`. An unknown token is **left visible** rather than replaced with nothing.

#### The three deployment modes

The mode is chosen **per deployment** (`--mode`, which overrides the manifest). What separates them is **visibility**, not power: all three end up installing.

| Mode | Gate dialog | Progress / completion message | Closes applications |
|---|---|---|---|
| `interactive` | yes — deferral and countdown | yes | after consent, or on expiry |
| `nonInteractive` | **no** — no choice offered | yes | by force |
| `silent` | no | **no** — nothing on screen | by force |

The non-interactive modes respect the deferral window before closing: as long as neither `deadline`, nor `deferralDays`, nor `maxDeferrals` is reached, they return `64` and let Intune retry. To install without waiting, `allowDeferral: false`.

#### Application detection and closing

macdeploy detects running blocking applications itself (libproc, agent side — works in a daemon context), shows the warning dialog (swiftDialog), then **closes with `SIGKILL`**.

- **No PPPC profile, no AppleEvent, no TCC.** Closing is a `kill(2)` by PID on the agent side, which depends on no session and requires no authorization.
- The dialog (warning + deferral + countdown) is **the only window to save one's work**: on consent or at the deadline, the application is killed on the spot, with no "Save?" sheet.
- `persistPromptSeconds` brings an ignored dialog back to the foreground; a deferrable dialog also carries its own countdown, whose expiry triggers the installation.

#### Intune deployment

The hook already exists and requires **no modification**: `Update-IntuneMacOSApp` accepts `-PreInstallScript` / `-PostInstallScript` for `macOSPkgApp`, fed by `ApplicationIntune.pre_install_script` / `post_install_script`.

```
Intune — "macOS app (PKG)" app, required
  │
  ├─ installer -pkg            [done by Intune — lays down agent + swiftDialog + manifest + payload]
  │
  └─ post-install script ─> macdeploy install   [root, daemon context]
        ├─ process scan             (libproc)
        ├─ dialog + deferral        (launchctl asuser → macdeploy-ui → swiftDialog)
        ├─ SIGKILL close            (kill by PID, agent side)
        ├─ DMG mount, .app copy, hardening, detection
        ├─ cleanup (removes agent + swiftDialog + payload; keeps state + logs)
        └─ RestartAction
```

**What is frozen in the signed pkg** (decided at build, per app/version): the manifest and the payload.
**What is dynamic at deployment** (text, regenerated by CoreUpdate, no rebuild): the `--mode` and any pre/post scripts. Changing mode = regenerate the post-install, the pkg does not move.

The templates in `Scripts/templates/` are instantiated by substitution, exactly like `InstallExtractAndRun.ps1` and its `{##…##}` on the Windows side.

##### Apps shipped as a DMG

`macOSDmgApp` accepts no script. A DMG app becomes a `macOSPkgApp` whose **payload is the vendor's DMG**. The DMG travels as an opaque file inside the pkg (never mounted on the build host); only the device mounts it, copies the `.app` by atomic swap, hardens and unmounts. macdeploy also handles a `.pkg` or an `.app` inside the DMG, and explicitly refuses an image with several candidates (unless `payload.bundleName`).

#### Per-app hooks

```json
"hooks": { "preInstall": "hooks/pre-install.sh", "postInstall": "hooks/post-install.sh" }
```

Paths **relative to the manifest directory**, run as root, killed after 600 s. Context arrives through the environment.
`preInstall` runs after the applications are closed and before the installation.

**Security**: a script path read from a JSON and run as root is a code-execution primitive. Four safeguards, all checked before execution and tested:

1. the resolved path must stay **inside** the manifest directory (`..` refused, absolute path outside rejected);
2. the script must exist and carry an execute bit;
3. it must be owned by root;
4. it must not be writable by group or others.

```bash
chown root:wheel hooks/pre-install.sh && chmod 755 hooks/pre-install.sh
```

#### Uninstall — plan safety

The most dangerous code in the project: the same plan runs across the whole fleet, so a mistake produces a fleet-wide reinstall, not a ticket. Three design choices, all tested:

1. **The plan is a pure value**, computed without touching the disk, auditable and testable.
2. **Each path is validated before pruning** (`pkgutil --files` lists intermediate directories, including `Applications` itself).
3. **Allowlist by default**, not denylist: anything not explicitly under `/Applications`, `/Library`, `/usr/local`, `/opt` or `/Users` is refused. Comparison by components, never by string prefix. Under `/Users`, a minimum depth of 4 plus a relative blocklist.

#### Exit codes

| Code | Meaning |
|---|---|
| `0` | Installed, or clear to install |
| `1`–`6` | Failure. `5` = `force_close_failed` (a process survived the SIGKILL). `6` = `hook_failed` |
| `60`–`65` | Not installed, legitimate transient block. Intune should retry |
| `70`–`72` | Installed, restart / logout / shutdown required |

Intune only distinguishes 0 / non-zero. Two consequences:

- **A user deferral shows up as "failed"** on the dashboard, functionally correct (will be retried), unreadable in reporting. The source of truth:
  ```bash
  macdeploy status --json
  plutil -p "/Library/Application Support/CoreUpdate/Deploy/state.plist"
  log show --predicate 'subsystem == "com.coreupdate.deploy"' --last 1d
  ```
- **Codes 70–72 are translated to 0 by the post-install**, otherwise a successful installation requiring a restart would be reinstalled in a loop.

#### The `--dry-run` mode

Goes through the same evaluation, builds the same dialog and the same uninstall plan, but executes nothing and consumes no deferral. Works **without root**.

```bash
macdeploy pre -m Examples/slack.json --dry-run
macdeploy pre -m Examples/slack.json --dry-run --mode Silent
macdeploy uninstall -m Examples/slack.json --dry-run --json | jq
```

#### Build

```bash
Scripts/build-app-pkg.sh -m <manifest>.json -p <payload>.dmg [--mode …] [--hooks-dir …]
Scripts/build-app-pkg.sh … --unsigned     # local validation only (Intune refuses an unsigned pkg)
```

The script compiles the agent as a universal binary (`x86_64 arm64`), embeds swiftDialog, lays down the manifest + the payload, signs the pkg and renders the post-install. **Xcode is not required**: when `xcbuild` is absent, two `--triple` builds followed by a `lipo`.

`Scripts/build-pkg.sh` builds, signs and notarizes the pkg of the **agent alone** — useful for testing the agent in isolation.

#### Dependencies

**No dependency to install on the device.** macdeploy relies on **swiftDialog** for the UI (notarized by its author, MIT licence; markdown, dark mode, Notification Center, accessibility), but it **travels inside the pkg**: the build scripts copy `Dialog.app` from the build host, and the post-install removes it after installation. swiftDialog must therefore be present **on the build Mac** (`/Library/Application Support/Dialog/Dialog.app`, or `MDT_DIALOG_APP`).

**No Swift dependency.** A binary that runs as root on production devices does not drag a supply chain around: argument parsing and manifest format are hand-written. The `DialogSpec` indirection is the point where one would swap the UI without touching the logic.

### Developing & contributing

#### Repository layout

| Path | What lives there |
|---|---|
| `Sources/MDTKit/` | Pure-Foundation logic: manifest decoding, deferral engine, uninstall planner, dialog spec, templating, exit codes. **No Apple-only API.** |
| `Sources/MDTMac/` | Everything that touches the system: libproc process scan, SIGKILL close, DMG mount, installer, hooks, swiftDialog runner, session/IOKit probes. Entirely behind `#if canImport(Darwin)`. |
| `Sources/MacDeployToolkitCLI/` | The `macdeploy` agent entry point. |
| `Sources/MacDeployToolkitUI/` | The `macdeploy-ui` helper (runs in the user session, drives swiftDialog). |
| `Tests/MDTKitTests/` | XCTest suite for `MDTKit` — the whole decision surface, plus `ExamplesTests` which parses every file in `Examples/`. |
| `Examples/` | Reference manifests. Every one must parse (a test enforces it). |
| `Scripts/` | Build (`build-app-pkg.sh`, `build-pkg.sh`), the post-install `templates/`, and the Intune `probe-*` / `mac-smoke-test.sh` runbooks. |

#### The cardinal rule: logic goes in MDTKit

Put every decision — anything with a branch, a threshold or an edge case — in `MDTKit`, behind a pure function or value type, and let `MDTMac` only *perform* the effect. The payoff is that **the costly-to-get-wrong code is pure and unit-tested**, with no system state to stand up or mock. If you find yourself writing an `if` inside `MDTMac`, ask whether that decision belongs in `MDTKit` with a test next to it.

#### Build & test

```bash
swift build
swift test                    # requires full Xcode — XCTest is not in the Command Line Tools
Scripts/mac-smoke-test.sh     # end-to-end validation runbook on a Mac
```

`MDTKit` holds all the decision logic and carries the whole XCTest suite. `MDTMac` and the two executables are macOS-only and are covered by the smoke test rather than by unit tests.

`swift test` needs **full Xcode**: with the Command Line Tools alone it fails with `no such module 'XCTest'`. The build scripts, on the other hand, produce a universal binary **without Xcode** (two `--triple` builds + `lipo`), so a CLT-only Mac can still ship a pkg.

#### Conventions

- **No external dependency, ever.** This binary runs as root on production devices; the supply-chain surface must stay nil. Argument parsing and the manifest format are hand-written on purpose — keep them that way.
- **Allowlist, not denylist**, for anything that deletes or targets a path (see the uninstall planner). Compare by path components, never by string prefix.
- **Don't hardcode user-facing text.** End-user strings come from the `Messages` catalog (`Manifest.swift`), which ships built-in. Add a string to the catalog with both locales; never inline a dialog label in `MDTMac`.
- **Prefer a value you can test** over a side effect you can't. The uninstall *plan* is a pure value; the dialog is a `DialogSpec` built in `MDTKit`; MDTMac just executes them.

#### Common tasks

- **Add a manifest field** → extend the type in `Sources/MDTKit/Manifest.swift` (tolerant decoding, every key optional with a fallback), document it in the manifest table above, and add a case to `Tests/MDTKitTests/ManifestTests.swift`.
- **Add an example** → drop a `.json` in `Examples/`; `ExamplesTests` will require it to parse, so keep it valid. Use real data for real apps, English for prose and `_commentaire`.
- **Change the post-install** → edit `Scripts/templates/macos-postinstall-standalone.sh.template`. Tokens are `{##PACKAGE_KEY##}` / `{##DEPLOY_MODE##}` and must never appear in a comment line (a test checks this); the rendered script must pass `sh -n`.
- **Add an exit code** → put the meaning in `Sources/MDTKit/ExitCode.swift` and reflect it in the exit-code table above and, if the post-install must swallow it, in the template's code translation.

#### Architecture — why two binaries

From the daemon context where Intune runs its scripts, there is no access to the WindowServer: no UI is possible. The dialog must therefore show up in the user session, hence the `macdeploy-ui` helper, launched with `launchctl asuser` **and** `sudo -u` (the first for the session context, the second so the dialog shows up on the user's behalf). Closing applications, on the other hand, happens **on the agent side** via SIGKILL. The agent↔helper dialog goes through stdin/stdout as JSON, one invocation per exchange.

#### Project status

| Component | Status |
|---|---|
| `MDTKit` — decision logic, manifest, uninstall plan | Unit tests green |
| `MDTMac` — Apple system calls (libproc, SCDynamicStore, IOKit) | Compiles and runs — validated on macOS 26.3.2 / arm64 |
| `macdeploy` / `macdeploy-ui` executables | Exercised end to end: gate, deferral, deadline, SIGKILL close, installation of a real DMG, all three modes |
| Self-contained pkg build (`build-app-pkg.sh`) | Operational, signs the pkg on the build host |

The split into two modules is deliberate: `MDTKit` is pure Foundation and carries all the logic where a mistake is costly, under unit test; `MDTMac` is entirely behind `#if canImport(Darwin)`.
