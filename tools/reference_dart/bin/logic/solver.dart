import '../models/magnet.dart';
import '../models/position.dart';
import '../models/puzzle.dart';
import 'movement.dart';

/// A solution found by the [Solver].
///
/// [magnets] is the placement; [sequence] is the activation order as indices
/// into [magnets] (the same magnet may appear more than once — repeated
/// activation is allowed, Variante 1). [magnetCount] is the objective
/// difficulty measure (§7).
class Solution {
  final List<Magnet> magnets;
  final List<int> sequence;
  final int magnetCount;
  final int checked;

  const Solution({
    required this.magnets,
    required this.sequence,
    required this.magnetCount,
    required this.checked,
  });

  int get activationCount => sequence.length;
}

/// Searches over magnet *sets* (placement + type) AND activation *sequences*,
/// returning the solution with the fewest magnets.
///
/// Faithful port of the prototype solver (§7). Complete and correct only within
/// its search space (budget + [maxDepth]); beyond that it reports "unsolvable".
/// In the content pipeline this must be used as a *filter*, never an oracle:
/// only ship a puzzle whose solution was actually replayed and verified.
class Solver {
  final Puzzle puzzle;
  final int maxDepth;

  /// Optional cap on the magnet count the search will consider. When set, the
  /// solver gives up (returns null) instead of looking for solutions that need
  /// more than [magnetCap] magnets — the escape hatch that keeps generation fast:
  /// a board whose minimal solution exceeds the target band is rejected cheaply
  /// rather than proven expensive. Null = search the full budget.
  final int? magnetCap;

  int _checked = 0;

  Solver(this.puzzle, {this.maxDepth = 8, this.magnetCap});

  Solution? solve() {
    _checked = 0;

    final cells = _placeableCells();
    var maxMagnets = puzzle.plusBudget + puzzle.minusBudget;
    if (magnetCap != null && magnetCap! < maxMagnets) maxMagnets = magnetCap!;

    // Iterative deepening over magnet count → fewest magnets wins.
    for (var n = 1; n <= maxMagnets; n++) {
      final result = _chooseN(cells, n, <Magnet>[], 0);
      if (result != null) {
        return Solution(
          magnets: result.$1,
          sequence: result.$2,
          magnetCount: n,
          checked: _checked,
        );
      }
    }
    return null;
  }

  /// Counts distinct [n]-magnet placements that solve the puzzle, stopping once
  /// [cap] is reached. A *difficulty proxy*: the fewer minimal solutions a
  /// puzzle has, the harder it is to find one (a unique solution is the
  /// hardest). Call with `n = solution.magnetCount` from a prior [solve].
  int countMinimalSolutions(int n, {int cap = 8}) {
    final cells = _placeableCells();
    var count = 0;
    final acc = <Magnet>[];

    bool recurse(int start) {
      if (acc.length == n) {
        var plus = 0, minus = 0;
        for (final m in acc) {
          if (m.isPlus) {
            plus++;
          } else {
            minus++;
          }
        }
        if (plus > puzzle.plusBudget || minus > puzzle.minusBudget) {
          return false;
        }
        if (_findSequence(acc) != null) {
          count++;
          if (count >= cap) return true; // enough; stop early
        }
        return false;
      }
      for (var i = start; i < cells.length; i++) {
        for (final type in MagnetType.values) {
          acc.add(Magnet(cells[i], type));
          if (recurse(i + 1)) return true;
          acc.removeLast();
        }
      }
      return false;
    }

    recurse(0);
    return count;
  }

  List<Position> _placeableCells() => <Position>[
    for (var r = 0; r < puzzle.size; r++)
      for (var c = 0; c < puzzle.size; c++)
        if (puzzle.isPlaceable(Position(r, c))) Position(r, c),
  ];

  /// Backtracking choice of [n] magnets from [pool]; on a complete set, runs a
  /// BFS over activation sequences. Returns (magnets, sequence) or null.
  (List<Magnet>, List<int>)? _chooseN(
    List<Position> pool,
    int n,
    List<Magnet> acc,
    int start,
  ) {
    if (acc.length == n) {
      var plus = 0, minus = 0;
      for (final m in acc) {
        if (m.isPlus) {
          plus++;
        } else {
          minus++;
        }
      }
      if (plus > puzzle.plusBudget || minus > puzzle.minusBudget) return null;

      _checked++;
      final seq = _findSequence(acc);
      if (seq != null) return (List<Magnet>.from(acc), seq);
      return null;
    }

    for (var i = start; i < pool.length; i++) {
      for (final type in MagnetType.values) {
        acc.add(Magnet(pool[i], type));
        final found = _chooseN(pool, n, acc, i + 1);
        if (found != null) return found;
        acc.removeLast();
      }
    }
    return null;
  }

  /// BFS over activation sequences for a fixed magnet set.
  /// State = ball position, action = activating one magnet.
  ///
  /// The state grows with the puzzle's rules:
  ///  - [Puzzle.singleUse] adds a bitmask of spent magnets (a magnet fires once,
  ///    so the same cell reached with different magnets left is a new state);
  ///  - [Puzzle.waypoints] add a bitmask of collected waypoints (the goal is
  ///    reached only once every waypoint is collected).
  /// With neither, the position alone identifies the state (Variante 1).
  List<int>? _findSequence(List<Magnet> magnetSet) {
    if (puzzle.isMultiBall) return _findSequenceMulti(magnetSet);

    final singleUse = puzzle.singleUse;
    final wps = puzzle.waypoints;
    final hasWp = wps.isNotEmpty;
    final allWp = (1 << wps.length) - 1; // 0 when there are no waypoints
    // Plates change which cells are solid, so the board a move is judged
    // against is part of the search state, not a constant.
    final hasPlates = puzzle.plates.isNotEmpty;
    final needsPath = hasWp || hasPlates;

    // A single-use sequence can be no longer than the number of magnets.
    final maxLen = singleUse ? magnetSet.length : maxDepth;

    int collectAlongPath(List<Position> path, int mask) {
      var m = mask;
      for (var i = 0; i < wps.length; i++) {
        if ((m & (1 << i)) == 0 && path.contains(wps[i])) m |= (1 << i);
      }
      return m;
    }

    // A waypoint already on the start cell is collected before the first move.
    var startCollected = 0;
    for (var i = 0; i < wps.length; i++) {
      if (wps[i] == puzzle.start) startCollected |= (1 << i);
    }

    Object keyOf(Position p, int used, int collected, int gates) =>
        (p, used, collected, gates);

    final visited = <Object>{keyOf(puzzle.start, 0, startCollected, 0)};
    var frontier = <_Node>[_Node(puzzle.start, const [], 0, startCollected, 0)];

    for (var depth = 0; depth < maxLen; depth++) {
      final next = <_Node>[];
      for (final node in frontier) {
        for (var mi = 0; mi < magnetSet.length; mi++) {
          if (singleUse && (node.used & (1 << mi)) != 0) continue; // spent
          // With waypoints, walk the real (possibly deflected) path so a
          // waypoint is collected iff the ball actually crosses it.
          final Position np;
          var collected = 0;
          var gates = node.gates;
          if (needsPath) {
            final path = slidePath(
              node.pos,
              magnetSet[mi],
              magnetSet,
              puzzle,
              node.gates,
            );
            np = path.last;
            if (np == node.pos) continue; // no movement → useless action
            if (hasWp) collected = collectAlongPath(path, node.collected);
            // Plates flip only once the slide has fully resolved.
            gates = node.gates ^ puzzle.platesToggledBy([path]);
          } else {
            np = activate(node.pos, magnetSet[mi], magnetSet, puzzle, node.gates);
            if (np == node.pos) continue; // no movement → useless action
          }
          final seq = [...node.seq, mi];
          if (puzzle.isTarget(np) && collected == allWp) return seq;
          final used = singleUse ? (node.used | (1 << mi)) : 0;
          final key = keyOf(np, used, collected, gates);
          if (visited.add(key)) next.add(_Node(np, seq, used, collected, gates));
        }
      }
      frontier = next;
      if (frontier.isEmpty) break;
    }
    return null;
  }

  /// BFS over activation sequences for a multi-ball puzzle. State = the tuple of
  /// all ball positions, plus a spent-magnet mask (single-use) and a collected-
  /// waypoint mask (when the puzzle has waypoints). The goal is reached only when
  /// **every** ball rests on its own target *and* every waypoint has been
  /// collected — a waypoint counts as collected the moment any ball crosses it.
  /// Uses the same [activateAll] / [activateAllPaths] the live game uses, so
  /// solver and game stay in lock-step.
  List<int>? _findSequenceMulti(List<Magnet> magnetSet) {
    final singleUse = puzzle.singleUse;
    final targets = puzzle.ballTargets;
    final wps = puzzle.waypoints;
    final hasWp = wps.isNotEmpty;
    final allWp = (1 << wps.length) - 1; // 0 when there are no waypoints
    final needsPath = hasWp || puzzle.plates.isNotEmpty;
    final maxLen = singleUse ? magnetSet.length : maxDepth;

    bool ballsHome(List<Position> pos) {
      for (var i = 0; i < pos.length; i++) {
        if (pos[i] != targets[i]) return false;
      }
      return true;
    }

    // Fold every waypoint any ball crossed on these paths into the mask.
    int collectAlong(List<List<Position>> paths, int mask) {
      var m = mask;
      for (var i = 0; i < wps.length; i++) {
        if ((m & (1 << i)) != 0) continue;
        for (final path in paths) {
          if (path.contains(wps[i])) {
            m |= (1 << i);
            break;
          }
        }
      }
      return m;
    }

    String keyOf(List<Position> pos, int used, int collected, int gates) {
      final sb = StringBuffer();
      for (final p in pos) {
        sb
          ..write(p.row)
          ..write(',')
          ..write(p.col)
          ..write(';');
      }
      sb
        ..write('|')
        ..write(used)
        ..write('|')
        ..write(collected)
        ..write('|')
        ..write(gates);
      return sb.toString();
    }

    // Waypoints already sitting on a ball's start are collected up front.
    final startPos = puzzle.ballStarts;
    var startCollected = 0;
    for (var i = 0; i < wps.length; i++) {
      if (startPos.contains(wps[i])) startCollected |= (1 << i);
    }
    if (ballsHome(startPos) && startCollected == allWp) return const [];

    final visited = <String>{keyOf(startPos, 0, startCollected, 0)};
    var frontier = <_MNode>[_MNode(startPos, const [], 0, startCollected, 0)];

    for (var depth = 0; depth < maxLen; depth++) {
      final next = <_MNode>[];
      for (final node in frontier) {
        for (var mi = 0; mi < magnetSet.length; mi++) {
          if (singleUse && (node.used & (1 << mi)) != 0) continue; // spent
          final List<Position> np;
          var collected = 0;
          var gates = node.gates;
          if (needsPath) {
            final paths = activateAllPaths(
              node.pos,
              magnetSet[mi],
              magnetSet,
              puzzle,
              node.gates,
            );
            np = [for (final p in paths) p.last];
            if (hasWp) collected = collectAlong(paths, node.collected);
            gates = node.gates ^ puzzle.platesToggledBy(paths);
          } else {
            np = activateAll(
              node.pos,
              magnetSet[mi],
              magnetSet,
              puzzle,
              node.gates,
            );
          }
          if (_samePositions(np, node.pos)) continue; // no movement → useless
          final seq = [...node.seq, mi];
          if (ballsHome(np) && collected == allWp) return seq;
          final used = singleUse ? (node.used | (1 << mi)) : 0;
          final key = keyOf(np, used, collected, gates);
          if (visited.add(key)) next.add(_MNode(np, seq, used, collected, gates));
        }
      }
      frontier = next;
      if (frontier.isEmpty) break;
    }
    return null;
  }

  static bool _samePositions(List<Position> a, List<Position> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

class _Node {
  final Position pos;
  final List<int> seq;
  final int used; // bitmask of spent magnets (single-use only)
  final int collected; // bitmask of collected waypoints
  final int gates; // bitmask of toggled gate channels
  const _Node(this.pos, this.seq, this.used, this.collected, this.gates);
}

class _MNode {
  final List<Position> pos; // one entry per ball, index-aligned with targets
  final List<int> seq;
  final int used; // bitmask of spent magnets (single-use only)
  final int collected; // bitmask of collected waypoints
  final int gates; // bitmask of toggled gate channels
  const _MNode(this.pos, this.seq, this.used, this.collected, this.gates);
}

/// Human-readable difficulty derived from the minimal magnet count (§7).
String difficultyLabel(int? count) {
  if (count == null) return 'Ungelöst';
  if (count <= 1) return 'Sehr leicht';
  if (count == 2) return 'Leicht';
  if (count == 3) return 'Mittel';
  if (count == 4) return 'Schwer';
  return 'Sehr schwer';
}
