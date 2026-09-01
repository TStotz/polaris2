import 'dart:math';

import '../models/deflector.dart';
import '../models/magnet.dart';
import '../models/position.dart';
import '../models/puzzle.dart';
import 'movement.dart';
import 'solver.dart';

/// A generated puzzle plus its minimal solver solution (for difficulty display).
class GeneratedPuzzle {
  final Puzzle puzzle;
  final Solution solution;

  /// How many distinct minimal-magnet solutions the puzzle has (capped during
  /// generation). 1 = a unique solution, the hardest to find. A second
  /// difficulty axis next to the raw magnet count.
  final int solutionCount;

  const GeneratedPuzzle(this.puzzle, this.solution, {this.solutionCount = 0});

  int get difficulty => solution.magnetCount;
  String get difficultyText => difficultyLabel(difficulty);
}

/// How hard a generated puzzle should be.
///
/// Difficulty here is **how hard the solution is to find**, not just how big it
/// is. Three forces are stacked on top of the magnet count:
///
///  - finite [Puzzle.magnetStrength] + [Puzzle.singleUse] make a magnet a stepping
///    stone, so a distant target needs a *chain* of distinct magnets;
///  - a **tight budget** (exactly the magnets the solution uses) removes the
///    slack a player would otherwise brute-force with;
///  - **scarcity + detours**: candidates are filtered to those with at most
///    [maxSolutions] distinct minimal solutions and, for harder bands, a
///    *non-monotone* solution (the ball must retreat from the target at least
///    once). An open, monotone puzzle with dozens of interchangeable solutions
///    is trivial no matter how many magnets it needs.
///
/// The bands still map to a magnet count, but each is now genuinely a search:
///
///  - [easy]   — 2 magnets, up to 3 solutions, no forced detour ("Leicht").
///  - [medium] — 3 magnets, ≤2 solutions, must detour ("Mittel").
///  - [hard]   — 4+ magnets, ≤2 solutions, must detour ("Schwer").
///
/// Construction hints ([strength], [chain], wall counts) only *bias* generation;
/// the [Solver] is still the ground truth, so they affect how many tries are
/// needed, never correctness.
enum Difficulty {
  easy(
    label: '2',
    minMagnets: 2,
    maxMagnets: 2,
    strength: 2,
    chain: 2,
    minWalls: 8,
    extraWalls: 5,
    maxSolutions: 3,
    requireDetour: false,
  ),
  medium(
    label: '3',
    minMagnets: 3,
    maxMagnets: 3,
    strength: 2,
    chain: 3,
    minWalls: 9,
    extraWalls: 5,
    maxSolutions: 2,
    requireDetour: true,
  ),
  hard(
    label: '4+',
    minMagnets: 4,
    maxMagnets: 6,
    strength: 2,
    chain: 4,
    minWalls: 9,
    extraWalls: 5,
    maxSolutions: 2,
    requireDetour: true,
  );

  const Difficulty({
    required this.label,
    required this.minMagnets,
    required this.maxMagnets,
    required this.strength,
    required this.chain,
    required this.minWalls,
    required this.extraWalls,
    required this.maxSolutions,
    required this.requireDetour,
  });

  /// Short selector label — the band's target minimal magnet count.
  final String label;

  /// Accepted band for the solver's minimal magnet count, inclusive.
  final int minMagnets;
  final int maxMagnets;

  /// Magnet strength for this band (cells the ball travels per activation); see
  /// [Puzzle.magnetStrength].
  final int strength;

  /// How many stepping-stone magnets the construction tries to lay down.
  final int chain;

  /// Wall-count range scattered onto the board. Dense walls cut down the number
  /// of interchangeable solutions and force the ball around obstacles.
  final int minWalls;
  final int extraWalls;

  /// Reject candidates with more than this many distinct minimal solutions.
  final int maxSolutions;

  /// Require the minimal solution to make the ball retreat from the target at
  /// least once (a non-obvious "go away to come back" route).
  final bool requireDetour;

  /// Whether a candidate whose minimal solution uses [magnetCount] magnets is
  /// in this band.
  bool accepts(int magnetCount) =>
      magnetCount >= minMagnets && magnetCount <= maxMagnets;
}

/// Random puzzle generator (debug / "Practice" precursor).
///
/// Mirrors the content pipeline of §8: **construct → solve → verify**, then a
/// **difficulty filter** that keeps only puzzles whose solution is genuinely
/// hard to *find*:
///  1. Construct a config by a wandering *chain* of stepping-stone magnets on a
///     wall-dense board — solvable by construction, and (with finite range +
///     single-use) needing a chain of several magnets.
///  2. Solve to get the true minimal magnet count; keep only the requested
///     [Difficulty] band.
///  3. Optionally add *detour waypoints*: gems dropped on visited cells that the
///     bare solution skips, so collecting them strictly raises the magnet count.
///  4. Filter for findability: optionally require a non-monotone solution, tighten
///     the budget to exactly what the solution uses, then keep only candidates
///     with at most [Difficulty.maxSolutions] distinct minimal solutions.
///  5. Verify by replay — reach the target collecting every waypoint (§7).
class PuzzleGenerator {
  final Random _random;

  PuzzleGenerator([int? seed]) : _random = Random(seed);

  /// Returns a hard-to-solve puzzle of the requested [difficulty], or null if
  /// none was found within [tries].
  ///
  /// [tries] defaults high because the scarcity + detour filters reject most
  /// candidates (a deliberately hard puzzle is rare); easier bands still return
  /// after a handful of tries, so the high cap costs them nothing.
  GeneratedPuzzle? generate({
    Difficulty difficulty = Difficulty.medium,
    int size = 6,
    int maxRuns = 5,
    int plusBudget = 3,
    int minusBudget = 3,
    int waypoints = 0,
    int deflectors = 0,
    int balls = 1,
    int tries = 15000,
  }) {
    // Multiple balls use a construction path of their own (below); the tuned
    // single-ball pipeline stays untouched.
    if (balls > 1) {
      return _generateMultiBall(
        difficulty: difficulty,
        size: size,
        maxRuns: maxRuns,
        balls: balls,
        deflectors: deflectors,
        waypoints: waypoints,
        tries: tries,
      );
    }
    for (var t = 0; t < tries; t++) {
      final candidate = _construct(
        difficulty,
        size,
        maxRuns,
        plusBudget,
        minusBudget,
      );
      if (candidate == null) continue;
      var (base, touched) = candidate;

      // Sprinkle deflectors onto cells the ball crossed, then re-solve the new
      // board from scratch. They are kept only if a solution still exists and
      // actually routes through one (otherwise they'd be inert decoration).
      if (deflectors > 0) {
        final placed = _pickDeflectors(touched, deflectors);
        if (placed == null) continue; // not enough room
        base = _withDeflectors(base, placed);
        touched = touched.where((c) => !placed.containsKey(c)).toList();
      }

      // Solve the bare board (no waypoints) for the baseline difficulty.
      final baseSolution = Solver(base).solve();
      if (baseSolution == null) continue;
      if (deflectors > 0 && !_usesDeflector(base, baseSolution)) continue;

      // Add detour waypoints: drop them on visited-but-off-the-base-path cells
      // so collecting them strictly *raises* the magnet count.
      final Puzzle withWaypoints;
      final Solution solution;
      if (waypoints > 0) {
        final placed = _pickDetourWaypoints(
          base,
          baseSolution,
          touched,
          waypoints,
        );
        if (placed == null) continue; // not enough off-path room
        withWaypoints = _withWaypoints(base, placed);
        final s = Solver(withWaypoints).solve();
        if (s == null) continue;
        if (s.magnetCount <= baseSolution.magnetCount) continue; // no detour
        solution = s;
      } else {
        withWaypoints = base;
        solution = baseSolution;
      }

      if (!difficulty.accepts(solution.magnetCount)) continue; // wrong band

      // Cheap filter first: harder bands demand a non-monotone (retreating)
      // solution before we pay for the expensive solution count.
      if (difficulty.requireDetour &&
          !_isNonMonotone(withWaypoints, solution)) {
        continue;
      }

      // Tighten the budget to exactly what the solution uses — no slack to
      // brute-force with — then demand the solution be scarce on that board.
      final puzzle = _withTightBudget(withWaypoints, solution);
      final count = Solver(puzzle).countMinimalSolutions(
        solution.magnetCount,
        cap: difficulty.maxSolutions + 1,
      );
      if (count > difficulty.maxSolutions) continue;

      // Verify by replay (§7): reach the target collecting every waypoint.
      var ball = puzzle.start;
      final collected = {...puzzle.waypoints.where((w) => w == puzzle.start)};
      for (final mi in solution.sequence) {
        final from = ball;
        ball = activate(ball, solution.magnets[mi], solution.magnets, puzzle);
        for (final w in puzzle.waypoints) {
          if (onBallPath(w, from, ball)) collected.add(w);
        }
      }
      if (!puzzle.isTarget(ball)) continue;
      if (collected.length != puzzle.waypoints.length) continue;

      return GeneratedPuzzle(puzzle, solution, solutionCount: count);
    }
    return null;
  }

  /// Picks [count] waypoints from [touched], preferring cells the base solution
  /// does *not* pass through (so collecting them forces a detour). Returns null
  /// if there aren't enough candidates.
  List<Position>? _pickDetourWaypoints(
    Puzzle base,
    Solution baseSolution,
    List<Position> touched,
    int count,
  ) {
    if (touched.length < count) return null;
    final onPath = _solutionPath(base, baseSolution);
    final offPath = touched.where((c) => !onPath.contains(c)).toList()
      ..shuffle(_random);
    final onPathRest = touched.where((c) => onPath.contains(c)).toList()
      ..shuffle(_random);
    // Off-path cells first (likely detours), then on-path to make up the count.
    final ordered = [...offPath, ...onPathRest];
    if (ordered.length < count) return null;
    return ordered.take(count).toList();
  }

  /// The set of cells the ball touches while replaying [solution].
  Set<Position> _solutionPath(Puzzle puzzle, Solution solution) {
    final cells = <Position>{puzzle.start};
    var ball = puzzle.start;
    for (final mi in solution.sequence) {
      final from = ball;
      ball = activate(ball, solution.magnets[mi], solution.magnets, puzzle);
      for (var r = 0; r < puzzle.size; r++) {
        for (var c = 0; c < puzzle.size; c++) {
          final cell = Position(r, c);
          if (onBallPath(cell, from, ball)) cells.add(cell);
        }
      }
    }
    return cells;
  }

  Puzzle _withWaypoints(Puzzle p, List<Position> waypoints) => Puzzle(
    id: p.id,
    size: p.size,
    start: p.start,
    target: p.target,
    walls: p.walls,
    plusBudget: p.plusBudget,
    minusBudget: p.minusBudget,
    maxRuns: p.maxRuns,
    magnetStrength: p.magnetStrength,
    magnetReach: p.magnetReach,
    singleUse: p.singleUse,
    waypoints: waypoints,
    deflectors: p.deflectors,
    extraBalls: p.extraBalls,
  );

  /// Picks [count] cells the ball crossed and gives each a random orientation —
  /// deflector candidates that sit on the action path, so they are likely to
  /// matter. Returns null if there aren't enough cells.
  Map<Position, DeflectorDir>? _pickDeflectors(
    List<Position> touched,
    int count,
  ) {
    if (touched.length < count) return null;
    final cells = List.of(touched)..shuffle(_random);
    return {
      for (final c in cells.take(count))
        c: _random.nextBool() ? DeflectorDir.backslash : DeflectorDir.slash,
    };
  }

  Puzzle _withDeflectors(Puzzle p, Map<Position, DeflectorDir> deflectors) =>
      Puzzle(
        id: p.id,
        size: p.size,
        start: p.start,
        target: p.target,
        walls: p.walls,
        plusBudget: p.plusBudget,
        minusBudget: p.minusBudget,
        maxRuns: p.maxRuns,
        magnetStrength: p.magnetStrength,
        magnetReach: p.magnetReach,
        singleUse: p.singleUse,
        waypoints: p.waypoints,
        deflectors: deflectors,
        extraBalls: p.extraBalls,
      );

  /// Whether replaying [solution] ever sends the ball through a deflector — the
  /// guard that the deflectors genuinely route the solution rather than sitting
  /// inert off the path.
  bool _usesDeflector(Puzzle puzzle, Solution solution) {
    var ball = puzzle.start;
    for (final mi in solution.sequence) {
      final path = slidePath(
        ball,
        solution.magnets[mi],
        solution.magnets,
        puzzle,
      );
      if (path.any(puzzle.isDeflector)) return true;
      ball = path.last;
    }
    return false;
  }

  /// Whether [solution] ever moves the ball *away* from the target (Manhattan
  /// distance grows). A purely monotone solution is the obvious greedy one and
  /// makes for an easy puzzle.
  bool _isNonMonotone(Puzzle puzzle, Solution solution) {
    int dist(Position p) =>
        (p.row - puzzle.target.row).abs() + (p.col - puzzle.target.col).abs();
    var ball = puzzle.start;
    for (final mi in solution.sequence) {
      final from = ball;
      ball = activate(ball, solution.magnets[mi], solution.magnets, puzzle);
      if (dist(ball) > dist(from)) return true;
    }
    return false;
  }

  /// A copy of [puzzle] whose per-type budget is exactly the number of plus /
  /// minus magnets [solution] uses.
  Puzzle _withTightBudget(Puzzle puzzle, Solution solution) {
    var plus = 0, minus = 0;
    for (final m in solution.magnets) {
      if (m.isPlus) {
        plus++;
      } else {
        minus++;
      }
    }
    return Puzzle(
      id: puzzle.id,
      size: puzzle.size,
      start: puzzle.start,
      target: puzzle.target,
      walls: puzzle.walls,
      plusBudget: plus,
      minusBudget: minus,
      maxRuns: puzzle.maxRuns,
      magnetStrength: puzzle.magnetStrength,
      magnetReach: puzzle.magnetReach,
      singleUse: puzzle.singleUse,
      waypoints: puzzle.waypoints,
      deflectors: puzzle.deflectors,
      extraBalls: puzzle.extraBalls,
    );
  }

  /// Builds one candidate: the base puzzle (no waypoints) plus the cells the
  /// ball crossed while it was constructed (collectible waypoint candidates).
  (Puzzle, List<Position>)? _construct(
    Difficulty difficulty,
    int size,
    int maxRuns,
    int plusBudget,
    int minusBudget,
  ) {
    final strength = difficulty.strength;

    // 1. Walls.
    final walls = <Position>{};
    final wallCount =
        difficulty.minWalls + _random.nextInt(difficulty.extraWalls);
    while (walls.length < wallCount) {
      walls.add(Position(_random.nextInt(size), _random.nextInt(size)));
    }

    final freeCount = size * size - walls.length;
    if (freeCount < 10) return null;

    final free = <Position>[
      for (var r = 0; r < size; r++)
        for (var c = 0; c < size; c++)
          if (!walls.contains(Position(r, c))) Position(r, c),
    ];
    final start = free[_random.nextInt(free.length)];

    // The board the construction walk runs on (single-use + finite range so the
    // walk obeys the same rules the player and solver will).
    final board = Puzzle(
      id: 0,
      size: size,
      start: start,
      target: start,
      walls: walls,
      plusBudget: plusBudget,
      minusBudget: minusBudget,
      maxRuns: maxRuns,
      magnetStrength: strength,
      magnetReach: size - 1,
      singleUse: true,
    );

    final magnets = <Magnet>[];
    final occupied = <Position>{};
    final touched =
        <Position>{}; // cells the ball crosses → waypoint candidates
    var plus = 0, minus = 0;
    var ball = start;

    bool freeCell(Position p) =>
        board.inBounds(p) &&
        !walls.contains(p) &&
        !occupied.contains(p) &&
        p != start;

    // 2. Lay a stepping-stone chain, wandering in any direction (not straight
    //    at a corner) so the path winds and the target can end up needing a
    //    detour. Each magnet moves the ball exactly [range] cells: a PLUS just
    //    beyond the landing cell (pulls), or a MINUS just behind the ball
    //    (pushes). Every magnet is distinct, so under single-use the solution is
    //    a genuine chain.
    const directions = [
      [1, 0],
      [-1, 0],
      [0, 1],
      [0, -1],
    ];

    var attempts = 0;
    while (magnets.length < difficulty.chain &&
        attempts < difficulty.chain * 12) {
      attempts++;
      final dirs = List.of(directions)..shuffle(_random);
      var moved = false;
      for (final d in dirs) {
        final dr = d[0], dc = d[1];

        // Every cell the ball crosses must be clear.
        var clear = true;
        for (var k = 1; k <= strength; k++) {
          if (!freeCell(Position(ball.row + dr * k, ball.col + dc * k))) {
            clear = false;
            break;
          }
        }
        if (!clear) continue;

        final landing = Position(
          ball.row + dr * strength,
          ball.col + dc * strength,
        );
        final aheadPlus = Position(
          ball.row + dr * (strength + 1),
          ball.col + dc * (strength + 1),
        );
        final behindMinus = Position(ball.row - dr, ball.col - dc);

        Magnet? chosen;
        if (plus < plusBudget && freeCell(aheadPlus)) {
          chosen = Magnet(aheadPlus, MagnetType.plus);
        } else if (minus < minusBudget && freeCell(behindMinus)) {
          chosen = Magnet(behindMinus, MagnetType.minus);
        }
        if (chosen == null) continue;

        // Confirm the magnet actually lands the ball where we planned.
        if (activate(ball, chosen, [...magnets, chosen], board) != landing) {
          continue;
        }
        magnets.add(chosen);
        occupied.add(chosen.pos);
        if (chosen.isPlus) {
          plus++;
        } else {
          minus++;
        }
        for (var k = 1; k <= strength; k++) {
          touched.add(Position(ball.row + dr * k, ball.col + dc * k));
        }
        ball = landing;
        moved = true;
        break;
      }
      if (!moved) break; // boxed in
    }

    final target = ball;
    if (magnets.length < 2 || target == start) return null;

    final base = Puzzle(
      id: 100 + _random.nextInt(900),
      size: size,
      start: start,
      target: target,
      walls: walls,
      plusBudget: plusBudget,
      minusBudget: minusBudget,
      maxRuns: maxRuns,
      magnetStrength: strength,
      magnetReach: size - 1,
      singleUse: true,
    );

    // Cells the ball actually crossed (minus the target / magnet cells) are the
    // collectible-by-construction candidates for waypoints.
    final candidates = touched
        .where((p) => p != target && !occupied.contains(p))
        .toList();
    return (base, candidates);
  }

  // --- Multi-ball generation ------------------------------------------------

  /// Generates a solvable multi-ball puzzle by *construction*: it walks the
  /// balls with random activations (so a solving sequence exists by design),
  /// sets each ball's final cell as its target, then lets the solver measure the
  /// true minimal difficulty. Construction keeps the solver fast (a solution
  /// always exists) and lets deflectors and waypoints compose cleanly.
  GeneratedPuzzle? _generateMultiBall({
    required Difficulty difficulty,
    required int size,
    required int maxRuns,
    required int balls,
    required int deflectors,
    required int waypoints,
    required int tries,
  }) {
    // Multi-ball difficulty scales with the ball count, so it uses its own knobs
    // rather than the single-ball magnet bands: [difficulty] just nudges how far
    // the balls are walked (and thus the minimal magnet count).
    final extra = difficulty.index; // easy 0, medium 1, hard 2

    for (var t = 0; t < tries; t++) {
      final moves = balls + extra + _random.nextInt(2);
      final built = _constructMultiBall(
        size,
        maxRuns,
        balls,
        deflectors,
        moves,
      );
      if (built == null) continue;
      var (puzzle, touched, walkMagnets) = built;

      if (waypoints > 0) {
        final cands = touched.where(puzzle.isPlaceable).toList()
          ..shuffle(_random);
        if (cands.length < waypoints) continue;
        puzzle = _withWaypoints(puzzle, cands.take(waypoints).toList());
      }

      // The construction *is* a verified solution: each distinct magnet fired
      // once, in order. Use it directly — running the full minimal solver here
      // would be far too slow for 3 balls (huge BFS state) and froze the UI.
      final solution = Solution(
        magnets: walkMagnets,
        sequence: List<int>.generate(walkMagnets.length, (i) => i),
        magnetCount: walkMagnets.length,
        checked: 0,
      );
      if (solution.activationCount < 2) continue; // avoid trivial one-move wins
      if (deflectors > 0 && !_usesDeflectorMulti(puzzle, solution)) continue;
      if (!_replayMultiReaches(puzzle, solution)) continue;

      // Tighten the budget to exactly what the solution uses (like single-ball).
      return GeneratedPuzzle(_withTightBudget(puzzle, solution), solution);
    }
    return null;
  }

  /// One construction attempt: light walls + deflectors, [balls] random starts,
  /// then random activations until several balls have moved. Returns the base
  /// puzzle (targets = final positions), the cells the balls crossed (waypoint
  /// candidates), and the exact magnets+order that solves it — so the caller can
  /// use that as a verified solution without paying for the (expensive) solver.
  /// Null on a dud layout.
  (Puzzle, List<Position>, List<Magnet>)? _constructMultiBall(
    int size,
    int maxRuns,
    int balls,
    int deflectors,
    int moves,
  ) {
    final walls = <Position>{};
    final wallCount = _random.nextInt(
      size,
    ); // kept light so balls can be routed
    while (walls.length < wallCount) {
      walls.add(Position(_random.nextInt(size), _random.nextInt(size)));
    }

    final free = <Position>[
      for (var r = 0; r < size; r++)
        for (var c = 0; c < size; c++)
          if (!walls.contains(Position(r, c))) Position(r, c),
    ]..shuffle(_random);
    if (free.length < balls * 2 + deflectors + 4) return null;

    var idx = 0;
    final starts = [for (var i = 0; i < balls; i++) free[idx++]];
    final deflectorMap = <Position, DeflectorDir>{
      for (var i = 0; i < deflectors; i++)
        free[idx++]: _random.nextBool()
            ? DeflectorDir.backslash
            : DeflectorDir.slash,
    };

    // The board the walk runs on: board-wide reach, unlimited strength.
    final board = Puzzle(
      id: 0,
      size: size,
      start: starts[0],
      target: starts[0],
      extraBalls: [
        for (var i = 1; i < balls; i++) (start: starts[i], target: starts[i]),
      ],
      walls: walls,
      deflectors: deflectorMap,
      magnetReach: size - 1,
      plusBudget: 9,
      minusBudget: 9,
    );

    var positions = List.of(starts);
    final touched = <Position>{...starts};
    final usedCells = <Position>{}; // distinct construction magnet cells
    final walkMagnets = <Magnet>[]; // the solving sequence, in order
    final steps = moves < 2 ? 2 : moves;
    var attempts = 0;
    while (usedCells.length < steps && attempts < steps * 12) {
      attempts++;
      final cell = free[_random.nextInt(free.length)];
      // Never place on a ball, a reused cell, a ball's start, or a deflector —
      // the magnet must stay placeable in the finished puzzle.
      if (positions.contains(cell) ||
          usedCells.contains(cell) ||
          starts.contains(cell) ||
          deflectorMap.containsKey(cell)) {
        continue;
      }
      final magnet = Magnet(
        cell,
        _random.nextBool() ? MagnetType.plus : MagnetType.minus,
      );
      final paths = activateAllPaths(positions, magnet, [magnet], board);
      final next = [for (final p in paths) p.last];
      if (_samePositions(next, positions)) continue; // nothing moved
      for (final p in paths) {
        touched.addAll(p);
      }
      usedCells.add(cell);
      walkMagnets.add(magnet);
      positions = next;
    }
    if (usedCells.length < 2) return null;

    final targets = positions;
    // Reject degenerate layouts: a ball still on its start, duplicate targets, or
    // a target on a deflector tile.
    if (targets.toSet().length != targets.length) return null;
    for (var i = 0; i < balls; i++) {
      if (targets[i] == starts[i]) return null;
      if (deflectorMap.containsKey(targets[i])) return null;
    }
    // A construction magnet landing on a final target would be unplaceable, so
    // the constructed solution couldn't be reproduced — drop the layout.
    for (final c in usedCells) {
      if (targets.contains(c)) return null;
    }

    final puzzle = Puzzle(
      id: 400 + _random.nextInt(600),
      size: size,
      start: starts[0],
      target: targets[0],
      extraBalls: [
        for (var i = 1; i < balls; i++) (start: starts[i], target: targets[i]),
      ],
      walls: walls,
      deflectors: deflectorMap,
      magnetReach: size - 1,
      plusBudget: balls + 3,
      minusBudget: balls + 3,
      maxRuns: maxRuns,
    );

    final candidates = touched
        .where((p) => !starts.contains(p) && !targets.contains(p))
        .toList();
    return (puzzle, candidates, walkMagnets);
  }

  /// Replays [solution] on a multi-ball [puzzle]; true iff every ball lands on
  /// its target and every waypoint is collected on the way.
  bool _replayMultiReaches(Puzzle puzzle, Solution solution) {
    var balls = puzzle.ballStarts;
    final collected = <Position>{
      ...puzzle.waypoints.where(puzzle.ballStarts.contains),
    };
    for (final mi in solution.sequence) {
      final paths = activateAllPaths(
        balls,
        solution.magnets[mi],
        solution.magnets,
        puzzle,
      );
      for (final w in puzzle.waypoints) {
        if (paths.any((p) => p.contains(w))) collected.add(w);
      }
      balls = [for (final p in paths) p.last];
    }
    final targets = puzzle.ballTargets;
    for (var i = 0; i < balls.length; i++) {
      if (balls[i] != targets[i]) return false;
    }
    return collected.length == puzzle.waypoints.length;
  }

  /// Whether replaying [solution] ever routes any ball through a deflector.
  bool _usesDeflectorMulti(Puzzle puzzle, Solution solution) {
    var balls = puzzle.ballStarts;
    for (final mi in solution.sequence) {
      final paths = activateAllPaths(
        balls,
        solution.magnets[mi],
        solution.magnets,
        puzzle,
      );
      for (final p in paths) {
        if (p.any(puzzle.isDeflector)) return true;
      }
      balls = [for (final p in paths) p.last];
    }
    return false;
  }

  static bool _samePositions(List<Position> a, List<Position> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
