/// A gate tile: solid when closed, empty when open.
///
/// Gates belong to a [channel]. Every plate on the same channel toggles every
/// gate on it, so a channel is one linked mechanism. [openAtStart] lets a level
/// ship gates that begin open and slam shut, not only the other way round.
///
/// The live open/closed state is **not** stored here. It lives in a per-run
/// bitmask of toggled channels that the movement rules take as an argument, so
/// the puzzle definition stays immutable and a slide is always evaluated against
/// exactly one board.
class Gate {
  final int channel;
  final bool openAtStart;

  const Gate(this.channel, {this.openAtStart = false});

  /// Whether this gate stands open given the run's [gateMask].
  bool isOpen(int gateMask) {
    final toggled = (gateMask & (1 << channel)) != 0;
    return openAtStart != toggled; // XOR
  }

  @override
  String toString() => 'gate(ch$channel${openAtStart ? ',open' : ''})';
}
