# pnpm owner-command journal repair verification

Run from the repository root on macOS with Swift and Clang installed:

```sh
TMPDIR="${TMPDIR}" sh docs/verification/pnpm-owner-recipe/run-journal.sh
```

The script creates and deletes a task-specific temporary directory, compiles the actual `DiskReservoirCore` sources and `JournalE2E.swift`, and runs the controlled `fixture.sh` with an isolated `HOME` and store. It never invokes installed pnpm or cleans the real cache. The repeatable output artifact is [`journal-last-run.log`](journal-last-run.log).

Inputs: an isolated store containing `unreferenced-package`; a JSON store that throws on its first save, one that throws on its second save, and a normal store. The fixture records each prune invocation and removes only that isolated package. Observed: nine assertions passed. A failed attempt write prevented the invocation and preserved the package. A failed completion write following either command success or command failure returned a distinct result and left a persisted `started` record. Normal execution persisted `started` and linked `success` records before the simulated caller refresh boundary.

The AppService source path calls `OwnerCommandJournal.execute` in one detached operation, delivers the journal result to the UI, then begins `refreshVolumeCapacity` / `scanNow` after awaiting the operation. This source ordering is verified by inspection; the E2E harness does not launch the macOS UI or its actual scan. The `pnpm.error_launch` localization now reports an uncertain process outcome because launch monitoring can fail after the process starts. Director owns the full app build and UI acceptance. `python3 -m json.tool PoolProblem/PoolProblem/Localizable.xcstrings` and `git diff --check` passed.
