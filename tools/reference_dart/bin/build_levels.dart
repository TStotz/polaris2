// Bakes the campaign level pack for the Godot game.
//
// Runs the pinned Dart `PuzzleGenerator` — construct -> solve -> verify -> filter
// (see POLARIS_CONTEXT §8) — and writes every accepted puzzle, together with the
// minimal solution the solver found, to `res://data/levels.json`.
//
// Why offline: generation is deliberately expensive (most candidates are thrown
// away) and GDScript runs the exhaustive placement search several times slower
// than Dart. A Steam player should start a level instantly, not watch a spinner
// while their CPU searches. Baking also means every shipped level is
// solver-verified and has a stable id — the thing achievements and level select
// need to lean on.
//
//   dart run bin/build_levels.dart > ../../data/levels.json

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'logic/generator.dart';
import 'logic/movement.dart';
import 'logic/solver.dart';
import 'models/gate.dart';
import 'models/position.dart';
import 'models/puzzle.dart';

/// One chapter of the campaign: a name, the mechanics it introduces, and the
/// generator knobs that produce its levels.
class Chapter {
  final String id;
  final String title;

  /// One line shown when the chapter is unlocked — what the player is about to
  /// learn.
  final String intro;
  final int count;
  final Difficulty difficulty;
  final int size;
  final int waypoints;
  final int deflectors;
  final int balls;

  /// Floor on the magnet count for chapters that re-solve their candidates
  /// ([unlimitedStrength]).
  ///
  /// Switch chapters keep this low on purpose: the gate is added *after* the
  /// re-solve and raises the count itself, so demanding a hard board before the
  /// gate exists rejects exactly the candidates the gate would have made hard.
  final int minMagnets;

  /// Spare magnets of each type on top of what the solution needs.
  ///
  /// Tightening the budget to exactly the solution was meant to remove the slack
  /// a player could brute-force with. It did the opposite: a board labelled
  /// "Anziehen x2, Abstossen x0" has already told you the answer is two magnets
  /// and both of them pull. Every level in the first shipped campaign leaked its
  /// own solution that way.
  ///
  /// With slack the composition is a real question again, and the star rating
  /// still rewards the tight answer — solving it sloppily just costs stars
  /// instead of being impossible.
  final int budgetSlack;

  /// How many gates to fit onto the board, each with its own plate and channel.
  ///
  /// Zero for every chapter that predates the mechanic.
  final int switches;

  /// Re-solve the candidate with **unlimited** magnet strength before judging it.
  ///
  /// The difficulty bands hard-code `strength: 2`, and the slide rule applies the
  /// strength cap *before* it looks for a deflector — so a ball that has already
  /// spent its two cells stops dead on the tile instead of turning. At strength 2
  /// a visible bend needs the deflector to sit exactly one cell away, which random
  /// placement almost never produces: the first bake of the "Deflektoren" chapter
  /// contained fourteen levels and not one of them bent the ball.
  ///
  /// Letting the ball roll the full line is what the mechanic is *for*, so this
  /// chapter rebuilds each candidate uncapped and asks the solver again. The
  /// solver stays the ground truth; only the board it judges changed.
  final bool unlimitedStrength;

  /// Reject a candidate whose board is more than this fraction walls.
  ///
  /// The generator scatters a fixed *count* of walls (8–13) regardless of board
  /// size, which was tuned for 6×6. Left alone it buries a small board — the
  /// first shipped level came out 13 walls on 25 cells, which reads as rubble
  /// rather than a puzzle. Density is a presentation decision, so it is filtered
  /// here rather than by patching the pinned generator.
  final double maxWallRatio;

  const Chapter({
    required this.id,
    required this.title,
    required this.intro,
    required this.count,
    required this.difficulty,
    this.size = 6,
    this.waypoints = 0,
    this.deflectors = 0,
    this.balls = 1,
    this.maxWallRatio = 0.3,
    this.unlimitedStrength = false,
    this.switches = 0,
    this.budgetSlack = 1,
    this.minMagnets = 3,
  });
}

/// Rebuilds [puzzle] with unlimited magnet strength and a roomy budget, re-solves
/// it, and returns the accepted level as `(puzzle, solution)` — or null when the
/// uncapped board has no solution, needs an unreasonable number of magnets, or
/// still fails to put the deflector to work.
///
/// The returned puzzle's budget is tightened back to exactly what the new
/// solution uses, so the player gets no slack to brute-force with.
(Puzzle, Solution)? uncap(Puzzle puzzle, {int minMagnets = 2, int maxMagnets = 4}) {
  Puzzle rebuild({required int plus, required int minus}) => Puzzle(
    id: puzzle.id,
    size: puzzle.size,
    start: puzzle.start,
    target: puzzle.target,
    walls: puzzle.walls,
    waypoints: puzzle.waypoints,
    deflectors: puzzle.deflectors,
    extraBalls: puzzle.extraBalls,
    plusBudget: plus,
    minusBudget: minus,
    maxRuns: puzzle.maxRuns,
    magnetStrength: null, // the whole point
    magnetReach: puzzle.magnetReach,
    singleUse: puzzle.singleUse,
  );

  // Solve with room to breathe, then tighten to what the answer actually used.
  final open = rebuild(plus: 3, minus: 3);
  final solution = Solver(open, magnetCap: maxMagnets).solve();
  if (solution == null) return null;
  if (solution.magnetCount < minMagnets) return null;

  var plus = 0, minus = 0;
  for (final m in solution.magnets) {
    if (m.isPlus) {
      plus++;
    } else {
      minus++;
    }
  }
  final tight = rebuild(plus: plus, minus: minus);
  if (!replayWins(tight, solution)) return null;
  return (tight, solution);
}

/// The cells crossed on each activation, in order — one entry per move.
List<Set<Position>> cellsPerMove(Puzzle puzzle, Solution solution) {
  final perMove = <Set<Position>>[];
  var balls = puzzle.ballStarts;
  var gates = 0;
  for (final index in solution.sequence) {
    final paths = activateAllPaths(
      balls,
      solution.magnets[index],
      solution.magnets,
      puzzle,
      gates,
    );
    final touched = <Position>{};
    for (final path in paths) {
      touched.addAll(path);
    }
    perMove.add(touched);
    gates ^= puzzle.platesToggledBy(paths);
    balls = [for (final path in paths) path.last];
  }
  return perMove;
}

/// Turns a solved board into a switch puzzle, or returns null.
///
/// Built rather than guessed. An earlier version dropped the gate on the
/// solution's route and the plate on a random free cell, then hoped some new
/// route existed that pressed the plate first — out of 110 candidates it found
/// exactly zero. So instead:
///
///  - the **gate** goes on a cell the ball crosses on some move `k`;
///  - the **plate** goes on a cell it crossed on an *earlier* move.
///
/// The existing solution therefore still works unchanged — it presses the plate
/// before it ever reaches the gate — which makes solvability a near certainty
/// instead of a lottery. What is still checked, not assumed, is the half that
/// matters: with the plates inert, the board must be impossible.
final switchRejects = <String, int>{};

void reject(String reason) =>
    switchRejects[reason] = (switchRejects[reason] ?? 0) + 1;

(Puzzle, Solution)? withSwitches(
  Puzzle puzzle,
  Solution solution,
  Random rng,
  int count,
) {
  final perMove = cellsPerMove(puzzle, solution);
  if (perMove.length < 2) {
    reject('solution has fewer than two moves');
    return null;
  }

  bool usable(Position c) =>
      puzzle.isPlaceable(c) &&
      !puzzle.ballStarts.contains(c) &&
      !puzzle.ballTargets.contains(c);

  final gates = <Position, Gate>{};
  final plates = <Position, int>{};
  final taken = <Position>{};

  for (var channel = 0; channel < count; channel++) {
    // Try the moves from the back: a gate late in the route leaves the most room
    // for a plate before it, and breaks the most of the route when shut.
    Position? gateCell;
    Position? plateCell;
    for (var k = perMove.length - 1; k >= 1 && gateCell == null; k--) {
      final gateChoices = perMove[k]
          .where((c) => usable(c) && !taken.contains(c))
          .toList()
        ..shuffle(rng);
      if (gateChoices.isEmpty) continue;

      final earlier = <Position>{};
      for (var j = 0; j < k; j++) {
        earlier.addAll(perMove[j]);
      }
      for (final candidate in gateChoices) {
        final plateChoices = earlier
            .where((c) => usable(c) && !taken.contains(c) && c != candidate)
            .toList()
          ..shuffle(rng);
        if (plateChoices.isEmpty) continue;
        gateCell = candidate;
        plateCell = plateChoices.first;
        break;
      }
    }
    if (gateCell == null || plateCell == null) {
      reject('no gate cell with a usable plate cell before it');
      return null;
    }
    taken..add(gateCell)..add(plateCell);
    gates[gateCell] = Gate(channel);
    plates[plateCell] = channel;
  }

  Puzzle rebuild({
    required Map<Position, int> withPlates,
    required int plus,
    required int minus,
  }) => Puzzle(
    id: puzzle.id,
    size: puzzle.size,
    start: puzzle.start,
    target: puzzle.target,
    walls: puzzle.walls,
    waypoints: puzzle.waypoints,
    deflectors: puzzle.deflectors,
    extraBalls: puzzle.extraBalls,
    plates: withPlates,
    gates: gates,
    plusBudget: plus,
    minusBudget: minus,
    maxRuns: puzzle.maxRuns,
    magnetStrength: puzzle.magnetStrength,
    magnetReach: puzzle.magnetReach,
    singleUse: puzzle.singleUse,
  );

  // Cap at three magnets. The exhaustive placement search grows as
  // C(cells, n)·2^n, so a fourth magnet on a 6x6 board multiplies the work by
  // more than ten — and this runs twice per candidate.
  const cap = 4;
  final board = rebuild(withPlates: plates, plus: 3, minus: 3);
  final found = Solver(board, magnetCap: cap).solve();
  if (found == null) {
    reject('gated board unsolvable within $cap magnets');
    return null;
  }
  if (found.magnetCount < 3) {
    reject('gated board still solvable with ${found.magnetCount} magnets');
    return null;
  }

  var plus = 0, minus = 0;
  for (final m in found.magnets) {
    if (m.isPlus) {
      plus++;
    } else {
      minus++;
    }
  }
  final tight = rebuild(withPlates: plates, plus: plus, minus: minus);
  if (!replayWins(tight, found)) {
    reject('solution fails to replay on the tightened board');
    return null;
  }

  // The whole point: with the plates inert the gates never move, and the board
  // must then be impossible. Otherwise the switch is scenery.
  //
  // The proof runs on the *tightened* board and is capped at its own budget,
  // which is not a weakening — the player cannot place more magnets than the
  // budget allows, so "unsolvable within the budget" is exactly "unsolvable".
  final frozen = rebuild(withPlates: const {}, plus: plus, minus: minus);
  if (Solver(frozen, magnetCap: plus + minus).solve() != null) {
    reject('still solvable with the plates inert — the switch is scenery');
    return null;
  }

  return (tight, found);
}

/// A copy of [puzzle] whose budget is the solution's magnet count plus
/// [slack] of each type, with at least one of each so both tools are always on
/// the palette.
Puzzle widenBudget(Puzzle puzzle, Solution solution, int slack) {
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
    waypoints: puzzle.waypoints,
    deflectors: puzzle.deflectors,
    extraBalls: puzzle.extraBalls,
    plates: puzzle.plates,
    gates: puzzle.gates,
    plusBudget: plus + slack < 1 ? 1 : plus + slack,
    minusBudget: minus + slack < 1 ? 1 : minus + slack,
    maxRuns: puzzle.maxRuns,
    magnetStrength: puzzle.magnetStrength,
    magnetReach: puzzle.magnetReach,
    singleUse: puzzle.singleUse,
  );
}

/// A hand-authored teaching level.
///
/// The opening minutes decide whether anyone keeps playing, and a random board
/// cannot introduce one rule at a time. These do — and every one of them is put
/// through the same [Solver] as the generated levels, with its intended magnet
/// count asserted, so a tutorial can never ship broken or accidentally harder
/// than the chapter that follows it.
class Handmade {
  final String title;
  final int size;
  final List<int> start;
  final List<int> target;
  final List<List<int>> walls;
  final int plus;
  final int minus;
  final int reach;
  final int strength; // -1 = unlimited
  final int expectedMagnets;

  const Handmade({
    required this.title,
    required this.size,
    required this.start,
    required this.target,
    required this.plus,
    required this.minus,
    required this.expectedMagnets,
    this.walls = const [],
    this.reach = 5,
    this.strength = -1,
  });

  Puzzle build(int id) => Puzzle(
    id: id,
    size: size,
    start: Position(start[0], start[1]),
    target: Position(target[0], target[1]),
    walls: {for (final w in walls) Position(w[0], w[1])},
    plusBudget: plus,
    minusBudget: minus,
    magnetReach: reach,
    magnetStrength: strength == -1 ? null : strength,
    maxRuns: 5,
  );
}

/// The teaching chapter, one new idea per board.
const tutorial = <Handmade>[
  Handmade(
    title: 'Anziehen',
    size: 5,
    start: [2, 0],
    target: [2, 3],
    plus: 1,
    minus: 0,
    expectedMagnets: 1,
  ),
  Handmade(
    title: 'Abstoßen',
    size: 5,
    start: [2, 2],
    target: [2, 0],
    plus: 0,
    minus: 1,
    expectedMagnets: 1,
  ),
  Handmade(
    title: 'Wände stoppen',
    size: 5,
    start: [2, 1],
    target: [2, 3],
    walls: [
      [2, 4],
    ],
    plus: 0,
    minus: 1,
    expectedMagnets: 1,
  ),
  Handmade(
    title: 'Stärke',
    size: 5,
    start: [0, 0],
    target: [0, 2],
    plus: 1,
    minus: 0,
    strength: 2,
    expectedMagnets: 1,
  ),
  Handmade(
    title: 'Zwei Magnete',
    size: 5,
    start: [0, 0],
    target: [3, 3],
    plus: 2,
    minus: 0,
    expectedMagnets: 2,
  ),
  Handmade(
    title: 'Reihenfolge',
    size: 6,
    start: [0, 0],
    target: [3, 2],
    plus: 2,
    minus: 0,
    expectedMagnets: 2,
  ),
];

/// The campaign arc: each chapter adds exactly one idea on top of the last, and
/// difficulty climbs inside every chapter because the generator is asked for a
/// band, not a fixed shape.
const chapters = <Chapter>[
  // The on-ramp, and the only chapter that stays at two magnets. Everything
  // after it sits in the hard band: the first campaign put 79% of its levels at
  // three magnets or fewer, and with the move preview showing what each magnet
  // does, a two-move puzzle is solved by walking greedily at the target.
  Chapter(
    id: 'pull',
    title: 'Erste Züge',
    intro: 'Zwei Magnete, eine Reihenfolge — mehr braucht es hier nicht.',
    count: 8,
    difficulty: Difficulty.easy,
    maxWallRatio: 0.26,
  ),
  Chapter(
    id: 'chain',
    title: 'Kettenzug',
    intro: 'Magnete sind Trittsteine. Der kurze Weg ist selten der richtige.',
    count: 12,
    difficulty: Difficulty.hard,
  ),
  Chapter(
    id: 'deflect',
    title: 'Deflektoren',
    intro: 'Diagonale Spiegel lenken die rollende Kugel um 90° ab.',
    count: 12,
    difficulty: Difficulty.medium,
    deflectors: 1,
    // Uncapped strength: the ball has to actually roll for a 90° turn to be
    // worth teaching. See [Chapter.unlimitedStrength].
    unlimitedStrength: true,
  ),
  Chapter(
    id: 'collect',
    title: 'Wegpunkte',
    intro: 'Sammle jeden Kristall ein, bevor du ins Ziel rollst.',
    count: 12,
    difficulty: Difficulty.hard,
    waypoints: 1,
  ),
  Chapter(
    id: 'switch',
    title: 'Schalter',
    intro: 'Rollt die Kugel über eine Platte, öffnet sich das gleichfarbige Tor.',
    count: 12,
    difficulty: Difficulty.medium,
    // The medium band always scatters at least 9 walls, so a 0.24 cap on a 6x6
    // board (8 walls) rejected literally every candidate before the gate was
    // even placed. Keep it in line with the other chapters.
    maxWallRatio: 0.3,
    unlimitedStrength: true,
    switches: 1,
    minMagnets: 2,
  ),
  Chapter(
    id: 'tangle',
    title: 'Verflechtung',
    intro: 'Deflektoren und Kristalle zusammen — Umwege werden Pflicht.',
    count: 10,
    difficulty: Difficulty.hard,
    waypoints: 1,
    deflectors: 1,
    unlimitedStrength: true,
  ),
  Chapter(
    id: 'twin',
    title: 'Zwillinge',
    intro: 'Ein Zug bewegt beide Kugeln. Sie blockieren einander.',
    count: 12,
    difficulty: Difficulty.hard,
    balls: 2,
  ),
  Chapter(
    id: 'swarm',
    title: 'Schwarm',
    intro: 'Drei Kugeln, ein gemeinsamer Zug. Viel Glück.',
    count: 10,
    difficulty: Difficulty.hard,
    balls: 3,
  ),
];

Map<String, int> pos(Position p) => {'r': p.row, 'c': p.col};

Map<String, dynamic> puzzleJson(Puzzle p) => {
  'size': p.size,
  'start': pos(p.start),
  'target': pos(p.target),
  'walls': [for (final w in p.walls) pos(w)],
  'waypoints': [for (final w in p.waypoints) pos(w)],
  'deflectors': [
    for (final e in p.deflectors.entries) {...pos(e.key), 'd': e.value.name},
  ],
  'balls': [
    for (final b in p.extraBalls)
      {'start': pos(b.start), 'target': pos(b.target)},
  ],
  'plates': [
    for (final e in p.plates.entries) {...pos(e.key), 'ch': e.value},
  ],
  'gates': [
    for (final e in p.gates.entries)
      {...pos(e.key), 'ch': e.value.channel, 'open': e.value.openAtStart},
  ],
  'budget': {'plus': p.plusBudget, 'minus': p.minusBudget},
  'max_runs': p.maxRuns,
  'magnet_strength': p.magnetStrength ?? -1,
  'magnet_reach': p.magnetReach,
  'single_use': p.singleUse,
};

Map<String, dynamic> solutionJson(Solution s) => {
  'magnets': [
    for (final m in s.magnets) {...pos(m.pos), 't': m.type.name},
  ],
  'sequence': s.sequence,
};

/// True when [puzzle] is a duplicate of one already accepted. Generated boards
/// repeat more often than you would think, and two identical levels in a row
/// reads as a bug to the player.
String signatureOf(Puzzle p) => jsonEncode(puzzleJson(p));

/// Replays [solution] on [board] and reports whether it still wins — every ball
/// on its own target, every waypoint collected.
bool replayWins(Puzzle board, Solution solution) {
  var balls = board.ballStarts;
  var gates = 0;
  final collected = <Position>{
    ...board.waypoints.where(board.ballStarts.contains),
  };
  for (final index in solution.sequence) {
    final paths = activateAllPaths(
      balls,
      solution.magnets[index],
      solution.magnets,
      board,
      gates,
    );
    for (final w in board.waypoints) {
      if (paths.any((path) => path.contains(w))) collected.add(w);
    }
    // Plates fire once the slide has resolved, so the next move is the first
    // that sees the new doors.
    gates ^= board.platesToggledBy(paths);
    balls = [for (final path in paths) path.last];
  }
  final targets = board.ballTargets;
  for (var i = 0; i < balls.length; i++) {
    if (balls[i] != targets[i]) return false;
  }
  return collected.length == board.waypoints.length;
}

/// Whether the board's deflectors are load-bearing: strip them and the solution
/// must stop working.
///
/// The generator only checks that the solution's path *crosses* a deflector, and
/// since it drops deflectors onto cells the construction walk already used, that
/// is almost always true and almost never meaningful. Baked without this filter,
/// every single level of the "Deflektoren" chapter shipped with a tile that
/// changed nothing — a chapter teaching a mechanic that never fired.
/// Whether the solution ever makes a ball *visibly* turn a corner on a deflector
/// and keep rolling.
///
/// This is the property a player actually reads. A ball that enters a deflector
/// and stops dead on it — because the new direction runs straight into a wall or
/// the board edge — looks exactly like a ball that ignored the tile, which is
/// what the "the deflector does nothing" report was about. So: the path must
/// change direction *at* a deflector cell and travel at least one more cell
/// afterwards.
bool deflectorsBendVisibly(Puzzle puzzle, Solution solution) {
  if (puzzle.deflectors.isEmpty) return true;
  var balls = puzzle.ballStarts;
  var gates = 0;
  for (final index in solution.sequence) {
    final paths = activateAllPaths(
      balls,
      solution.magnets[index],
      solution.magnets,
      puzzle,
      gates,
    );
    gates ^= puzzle.platesToggledBy(paths);
    for (final path in paths) {
      // A bend needs a cell before and a cell after, so scan the interior.
      for (var i = 1; i < path.length - 1; i++) {
        if (!puzzle.isDeflector(path[i])) continue;
        final inRow = path[i].row - path[i - 1].row;
        final inCol = path[i].col - path[i - 1].col;
        final outRow = path[i + 1].row - path[i].row;
        final outCol = path[i + 1].col - path[i].col;
        if (inRow != outRow || inCol != outCol) return true;
      }
    }
    balls = [for (final path in paths) path.last];
  }
  return false;
}

bool deflectorsMatter(Puzzle puzzle, Solution solution) {
  if (puzzle.deflectors.isEmpty) return true;
  final bare = Puzzle(
    id: puzzle.id,
    size: puzzle.size,
    start: puzzle.start,
    target: puzzle.target,
    walls: puzzle.walls,
    waypoints: puzzle.waypoints,
    deflectors: const {},
    extraBalls: puzzle.extraBalls,
    plusBudget: puzzle.plusBudget,
    minusBudget: puzzle.minusBudget,
    maxRuns: puzzle.maxRuns,
    magnetStrength: puzzle.magnetStrength,
    magnetReach: puzzle.magnetReach,
    singleUse: puzzle.singleUse,
  );
  return !replayWins(bare, solution);
}

void main(List<String> args) {
  // `--only <chapter>` bakes a single chapter. The full pack takes ~25 minutes,
  // nearly all of it in the two deflector chapters, which makes iterating on any
  // other chapter unbearable without this.
  var only = '';
  final positional = <String>[];
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--only' && i + 1 < args.length) {
      only = args[++i];
    } else {
      positional.add(args[i]);
    }
  }

  // A fixed seed keeps the shipped pack reproducible: the same command always
  // bakes the same campaign, so a level id means the same board forever.
  final seed = positional.isEmpty ? 20260831 : int.parse(positional.first);
  final generator = PuzzleGenerator(seed);
  final rng = Random(seed);

  final levels = <Map<String, dynamic>>[];
  final seen = <String>{};
  final chapterMeta = <Map<String, dynamic>>[];
  var nextId = 1;

  // --- the hand-authored teaching chapter, solver-checked -------------------
  for (final handmade in tutorial) {
    final puzzle = handmade.build(nextId);
    final solution = Solver(puzzle).solve();
    if (solution == null) {
      stderr.writeln('FATAL: tutorial "${handmade.title}" has no solution');
      exit(1);
    }
    if (solution.magnetCount != handmade.expectedMagnets) {
      stderr.writeln(
        'FATAL: tutorial "${handmade.title}" needs ${solution.magnetCount} '
        'magnets, not the intended ${handmade.expectedMagnets}',
      );
      exit(1);
    }
    levels.add({
      'id': nextId,
      'chapter': 'tutorial',
      'title': handmade.title,
      'puzzle': puzzleJson(puzzle),
      'solution': solutionJson(solution),
      'min_magnets': solution.magnetCount,
      'solution_count': 0,
    });
    seen.add(signatureOf(puzzle));
    nextId++;
  }
  chapterMeta.add({
    'id': 'tutorial',
    'title': 'Grundlagen',
    'intro': 'Anziehen, Abstoßen, Wände, Stärke — ein Gedanke pro Brett.',
    'level_count': tutorial.length,
  });
  stderr.writeln('tutorial  ${tutorial.length} levels (hand-authored, verified)');

  for (final chapter in chapters) {
    if (only.isNotEmpty && chapter.id != only) continue;
    final started = DateTime.now();
    final produced = <Map<String, dynamic>>[];
    var attempts = 0;
    var rejectedInertDeflector = 0;
    var rejectedInertSwitch = 0;

    // The density filter throws a lot away, so allow generous retries. Chapters
    // that fill quickly are unaffected — the loop exits on count, not attempts.
    while (produced.length < chapter.count && attempts < chapter.count * 40) {
      attempts++;
      final generated = generator.generate(
        difficulty: chapter.difficulty,
        size: chapter.size,
        waypoints: chapter.waypoints,
        deflectors: chapter.deflectors,
        balls: chapter.balls,
        maxRuns: 5,
        tries: 4000,
      );
      if (generated == null) continue;

      final cells = chapter.size * chapter.size;
      if (generated.puzzle.walls.length > cells * chapter.maxWallRatio) {
        continue; // too much rubble to read as a puzzle
      }

      var puzzle = generated.puzzle;
      var solution = generated.solution;
      var solutionCount = generated.solutionCount;

      if (chapter.unlimitedStrength) {
        final uncapped = uncap(puzzle, minMagnets: chapter.minMagnets);
        if (uncapped == null) continue;
        (puzzle, solution) = uncapped;
        solutionCount = 0; // measured below, once the level is otherwise accepted
      }

      if (chapter.switches > 0) {
        final switched = withSwitches(puzzle, solution, rng, chapter.switches);
        if (switched == null) {
          rejectedInertSwitch++;
          continue;
        }
        (puzzle, solution) = switched;
        solutionCount = 0;
      }

      if (!deflectorsMatter(puzzle, solution) ||
          !deflectorsBendVisibly(puzzle, solution)) {
        rejectedInertDeflector++;
        continue; // the deflector would be decoration
      }

      final signature = signatureOf(puzzle);
      if (!seen.add(signature)) continue; // already in the pack

      // Hand the player spare magnets so the budget stops spelling out the
      // answer. Both types are always offered, even when the solution uses only
      // one — "no minus magnets at all" is itself a giveaway.
      puzzle = widenBudget(puzzle, solution, chapter.budgetSlack);

      // Scarcity is the second difficulty axis and drives the in-chapter order.
      // It is the expensive measure, so it runs last — only on levels that have
      // already cleared every cheap filter, and on the *final* board, because a
      // wider budget admits type combinations the tight one forbade.
      solutionCount = Solver(
        puzzle,
      ).countMinimalSolutions(solution.magnetCount, cap: 5);

      produced.add({
        'id': nextId++,
        'chapter': chapter.id,
        'puzzle': puzzleJson(puzzle),
        'solution': solutionJson(solution),
        'min_magnets': solution.magnetCount,
        'solution_count': solutionCount,
      });
    }

    // Inside a chapter, climb: fewest magnets first, then scarcest solution
    // (a unique solution is the hardest to find). Order is the difficulty curve.
    produced.sort((a, b) {
      final byMagnets = (a['min_magnets'] as int).compareTo(
        b['min_magnets'] as int,
      );
      if (byMagnets != 0) return byMagnets;
      final ac = a['solution_count'] as int;
      final bc = b['solution_count'] as int;
      // solution_count 0 means "not measured" (multi-ball); treat as neutral.
      if (ac == 0 || bc == 0) return 0;
      return bc.compareTo(ac); // many solutions = easier = earlier
    });
    // Re-number so ids run in play order.
    for (var i = 0; i < produced.length; i++) {
      produced[i]['id'] = levels.length + i + 1;
    }
    levels.addAll(produced);

    final elapsed = DateTime.now().difference(started);
    chapterMeta.add({
      'id': chapter.id,
      'title': chapter.title,
      'intro': chapter.intro,
      'level_count': produced.length,
    });
    stderr.writeln(
      '${chapter.id.padRight(9)} ${produced.length}/${chapter.count} levels '
      'in ${elapsed.inMilliseconds} ms ($attempts attempts'
      '${rejectedInertDeflector > 0 ? ', $rejectedInertDeflector inert deflectors rejected' : ''}'
      '${rejectedInertSwitch > 0 ? ', $rejectedInertSwitch inert switches rejected' : ''})',
    );
    if (produced.length < chapter.count) {
      stderr.writeln(
        '  WARNING: chapter "${chapter.id}" is short by '
        '${chapter.count - produced.length} levels.',
      );
      final reasons = switchRejects.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      for (final entry in reasons) {
        stderr.writeln('    ${entry.value.toString().padLeft(5)}  ${entry.key}');
      }
    }
    switchRejects.clear();
  }

  nextId = levels.length;
  stderr.writeln('total: $nextId levels');
  print(
    const JsonEncoder.withIndent('  ').convert({
      'version': 1,
      'seed': seed,
      'chapters': chapterMeta,
      'levels': levels,
    }),
  );
}
