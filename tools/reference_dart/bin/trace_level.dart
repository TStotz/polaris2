// Replays a shipped level's stored solution through the pinned Dart reference
// and prints every activation's slide path.
//
// The arbiter when a level looks wrong in the game: if this and the Godot side
// print the same paths, the rules agree and the problem is the level's *design*;
// if they differ, the port has drifted and the differential fixture missed a case.
//
//   dart run bin/trace_level.dart 61

import 'dart:convert';
import 'dart:io';

import 'logic/movement.dart';
import 'models/deflector.dart';
import 'models/magnet.dart';
import 'models/position.dart';
import 'models/puzzle.dart';

Position pos(Map<String, dynamic> m) => Position(m['r'] as int, m['c'] as int);

void main(List<String> args) {
  final id = int.parse(args.isEmpty ? '61' : args.first);
  final data =
      jsonDecode(File('../../data/levels.json').readAsStringSync())
          as Map<String, dynamic>;
  final level = (data['levels'] as List)
      .cast<Map<String, dynamic>>()
      .firstWhere((l) => l['id'] == id);
  final p = level['puzzle'] as Map<String, dynamic>;
  final budget = p['budget'] as Map<String, dynamic>;

  final puzzle = Puzzle(
    id: id,
    size: p['size'] as int,
    start: pos(p['start'] as Map<String, dynamic>),
    target: pos(p['target'] as Map<String, dynamic>),
    walls: (p['walls'] as List).cast<Map<String, dynamic>>().map(pos).toSet(),
    waypoints: (p['waypoints'] as List)
        .cast<Map<String, dynamic>>()
        .map(pos)
        .toList(),
    deflectors: {
      for (final m in (p['deflectors'] as List).cast<Map<String, dynamic>>())
        pos(m): DeflectorDir.parse(m['d'] as String),
    },
    extraBalls: [
      for (final b in (p['balls'] as List).cast<Map<String, dynamic>>())
        (
          start: pos(b['start'] as Map<String, dynamic>),
          target: pos(b['target'] as Map<String, dynamic>),
        ),
    ],
    plusBudget: budget['plus'] as int,
    minusBudget: budget['minus'] as int,
    maxRuns: p['max_runs'] as int,
    magnetStrength: (p['magnet_strength'] as int) == -1
        ? null
        : p['magnet_strength'] as int,
    magnetReach: p['magnet_reach'] as int,
    singleUse: p['single_use'] as bool,
  );

  final magnets = [
    for (final m in (level['solution']['magnets'] as List)
        .cast<Map<String, dynamic>>())
      Magnet(
        pos(m),
        m['t'] == 'plus' ? MagnetType.plus : MagnetType.minus,
      ),
  ];
  final sequence = (level['solution']['sequence'] as List).cast<int>();

  stdout.writeln('level $id  start ${puzzle.start} -> target ${puzzle.target}');
  stdout.writeln(
    '  strength ${puzzle.magnetStrength}  reach ${puzzle.magnetReach}  '
    'singleUse ${puzzle.singleUse}',
  );
  stdout.writeln('  deflectors ${puzzle.deflectors}');
  stdout.writeln('  waypoints ${puzzle.waypoints}');

  var balls = puzzle.ballStarts;
  final collected = <Position>{
    ...puzzle.waypoints.where(puzzle.ballStarts.contains),
  };

  for (var step = 0; step < sequence.length; step++) {
    final magnet = magnets[sequence[step]];
    final paths = activateAllPaths(balls, magnet, magnets, puzzle);
    for (final w in puzzle.waypoints) {
      if (paths.any((path) => path.contains(w))) collected.add(w);
    }
    for (final path in paths) {
      final touchedDeflector = path.where(puzzle.isDeflector).toList();
      stdout.writeln(
        '  ${step + 1}. $magnet  path ${path.join(' -> ')}'
        '${touchedDeflector.isEmpty ? '' : '   [deflector on ${touchedDeflector.join(',')}]'}',
      );
    }
    balls = [for (final path in paths) path.last];
  }

  final targets = puzzle.ballTargets;
  var home = true;
  for (var i = 0; i < balls.length; i++) {
    if (balls[i] != targets[i]) home = false;
  }
  stdout.writeln(
    '  RESULT balls $balls  onTarget $home  '
    'waypoints ${collected.length}/${puzzle.waypoints.length}',
  );
}
