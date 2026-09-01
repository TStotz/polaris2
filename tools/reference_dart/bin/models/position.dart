
/// Immutable grid coordinate (row, col).
///
/// Used everywhere as the unit of the discrete board. Integer-only by design
/// (see POLARIS_CONTEXT §9): bit-identical movement results across devices,
/// which is critical for the shared daily puzzle.

class Position {
  final int row;
  final int col;

  const Position(this.row, this.col);

  Position copyWith({int? row, int? col}) =>
      Position(row ?? this.row, col ?? this.col);

  @override
  bool operator ==(Object other) =>
      other is Position && other.row == row && other.col == col;

  @override
  int get hashCode => Object.hash(row, col);

  @override
  String toString() => '($row,$col)';
}
