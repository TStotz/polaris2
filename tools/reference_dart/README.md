# Dart reference implementation (pinned)

This folder holds a **frozen copy of the original Flutter app's game logic** and
the scripts that turn it into the golden fixtures under `res://tests/data/`.

It is not part of the game build. Nothing in `res://scripts/` imports it. Its
only job is to answer one question with evidence rather than confidence:

> Does the GDScript port compute *exactly* what the Dart original computed?

## Provenance

| | |
|---|---|
| Source | `polaris/lib/` of the Flutter app |
| Commit | `a937c2e` (2026-08-26) |
| Changes | Only the `package:flutter/foundation.dart` imports and the `@immutable` annotations were stripped, so the files run under a plain Dart SDK. The logic is byte-for-byte the original. |

`bin/models/` and `bin/logic/` are that copy. **Do not hand-edit them** to fix a
port bug: if the Flutter app's rules change and the Godot game is meant to follow,
re-copy the files, re-generate the fixtures, and let the differential tests show
you what moved.

### The one deliberate extension

Plates and gates (`models/gate.dart`, the `plates`/`gates` fields on `Puzzle`,
and the `gateMask` argument threaded through `movement.dart` and `solver.dart`)
are **new** — the Flutter original never had them. They live here because the
pipeline has to generate and verify switch levels, and the solver cannot do that
without understanding them.

That does not weaken the pin. Both fixtures were regenerated after the change and
came back **bit-identical**, because a board with no gates passes `gateMask = 0`
and every rule collapses to what it was before. So the original-parity guarantee
still holds, and it is now also a regression guard: touching the gate code again
must leave those two files unchanged.

Gate behaviour itself has no Dart original to diff against, so its specification
is `res://tests/test_gates.gd`, and these files are kept in step with it by hand.

## What the fixtures cover

| Fixture | Generator | Cases | Pinned behaviour |
|---|---|---|---|
| `res://tests/data/golden_movement.json` | `bin/dump.dart` | 2000 | `activate`, `slidePath`, `activateAll`, `activateAllPaths`, `magnetField` — walls, deflectors, per-magnet strength/reach overrides, 1–3 balls, magnet-as-blocker, the deflector cycle guard |
| `res://tests/data/golden_solver.json` | `bin/dump_solver.dart` | 100 | Solvability, minimal magnet count, the exact placement **and** activation sequence, and `countMinimalSolutions` — across waypoints, single-use, finite strength/reach, deflectors and multi-ball boards |

Both generators build their boards from a small LCG so a re-run reproduces the
same fixture. They deliberately read the **high** bits of the LCG state: modulo a
power of two its low bits have tiny periods (bit 0 merely alternates), which
silently collapsed every coin flip in an earlier version of this fixture and cost
it most of its coverage.

The solver sweep is kept to 4×4 boards with a 2+2 budget on purpose. GDScript
runs the exhaustive placement search roughly 5–10× slower than Dart, and this
fixture has to stay a *fast* regression guard — a bigger sweep froze the editor
for minutes.

## Baking one chapter at a time

```bash
dart run bin/build_levels.dart --only switch > /dev/null
```

The full pack takes ~25 minutes and nearly all of it goes into the two deflector
chapters, which makes iterating on any other chapter unbearable. `--only` bakes a
single chapter in seconds.

When a chapter comes up short the builder prints *why*, counted by cause:

```
switch    0/10 levels in 320 ms (400 attempts, 108 inert switches rejected)
  WARNING: chapter "switch" is short by 10 levels.
       79  solution fails to replay on the tightened board
       16  gated board unsolvable within 3 magnets
       13  still solvable with the plates inert — the switch is scenery
```

That is worth having. The first switch bake produced zero levels, and the
histogram named the cause immediately: `replayWins` predated gates and re-ran
every solution with the doors permanently shut. Without it there were four
plausible suspects and no way to tell them apart.

## Tracing a single level

```bash
dart run bin/trace_level.dart 61
```

Prints every activation's slide path for a shipped level, straight from the
reference. When a level looks wrong in the game this is the fastest way to split
a rules bug from a design bug: if Dart and Godot print the same path, the rules
agree and the level itself is the problem.

## Regenerating

```bash
cd tools/reference_dart
dart pub get
dart run bin/dump.dart > ../../tests/data/golden_movement.json
dart run bin/dump_solver.dart > ../../tests/data/golden_solver.json
```

Then re-run the Godot suites `movement_differential` and `solver_differential`.

## The tests that consume them

- `res://tests/test_movement_differential.gd`
- `res://tests/test_solver_differential.gd`

Both replay the *recorded inputs* — they never run the LCG themselves — and
demand identical outputs. A failure names the case index and prints both sides,
so the offending board can be rebuilt by hand.

These have been verified to actually fail: inverting the deflector rotation in
`Movement._deflect` was caught immediately, on case 0.
