# POLARIS — Godot

Ein Magnet-Puzzle für Steam (Desktop, Maus + Tastatur). Portiert aus der
Flutter-App unter `C:\Users\Til\Code\flutter\polaris`.

## Die eine wichtige Regel

`scripts/core/movement.gd` ist die **einzige** Quelle der Bewegungsregeln.
Spiel, [Solver] und Generator rufen dieselben Funktionen auf. Wer dort etwas
ändert, ändert alle drei — und muss die Differential-Tests neu backen.

Halte die Datei rein: nur Integer, kein Float, kein Zufall, kein Engine-State.
Nur so ist ein Lauf auf jeder Maschine identisch.

## Koordinaten

Eine Zelle ist ein `Vector2i` mit **x = row, y = col**. Das entspricht dem
`Position(row, col)` des Dart-Originals, damit Port und Referenz Zeile für Zeile
gleich lesen. Nur `BoardView` dreht das in x/y-Pixel — an genau einer Stelle
(`cell_rect`).

Sets von Zellen sind `Dictionary`s (Zelle → `true`), weil GDScript kein Set hat
und `Vector2i` als Wert-Typ hashbar ist.

`null` gibt es bei Ints nicht: `Magnet.INHERIT` (-1) heißt „nimm den Puzzle-Wert",
`Puzzle.UNLIMITED` (-1) heißt „keine Begrenzung".

## Aufbau

```
scripts/core/     reine Spiellogik, engine-unabhängig (@tool)
  movement.gd       die Regeln — single source of truth
  solver.gd         BFS über Aktivierungssequenzen, Iterative Deepening
  generator.gd      construct → solve → verify (siehe „Warum offline")
  puzzle.gd magnet.gd deflector.gd gate.gd solution.gd difficulty.gd
scripts/game/     Spielzustand und Fortschritt
  game_state.gd     ein gespieltes Level; treibt die Simulation
  level.gd level_pack.gd   das gebackene Level-Pack
  player_progress.gd       Autoload, user://progress.cfg
scripts/ui/       Darstellung und Eingabe
  board_view.gd     alles per _draw; Maus geht direkt an GameState
  game_screen.gd main_menu.gd level_select.gd main.gd polaris_theme.gd
scenes/           main.tscn (Root), game_screen.tscn
data/levels.json  das gebackene Level-Pack (nicht von Hand editieren)
tests/            Godot-Testsuiten + golden fixtures
tools/reference_dart/   eingefrorene Dart-Referenz + Pipeline
```

## Warum die Level offline gebacken werden

Der Generator wirft die meisten Kandidaten weg, und GDScript läuft bei der
erschöpfenden Platzierungssuche des Solvers rund 5–10× langsamer als Dart. Das
komplette Pack zu backen dauert in Dart ~40 Minuten — in GDScript wären es
Stunden, und ein Kapitel wie `deflect` allein blockierte den Editor minutenlang.

Deshalb: `tools/reference_dart/bin/build_levels.dart` erzeugt `data/levels.json`,
das Spiel **lädt** nur. Jedes Level ist damit solver-geprüft, hat eine stabile ID
und startet sofort. Die mitgelieferte Lösung ist auch der Hint — zur Laufzeit
wird nie gesucht.

Neu backen (dauert ~40 min, Seed ist fix, also reproduzierbar):

```bash
cd tools/reference_dart && dart run bin/build_levels.dart > ../../data/levels.json
```

Danach ist gespeicherter Fortschritt automatisch ungültig: Level-IDs sind
Positionen im Pack, und `PlayerProgress.adopt_pack` verwirft Sterne, die zu einer
anderen Kampagne gehörten.

`PuzzleGenerator` und `Solver` sind trotzdem vollständig portiert und getestet —
für Editor-Tooling und einen möglichen Endlos-Modus (dann aber in einem `Thread`).

## Stärke schlägt Deflektor — die Falle beim Level-Design

In `_slide` greift die Stärke-Kappung **vor** der Deflektor-Prüfung (so schon im
Dart-Original). Ein Ball, der seine letzte Bewegung auf einem Deflektor beendet,
biegt also nicht mehr ab — er bleibt darauf stehen.

Bei `magnet_strength = 2` heißt das: ein sichtbarer 90°-Bogen entsteht nur, wenn
der Deflektor **genau ein Feld** vom Ball entfernt liegt. Zufällige Platzierung
trifft das fast nie. Der erste gebackene Durchlauf hatte deshalb 14 Level im
Kapitel „Deflektoren", in denen der Ball kein einziges Mal abbog.

Deshalb backen `deflect` und `tangle` mit **unbegrenzter Stärke** (Chapter-Flag
`unlimitedStrength`), und `build_levels.dart` verwirft jeden Kandidaten, dessen
Deflektor nicht beides erfüllt:

- **wirksam** — ohne ihn gewinnt dieselbe Lösung nicht mehr;
- **sichtbar** — der Ball wechselt *auf* dem Deflektor die Richtung und rollt
  danach noch mindestens ein Feld weiter.

`test_level_pack.gd` prüft beides für jedes ausgelieferte Level nach.

## Tests

```
test_movement.gd               portiert aus test/movement_test.dart
test_movement_differential.gd  2000 Bretter gegen die Dart-Referenz
test_solver_differential.gd    100 Bretter, Platzierung UND Sequenz
test_level_pack.gd             jedes ausgelieferte Level, mit Godot-Regeln
test_gates.gd                  Schalter & Tore — die Spezifikation, kein Diff
```

Die Differential-Tests sind der Beweis, dass der Port die Regeln nicht verbogen
hat. Details und das Neu-Backen der Fixtures: `tools/reference_dart/README.md`.

`test_level_pack.gd` ist der zweite Beweis: die Pipeline prüft die Level mit den
*Dart*-Regeln, dieser Test spielt jede ausgelieferte Lösung mit den *Godot*-Regeln
nach und verlangt einen Sieg. Ein unlösbares Level in der Kampagne wäre sonst der
schlechteste denkbare Weg, eine Abweichung zu bemerken. Er prüft außerdem Budgets,
IDs und die beiden Deflektor-Kriterien oben.

Wenn ein Level im Spiel falsch aussieht, trennt
`dart run bin/trace_level.dart <id>` Regel-Bug von Design-Bug: es druckt jeden
Slide-Pfad aus der Dart-Referenz. Stimmt das mit Godot überein, liegt es am Level.

Ausführen über MCP (`test_run`) oder den Godot-AI-Dock. Der Solver-Test ist
absichtlich in Slices geteilt: der Runner bedient den Editor-Transport nur
*zwischen* Tests, ein minutenlanger Testkörper würde die Session abwerfen.

## Schalter & Tore

Die einzige Mechanik, die es im Flutter-Original nicht gab. Deshalb ist sie in
**beiden** Implementierungen gebaut: die Pipeline muss Schalter-Level erzeugen
und verifizieren können, und `test_gates.gd` ist die Spezifikation für beide.

- Eine **Platte** kippt ihren Kanal, wenn eine Kugel sie berührt — durchrollen
  zählt, wie beim Kristall.
- Ein **Tor** ist geschlossen oder offen und gehört zu einem Kanal. Geschlossen
  ist es in jeder Hinsicht eine Wand: es stoppt die Kugel **und** kappt das
  Magnetfeld.
- Plattenfarbe = Torfarbe. Welcher Knopf welche Tür öffnet, braucht keine Legende.
- Auf Platten und Toren stehen keine Magnete (`is_placeable`).

**Die eine Regel, an der alles hängt:** die Umschaltung greift erst, *nachdem*
der Zug vollständig aufgelöst ist. Ein Slide wird damit immer gegen genau ein
Brett gerechnet — und „Platte drücken" wird ein eigener Zug. Genau das erzeugt
die Reihenfolge-Tiefe, um die es bei der Mechanik geht. Rollt die Kugel im selben
Zug über Platte *und* Tor, bleibt sie am noch geschlossenen Tor stehen.

Zwei Platten desselben Kanals in einem Zug kippen ihn **einmal**, nicht zweimal.
Sich gegenseitig aufhebende Platten wären eine Gemeinheit, kein Rätsel.

**Der Torzustand ist kein Brett-Zustand.** Er ist eine `gate_mask` (Bitmaske der
gekippten Kanäle), die jeder Bewegungsaufruf als Argument bekommt. Deshalb bleibt
`Puzzle` unveränderlich, und der Solver kann die Maske sauber in seinen
BFS-Zustand aufnehmen — ohne sie fände er Lösungen, die es nicht gibt.

**Annahmekriterium für ausgelieferte Schalter-Level:** mit toten Platten muss das
Brett *unlösbar* sein. Sonst ist der Schalter Deko — dieselbe Falle wie bei den
Deflektoren. `build_levels.dart` löst dazu jedes Brett zweimal komplett neu;
`test_level_pack.gd` prüft die günstige Hälfte davon bei jedem Testlauf nach.

Schalter-Level werden **konstruiert, nicht geraten**: das Tor kommt auf eine
Zelle, die der Ball in Zug *k* überrollt, die Platte auf eine aus einem *früheren*
Zug. Damit funktioniert die vorhandene Lösung unverändert weiter — sie drückt die
Platte, bevor sie das Tor braucht — und Lösbarkeit ist fast sicher statt Lotterie.
Die erste Fassung setzte das Tor auf den Weg und die Platte irgendwohin: 110
Kandidaten, null Level.

Ein Kapitel isoliert backen (Sekunden statt 25 Minuten) und bei Fehlschlag die
Ablehnungsgründe sehen:

```bash
cd tools/reference_dart && dart run bin/build_levels.dart --only switch > /dev/null
```

## Schwierigkeit: was das Rätsel verrät, ist wichtiger als seine Größe

Die erste Kampagne war zu leicht, und der Grund war nicht die Rätselgröße allein:

- **79 % der Level brauchten ≤ 3 Magnete.** Bei zwei bis drei Zügen reicht
  Greedy — Richtung Ziel, fertig.
- **Alle 100 Level verrieten ihre Lösungsgröße über das Budget.** „Anziehen ×2,
  Abstoßen ×0" sagt: zwei Magnete, beide anziehend. Das kam vom Verengen des
  Budgets auf exakt die Lösung, das Brute-Force verhindern sollte — und
  stattdessen Anzahl *und* Zusammensetzung ausplauderte.

Die Schwierigkeit war vorher **künstlich**: sie kam daher, dass man den Zug nicht
vorher sehen konnte. Die Hover-Vorschau hat das Rätsel nicht kaputtgemacht, sie
hat nur sichtbar gemacht, dass darunter wenig war.

Drei Regeln daraus, die beim Weiterbauen gelten:

1. **`budgetSlack`** (Standard 1) gibt pro Typ einen Magneten mehr als die Lösung
   braucht, und immer mindestens einen von jeder Sorte. Die Zusammensetzung ist
   damit wieder eine Frage. Nur das handgebaute Tutorial behält enge Budgets —
   dort *ist* „hier ist genau ein Anziehmagnet" die Lektion.
2. **Der Bestwert bleibt bis zur ersten Lösung verborgen** (Spielansicht und
   Level-Auswahl-Tooltip). Vorab „braucht 4 Magnete" zu verraten legt die Größe
   der Antwort fest, bevor man aufs Brett geschaut hat. Danach ist dieselbe Zahl
   das Wiederspiel-Ziel und damit motivierend statt verratend.
3. **Fast alle Kapitel laufen im `hard`-Band.** Nur „Erste Züge" bleibt bei 2
   Magneten; das ist die Auffahrt. Ergebnis: Anteil ≤ 3 Magnete von 79 % auf 42 %.

Eine harte Untergrenze setzt der Solver: die erschöpfende Platzierungssuche
wächst mit C(Zellen, n)·2^n, ein fünfter Magnet auf 6×6 kostet also grob das
Zehnfache. Deshalb ist `hard` (4–6) das Ende der Fahnenstange, solange die
Minimalität bewiesen werden soll.

## Die Schleife: Zug für Zug, nicht Sequenz-dann-Abspielen

Die erste Fassung sammelte eine Aktivierungs-Reihenfolge ein und spielte sie auf
Tastendruck ab, mit 5 Versuchen pro Level. Das war das eigentliche Problem am
Spiel: die ganze interessante Arbeit passierte still im Kopf des Spielers,
während das Brett nichts zeigte — und dann rationierte es die Commits auch noch.

Jetzt gilt:

- **Klick auf einen Magneten löst ihn sofort aus.** Die Kugeln bewegen sich, man
  sieht das Ergebnis, man macht weiter.
- **Hovern zeigt den Zug vorher.** Gestrichelte Linie plus Geisterball auf dem
  Landefeld — inklusive Deflektor-Bogen. Das zeigt die Folge *einer* Aktion, nie
  den Weg ins Ziel: die Reihenfolge bleibt vollständig das Rätsel.
- **Z nimmt zurück, beliebig oft.** Kein Versuchslimit mehr.
- **Sterne messen Effizienz**, nicht Versuche: 3 = mit der bewiesenen
  Mindest-Magnetzahl, 2 = einer mehr, 1 = gelöst. Ausprobieren kostet nichts,
  die knappe Lösung ist der Anreiz.

**Wichtige Invariante:** jede Änderung an der Platzierung spult den Lauf auf
Anfang zurück (`_rewind_to_start`). Die Regeln behandeln Magnete für den ganzen
Lauf als solide Blocker, und genau auf diesem Brett wurden die ausgelieferten
Lösungen verifiziert. Würde man einen Magneten mitten in der Sequenz nachlegen,
spielte man auf einem Brett, das nie ein Solver geprüft hat.

## Was der Steam-Port gegenüber der App geändert hat

- **Kein Daily.** Statt einem Rätsel pro Tag eine Kampagne aus 94 Leveln in 9
  Kapiteln, die je eine Mechanik einführen.
- **Handgebautes Tutorial.** Sechs Bretter, ein Gedanke pro Brett, im Build vom
  Solver gegen die beabsichtigte Magnetzahl geprüft — der Build bricht ab, wenn
  ein Tutorial-Brett nicht mehr stimmt.
- **Maus + Tastatur.** Linksklick setzt bzw. löst aus, Rechtsklick entfernt,
  1/2/3 wählt Werkzeug, Z nimmt zurück, R spult den Lauf zurück, H verrät die
  Magnete (nicht die Reihenfolge), Esc geht raus. Alles über die InputMap.
- **Kein Share-Grid.** `logic/share.dart` wurde nicht portiert — der virale
  Wordle-Loop trägt auf Steam nicht.

## Offen

- Ton (Musik + SFX; `PlayerProgress` hat die Flags schon)
- Einstellungs-Screen (Lautstärke, Tastenbelegung, Fortschritt löschen)
- Steamworks (Achievements auf Kapitel-Abschlüsse, Cloud-Saves)
- Lokalisierung — alle Strings stehen aktuell deutsch im Code
