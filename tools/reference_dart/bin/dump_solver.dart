// Golden-fixture generator for the POLARIS solver.
//
// Same idea as bin/dump.dart, one level up: runs the ORIGINAL Dart `Solver`
// over a deterministic list of small boards and records the minimal solution it
// finds — magnet count, placement, activation sequence — plus the minimal
// solution count.
//
// The Godot port must reproduce all of it exactly. It can, because both walk
// the identical search order (placeable cells row-major, PLUS before MINUS,
// BFS frontier in insertion order), so "a" minimal solution is in fact "the"
// minimal solution for both.
//
// Boards are kept small (4x4, budget 2+2) so the whole sweep runs in seconds on
// both sides — GDScript is roughly an order of magnitude slower than Dart at the
// solver's exhaustive placement search, and this fixture has to stay a quick
// regression guard.
//
//   dart run bin/dump_solver.dart > golden_solver.json

import 'dart:convert';

import 'logic/solver.dart';
import 'models/deflector.dart';
import 'models/magnet.dart';
import 'models/position.dart';
import 'models/puzzle.dart';

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
  final lcg = Lcg(24680);
  final cases = <Map<String, dynamic>>[];

  var built = 0;
  while (built < 100) {
    const size = 4;

    final walls = <Position>{};
    final wallCount = lcg.next(4);
    for (var w = 0; w < wallCount; w++) {
      walls.add(Position(lcg.next(size), lcg.next(size)));
    }

    final deflectors = <Position, DeflectorDir>{};
    if (lcg.next(3) == 0) {
      final p = Position(lcg.next(size), lcg.next(size));
      if (!walls.contains(p)) {
        deflectors[p] = lcg.next(2) == 0
            ? DeflectorDir.backslash
            : DeflectorDir.slash;
      }
    }

    Position pick() {
      Position p;
      var guard = 0;
      do {
        p = Position(lcg.next(size), lcg.next(size));
      } while ((walls.contains(p) || deflectors.containsKey(p)) &&
          guard++ < 100);
      return p;
    }

    final start = pick();
    final target = pick();
    if (start == target) continue;

    // Waypoints on free cells that are neither start nor target.
    final waypoints = <Position>[];
    // Waypoints make a random board unsolvable fast, so keep them rare — the
    // point is a fixture with plenty of *solved* cases to compare.
    final wpCount = lcg.next(4) == 0 ? 1 : 0;
    for (var w = 0; w < wpCount; w++) {
      final p = pick();
      if (p != start && p != target && !waypoints.contains(p)) {
        waypoints.add(p);
      }
    }

    // Extra balls exercise the multi-ball BFS. Kept to at most one so the
    // sweep stays quick.
    final extraBalls = <({Position start, Position target})>[];
    if (lcg.next(2) == 0) {
      final s = pick();
      final t = pick();
      if (s != start && s != target && t != start && t != target && s != t) {
        extraBalls.add((start: s, target: t));
      }
    }

    final strengthRoll = lcg.next(4);
    final int? strength = strengthRoll == 0 ? null : strengthRoll;
    final singleUse = lcg.next(3) == 0;

    final puzzle = Puzzle(
      id: built,
      size: size,
      start: start,
      target: target,
      walls: walls,
      waypoints: waypoints,
      deflectors: deflectors,
      extraBalls: extraBalls,
      plusBudget: 2,
      minusBudget: 2,
      magnetStrength: strength,
      magnetReach: 2 + lcg.next(size - 1),
      singleUse: singleUse,
    );

    final solver = Solver(puzzle, maxDepth: 5);
    final solution = solver.solve();

    // The scarcity measure the generator filters on. Only meaningful when a
    // solution exists.
    final count = solution == null
        ? 0
        : Solver(puzzle, maxDepth: 5).countMinimalSolutions(
            solution.magnetCount,
            cap: 4,
          );

    cases.add({
      'puzzle': {
        'id': built,
        'size': size,
        'start': pos(start),
        'target': pos(target),
        'walls': [for (final w in walls) pos(w)],
        'waypoints': [for (final w in waypoints) pos(w)],
        'deflectors': [
          for (final e in deflectors.entries)
            {...pos(e.key), 'd': e.value.name},
        ],
        'balls': [
          for (final b in extraBalls)
            {'start': pos(b.start), 'target': pos(b.target)},
        ],
        'budget': {'plus': puzzle.plusBudget, 'minus': puzzle.minusBudget},
        'magnet_strength': strength ?? -1,
        'magnet_reach': puzzle.magnetReach,
        'single_use': singleUse,
      },
      'solved': solution != null,
      'magnet_count': solution?.magnetCount ?? 0,
      'magnets': [
        for (final m in solution?.magnets ?? const <Magnet>[])
          {...pos(m.pos), 't': m.type.name},
      ],
      'sequence': solution?.sequence ?? const <int>[],
      'solution_count': count,
    });
    built++;
  }

  print(jsonEncode({'seed': 24680, 'cases': cases}));
}
