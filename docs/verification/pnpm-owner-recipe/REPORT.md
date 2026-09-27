# pnpm owner command isolated E2E

Run from any directory on macOS with Swift installed:

```sh
sh docs/verification/pnpm-owner-recipe/run.sh
```

The script creates a task-specific `$TMPDIR/poolproblem-pnpm-owner.*` directory, compiles the actual `DiskReservoirCore` sources with Swift and Clang module caches inside it, and launches the controlled `fixture.sh` with isolated `HOME`, `store`, and data directory. The input fixture implements `pnpm store path` and `pnpm store prune`; it never invokes installed pnpm. Temporary files are removed at exit. The repeatable output artifact is [`last-run.log`](last-run.log).

Observed result: 21 assertions pass. They cover exact store probing, successful prune preserving the store directory, separate owner command history and absent fabricated clean log, nonzero exit, target change and invalid target refusing prune, bounded output, timeout stopping the wrapper and ordinary child processes, and legacy/default recipe guards. This verifies the core command and persistence paths with a controlled executable. The separate journal harness passes nine assertions for durable attempt and completion recording; see [`JOURNAL-REPORT.md`](JOURNAL-REPORT.md). It does not establish that the real pnpm command behaves identically or that the macOS UI renders correctly. Both builds passed; live UI acceptance remains open.

Source inspection: default package manager paths exclude `~/Library/pnpm`; `Cleaner` checks old snapshot paths against `scan.volumeURL.path`; manual AppService cleanup checks its configured scan home; the dedicated command has no raw path deletion fallback. Any user-configured pnpm store at a different path is outside the legacy path guard and warrants separate policy review before claiming universal protection.

## Real pnpm smoke test

Run `docs/verification/pnpm-owner-recipe/run-real-pnpm.sh` with pnpm on `PATH`. The script gives pnpm an isolated task-specific `HOME`, XDG directories, and `PNPM_HOME`. It reads `pnpm store path` and refuses to run `prune` unless that path is inside the temporary fixture. Its input is an empty store; the output artifact is [`real-pnpm-last-run.log`](real-pnpm-last-run.log). On 2026-09-27, installed pnpm resolved its store within the fixture and `prune` exited successfully, reporting 0 packages removed. This verifies real command launch and target isolation, not meaningful space recovery from a populated store.

An attempt to populate the temporary store using `pnpm store add` with a local directory failed in the installed pnpm version (`pkgResponse.fetching is not a function`). The final smoke test therefore uses an empty store and makes no claim about populated-store prune behavior. No command was run on the real user store.

## Build checks

- `swift build --arch arm64 --scratch-path "$TMPDIR/poolproblem-pnpm-build"` succeeded with Swift Argument Parser 1.8.2 from the package cache.
- `xcodebuild -project PoolProblem/PoolProblem.xcodeproj -scheme PoolProblem -configuration Debug -destination 'platform=macOS' -derivedDataPath "$TMPDIR/poolproblem-pnpm-derived" CODE_SIGNING_ALLOWED=NO build` succeeded. The only reported warning was skipped App Intents metadata extraction because this app has no AppIntents dependency.

Both builds were run with permission for Xcode/SwiftPM host caches after the nested Agent Control Plane sandbox could not access them. A live popover interaction has not been verified; launching a disk-cleanup app against the user's real HOME was outside this isolated verification.
