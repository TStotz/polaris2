/// A diagonal deflector tile that turns a sliding ball 90°.
///
/// On entering a deflector cell the ball's step `(dr, dc)` is rotated:
///  - [backslash] `\` maps `(dr, dc)` → `(dc, dr)`  (right↔down, left↔up);
///  - [slash]     `/` maps `(dr, dc)` → `(-dc, -dr)` (right↔up, left↔down).
///
/// The turn is integer-exact and deterministic, so the ball's resting cell stays
/// fully computable — the same predictability contract as a plain slide
/// (POLARIS_CONTEXT §2). The reflection itself lives in `logic/movement.dart`,
/// the single source of truth for movement.
enum DeflectorDir {
  slash,
  backslash;

  /// Parses the JSON token (`'slash'` / `'backslash'`, or `'/'` / `'\'`).
  static DeflectorDir parse(String s) =>
      (s == 'slash' || s == '/') ? DeflectorDir.slash : DeflectorDir.backslash;
}
