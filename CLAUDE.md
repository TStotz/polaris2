# POLARIS — Godot

Ein Echtzeit-Magnetspiel für Steam (Desktop, Maus + Tastatur). Man setzt Magnete
auf ein Brett und hält sie im richtigen Moment gedrückt; die Kugel fliegt frei
durch einen Parcours ins Ziel.

## Die eine wichtige Regel

`scripts/sim/sim_world.gd` ist die **einzige** Quelle der Bewegungsregeln. Das
Spiel, jedes Replay und jedes künftige Level-Werkzeug rufen dieselbe `step()`.

Sie ist bewusst engine-frei: keine Nodes, kein `_physics_process`, kein
`RigidBody2D`. Ein fester Zeitschritt allein reicht für Reproduzierbarkeit
nämlich nicht — Godots Solver gibt keine Plattform-Garantie, seine
Iterationsreihenfolge ist nicht Teil des Vertrags, und wann ein Körper zur Ruhe
kommt, hängt an internen Toleranzen, die sich zwischen Versionen ändern. Ein
Kreis gegen achsenparallele Kästen ist klein genug, um ihn selbst zu besitzen —
und genau das macht Bestenlisten und geteilte Geister überhaupt erst möglich.

Die Regeln, an die sich dort jede Zeile hält:

- Zeit läuft **nur** in ganzen Ticks von `TICK_DELTA` (1/60 s). Das `delta` der
  Engine wird nie gelesen — ein Frame-Drop darf den Ausgang nicht ändern.
- Arithmetik nur `+ - * /` und `sqrt`. Alle fünf sind von IEEE 754 exakt
  festgelegt. `sin`, `cos`, `pow`, `atan2` sind es **nicht** und kommen deshalb
  nirgends vor.
- Kein Zufall, keine Iteration über ein `Dictionary`. Wände und Magnete sind
  `Array`s, damit die Reihenfolge die geschriebene ist.
- Eingabe kommt als **eine Bitmaske pro Tick**. Es gibt nichts Kontinuierliches,
  das man zum falschen Zeitpunkt abtasten könnte.

`state_hash()` faltet die ganze Flugbahn (auf 1/64 px quantisiert) zu einer Zahl.
`test_sim.gd` pinnt sie. Wer eine Regel oben bricht — Engine-Delta lesen,
`randf()` rufen, nach `sin` greifen — ändert die Zahl und fällt durch.

## Aufbau

```
scripts/sim/      die Simulation, engine-unabhängig (@tool)
  sim_world.gd      die Regeln — single source of truth
  sim_level.gd      reine Leveldaten: MagnetSpec + MoverSpec
  levels.gd         die Kampagne, als Code
scripts/ui/
  game_root.gd      tauscht Menü und Spiel; die Startszene
  menu_screen.gd    Level-Auswahl, nach Feature gruppiert
  play_screen.gd    Ablauf und Eingabe; ruft BoardArt fürs Aussehen
  board_art.gd      wie das Brett aussieht — darf `sin`, `Time`, Animation
  polaris_theme.gd  Palette, Font und der projektweite Theme
scenes/game.tscn  die Hauptszene (Wurzel)
scenes/menu.tscn  scenes/play.tscn
tests/test_sim.gd die Garantien (siehe unten)
docs/echtzeit-ideen.md  gesammelte Feature-Ideen, nach Wirkung sortiert
```

## Der Spieler setzt jeden Magneten selbst

`fixed_magnets` bleibt **leer**. Wo der Magnet hinkommt, ist die Entscheidung,
aus der das Spiel besteht — nimmt man sie weg, bleibt eine Rhythmusübung.

Level 1, 2 und 7 wurden einmal mit eingebautem Magneten ausgeliefert, mit der
Begründung, ein Einführungslevel solle eine Sache auf einmal lehren. Die
Begründung war falsch: sie nahm genau das weg, was eingeführt werden sollte.

Das Feld `SimLevel.fixed_magnets` existiert weiter, weil der Ideenvorrat eine
andere Verwendung dafür hat — dauerhaft aktive Feld-Möblierung, um die man
herumnavigieren muss. Für einen Magneten, den der Spieler sonst setzen würde,
ist es tabu.

Zwei Folgen sind beim Umbau aufgefallen und stehen unten im Detail: Level 2
verlor seine Lektion (sie galt nur, weil die Polarität aufgezwungen war), und der
gezeichnete Reichweitenkreis war irreführend, sobald man selbst platziert.

## Level sind Code, nicht gebacken

Beim Raster-Puzzle wurden die Level offline von einem Dart-Generator erzeugt und
solver-geprüft. Das ist weg: ein Parcours ist **gebaute Geometrie**, kein
Suchergebnis. Damit fällt die ganze Offline-Pipeline weg.

Was bleibt, ist der Vertrag: **jedes ausgelieferte Level bringt einen bewiesenen
Lösungsweg mit** (`par_placements` + `par_holds`), und `test_sim.gd` spielt sie
bei jedem Testlauf nach. Nichts wird ohne Beweis ausgeliefert — früher war das
eine Solver-Lösung, heute ein verifizierter Halteplan.

Ein `par_holds`-Eintrag ist `[magnet_index, an_tick, aus_tick]`.

### Sieben Annahmekriterien, alle aus Schaden gelernt

1. **Jeder Magnet muss tragen.** Lässt man die Haltezeiten *eines* Magneten weg
   und der Lauf gewinnt trotzdem, ist dieser Magnet Deko.
   `test_every_placed_magnet_is_load_bearing` lehnt das ab. Das ist dieselbe
   Regel, die das Raster-Spiel für Deflektoren hatte, und sie existiert aus
   demselben Grund: ein Level, das über seinen eigenen Bedarf lügt, bringt dem
   Spieler das Falsche bei. Level 4 gewann in seiner ersten Fassung nach 56 Ticks
   und hielt den zweiten Magneten ab Tick 220 — lange nach Schluss.
2. **Der Horizont ist eine Zahl.** `SimWorld.MAX_RUN_TICKS` (1200 = 20 s). Als
   der Replay-Sucher bei 480 deckelte und der Test bei 1200 lief, waren sie sich
   uneinig darüber, was „lösbar" heißt — der Sucher zertifizierte einen Plan, den
   der Test anschließend ablehnte. Dieselbe Zahl gilt auch im laufenden Spiel.
3. **Die Bahn ist gepinnt.** `PAR_FINGERPRINTS` in `test_sim.gd` hält pro Level
   Tickzahl *und* Trajektorien-Hash als Literal. Alle anderen Determinismus-Tests
   vergleichen Läufe nur miteinander und sind blind für eine Änderung, die *alle*
   Läufe gleich verschiebt — an Gravitation, Restitution oder am Kontaktlöser.
   Genau so ein Eingriff war der Umbau für bewegte Plattformen; die Pins haben
   bewiesen, dass er nichts verschoben hat. Absicht darf sie ändern, Zufall nicht.
4. **Ein Feature-Level benutzt sein Feature.** `test_a_level_with_movers_actually_rides_one`
   verlangt, dass das Par eines Levels mit Plattform diese auch berührt
   (`SimWorld.rode_mover`). Sonst steht ein Brett unter „Bewegte Plattformen“, das
   über die Plattform nichts beibringt. `test_a_flip_level_actually_needs_the_flip`
   ist dieselbe Regel für die Umpol-Taste.
5. **Ein Kriterium, das nur das Par prüft, ist blind.** `..._actually_needs_the_flip`
   nimmt die Eingabe aus dem Par heraus, lässt dessen Platzierung aber stehen —
   und sah deshalb nicht, dass Level 7 mit einer *anderen* Platzierung ganz ohne
   Umpolen zu gewinnen war (204 Wege, vom Spieler gefunden). Ein Feature-Level
   braucht zusätzlich den Rasterbeweis: Level 8 hat ihn
   (`test_08a/b_path_is_required`), Level 7 wurde einmalig so geprüft.
6. **Lösbar ist nicht fair.** `test_a_flip_level_gives_the_player_room_to_react`
   misst tickweise, wie viele Umpol-Zeitpunkte gewinnen, und verlangt mindestens
   15 (250 ms). Die erste Fassung von Level 7 erfüllte *jedes* Kriterium oben —
   bewiesenes Replay, beide Eingaben tragend — und war trotzdem unspielbar: genau
   **drei** Ticks gewannen, 50 ms. Die Landung lag so weit weg, dass nur ein
   nahezu maximaler Wurf ankam, das Fenster war also der Spalt, in dem der Wurf
   perfekt ist. Näher und tiefer gesetzt wurden daraus 900 ms, weil dann *jeder*
   Wurf über einer Untergrenze reicht.

   **Level 7 erfüllt dieses Kriterium nicht** und sagt das in seiner eigenen
   Definition (`min_flip_window = 3`). Der Grund ist strukturell: alles, was eine
   einzelne Polarität erreicht, ist als Zielort verboten, also bleibt nur der Rand
   der Reichweite — und dorthin kommen nur nahezu optimale Würfe. Vier
   Zielpositionen wurden probiert; entweder war das Brett auch ohne Umpolen zu
   gewinnen oder das Fenster blieb unter 50 ms. Ein wirklich fairer Umpol-Zwang
   braucht vermutlich einen zweiten beweglichen Teil, damit die Notwendigkeit aus
   der *Richtung* statt aus der *Energie* kommt. Die Schwelle steht deshalb pro
   Level und nicht global: ein Brett, das sie reißt, muss es selbst zugeben.
7. **Reichweite ist nicht Hebekraft**, und der Kreis muss es zeigen. Ein Magnet kann die Kugel nur anheben,
   solange `MAGNET_STRENGTH * falloff > GRAVITY` — bei linearem Abfall also unter
   **169 px** Abstand, nicht innerhalb der vollen 400 px Reichweite. Level 7 stand
   in der ersten Fassung 343 px entfernt: die Anziehung betrug dort 370 gegen 1500
   Gravitation, die Kugel rollte bloss seitwärts vom Sims. Das ist kein Testfall,
   sondern Kopfrechnen vor dem Bauen — und weil der Spieler nicht rechnen kann,
   zeichnet `play_screen.gd` neben dem Reichweitenkreis einen zweiten Ring bei
   `SimWorld.LIFT_RADIUS`. Ohne ihn behauptet der große Kreis „so weit wirke ich“,
   und ein Magnet, der heben soll, versagt für den Spieler grundlos. Dieselbe
   Fehlerklasse hatte der Prototyp schon einmal, als quadratischer Abfall die
   äußeren zwei Drittel des gezeichneten Kreises wirkungslos machte.

### Ein neues Level bauen

Geometrie in `levels.gd` schreiben, `par_placements`/`par_holds` leer lassen,
dann den Sucher hochdrehen (`SAMPLES` in `tests/test_zz_find_replays.gd`, im
Alltag auf 250 gedrosselt) und laufen lassen. Das Ergebnis landet in
`tools/replays_found.txt` und wird von Hand nach `levels.gd` übernommen.

Der Sucher ist in Slices geteilt: der Runner bedient den Editor-Transport nur
*zwischen* Tests, ein minutenlanger Testkörper wirft die Session ab.

**Für Level mit fester Magnetbestückung wird nicht gewürfelt, sondern gerechnet.**
`test_07_schleuder_sweep` zählt das ganze Raster aus Haltefenster × Umpolfenster
durch — ein paar tausend Läufe, billiger als 1200 Stichproben und im Gegensatz zu
ihnen eine Antwort statt einer Vermutung. Die Zufallssuche scheiterte an Level 7
aus einem Grund, der sich merken lässt: sie zieht den Haltebeginn über 0–445
Ticks, während auf diesem Brett *jede* Lösung bei Tick 0 anfängt — 89 von 90
Stichproben waren vertan, bevor die Suche überhaupt interessant wurde.

**Findet der Sucher nichts, ist meistens das Level schuld, nicht die Suche.** Das
ist zweimal passiert: Level 2 stand mit dem Magneten 580 px vom Fallweg entfernt,
also dauerhaft außerhalb seiner eigenen 400-px-Reichweite — unlösbar. Und Level 4
verlangte in einer Fassung 205 px Steigung zusätzlich zur Distanz; 2000
Zufallspläne scheiterten, was ein fairer Stellvertreter für einen Spieler am
vierten Brett ist. Ein Einstiegslevel, das die Zufallssuche nicht knackt, ist zu
schwer.

## Die Kampagne: ein Level pro Mechanik

Jedes `SimLevel` trägt ein `feature`. Das Menü gruppiert danach, also bringt ein
neues Feature-Level seine eigene Überschrift mit und braucht am Menü keine Zeile.

**Grundlagen**

| # | Titel | Lektion |
|---|-------|---------|
| 1 | Schub | Halten wirkt, und die Ladung ist endlich |
| 2 | Flug | Ein langer Fall — lenken statt rollen |
| 3 | Lücke | Die Lücke im Boden ist der Weg, nicht das Hindernis |
| 4 | Zwei | Ein Feld reicht 400 px; der Weg ist 530 lang — also übergib |
| 5 | Parcours | Zwei Kanten, zwei Lücken, jede auf der anderen Seite |

**Bewegte Plattformen**

| # | Titel | Lektion |
|---|-------|---------|
| 6 | Aufzug | Die Plattform trägt dich — warte, bis sie unten ist |

**Polarität umkehren**

| # | Titel | Lektion |
|---|-------|---------|
| 7 | Schleuder | Erst anziehen, um die Kugel zu holen — dann umpolen und wegschleudern |

**Geplante Magnetbahn**

| # | Titel | Lektion |
|---|-------|---------|
| 8 | Fahrt | Zieh dem Magneten vor dem Start eine Bahn; er schleppt die Kugel mit |

Dass ein Anziehmagnet die Kugel **bei sich parkt** statt sie vorbeizuschleudern,
ist die überraschendste Eigenschaft des Spiels. Level 2 lehrte das einmal — aber
nur, weil es einen Anziehmagneten aufzwang. Mit freier Wahl gewinnt dort ein
Abstoßer mühelos, das Brett hätte also über sich selbst gelogen. Die Lektion sitzt
jetzt in Level 7, wo die Mechanik sie erzwingt.

## Bewegte Plattformen

`SimLevel.MoverSpec` ist eine **Dreieckswelle**: hin über `period` Ticks, zurück,
gesteuert allein vom Tick-Zähler. Bewusst keine Sinuskurve — `sin` ist von
IEEE 754 nicht bitgenau festgelegt und bräche genau die Regel oben. Die Bahn
akkumuliert nichts, also kann eine Plattform über einen langen Lauf nicht aus der
Phase driften, und jeder Tick ist einzeln auswertbar.

Der Kontakt wird **im Bezugssystem der Plattform** gelöst: Stoß und Reibung
rechnen auf der Relativgeschwindigkeit, danach kommt die Plattformgeschwindigkeit
wieder drauf. Für eine Wand ist sie null, und Null abziehen und wieder addieren
ist in IEEE 754 exakt — deshalb hashen alle vor den Plattformen aufgenommenen
Replays unverändert. Das ist geprüft, nicht gehofft (siehe Fingerprints unten).

**Plattformen fahren senkrecht, nicht waagerecht.** `FRICTION` ist mit 0,015 pro
Tick absichtlich klein, damit Rollen sich nicht wie Sand anfühlt. Eine waagerecht
fahrende Plattform zieht die Kugel deshalb kaum mit — sie erreicht über eine
ganze Fahrt nur etwa drei Viertel der Plattformgeschwindigkeit und rutscht hinten
runter. Ein Aufzug braucht gar keine Reibung: die Kontaktnormale trägt direkt.
Waagerechte Plattformen brauchen erst eine Änderung am Kontaktmodell, kein Level,
das halb funktioniert.

## Polarität umkehren

`SimWorld.INVERT_BIT` reitet in derselben Bitmaske wie die Halte-Bits, oberhalb
der vier Magnet-Bits — die Regel „eine Bitmaske pro Tick“ bleibt also wörtlich
erhalten, und im Halteplan erscheint das Umpolen als ganz normaler Eintrag
`[INVERT_INPUT, an_tick, aus_tick]`.

**Halten kehrt um, kein Umschalter.** Ein Umschalter bräuchte Gedächtnis über
Ticks hinweg, und ein verlorener oder doppelter Tick würde die Polarität für den
Rest des Laufs verdrehen. Gehalten steht jeder Tick für sich.

Das Umkehren ist eine Entscheidung darüber, *welcher Zweig* genommen wird, kein
zusätzlicher Rechenterm — ein Lauf ohne Umpolen rechnet exakt dasselbe wie vor
dem Feature, und die gepinnten Fingerprints beweisen es.

`SimLevel.flip_enabled` schaltet die Taste pro Level frei, nicht global: die
frühen Bretter lehren, dass Anziehen die Kugel parkt und Abstoßen sie treibt, und
diese Lektionen gelten nur, solange ein Magnet die Polarität behält, mit der er
gesetzt wurde.

## Geplante Magnetbahn

Vor dem Start zieht der Spieler dem Magneten eine gerade Pendelstrecke: Drücken
setzt ihn, Loslassen legt den Endpunkt fest, ein Klick ohne Ziehen lässt ihn
stehen. Im Lauf fährt er die Strecke mit `SimWorld.MAGNET_SWEEP_SPEED` (200 px/s)
hin und her; die Legdauer folgt aus der Länge, der Spieler entscheidet also nur
über den Weg, nicht zusätzlich über ein Tempo.

**Das kostet den Determinismus nichts.** Die Bahn ist Leveldaten von *vor* Tick 0,
keine Eingabe — die Regel „eine Bitmaske pro Tick“ bleibt wörtlich erhalten, und
ein aufgezeichneter Lauf braucht kein neues Feld. `MagnetSpec.position_at()` ist
dieselbe Dreieckswelle wie bei den Plattformen und kehrt für `travel == 0` sofort
zurück, weshalb alle Bretter ohne Bahn bitgleich rechnen; die gepinnten
Fingerprints beweisen es. Der Endpunkt wird beim Loslassen auf ganze Pixel
gerundet, sonst könnte ein Replay nicht versprechen, dieselbe Bahn zu treffen.

**Warum die Bahn auf Level 8 unumgänglich ist**, in Zahlen: ein Magnet bringt eine
ruhende Kugel nur aus höchstens 400 px in Bewegung und hebt sie nur aus höchstens
169 px an. Start und Steigung liegen 670 px auseinander — mehr als 400 + 169. Es
gibt also **keinen Punkt in der Arena**, der beides kann. Ein einzelner Wurf
scheitert ebenfalls: nötig wären rund 1130 px/s, `MAX_SPEED` ist 1100.
`test_08a/b_path_is_required` rechnet das ganze Platzierungsraster durch und
verlangt, dass **kein** stehender Magnet gewinnt.

## Steuerung

Im Menü: `↑`/`↓` (oder `W`/`S`) wählen, `Enter` startet, Maus fährt und klickt
ebenso, `Esc` beendet.

Im Level: Linksklick setzt einen Magneten, Rechtsklick entfernt ihn, `Tab` schaltet die
Polarität, Leertaste startet den Lauf, `1`–`4` **gedrückt halten** lässt den
jeweiligen Magneten wirken, **Ziehen** statt Klicken gibt dem Magneten eine Bahn (nur wo das Level es
freischaltet), `Shift` **gedrückt halten** kehrt alle wirkenden Felder um (ebenso
pro Level), `R` startet neu, `P` zeigt den Musterlauf, `Esc`
geht zurück ins Menü. (`Esc` feuert `exit_requested`; unter `game.tscn` hängt die
Wurzel daran. Läuft `play.tscn` allein, hört niemand zu — dann wird beendet,
statt die Taste stumm ins Leere laufen zu lassen.)

Alles wird als roher Tastendruck abgefragt, nicht über die InputMap — die alten
Actions sind aus `project.godot` entfernt. Die Klickposition kommt aus dem
Maus-Event selbst, nicht aus `get_local_mouse_position()`: zwei Quellen für
denselben Klick können auseinanderlaufen, und die zweite ist von außen nicht
ansteuerbar.

## Tests

```
test_sim.gd   Determinismus + jedes Level ist gewinnbar und fair (17 Tests)
```

Ausführen über MCP: `test_run(suite="sim")`. Der Determinismus-Teil prüft auch
sich selbst — `test_one_different_tick_changes_the_hash` verschiebt einen Tick
und verlangt einen anderen Hash, sonst wären die anderen Tests gehaltlos.

## Der Musterlauf leiht sich das Brett nur

`P` spielt das Par-Replay ab, und dazu müssen dessen Magnete auf dem Brett stehen.
Sie gehören aber nicht dem Spieler. In der ersten Fassung schrieb der Handler
schlicht `placed = _par_placements()` — damit überschrieb ein Blick auf die
Lösung die eigene Bestückung, und nach `R` stand die Demo-Bestückung da, als hätte
man sie selbst gesetzt. Auf Level 6 fiel es auf, weil das Par abstößt, während die
Werkzeuganzeige noch „Anziehen“ sagte. Derselbe Lauf trug sich obendrein als
Bestzeit ein: die Demo spielte gegen den Rekord des Spielers.

Jetzt legt `_demo` die eigene Bestückung in `_player_placed` beiseite, und
`_leave_demo()` gibt sie zurück — aufgerufen von `R`, von der Leertaste, vom Setzen
und vom Entfernen. Gewonnene Demoläufe zählen nicht als Bestzeit.

**Diese Fehlerklasse hat keine Testabdeckung.** `play_screen.gd` ist kein `@tool`,
also kann der Test-Runner es nicht instanziieren, und die Suite prüft nur die
Simulation. UI-Zustand wird bisher von Hand im laufenden Spiel geprüft — deshalb
ist dieser Fehler beim Spieler gelandet und nicht im Testlauf.

## Zwei Grenzen des Werkzeugs

**Ein Testkörper über ~20 s wirft die Editor-Sitzung ab**, manchmal so hart, dass
die Plugin-Verbindung ganz stirbt und Godot neu gestartet werden muss. Lange
Suchläufe gehören deshalb in Scheiben à mehrere Testmethoden — der Runner bedient
den Transport nur *zwischen* Tests.

**Godot headless hilft dabei nicht.** `godot --headless --path . --script res://…`
gibt hier weder Ausgabe noch schreibt es Dateien, weder mit `_init` noch mit
`_initialize`. Das ist zweimal ausprobiert worden (einmal beim Raster-Spiel, einmal
bei der Level-7-Suche); beides Mal umsonst. Alles läuft über den Editor.

## Grafik: prozedural, in einer eigenen Datei

`board_art.gd` zeichnet das Brett, `play_screen.gd` entscheidet den Ablauf. Die
Trennung ist dieselbe Disziplin wie bei `SimWorld`: die Kunstschicht darf `sin`,
`Time` und Animation pro Frame benutzen — alles, was in der Simulation verboten
ist. Sie gibt dafür nie einen Wert zurück; jede Funktion nimmt entgegen, was sie
zeichnen soll, und liefert nichts.

**Variation kommt aus einem Hash der Position, nicht aus `randf()`.** Ein pro
Frame gewürfelter Wert liesse die Wände flimmern; der Hash hält denselben Ziegel
den ganzen Lauf lang in derselben Schattierung.

Aufgebaut wird von hinten nach vorn: Verlauf, zwei Lagen ferner Blöcke
(unterschiedlich gross, sonst liest es sich als Gitter), Rahmen, Ziel, Wände,
Magnete, Ball mit Spur, Vignette. Jede Wand entsteht aus Schatten, Körper,
Ziegelfugen, beleuchteter Oberkante, dunkler Unterkante und Kontur — die
Oberkante ist das, was eine Plattform als etwas lesbar macht, auf dem man landet.

**Das Magnetfeld zeigt seine Richtung, nicht nur seine Farbe.** Rot und Blau sind
eine Konvention, die man erst lernen muss; Ringe und Funken, die nach **innen**
laufen (Anziehen) oder nach **außen** (Abstoßen), sagen es ohne Legende. Dazu vier
Pfeilspitzen am Rand des Magneten, die dieselbe Richtung zeigen — der Teil des
Bildes, der auch bei Farbenblindheit übrig bleibt. Ist ein Magnet aktiv und die
Kugel in Reichweite, läuft ein gestrichelter Strahl zwischen beiden, ebenfalls in
Wirkrichtung; kein Strahl heißt „außerhalb der Reichweite" und beantwortet damit
die Frage, warum nichts passiert.

Gezeichnet wird die **wirkende** Polarität, nicht die gesetzte: `Shift` dreht die
Strömung sichtbar um.

Der **Rahmen** zeichnet die Seitenwände, die `SimWorld` jedem Level ohnehin
hinzufügt und die vorher unsichtbar waren; unten bleibt er offen, weil dort
wirklich kein Boden ist, und das rote Band sagt es.

## Die Editor-Cache-Falle

Der Godot-Editor merkt Änderungen an `.gd`-Dateien **nicht**, wenn sie von außen
geschrieben werden (Bash, Python, `sed`). Er liefert weiter die alte Version aus
— Tests laufen dann gegen Code, den es nicht mehr gibt. Das hat hier schon Stunden
gekostet, einmal beim Raster-Spiel und einmal bei `levels.gd`, wo eine Suche
minutenlang auf der alten Geometrie lief.

Nach jeder Bearbeitung außerhalb des Editors: `filesystem_manage(op="scan")`.
Änderungen über `script_patch` sind davon nicht betroffen.

## Was der Umbau gegenüber dem Raster-Puzzle geändert hat

Vorher war POLARIS ein rundenbasiertes Magnet-Puzzle: Magnete setzen, dann in
einer Reihenfolge aktivieren, die Kugel rutschte Feld für Feld. Das war zu leicht
und zu still — die ganze interessante Arbeit passierte im Kopf des Spielers,
während das Brett nichts zeigte. Der komplette Raster-Zweig (Solver, Generator,
Dart-Pipeline, 94 gebackene Level, Schalter & Tore) ist gelöscht; er steht im
Commit `0e9bae6`, falls je etwas davon gebraucht wird.

Geblieben ist die Disziplin: eine einzige Quelle der Regeln, und nichts wird
ausgeliefert, was nicht bewiesen ist.

## Offen

- Waagerecht fahrende Plattformen — brauchen ein Kontaktmodell, das die Kugel
  mitnimmt (siehe oben), nicht nur ein neues Level
- Förderbänder, das nächste Feature-Level
- Ein Lauf endet nach `SimWorld.MAX_RUN_TICKS`, wenn der Ball liegen bleibt.
  Das ist bewusst dieselbe Zahl wie offline — aber 20 s auf einen stehenden Ball
  zu warten fühlt sich lang an. Falls das stört, ist die Antwort ein
  *Stillstands*-Kriterium in `SimWorld` (und damit auch in den Tests), kein
  zweiter, kürzerer Timer nur im Spiel.
- Fortschritt speichern — `PlayerProgress` war ans Raster gekoppelt und ist mit
  gelöscht; das Neue braucht einen eigenen Speicher (Bestzeiten pro Level)
- Mehr Level; der Ideenvorrat steht in `docs/echtzeit-ideen.md`
- Ton, Einstellungs-Screen, Steamworks
- Lokalisierung — alle Strings stehen deutsch im Code
