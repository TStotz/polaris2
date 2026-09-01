import '../models/deflector.dart';
import '../models/magnet.dart';
import '../models/position.dart';
import '../models/puzzle.dart';

/// Whether [cell] lies on the straight slide from [from] to [to], endpoints
/// included. Each activation moves the ball along a single row or column, so the
/// ball touches exactly the cells on this segment — the basis for collecting a
/// waypoint by either stopping on it or sliding through it.
bool onBallPath(Position cell, Position from, Position to) {
  if (from.row == to.row && cell.row == from.row) {
    final lo = from.col < to.col ? from.col : to.col;
    final hi = from.col < to.col ? to.col : from.col;
    return cell.col >= lo && cell.col <= hi;
  }
  if (from.col == to.col && cell.col == from.col) {
    final lo = from.row < to.row ? from.row : to.row;
    final hi = from.row < to.row ? to.row : from.row;
    return cell.row >= lo && cell.row <= hi;
  }
  return false;
}

/// THE single source of truth for the movement rules (Modell A, §2).
///
/// Returns where the ball comes to rest after one activation. Both the live game
/// and the [Solver] call this exact function — and any future Python pipeline
/// must match it bit-for-bit (differential test, §7). Keep this pure and
/// integer-only; do not introduce float math or randomness.
///
/// Rules:
///  - A magnet only acts when the ball shares its row OR column (never diagonal).
///  - **Reach** (field radius): the magnet only grabs the ball if it is within
///    `reach` cells along that line *and* no wall blocks the straight line
///    between them ([Puzzle.blocksReach]); otherwise no effect. Reach is
///    [Magnet.reach] ?? [Puzzle.magnetReach] and is always finite.
///  - The ball then slides — towards a PLUS (attract) or away from a MINUS
///    (repel) — and stops at the last free cell before a blocker (wall, board
///    edge, or any magnet — magnets are solid). Stopping before the acting
///    magnet is what "parks directly next to it" means for PLUS.
///  - **Strength** (push/pull distance): caps how many cells the ball travels,
///    [Magnet.strength] ?? [Puzzle.magnetStrength] (null = unlimited). Reach and
///    strength are independent.
///  - A **deflector** tile turns the slide 90° (see [DeflectorDir]); the ball
///    keeps going along the new direction. The path is therefore a polyline, but
///    every turn is integer-exact, so the resting cell is still fully computable.
///  - A **closed gate** is a wall: it stops the slide and cuts off the field.
///    Which gates are shut is not part of the board — it is the run's
///    `gateMask`, a bitmask of the channels toggled so far, passed in by the
///    caller. Keeping it an argument rather than mutable puzzle state is what
///    lets one activation be evaluated against exactly one board.
///  - Ball not in line, out of reach, or field blocked → no movement.
Position activate(
  Position ball,
  Magnet magnet,
  Iterable<Magnet> magnets,
  Puzzle puzzle, [
  int gateMask = 0,
]) => _slide(ball, magnet, magnets, puzzle, null, gateMask: gateMask);

/// The full ordered list of cells the ball travels through for this activation,
/// from [ball] (inclusive) to its resting cell (inclusive), turning at
/// deflectors. `[ball]` alone when it does not move. This is what waypoint
/// collection must use, since a deflected path is not a straight segment.
List<Position> slidePath(
  Position ball,
  Magnet magnet,
  Iterable<Magnet> magnets,
  Puzzle puzzle, [
  int gateMask = 0,
]) {
  final trace = <Position>[];
  _slide(ball, magnet, magnets, puzzle, trace, gateMask: gateMask);
  return trace;
}

/// The cells [magnet]'s field covers, each with the step `(dr, dc)` a ball
/// resting there would take when the magnet fires: **towards** a PLUS, **away**
/// from a MINUS.
///
/// This is the magnet's area of effect, derived from the very same reach rule
/// [activate] applies: at most `reach` cells along each row/column direction,
/// and a wall ([Puzzle.blocksReach]) cuts the field off beyond it. It describes
/// only the *first* step — where the ball ends up also depends on strength,
/// deflectors and blockers — so showing it teaches the rule without giving the
/// puzzle's answer away.
List<({Position cell, int dr, int dc})> magnetField(
  Magnet magnet,
  Puzzle puzzle, [
  int gateMask = 0,
]) {
  final reach = magnet.reach ?? puzzle.magnetReach;
  final field = <({Position cell, int dr, int dc})>[];
  const dirs = [(-1, 0), (1, 0), (0, -1), (0, 1)];

  for (final (dr, dc) in dirs) {
    for (var k = 1; k <= reach; k++) {
      final cell = Position(magnet.pos.row + dr * k, magnet.pos.col + dc * k);
      if (!puzzle.inBounds(cell)) break;
      // A wall can't hold a ball and blocks the field for everything behind it.
      if (puzzle.blocksReach(cell, magnet.type, gateMask)) break;
      // Outward from the magnet is (dr, dc); a PLUS pulls the ball back along it.
      field.add(
        magnet.isPlus
            ? (cell: cell, dr: -dr, dc: -dc)
            : (cell: cell, dr: dr, dc: dc),
      );
    }
  }
  return field;
}

/// Applies one activation of [magnet] to **every** ball, returning the new
/// positions index-aligned with [balls]. This is the multi-ball rule: all balls
/// on the magnet's line (within reach) slide at once, and balls are solid — so
/// they stack up deterministically. The ball furthest along the slide direction
/// settles first; the rest stop behind it. Balls not in line stay put but still
/// block, exactly like a wall or magnet.
///
/// Reuses the same [_slide] as the single-ball [activate], so the movement rules
/// (reach, strength, deflectors, cycle guard) stay bit-identical — the only
/// addition is that other balls count as blockers.
List<Position> activateAll(
  List<Position> balls,
  Magnet magnet,
  Iterable<Magnet> magnets,
  Puzzle puzzle, [
  int gateMask = 0,
]) => _resolveAll(balls, magnet, magnets, puzzle, null, gateMask);

/// Like [activateAll], but also returns the full path each ball travelled
/// (start included), index-aligned with [balls]. Needed for waypoint collection
/// and animation, since a ball may cross several cells (and bend at deflectors)
/// on its way to rest.
List<List<Position>> activateAllPaths(
  List<Position> balls,
  Magnet magnet,
  Iterable<Magnet> magnets,
  Puzzle puzzle, [
  int gateMask = 0,
]) {
  final paths = List<List<Position>>.filled(
    balls.length,
    const [],
    growable: false,
  );
  _resolveAll(balls, magnet, magnets, puzzle, paths, gateMask);
  return paths;
}

/// Shared core for [activateAll] / [activateAllPaths]. Resolves every ball
/// front-to-back along its own travel direction, so the ball nearest the
/// stopping edge settles first and the rest stack behind it (other balls are
/// solid blockers). When [outPaths] is non-null, each ball's traced path is
/// stored into it.
List<Position> _resolveAll(
  List<Position> balls,
  Magnet magnet,
  Iterable<Magnet> magnets,
  Puzzle puzzle,
  List<List<Position>>? outPaths, [
  int gateMask = 0,
]) {
  final result = List<Position>.of(balls);
  final occupied = balls.toSet();

  final order = List<int>.generate(balls.length, (i) => i);
  int projOf(int i) {
    final (dr, dc) = _travelStep(balls[i], magnet);
    return balls[i].row * dr + balls[i].col * dc;
  }

  order.sort((a, b) => projOf(b).compareTo(projOf(a)));

  for (final i in order) {
    occupied.remove(result[i]);
    final trace = outPaths == null ? null : <Position>[];
    result[i] = _slide(
      result[i],
      magnet,
      magnets,
      puzzle,
      trace,
      occupied: occupied,
      gateMask: gateMask,
    );
    if (outPaths != null) outPaths[i] = trace!;
    occupied.add(result[i]);
  }
  return result;
}

/// The step a ball would take on this activation: toward a PLUS, away from a
/// MINUS, or `(0, 0)` when the ball is not in the magnet's line. Used only to
/// order simultaneous balls; the actual slide recomputes it in [_slide].
(int, int) _travelStep(Position ball, Magnet magnet) {
  int dr = 0, dc = 0;
  if (ball.row == magnet.pos.row && ball.col != magnet.pos.col) {
    dc = magnet.pos.col > ball.col ? 1 : -1;
  } else if (ball.col == magnet.pos.col && ball.row != magnet.pos.row) {
    dr = magnet.pos.row > ball.row ? 1 : -1;
  } else {
    return (0, 0);
  }
  return magnet.isMinus ? (-dr, -dc) : (dr, dc);
}

/// 90° turn of a step `(dr, dc)` on entering a deflector of [dir].
(int, int) _deflect(DeflectorDir dir, int dr, int dc) =>
    dir == DeflectorDir.backslash ? (dc, dr) : (-dc, -dr);

/// Compact id for a (direction) of the four orthogonal steps, for cycle keys.
int _dirIndex(int dr, int dc) =>
    dr == -1 ? 0 : (dr == 1 ? 1 : (dc == -1 ? 2 : 3));

/// Core slide. When [trace] is non-null, every visited cell is appended to it.
/// [occupied] holds other balls, which are solid blockers for the slide (but do
/// not block the magnet's field — only walls do). Empty for a single-ball move.
Position _slide(
  Position ball,
  Magnet magnet,
  Iterable<Magnet> magnets,
  Puzzle puzzle,
  List<Position>? trace, {
  Set<Position> occupied = const {},
  int gateMask = 0,
}) {
  trace?.add(ball);

  final sameRow = ball.row == magnet.pos.row;
  final sameCol = ball.col == magnet.pos.col;
  if (!sameRow && !sameCol) return ball; // not in line → no effect
  if (ball == magnet.pos) return ball; // ball already on the magnet cell

  // Step towards the magnet (used both to measure reach and as the PLUS
  // direction; MINUS reverses it below).
  int tdr = 0, tdc = 0;
  if (sameRow) {
    tdc = magnet.pos.col > ball.col ? 1 : -1;
  } else {
    tdr = magnet.pos.row > ball.row ? 1 : -1;
  }

  // REACH gate: the magnet only grabs the ball if it sits within `reach` cells
  // along the straight line, with no wall blocking the field on the way. A
  // per-magnet reach wins; otherwise the puzzle-wide value. Reach is always
  // finite, so this gate always applies.
  final reach = magnet.reach ?? puzzle.magnetReach;
  var rr = ball.row, rc = ball.col;
  var within = false;
  for (var k = 1; k <= reach; k++) {
    rr += tdr;
    rc += tdc;
    final cell = Position(rr, rc);
    if (cell == magnet.pos) {
      within = true;
      break;
    }
    if (puzzle.blocksReach(cell, magnet.type, gateMask)) break; // field blocked
  }
  if (!within) return ball; // too far or blocked → no effect

  // Slide direction: towards a PLUS, away from a MINUS.
  int dr = tdr, dc = tdc;
  if (magnet.isMinus) {
    dr = -dr;
    dc = -dc;
  }

  // A cell blocks the ball if it is off-board, a wall, or holds a magnet (the
  // acting magnet included — that is how PLUS parks directly next to it).
  bool blocked(int r, int c) {
    final p = Position(r, c);
    if (!puzzle.inBounds(p)) return true;
    // A shut gate is a wall for as long as it is shut.
    if (puzzle.blocksBall(p, gateMask)) return true;
    if (occupied.contains(p)) return true; // another ball is solid
    return magnets.any((m) => m.pos == p);
  }

  // STRENGTH: how many cells the ball travels. A per-magnet strength wins;
  // otherwise the puzzle-wide cap (null = unlimited).
  final strength = magnet.strength ?? puzzle.magnetStrength;
  final visited = <int>{};
  var cur = ball;
  var moved = 0;

  while (true) {
    final nr = cur.row + dr, nc = cur.col + dc;
    if (blocked(nr, nc)) return cur; // can't advance → rest here
    cur = Position(nr, nc);
    trace?.add(cur);
    if (strength != null && ++moved >= strength) return cur; // strength cap

    final dir = puzzle.deflectorAt(cur);
    if (dir != null) {
      final (ndr, ndc) = _deflect(dir, dr, dc);
      dr = ndr;
      dc = ndc;
    }

    // A repeated (cell, direction) means the ball loops forever between
    // deflectors and never rests → treat the activation as no movement.
    final key = (cur.row * puzzle.size + cur.col) * 4 + _dirIndex(dr, dc);
    if (!visited.add(key)) {
      trace
        ?..clear()
        ..add(ball);
      return ball;
    }
  }
}
