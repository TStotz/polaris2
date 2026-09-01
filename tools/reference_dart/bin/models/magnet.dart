
import 'position.dart';

/// The two magnet polarities (Modell A, POLARIS_CONTEXT §2).
///
/// [plus] attracts the ball, parking it directly next to the magnet.
/// [minus] repels the ball, pushing it to the last free cell before a blocker.
enum MagnetType { plus, minus }


class Magnet {
  final Position pos;
  final MagnetType type;

  /// How many cells the ball travels when this magnet acts, overriding the
  /// puzzle's [Puzzle.magnetStrength] when set (null → use the puzzle value).
  final int? strength;

  /// How many cells away the magnet still grabs the ball (its field radius),
  /// overriding [Puzzle.magnetReach] when set (null → use the puzzle value).
  /// Beyond it — or with a wall blocking the line — the magnet has no effect.
  ///
  /// [strength] and [reach] are independent: a short-reach, high-strength magnet
  /// is a contact catapult; a long-reach, low-strength one is a gentle nudge.
  /// These are the seam for future "special" magnets; today placed magnets leave
  /// both null and inherit the puzzle's values.
  final int? reach;

  const Magnet(this.pos, this.type, {this.strength, this.reach});

  bool get isPlus => type == MagnetType.plus;
  bool get isMinus => type == MagnetType.minus;

  @override
  bool operator ==(Object other) =>
      other is Magnet &&
      other.pos == pos &&
      other.type == type &&
      other.strength == strength &&
      other.reach == reach;

  @override
  int get hashCode => Object.hash(pos, type, strength, reach);

  @override
  String toString() {
    final s = strength == null ? '' : '·s$strength';
    final r = reach == null ? '' : '·r$reach';
    return '${type.name}@$pos$s$r';
  }
}
