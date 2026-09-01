
import 'deflector.dart';
import 'gate.dart';
import 'magnet.dart';
import 'position.dart';

/// A single daily puzzle definition.
///
/// This is the immutable input to a game: the board geometry plus the magnet
/// budget and the number of attempts. The mutable, in-progress state (placed
/// magnets, activation sequence, attempts used) lives in the game controller.

class Puzzle {
  final int id;
  final int size;
  final Position start;
  final Position target;
  final Set<Position> walls;

  /// Cells the ball must collect before the target counts as reached. A waypoint
  /// is collected the moment the ball touches its cell — whether it stops on it
  /// or merely slides through it. Order does not matter. Empty for a plain
  /// "reach the target" puzzle.
  final List<Position> waypoints;

  /// Diagonal deflector tiles, keyed by cell. A sliding ball turns 90° on
  /// entering one (see [DeflectorDir]). They are pure routing tiles: not
  /// blockers, and no magnet may be placed on them.
  final Map<Position, DeflectorDir> deflectors;

  /// Extra balls beyond the primary [start]/[target]. Each entry pairs a ball's
  /// start with the target it must reach, so ball `i+1` must arrive on
  /// `extraBalls[i].target`. Empty for a classic single-ball puzzle.
  ///
  /// A single activation moves **every** ball on the magnet's line at once, and
  /// balls are solid (they block each other and the magnetic slide, like
  /// magnets). That shared move is the whole point: one action that helps one
  /// ball can strand another. See [ballStarts] / [ballTargets] and `activateAll`
  /// in `logic/movement.dart`.
  final List<({Position start, Position target})> extraBalls;

  /// Pressure plates, keyed by cell -> channel. A ball touching one toggles
  /// every [Gate] on that channel — whether it stops on the plate or merely
  /// slides through, exactly like a waypoint.
  ///
  /// The toggle lands **after** the activation has fully resolved, so a slide is
  /// always computed against one consistent board. That also makes pressing a
  /// plate a move of its own, which is the whole point: it forces an order.
  final Map<Position, int> plates;

  /// Gate tiles, keyed by cell. A closed gate is a wall in every respect — it
  /// stops the ball and it cuts off a magnet's field.
  final Map<Position, Gate> gates;

  final int plusBudget;
  final int minusBudget;
  final int maxRuns;

  /// How many cells the ball *travels* in a single activation, or null for
  /// unlimited. This is the magnet's **strength** (the push/pull distance);
  /// shorter values turn a magnet into a stepping stone rather than a teleport.
  /// A per-magnet [Magnet.strength] overrides it. Read by [activate] (§2).
  final int? magnetStrength;

  /// How many cells away a magnet still *grabs* the ball — its **reach** (field
  /// radius). Beyond it, or with a wall on the straight line between ball and
  /// magnet ([blocksReach]), the magnet has no effect. Always finite (a magnet's
  /// pull/push is never board-wide) and **required** so it can never be left
  /// unlimited by accident. Independent of [magnetStrength]; a per-magnet
  /// [Magnet.reach] overrides it.
  final int magnetReach;

  /// When true, each magnet may be activated at most once per run (no
  /// re-pumping). Combined with a finite [magnetStrength] this is the main lever
  /// for genuine difficulty: a distant target then needs a *chain* of distinct
  /// magnets, so the minimal magnet count scales with distance. Default false
  /// keeps the original "repeats allowed" rule (Variante 1, §7).
  final bool singleUse;

  const Puzzle({
    required this.id,
    required this.start,
    required this.target,
    required this.walls,
    required this.plusBudget,
    required this.minusBudget,
    required this.magnetReach,
    this.size = 6,
    this.maxRuns = 5,
    this.magnetStrength,
    this.singleUse = false,
    this.waypoints = const [],
    this.deflectors = const {},
    this.extraBalls = const [],
    this.plates = const {},
    this.gates = const {},
  });

  /// Every ball's start, primary first: `[start, ...extraBalls.start]`.
  List<Position> get ballStarts => [start, for (final b in extraBalls) b.start];

  /// Every ball's target, index-aligned with [ballStarts].
  List<Position> get ballTargets => [
    target,
    for (final b in extraBalls) b.target,
  ];

  /// Number of balls in play (always ≥ 1).
  int get ballCount => 1 + extraBalls.length;

  /// True when the puzzle has more than one ball (shared-move rules apply).
  bool get isMultiBall => extraBalls.isNotEmpty;

  bool inBounds(Position p) =>
      p.row >= 0 && p.row < size && p.col >= 0 && p.col < size;

  bool isWall(Position p) => walls.contains(p);

  bool isTarget(Position p) => p == target;

  bool isStart(Position p) => p == start;

  /// Which ball's target sits on [p], or null. Index 0 is the primary ball.
  int? targetIndexAt(Position p) {
    final t = ballTargets;
    for (var i = 0; i < t.length; i++) {
      if (t[i] == p) return i;
    }
    return null;
  }

  /// Which ball starts on [p], or null. Index 0 is the primary ball.
  int? startIndexAt(Position p) {
    final s = ballStarts;
    for (var i = 0; i < s.length; i++) {
      if (s[i] == p) return i;
    }
    return null;
  }

  bool isWaypoint(Position p) => waypoints.contains(p);

  bool isDeflector(Position p) => deflectors.containsKey(p);

  bool isPlate(Position p) => plates.containsKey(p);

  bool isGate(Position p) => gates.containsKey(p);

  /// Whether the gate on [p] stands open under [gateMask]. Cells without a gate
  /// are trivially "open" — the caller asks this only about gate cells.
  bool gateOpen(Position p, int gateMask) {
    final gate = gates[p];
    return gate == null || gate.isOpen(gateMask);
  }

  /// Whether [p] stops a ball: a wall, or a gate that is currently shut.
  bool blocksBall(Position p, int gateMask) =>
      isWall(p) || (isGate(p) && !gateOpen(p, gateMask));

  /// The channels the cells in [paths] toggle. A channel flips once per
  /// activation no matter how many of its plates were crossed — two plates on
  /// one channel cancelling out would be a gotcha, not a puzzle.
  int platesToggledBy(Iterable<List<Position>> paths) {
    var mask = 0;
    for (final path in paths) {
      for (final cell in path) {
        final channel = plates[cell];
        if (channel != null) mask |= 1 << channel;
      }
    }
    return mask;
  }

  DeflectorDir? deflectorAt(Position p) => deflectors[p];

  /// Whether a magnet of [type] has its reach (field) blocked at cell [p] on the
  /// straight line to the ball. Today every wall blocks both polarities; this is
  /// the seam for future wall types that let only pulling (plus) or only pushing
  /// (minus) fields pass — that logic will branch on [type] here.
  bool blocksReach(Position p, MagnetType type, [int gateMask = 0]) =>
      blocksBall(p, gateMask);

  /// A cell that can hold a magnet (free, not on any ball start/target, and not
  /// a waypoint or deflector). A magnet on a waypoint would make it impossible
  /// to collect, and a deflector is a fixed routing tile, so both are off-limits;
  /// with multiple balls every start and target is likewise off-limits.
  bool isPlaceable(Position p) =>
      inBounds(p) &&
      !isWall(p) &&
      startIndexAt(p) == null &&
      targetIndexAt(p) == null &&
      !isWaypoint(p) &&
      !isDeflector(p) &&
      // A magnet on a plate would make it impossible to press, and a gate cell
      // can turn solid underneath it.
      !isPlate(p) &&
      !isGate(p);

  factory Puzzle.fromJson(Map<String, dynamic> json) {
    Position pos(Map<String, dynamic> m) =>
        Position(m['r'] as int, m['c'] as int);
    final budget = json['budget'] as Map<String, dynamic>;
    return Puzzle(
      id: json['id'] as int,
      size: (json['size'] as int?) ?? 6,
      start: pos(json['start'] as Map<String, dynamic>),
      target: pos(json['target'] as Map<String, dynamic>),
      walls: ((json['walls'] as List).cast<Map<String, dynamic>>())
          .map(pos)
          .toSet(),
      waypoints: ((json['waypoints'] as List?) ?? const [])
          .cast<Map<String, dynamic>>()
          .map(pos)
          .toList(),
      deflectors: {
        for (final m
            in ((json['deflectors'] as List?) ?? const [])
                .cast<Map<String, dynamic>>())
          pos(m): DeflectorDir.parse(m['d'] as String),
      },
      plates: {
        for (final m
            in ((json['plates'] as List?) ?? const [])
                .cast<Map<String, dynamic>>())
          pos(m): m['ch'] as int,
      },
      gates: {
        for (final m
            in ((json['gates'] as List?) ?? const [])
                .cast<Map<String, dynamic>>())
          pos(m): Gate(
            m['ch'] as int,
            openAtStart: (m['open'] as bool?) ?? false,
          ),
      },
      plusBudget: budget['plus'] as int,
      minusBudget: budget['minus'] as int,
      maxRuns: (json['maxRuns'] as int?) ?? 5,
      magnetStrength: json['magnetStrength'] as int?,
      // Reach is always finite; a board that omits it falls back to its full
      // span rather than "unlimited".
      magnetReach:
          (json['magnetReach'] as int?) ?? ((json['size'] as int?) ?? 6) - 1,
      singleUse: (json['singleUse'] as bool?) ?? false,
      extraBalls: ((json['balls'] as List?) ?? const [])
          .cast<Map<String, dynamic>>()
          .map(
            (b) => (
              start: pos(b['start'] as Map<String, dynamic>),
              target: pos(b['target'] as Map<String, dynamic>),
            ),
          )
          .toList(),
    );
  }
}
