// Golden-fixture generator for the POLARIS movement rules.
//
// Runs the ORIGINAL Dart implementation (copied verbatim from the Flutter app,
// with only the `package:flutter/foundation.dart` import stripped) over a
// deterministic pseudo-random case list, and dumps every input together with
// its result as JSON.
//
// The Godot port replays the recorded inputs and must reproduce every recorded
// output exactly — the differential test POLARIS_CONTEXT §7 asks for. (Only this
// generator runs the LCG; the Godot side just reads the fixture.)
//
//   dart run bin/dump.dart > golden_movement.json

import 'dart:convert';

import 'logic/movement.dart';
import 'models/deflector.dart';
import 'models/magnet.dart';
import 'models/position.dart';
import 'models/puzzle.dart';

/// Small deterministic LCG, so re-running this generator reproduces the fixture.
class Lcg {
  int seed;
  Lcg(this.seed);

  int next(int max) {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    // High bits only: in an LCG modulo a power of two the low bits have tiny
    // periods (bit 0 simply alternates), so `seed % 2` would make every coin
    // flip in this fixture perfectly predictable and kill its coverage.
    return (seed >> 16) % max;
  }
}

Map<String, int> pos(Position p) => {'r': p.row, 'c': p.col};

void main() {
  final lcg = Lcg(987654321);
  final cases = <Map<String, dynamic>>[];

  for (var i = 0; i < 2000; i++) {
    const size = 6;

    // --- board ---------------------------------------------------------
    final walls = <Position>{};
    final wallCount = lcg.next(7);
    for (var w = 0; w < wallCount; w++) {
      walls.add(Position(lcg.next(size), lcg.next(size)));
    }

    final deflectors = <Position, DeflectorDir>{};
    final deflectorCount = lcg.next(4);
    for (var d = 0; d < deflectorCount; d++) {
      final p = Position(lcg.next(size), lcg.next(size));
      if (walls.contains(p)) continue;
      deflectors[p] = lcg.next(2) == 0
          ? DeflectorDir.backslash
          : DeflectorDir.slash;
    }

    // Strength: null (unlimited) half the time, otherwise 1..4.
    final strengthRoll = lcg.next(6);
    final int? strength = strengthRoll < 3 ? null : strengthRoll - 2;
    // Reach: always finite, 1..5.
    final reach = 1 + lcg.next(5);

    // 1..3 balls on distinct free cells.
    final ballCount = 1 + lcg.next(3);
    final balls = <Position>[];
    var guard = 0;
    while (balls.length < ballCount && guard++ < 200) {
      final p = Position(lcg.next(size), lcg.next(size));
      if (walls.contains(p) || balls.contains(p)) continue;
      balls.add(p);
    }
    if (balls.length < ballCount) continue;

    // A magnet somewhere free and not on a ball. Three times out of four it is
    // put on the primary ball's row or column: a magnet off both lines does
    // nothing at all, and a fixture of mostly no-ops would barely exercise the
    // sliding, deflecting and stacking rules this test exists to pin down.
    Position? mpos;
    guard = 0;
    final inLine = lcg.next(4) != 0;
    while (guard++ < 200) {
      final Position p;
      if (inLine) {
        p = lcg.next(2) == 0
            ? Position(balls[0].row, lcg.next(size))
            : Position(lcg.next(size), balls[0].col);
      } else {
        p = Position(lcg.next(size), lcg.next(size));
      }
      if (walls.contains(p) || balls.contains(p) || deflectors.containsKey(p)) {
        continue;
      }
      mpos = p;
      break;
    }
    if (mpos == null) continue;

    // Sometimes a second, inert magnet — it must still act as a solid blocker.
    final extraMagnets = <Magnet>[];
    if (lcg.next(3) == 0) {
      final p = Position(lcg.next(size), lcg.next(size));
      if (!walls.contains(p) &&
          !balls.contains(p) &&
          !deflectors.containsKey(p) &&
          p != mpos) {
        extraMagnets.add(
          Magnet(p, lcg.next(2) == 0 ? MagnetType.plus : MagnetType.minus),
        );
      }
    }

    // Per-magnet overrides exercise the "magnet wins over puzzle" rule.
    final perMagnetStrengthRoll = lcg.next(8);
    final int? perStrength = perMagnetStrengthRoll < 6
        ? null
        : perMagnetStrengthRoll - 5;
    final perReachRoll = lcg.next(8);
    final int? perReach = perReachRoll < 6 ? null : perReachRoll - 5;

    final magnet = Magnet(
      mpos,
      lcg.next(2) == 0 ? MagnetType.plus : MagnetType.minus,
      strength: perStrength,
      reach: perReach,
    );
    final magnets = <Magnet>[magnet, ...extraMagnets];

    final puzzle = Puzzle(
      id: i,
      size: size,
      start: balls[0],
      target: Position(lcg.next(size), lcg.next(size)),
      walls: walls,
      deflectors: deflectors,
      extraBalls: [
        for (var b = 1; b < balls.length; b++)
          (start: balls[b], target: balls[b]),
      ],
      plusBudget: 9,
      minusBudget: 9,
      magnetStrength: strength,
      magnetReach: reach,
    );

    // --- run the rules -------------------------------------------------
    final resting = activate(balls[0], magnet, magnets, puzzle);
    final path = slidePath(balls[0], magnet, magnets, puzzle);
    final allResting = activateAll(balls, magnet, magnets, puzzle);
    final allPaths = activateAllPaths(balls, magnet, magnets, puzzle);
    final field = magnetField(magnet, puzzle);

    cases.add({
      'puzzle': {
        'id': i,
        'size': size,
        'start': pos(puzzle.start),
        'target': pos(puzzle.target),
        'walls': [for (final w in walls) pos(w)],
        'deflectors': [
          for (final e in deflectors.entries)
            {...pos(e.key), 'd': e.value.name},
        ],
        'balls': [
          for (final b in puzzle.extraBalls)
            {'start': pos(b.start), 'target': pos(b.target)},
        ],
        'budget': {'plus': 9, 'minus': 9},
        'magnet_strength': strength ?? -1,
        'magnet_reach': reach,
      },
      'magnets': [
        for (final m in magnets)
          {
            ...pos(m.pos),
            't': m.type.name,
            's': m.strength ?? -1,
            'reach': m.reach ?? -1,
          },
      ],
      'balls': [for (final b in balls) pos(b)],
      'activate': pos(resting),
      'slide_path': [for (final p in path) pos(p)],
      'activate_all': [for (final p in allResting) pos(p)],
      'activate_all_paths': [
        for (final list in allPaths) [for (final p in list) pos(p)],
      ],
      'field': [
        for (final f in field) {...pos(f.cell), 'dr': f.dr, 'dc': f.dc},
      ],
    });
  }

  print(jsonEncode({'seed': 987654321, 'cases': cases}));
}
