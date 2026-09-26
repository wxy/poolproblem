# Pool Problem product contract

This document defines the current product boundary. Historical plans under
`docs/superpowers/` describe earlier explorations and are not the runtime
contract.

## Goal

Keep developer machines above a configurable free-space target while making
unattended deletion rarer, explainable, and bounded.

## Decision order

1. **Safety first.** A directory is never automatically deleted merely because
   it is large, old, regenerable, or classified as a cache. Automatic permanent
   deletion requires an explicit built-in recipe authorization. Age, whitelist,
   keep, and running-process checks remain vetoes.
2. **Urgency second.** Healthy machines do not recursively scan. The app probes
   available capacity every five minutes. Entering the warning band starts
   analysis; falling below the waterline permits emergency cleanup after the
   launch grace period. Repeated analysis is capped at once per 30 minutes in
   warning and once per 10 minutes in critical state, unless available space
   drops by another 1 GB or 500 MB respectively.
3. **Growth third.** Growth changes ordering, not eligibility. Among candidates
   that already passed the same safety gates, measured positive growth sorts
   ahead of slow, stable, or unknown growth.
4. **Verify the result.** Trash moves do not count as recovered capacity.
   Automatic cleanup uses permanent deletion only for authorized caches and
   re-reads volume capacity after the operation.

## Pressure state machine

| State | Condition | Work allowed |
| --- | --- | --- |
| Healthy | available >= target + analysis margin | Capacity probe only |
| Warning | target <= available < target + analysis margin | Analyze known recipes; no unattended deletion |
| Critical | available < target | Analyze; clean authorized caches toward target + recovery margin |

The analysis margin is `max(5 GB, target / 3)`. The recovery margin is
`max(2 GB, target / 6)`, which provides hysteresis and avoids repeated cleanup
at the exact threshold.

## Automatic boundary

Current automatic candidates are narrowly scoped built-in caches such as
XCTestDevices, Xcode documentation cache, Xcode preview cache, and known global
package-manager caches. Xcode processes guard the Xcode group. Legacy snapshots
that lack the authorization field decode as unauthorized.

DerivedData, archives, project outputs, `~/Library/Caches`, simulator user data,
and every user-added path are manual-only. Where deletion is supported, manual
cleanup uses Trash and records the resulting location.

## Performance boundary

- Opening the menu popover never starts a scan.
- Recursive walking runs off the main actor at background priority.
- A running walk cooperatively pauses for the popover's first frame.
- Continuous filesystem surveillance, periodic whole-disk analysis, automatic
  surface discovery, and background progressive cleanup are not part of the
  default loop.
- Growth discovery remains an explicit secondary action.

## Acceptance criteria

- No item without positive automatic authorization can be deleted by an
  automatic run.
- Urgency cannot bypass age, keep, whitelist, or process guards.
- Fast growth can reorder only already-eligible items.
- Healthy operation performs no recursive scan.
- Moving an item to Trash never increases the reported available capacity.
- The popover can present from cached state while a directory walk is active.
