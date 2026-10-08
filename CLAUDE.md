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
  sim_level.gd      reine Leveldaten: MagnetSpec + MoverSpec + GravitySpec
  levels.gd         die Kampagne, als Code
scripts/build/
  level_source.gd   Entwurf -> GDScript, und die Kopien für den Undo-Stapel
scripts/ui/
  game_root.gd      tauscht Menü, Spiel und Bau-Modus; die Startszene
  build_screen.gd   der Bau-Modus: Bretter mit der Maus zeichnen
  menu_screen.gd    Level-Auswahl, nach Feature gruppiert
  play_screen.gd    Ablauf und Eingabe; ruft BoardArt fürs Aussehen
  board_art.gd      wie das Brett aussieht — darf `sin`, `Time`, Animation
  world_art.gd      die Kulisse: Bänder pro Welt, und nichts mit Bedeutung
  polaris_theme.gd  Palette, Font und der projektweite Theme
scenes/game.tscn  die Hauptszene (Wurzel)
scenes/menu.tscn  scenes/play.tscn  scenes/build.tscn
tests/test_sim.gd die Garantien (siehe unten)
tests/test_build.gd  der Textausgabe des Bau-Modus auf die Finger geschaut
tests/test_zy_author.gd  Par-Sucher fuer Bretter mit Toren (Werkzeug, kein Test)
docs/echtzeit-ideen.md  gesammelte Feature-Ideen, nach Wirkung sortiert
```

## Der Spieler setzt jeden Magneten selbst

`fixed_magnets` bleibt **leer**. Wo der Magnet hinkommt, ist die Entscheidung,
aus der das Spiel besteht — nimmt man sie weg, bleibt eine Rhythmusübung.

Level 1, 2 und 7 wurden einmal mit eingebautem Magneten ausgeliefert, mit der
Begründung, ein Einführungslevel solle eine Sache auf einmal lehren. Die
Begründung war falsch: sie nahm genau das weg, was eingeführt werden sollte.

Das Feld `SimLevel.fixed_magnets` existiert weiter für die **eine** erlaubte
Verwendung: dauerhaft aktive Feld-Möblierung, um die man herumnavigiert. Level 9
nutzt sie. Der Unterschied ist entscheidend — Möblierung *nimmt* keine
Entscheidung weg, sie legt eine Kraft dazu, die der Spieler einplanen muss, und er
setzt seinen eigenen Magneten weiterhin selbst. Solche Magnete tragen
`always_on = true`: keine Taste, keine Ladung, nicht von `Shift` umpolbar. Für
einen Magneten, den der Spieler sonst gesetzt hätte, bleibt das Feld tabu.

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

### Neun Annahmekriterien, alle aus Schaden gelernt

1. **Jeder Magnet muss tragen.** Lässt man die Haltezeiten *eines* Magneten weg
   und der Lauf gewinnt trotzdem, ist dieser Magnet Deko.
   `test_every_placed_magnet_is_load_bearing` lehnt das ab. Das ist dieselbe
   Regel, die das Raster-Spiel für Deflektoren hatte, und sie existiert aus
   demselben Grund: ein Level, das über seinen eigenen Bedarf lügt, bringt dem
   Spieler das Falsche bei. Level 4 gewann in seiner ersten Fassung nach 56 Ticks
   und hielt den zweiten Magneten ab Tick 220 — lange nach Schluss.
2. **Der Horizont ist eine Zahl — pro Brett.** `SimWorld.MAX_RUN_TICKS` (1200 =
   20 s) ist die Vorgabe, `SimLevel.max_ticks` hebt sie für ein einzelnes Brett an,
   und `SimWorld.run_ticks` ist die Zahl, die Spiel, Test und Sucher lesen. Als der
   Replay-Sucher bei 480 deckelte und der Test bei 1200 lief, waren sie sich uneinig
   darüber, was „lösbar" heißt — der Sucher zertifizierte einen Plan, den der Test
   anschließend ablehnte. Das darf nie wieder passieren; *global* muss die Zahl
   dafür nicht sein.

   Level 15 braucht 2400 (40 s). Sie für alle anzuheben wäre die faule Variante
   gewesen: der Horizont ist das, was ein *verlierender* Plan kostet, und die beiden
   Fairness-Sweeps in `test_sim.gd` waren schon 6,2 von 6,6 Sekunden der Suite,
   während die Rasterbeweise bei 200 s gegen ein 300-s-Budget liegen. Verdreifacht
   hätte das beide verdreifacht, um einem einzigen Brett Luft zu schaffen.
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

   **Dieselbe Frage gilt für das erste Halten — und dort hat sie ein Spieler
   gefunden statt ein Test.** `test_the_par_gives_room_for_when_you_press`
   verschiebt den Beginn des ersten Halteeintrags nach vorn und hinten, behält
   seine Länge und misst die *längste zusammenhängende* Strecke gewinnender
   Verschiebungen. Zusammenhängend, weil niemand auf einen Kamm zielen kann: Level
   8 hat 24 gewinnende Zeitpunkte, aber in Grüppchen, davon nur 6 am Stück.
   Schwelle ist `SimLevel.min_timing_window`, Standard 15 (250 ms), pro Level
   absenkbar als Eingeständnis. Der Stand:

   | Level | Fenster | | Level | Fenster |
   |---|---|---|---|---|
   | 1 Schub | 36 | | 6 Aufzug | **2** |
   | 2 Flug | 18 | | 7 Schleuder | **1** |
   | 3 Lücke | 36 | | 8 Fahrt | **6** |
   | 4 Zwei | 53 | | 9 Kurve | 31 |
   | 5 Parcours | **7** | | 10 Kippe | 61 |
   | | | | 11 Der lange Weg | 31 |

   Und pro Station, für die Bretter mit Toren:

   | Level | Stationen | schwächste |
   |---|---|---|
   | 13 Sprungfolge | 41 / 14 / 13 / **7** | **7** |
   | 14 Aufstieg | 41 / 20 / 17 / 18 | 17 |
   | 15 Die Reise | 27 / 21 / 22 / 21 / 41 | 21 |

   **Auf einem Brett mit Toren wird pro Station gemessen, nicht über die ganze
   Kette — und das ist der wichtigste Fund von Level 15.** Über die Kette gemessen
   bekommt man das *Produkt* der Toleranzen: Level 15 hat fünf Stationen mit 27,
   21, 22, 21 und 41 Ticks und ein Kettenfenster von **1**. Jede Station
   großzügig, die fünf zusammen eine Messerschneide. Dieses Produkt muss niemand
   treffen — ein Tor gibt den Lauf genau dort zurück, wo er angekommen ist, also
   ist die Einheit, die ein Spieler wiederholt, der *Abschnitt*. An der Kette
   gemessen wäre dieses Brett abgelehnt worden, ohne dass irgendwo auf ihm ein
   einziger Griff knapp ist.

   Eine Station läuft von ihrem eigenen Magneten bis zur Geburt des nächsten, also
   bis zu dem Tor, das ihn ausgibt; die letzte läuft ins Ziel. Ein Par mit *einem*
   Magneten ist damit eine Station und wird gemessen wie bisher — Level 11 hat ein
   Tor, gibt den Magneten daraus aber nie aus, und seine Zahl bewegt sich nicht.
   Bretter ganz ohne Tore behalten ebenfalls die alte Messung: dort gibt es keine
   Stationen, der Plan steht und fällt als Ganzes, und ein Abschnitt daraus wäre
   ein Plan ohne die Magnete, die er braucht (Level 4 und 5 kamen genau so
   fälschlich auf 0).

   **Damit wurden der zweite, dritte und vierte Griff überhaupt zum ersten Mal
   gemessen.** Die alte Fassung verschob ausschließlich `par_holds[0]` und zog die
   späteren Einträge nur nach. Level 13 und 14 standen deshalb mit 21 und 23 grün
   da und hatten in Wahrheit Stationen bei 7 beziehungsweise 6 Ticks. Für Level 14
   ließ sich ein neues Par suchen (41 / 20 / 17 / 18), für Level 13 nicht.

   **Level 13 erfüllt das Kriterium nicht und sagt das in seiner eigenen
   Definition** (`min_timing_window = 7`), so wie Level 7 es beim Umpolen tut. Die
   Zahl ist nicht schlechter geworden, die Messung ist ehrlich geworden. Und es
   liegt nicht am Suchen: das Werkzeug hat dieses Brett zwei Minuten lang mit
   Backtracking durchkämmt und ein Dutzend robuster Antworten für den zweiten
   Sprung gefunden, von denen jede einzelne den dritten ohne robuste Antwort
   zurückließ. Das ist eine Aussage über die Geometrie — fünf Plattformen im
   Abstand 430 — und sie zu beheben heißt, die Plattformen zu verschieben.

   Die fetten Zahlen sind offene Schulden, nicht Absicht. Level 6 verlangt den
   Druck auf 33 ms genau — dieselbe Fehlerklasse, an der Level 11 gescheitert ist.
   Und das misst nur das *Par*: dass eine andere Platzierung gutmütiger wäre, ist
   damit nicht ausgeschlossen. Für Level 11 wurde es geprüft (keine Platzierung auf
   dem linken Boden war besser als 12 Ticks), für 5–8 nicht.
7. **Jedes Level-eigene Element muss sich verdienen.** Für Möblierung: `test_a_furniture_level_actually_needs_it`
   baut das Level ohne seine eingebauten Felder neu und verlangt, dass das Par
   dann verliert; `test_09a/b_furniture_is_required` prüft dasselbe über das ganze
   Platzierungsraster. Beachte: `test_every_placed_magnet_is_load_bearing` greift
   bei Möblierung *nicht* — sie hat keine Haltezeiten, die man wegnehmen könnte,
   und ist dort ausdrücklich übersprungen. Für kippende Zonen dasselbe Paar:
   `test_a_zone_level_actually_needs_it` und `test_10a/b_zone_is_required`.
8. **Reichweite ist nicht Hebekraft**, und der Kreis muss es zeigen. Ein Magnet kann die Kugel nur anheben,
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

9. **Ein Checkpoint muss den Lauf retten, nicht einsperren.** Weil die
   Geschwindigkeit mitgenommen wird, kommt der Spieler am Tor in einem Zustand an,
   von dem aus niemand den Rest bewiesen hat. Ein Checkpoint, aus dem es keinen
   Weg gibt, ist schlimmer als keiner: er beendet den Lauf, ohne ihn zu beenden.
   `test_11a_checkpoint_is_recoverable` fährt deshalb mehrere Präfixe durch
   dasselbe Tor — unterschiedlich schnell — und verlangt für jede Ankunft, dass
   *irgendeine* Platzierung des freigeschalteten Magneten das Brett zu Ende bringt.
   Das ist eine **Stichprobe, kein Beweis**: die Ankunftszustände sind ein
   Kontinuum, das Raster läuft darüber. Der Preis steht im Abschnitt „Checkpoints".

   **Diesen Beweis hat Level 13 nicht.** `_can_finish_from` setzt *einen* Magneten
   und sucht einen Sieg; auf einem verketteten Brett braucht es nach dem ersten Tor
   noch drei. Die Maschinerie passt also nicht, und ein Beweis, der nicht passt,
   wird nicht so getan als ob. Steht unter „Offen".

   Dazu ein billiger Nachbar: `test_a_level_never_promises_more_magnets_than_there_are_keys`.
   Die Halte-Tasten sind `1`–`SimWorld.HOLD_KEYS`; Checkpoint-Zugaben kommen erst
   *während* des Laufs dazu, also kann ein Brett, das beim Start im Budget liegt,
   trotzdem einen Magneten verteilen, den keine Taste aktiviert.

   **`HOLD_KEYS` steht auf 6 und war lange 4.** Vier war die Zahl, solange die
   längste Kette vier war, und sie deckelt, wie viele Stationen eine Reise haben
   kann: ein Magnet vor dem Start plus einer pro Tor. Level 15 braucht fünf. Die
   Grenze ist dabei die **Hand**, nicht die Bitmaske — unter `INVERT_INPUT` sind die
   Bits 0..15 frei, also hat die Maske Platz für weit mehr, als jemand Finger hat.
   Weiter hochziehen erst, nachdem jemand beim Griff nach Taste 7 zugesehen wurde.

**Das Budget wird in zwei Töpfen gezählt.** `test_par_placements_match_the_budget`
verlangt, dass die Magnete mit Geburtstick 0 genau `budget` sind — das sind die vor
dem Start gesetzten. Der Rest wurde an Toren verdient und darf höchstens so
zahlreich sein, wie die Tore hergeben, und **muss** einen Geburtstick tragen; sonst
stünde er von Anfang an mit auf dem Brett. Level 13 setzt vier Magnete gegen ein
Budget von eins, und die drei zusätzlichen sagen das mit ihrem Geburtstag.

### Ein neues Level bauen

**Der Regelfall: `tests/test_zy_author.gd`.** Geometrie in `levels.gd` schreiben,
`par_placements`/`par_holds` leer lassen, `TARGET_LEVEL` im Werkzeug setzen,
`test_run(suite="author")` — heraus kommt in `tools/found_par.txt` ein fertig
einsetzbarer Halteplan plus die Zeile für `PAR_FINGERPRINTS`. Übernommen wird von
Hand; das Werkzeug schreibt nie Quelltext.

Es sucht **einen Magneten pro Stufe**, und die Stufen ergeben sich aus den Toren
selbst: vom Start zu Tor 1, von Tor zu Tor, vom letzten Tor ins Ziel. Ein Brett
ohne Tore ist dann einfach eine Stufe (Level 1: 0,3 s). Bretter mit `budget > 1`
lehnt es ab und verweist auf den Zufallssucher.

**Warum es existiert, in Zahlen:** Level 13 und 14 wurden gebaut, indem ich diese
Suche dreimal von Hand schrieb — jedes Mal mit einem anderen Fehler, dazwischen
Dutzende Editor-Neustarts und zwei abgerissene Sitzungen. Dieselbe Kette für
Level 14 findet das Werkzeug in **9 Sekunden**, mit Urteil.

Jeder dieser Fehler ist jetzt eine Regel *in* der Suche statt einer Lehre, die man
neu zieht:

- **Ein Sieg zählt nur auf der letzten Stufe.** Ihn früher zu akzeptieren ließ
  einen Magneten über zwei Plattformen schleudern; die späteren wurden Deko.
- **Der erste Treffer ist meist die Messerschneide.** Zweimal ergab er ein Fenster
  von einem Tick. Ein Zug muss jetzt eine *ganze zusammenhängende Strecke* von
  `min_timing_window` Verschiebungen überstehen — nicht deren zwei Enden, und nicht
  ±6 pauschal. Beides war falsch, und beides hat Level 13 vorgeführt: mit nur den
  Enden kam ein Kandidat durch, der −7 und +7 gewann und mehrere Ticks dazwischen
  verlor (niemand zielt auf einen Kamm), und weil eine Verschiebung auf den
  Geburtstick geklemmt wurde, war bei einem Halt, der mit seinem Magneten beginnt,
  die negative Hälfte eine Kopie von null — „hält ±7" hieß „hält 0..+7", also
  genau die 8, die zurückkam.
- **Ein Halt darf später beginnen als sein Magnet geboren wird.** Auf einem
  Aufstieg *muss* er das.
- **Die Abschnittsregel gehört in die Suche**, nicht dahinter.
- **Die Eröffnung beginnt nie bei Tick 0**, sonst wird die Kugel gerissen, bevor
  sie liegt.

- **Was geprüft wurde, muss auch das sein, was aufgeschrieben wird.** Das Raster
  lag auf der Kugelposition, und die ist ein Bruchteil; gedruckt wurde mit `%d`.
  Level 15s Par lief im Werkzeug auf 688 Ticks und im Test in die Uhr, ein Tor
  einen Tick zu früh. Die Positionen werden jetzt auf ganze Pixel gerundet —
  derselbe Grund, aus dem das Spiel den Endpunkt einer gezogenen Bahn rundet.
- **Gierig heißt nicht klug, also darf die Suche zurück.** Sie nimmt die *nächste*
  Position, die ihre eigenen Verschiebungen übersteht, und „nächste" ist nicht
  dasselbe wie „lässt den Lauf irgendwo Brauchbarem". Level 13 und 14 scheiterten
  genau daran: eine völlig robuste Eröffnung, die die Kugel dorthin legte, wo die
  zweite Station keine robuste Antwort hatte — und der Bericht gab der Geometrie
  die Schuld für eine Entscheidung drei Zeilen vorher. Findet eine Stufe nichts,
  nimmt das Werkzeug jetzt die Antwort der vorigen zurück und sucht dort weiter.
  Für Level 14 fand es damit eine durchweg faire Kette (41 / 20 / 17 / 18); für
  Level 13 auch nach zwei Minuten keine, was die Aussage „das Brett ist zu scharf
  geschnitten" erst belastbar macht.

Vier Eigenschaften, die die Wegwerf-Proben nicht hatten:

- **Zeitbudget in Scheiben** (`BUDGET_MS`, 14 s) — und zwar **20 Scheiben, nicht
  eine pro Stufe**. Der Runner bedient den Editor nur *zwischen* Tests, ein Körper
  über rund zwanzig Sekunden nimmt die Sitzung mit; eine Methode pro Stufe deckelt
  damit stillschweigend die *Stufe* auf vierzehn Sekunden. Auf einem Reise-Brett
  reicht das nicht: Level 15s Wandklettern wird 600 Ticks nach dem Start geboren,
  also spielt jeder Kandidat erst diese 600 Ticks nach, bevor er etwas sagt — die
  Stufe lief zweimal hintereinander ins Budget, nachdem sie vielleicht die Hälfte
  ihrer Ringe gesehen hatte, und meldete „Zeitbudget aufgebraucht", was wahr und
  nutzlos ist. Eine Scheibe setzt jetzt genau dort fort, wo die letzte aufhörte:
  gleiche Stufe, gleicher Ring, gleiche Zelle. Das Budget gehört damit der *Suche*
  und nicht einer Stufe.
- **Ein Lauf wird bei `SEGMENT_MAX` hinter der Geburt abgeschnitten.** Ticks danach
  lehnt das Urteil ohnehin ab, also lehren sie nichts und kosten alles. Gemessen:
  ohne den Schnitt verbrannte Level 15s letzte Stufe die vollen 14 s und fand
  nichts — weil ein Kandidat, der scheitert, indem er die Kugel am fremden Feld
  parkt, sie über den ganzen 2400-Tick-Horizont am Leben hält. Auf einem
  Fünf-Sekunden-Brett mit offenem Boden fällt eine falsche Antwort nach einer
  halben Sekunde aus der Welt und das Problem existiert nicht.
- **Diagnose statt Schweigen.** Scheitert eine Stufe, läuft sie ohne die
  optionalen Regeln nochmal. Die Antwort lautet dann „gar nicht erreichbar — die
  Geometrie ist schuld", „erreichbar, aber zu knapp geschnitten" oder
  „Zeitbudget aufgebraucht". Das ist der Unterschied zwischen einer Stunde und
  einer Minute.
- **Das Urteil sagt, *welche* Station nachgibt.** Eine Zahl allein ist auf einem
  verketteten Brett nicht handlungsfähig: fünf fast faire Stationen multiplizieren
  sich zu einer Kette, die es nicht ist, und was zu tun ist, hängt ganz daran,
  welche zuerst nachgibt. Der Bericht listet deshalb das Fenster **je Station**,
  dazu das Kettenfenster als Schwierigkeitsangabe und ein Profil, wie weit der Lauf
  bei jeder Verschiebung kommt.
- **Es rastert ringförmig von der Kugel nach außen.** Zeilenweise aus der Ecke
  verbrauchte das ganze Budget auf Positionen 500 px entfernt und meldete
  „nichts gefunden" für eine Stufe, die Antworten hat — gemessen: 15,2 s ohne
  Ergebnis, ringförmig 4,4 s mit.

**Der Zufallssucher bleibt für Bretter ohne Tore und mit mehr als einem Magneten
vor dem Start** (`SAMPLES` in `tests/test_zz_find_replays.gd`, im Alltag auf 250
gedrosselt). Das Ergebnis landet in
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

**Fremdes Feld**

| # | Titel | Lektion |
|---|-------|---------|
| 9 | Kurve | Das fremde Feld wirkt durch die Wand und zieht dich an ihr hoch |

**Kippende Schwerkraft**

| # | Titel | Lektion |
|---|-------|---------|
| 10 | Kippe | Im Schacht kippt die Schwerkraft im Takt — ein Takt allein reicht nicht |

**Alles zusammen**

| # | Titel | Lektion |
|---|-------|---------|
| 11 | Der lange Weg | Brücke, dann der Tunnel über dem Nichts — steig ein, wenn der Takt nach oben zeigt |

**Zeitlupe**

| # | Titel | Lektion |
|---|-------|---------|
| 12 | Zeitlupe | Dasselbe Brett — aber nach dem Tor läuft die Zeit langsam, bis du gehalten hast |
| 13 | Sprungfolge | Der Ball ist hier leicht genug zum Springen — vier Lücken, vier Höhen |

**Aufstieg**

| # | Titel | Lektion |
|---|-------|---------|
| 14 | Aufstieg | Immer abwechselnd links und rechts nach oben — unter dir ist nichts |

**Die Reise**

| # | Titel | Lektion |
|---|-------|---------|
| 15 | Die Reise | Fünf Stationen am Stück; jedes Tor schenkt dir den Magneten für das, was danach kommt |

Level 12 ist **kein** neues Brett, sondern Level 11 aus derselben Funktion
(`Levels._lange_strecke`), mit einem Flag Unterschied. Das ist die einzige
absichtliche Dopplung in der Kampagne, und sie hat einen Grund: die Frage lautet,
was verlangsamte Zeit mit einer Entscheidung macht, und jeder andere Unterschied
zwischen den beiden würde die Antwort verwässern. `SimLevel.twin_of` sagt es
laut — die teuren Rasterbeweise überspringen einen Zwilling, weil sie sonst eine
Minute Suchbudget dafür ausgeben, eine Antwort noch einmal herzuleiten, die für
das Original schon aktenkundig ist. Die billigen Prüfungen laufen auf beiden, und
**beide sind auf denselben Fingerprint gepinnt** (299 / 1276947690) — der Beweis,
dass die Zeitlupe die Simulation nie erreicht.

Dass ein Anziehmagnet die Kugel **bei sich parkt** statt sie vorbeizuschleudern,
ist die überraschendste Eigenschaft des Spiels. Level 2 lehrte das einmal — aber
nur, weil es einen Anziehmagneten aufzwang. Mit freier Wahl gewinnt dort ein
Abstoßer mühelos, das Brett hätte also über sich selbst gelogen. Die Lektion sitzt
jetzt in Level 7, wo die Mechanik sie erzwingt.

### Level 13: das Brett, auf dem der Ball springt

Fünf Plattformen auf **vier verschiedenen Höhen**, Abstand 430 px, also viermal
150 px Nichts dazwischen. Ein Magnet vor dem Start, drei an den Toren — vier
Sprünge, vier Tasten, das Maximum.

**Hier ist der Ball leicht.** `SimLevel.magnet_strength` steht auf 6000 statt der
2600 der Kampagne. Das ist der Unterschied zwischen Steuern und Springen: bei 2600
schlägt ein Magnet die Schwerkraft nur innerhalb von 169 px, was reicht, um eine
rollende Kugel zu lenken, und nie, um eine liegende aufzuheben. Bei 6000 sind es
300 px, und ein Magnet 100 px über der Kugel zieht sie mit 3000 px/s² nach oben,
doppelt so stark wie die Schwerkraft nach unten. Erst dadurch dürfen die
Plattformen überhaupt unterschiedlich hoch stehen — eine Stufe *nach oben* war
vorher unmöglich, gemessen: die Kugel verlässt eine Plattform bei y=685 und ist am
Ort der nächsten schon bei 771.

Die Stärke steht **pro Level** und nicht global, und das ist keine Zaghaftigkeit:
sie global zu ändern hätte zwölf bewiesene Replays ungültig gemacht. Seit es
`SimLevel.field_strength` gibt, gilt sie außerdem nur für die Magnete des
*Spielers* — die eingebauten Felder des Levels haben ihre eigene Zahl, siehe
„Fremdes Feld". Bretter, die
das Feld nicht setzen, rechnen bitgleich weiter — die gepinnten Fingerprints
beweisen es.

Zwei Sachen, die der Bau gelehrt hat:

- **Die Tore stehen am *nahen* Rand jeder Plattform.** Der Anzieher, der die Kugel
  hinüberträgt, parkt sie auch: sie kommt im Schritttempo an und bleibt irgendwo
  liegen — gemessen über eine Spanne von 200 px. Mit dem Tor am fernen Ende hätte
  eine kurze Landung den Spieler ohne Magneten und ohne Bewegung zurückgelassen,
  also in genau der Sackgasse, die Kriterium 9 verbietet.
- **Ein gieriger Sucher findet Messerschneiden.** Die erste gefundene Kette gewann
  in 406 Ticks und hatte ein Fenster von **einem Tick** — jede Stufe lag am Rand
  ihres Fensters, weil der Sucher den ersten Treffer nimmt und der erste Treffer
  typischerweise der knappste ist. Die Fairness-Schwelle hat sie abgelehnt. Ein
  Zug wird jetzt nur akzeptiert, wenn er auch um ±6 Ticks verschoben noch landet;
  das trifft die Mitte eines Fensters statt seines Randes. Dieselbe Suche liefert
  dann 396 Ticks und ein Fenster über der Schwelle.

Das Par: vier Magnete, Tore bei 111, 220 und 293, 396 Ticks. Jeder Magnet trägt
seinen eigenen Sprung — lässt man einen weg, gewinnt der Lauf nicht mehr.

### Level 14: senkrecht, und ein Fund, der alle Sprungbretter betrifft

Fünf Plattformen im Zickzack nach oben, 140 px pro Stufe, 80 px Lücke zur Seite,
und darunter nichts. Das erste Brett, das höher als breit ist (800×1200) — die
Kamera zeigt beim Planen den ganzen Aufstieg und folgt im Lauf bei 1:1.

**Der wichtige Fund: der erste Griff darf nicht bei Tick 0 anfangen.** Das Par
hatte zuerst `[0, 0, 92]` und ein Fairness-Fenster von **einem Tick**. Die Ursache
war nicht die Geometrie, sondern der Kontaktzustand: steht der Magnet schon bei
Tick 0 in Hebereichweite, reißt er die Kugel hoch, *bevor* sie auf der Plattform
zur Ruhe gekommen ist. Gemessen ergab eine Verzögerung von drei Ticks deshalb
keinen verschobenen, sondern einen **anderen** Lauf — Tor 1 wanderte von Tick 105
auf 99, also nach *vorn*. Mit `[0, 20, 112]` liegt die Kugel erst still, und ein
kleiner Fehlgriff ist wieder das, was er sein soll: derselbe Sprung, einen Moment
später. Das gilt für jedes künftige Sprungbrett.

Zwei weitere Sachen, die die Suche gelernt hat:

- **Der Rücksprung ist teurer als der Hinsprung.** Mit 200 px Höhe und 200 px
  Weite fand sich für die *zweite* Stufe im ganzen Raster keine robuste Lösung,
  obwohl die erste ging: zurück kostet dieselbe Steigung ohne Anlauf. 140 px und
  80 px sind die Maße, die durchgehen.
- **Die Abschnittsregel gehört in die Suche, nicht dahinter.** Eine Kette lag bei
  105 / 114 / **39** / 87 Ticks und wäre von
  `test_the_par_passes_every_checkpoint_in_order` abgelehnt worden. Der Sucher
  verlangt jetzt schon beim Wählen, dass das nächste Tor mindestens 48 Ticks hinter
  dem vorigen liegt.

**Richtungswechsel kostet doppelt, und die gedehnte Zeit muss darauf liegen.**
Der Rücksprung heißt: erst den Schwung töten, dann in die Gegenrichtung
beschleunigen. Die Antwort des Pars ist, zu *warten*, bis die Kugel steht, und
dann zu greifen. Solange die Zeitlupe 25 Ticks lief, war sie in genau diesem
Moment schon aus, und wer sie benutzte, drückte zu früh. Mit 70 Ticks liegt sie
auf dem Warten: nachgemessen wird jeder der drei Magnete jetzt *in* Zeitlupe
gegriffen (Tick 166, 287, 410), Level 13 bleibt unverändert bei 25.

Das Par: vier Magnete, Tore bei 118, 176 und 258, gewonnen in 353 Ticks.
Abschnitte 118 / 58 / 82 / 95, jeder Magnet trägt seinen eigenen Sprung.

**Neu gesucht, nachdem die Fairness je Station gemessen wurde.** Das alte Par
(493 Ticks) hatte Stationen bei 41 / 20 / **6** / **10** — die alte Messung hatte
den dritten und vierten Griff nie angefasst. Mit Backtracking fand das Werkzeug
eine Kette, die überall über der Schwelle liegt: **41 / 20 / 17 / 18**. Der erste
Griff beginnt weiterhin nicht bei Tick 0, aus dem Grund darüber.

### Level 15: der Prototyp für ein *langes* Level

Level 1 bis 14 stellen je eine Frage und sind nach fünf bis acht Sekunden vorbei.
Dieses Brett stellt fünf hintereinander, und es existiert, um eine Frage über die
**Form** zu beantworten statt über eine Mechanik: trägt ein langes verkettetes
Brett, oder fühlt es sich an wie vier aneinandergeklebte Level?

**Was „lang" hier heißen kann und was nicht.** Ein fünfminütiger *Lauf* ist nicht
das, was man bauen will. Fünf Magnete sind fünf Entscheidungen; bei fünf Minuten
Flug entscheidet der Spieler alle sechzig Sekunden einmal und sieht den Rest zu —
Level 11s Fehlerbild (fünf Sekunden, getrieben von *einem* Druck) ins Große
gezogen. Lang macht ein Brett die **Zahl der Stationen**; lang macht eine
*Sitzung* das Planen, die Zeitlupe und die Wiederholungen. Gemessen: 967 Ticks
Flug (16,1 s), dazu vier Zeitlupenstrecken à 70 Ticks in Fünffachdehnung, macht
rund **35 Sekunden Wanduhr pro Versuch** — beim Musterlauf nachgemessen. Ein
Erstspieler ist damit Minuten beschäftigt.

Jede Station ist ein Stück, das die Kampagne schon bewiesen hat, in Reihe:

1. der Stoß und die **schwingende Brücke** — Level 11s Eröffnung, unverändert
2. der **Schacht mit kippender Schwerkraft** — auf dem richtigen Takt hinein
3. hinaus aus dem Schacht und hinüber auf ein **hohes Sims**
4. vom Sims über die Lücke an die **Wand**
5. das **fremde Feld** hinter der Wand zieht dich an ihr hoch, ins Ziel

Bewährte Bausteine wiederzuverwenden ist bei einem Prototyp der Punkt: scheitert
er, soll er an der Form scheitern und nicht daran, dass Station drei schlecht
geschnitten war.

**Vier Funde, alle vom Werkzeug gemeldet, keiner geraten:**

- **Reichweite ist nicht Hebekraft — schon wieder.** Das Ziel lag zuerst 220 px
  über dem Ankunftspunkt, hinter der Wand. Das Werkzeug meldete nicht „knapp",
  sondern **gar nicht erreichbar**, und das zu Recht: aus der Ruhe hebt ein
  2600-Feld etwa 170 px und keinen Pixel weiter, weil es die Schwerkraft nur
  innerhalb von 169 px schlägt und ein Anzieher die Kugel bei sich parkt. Ein
  Magnet, der hoch genug steht, um zu nützen, ist zu weit weg, um zu ziehen. Erst
  eine **Landung am Fuß der Wand** teilt Überqueren und Steigen in zwei Stationen,
  die einzeln hineinpassen. Kriterium 8, trotz eigener Aktennotiz hineingelaufen.
- **Das Ziel bleibt auf der Seite, auf der die Kugel ist.** Bei Level 9 wird die
  Wand nie überquert — das fremde Feld dahinter macht die *diesseitige* Seite
  erkletterbar. Der erste Entwurf wollte über die Wand hinweg und war damit
  unlösbar.
- **Ein Tor braucht Vorlauf, aber nicht zu viel.** Die Stationen 3, 4 und 5 kamen
  zuerst auf 11, 7 und 9 Ticks, alle drei aus demselben Grund: das Tor stand so
  dicht vor seiner Gefahr, dass der Magnet fast zu spät geboren wurde. Die Tore
  ein Stück zurückgesetzt, wurden daraus 21, 21 und 41. Umgekehrt gilt es auch —
  Tor 4 an den Rand der Lücke geschoben machte die letzte Station *unlösbar*,
  weil sie dann Überqueren **und** Steigen enthielt.
- **Zwei Tore auf einer Geraden sind wieder keine zwei Stationen.** Ein Band über
  dem ganzen Sims feuerte beim Aufsetzen; der Abschnitt davor maß 48 Ticks, exakt
  die Untergrenze. Am fernen Ende des Sims steht es da, wo es hingehört: direkt
  vor der Lücke.

Das Par: fünf Magnete, Tore bei 216 / 442 / 813 / 869, gewonnen nach 967 Ticks.
Abschnitte 216 / 226 / 371 / 56 / 98.

**Was das Brett noch nicht hat:** den Rückweg-Beweis (Kriterium 9) und den
Rasterbeweis, dass kein gewinnender Weg ein Tor auslässt (wie `test_11c/d`). Beides
steht unter „Offen", zusammen mit Level 13 und 14, denen dasselbe fehlt.

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

**Eine Plattform, die der Weg *ist*, muss um die Weghöhe schwingen — nicht
darunter hängen.** Die Brücke in Level 11 saß zuerst auf Bodenhöhe und fuhr 180 px
nach unten. Auf Übergangshöhe war sie damit nur einen Augenblick pro Zyklus, und
das Zeitfenster für den Eröffnungsstoß betrug **12 Ticks (200 ms)**. Wer es
verfehlte, fiel in die Lücke, hüpfte dort auf der Plattform und wartete die vollen
20 Sekunden ab — ohne je einen Checkpoint erreicht zu haben, an den er hätte
zurückfallen können. Ein Spieler hat das gemeldet, kein Test.

Jetzt sitzt sie 40 px über der Bodenlinie und fährt 100 px nach unten, schwingt
also durch die Übergangshöhe hindurch: **31 Ticks (517 ms)**. Die ganze Achse wurde
vorher durchgemessen, und die naheliegende Idee — die Plattform einfach
*langsamer* machen — ist nachweislich schlechter (Takt 110 und 150: null Gewinner),
weil die Kugel dann ankommt, während die Brücke weit unten steht, und nicht mehr
herauskommt.

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

## Fremdes Feld

Ein Magnet mit `always_on = true` wirkt in jedem Tick, ohne Taste und ohne Ladung,
und `Shift` polt ihn nicht um: er gehört dem Level, nicht dem Spieler.

**Es hat seine eigene Stärke.** `SimLevel.magnet_strength` gilt für die Magnete des
Spielers, `SimLevel.field_strength` für die des Levels; 0 heißt „wie die des
Spielers". Die beiden zu trennen war überfällig, und Level 15 hat gezeigt warum:
das fremde Feld muss von hinter einer Wand **heben helfen**, was Kraft verlangt,
während der Magnet des Spielers die Kugel nicht einfach bei sich parken darf, was
Zurückhaltung verlangt. Eine Zahl kann immer nur eins von beidem.

In `SimWorld.step` ist das die Wahl zwischen zwei Zahlen, kein zusätzlicher Term —
und auf einem Brett, das die beiden nie getrennt hat, sind sie gleich, also rechnet
es bitgleich weiter. `test_a_board_can_tune_its_own_field_apart_from_the_players`
prüft beide Hälften: ein schwächeres Fremdfeld *muss* den Lauf ändern (sonst greift
das Feld gar nicht), und auf denselben Wert gesetzt *muss* der Lauf derselbe sein.

Dazu ein gezeichnetes Detail, das sonst wieder lügen würde: `lift_radius()` ist der
Hebekreis des Spielers, `field_lift_radius()` der des Levels. Ein fremdes Feld mit
dem Radius des Spielers zu zeichnen wäre genau die Unwahrheit, gegen die der innere
Ring überhaupt eingeführt wurde (Kriterium 8), eine Ebene weiter. In
`SimWorld.step` ist das ein übersprungener Vorabcheck, kein zusätzlicher
Rechenterm — Bretter ohne Möblierung rechnen bitgleich weiter, die Fingerprints
beweisen es.

`magnets_for()` liefert seit Level 9 **erst die gesetzten, dann die eigenen des
Levels**. Andersherum hätte ein Brett mit einem eingebauten Feld den Magneten des
Spielers auf Taste 2 gelegt, und der Index in einem Halteplan hätte nicht mehr zur
aufgedruckten Zahl gepasst.

### Was ein dauerhaftes Feld kann — und was nicht

Drei Entwürfe für Level 9 wurden verworfen, jeder mit einer Messung als Begründung.
Das spart beim nächsten Möblierungs-Level Zeit:

- **Anziehen, das die Kugel hochträgt** funktioniert (58 gewinnende Pläne), war
  aber Level 7 mit anderem Anstrich — 7, 8 und 9 endeten alle auf demselben Bild.
  Der Nutzer hat das zu Recht als Kopie zurückgewiesen. **Mechanik-Etikett ≠
  Spielgefühl.**
- **Ein Abstoßer als Katapult** geht nicht. Ein dauerhaft aktiver Abstoßer ist ein
  Kissen: er drückt die Kugel bis zum Abstand, wo seine Kraft der Gravitation
  entspricht, und hält sie dort, weil nichts Energie speichert. Gemessener
  Anstieg: 25 px.
- **Ein Abstoßer als seitlicher Pflug** engt eher ein, als dass er trägt. Zellweise
  kartiert erreichte die Kugel **mit** ihm 13 Felder, **ohne** ihn 14.

Was tatsächlich trägt, hat erst die Messung gezeigt: **ein Feld wirkt durch
Geometrie hindurch**. Der fremde Anzieher steht hinter einer hohen Wand und
presst die Kugel dagegen — sie klebt an der Wandfläche und wird an ihr *nach oben*
gezogen, bis auf Zielhöhe. Im Trace steht die Kugel bei x=405, exakt einen
Ballradius links der Wand bei 420. Mit Feld erreicht sie 56 Zellen, ohne 48.

Dass Magnetfelder Wände ignorieren, stand die ganze Zeit in `SimWorld` — benutzt
hatte es kein Level. Die ursprüngliche Beschreibung dieses Bretts sprach von einer
„gebogenen Flugbahn um die Ecke“; das war eine Geschichte vor der Messung und
stimmte nicht.

**Das Ziel wurde nicht geraten, sondern gemessen.** Die Karte nannte acht Zellen,
die nur das Feld erreicht; das Ziel liegt in den zwei benachbarten davon. Ein
erster Versuch legte einen Sims darunter als Fangfläche — und löschte damit jede
Lösung, weil die Karte auf der Geometrie *ohne* Sims gemessen war. Wer das Ziel
nach einer Karte setzt, darf die Geometrie danach nicht mehr anfassen.

## Kippende Schwerkraft

`SimLevel.GravitySpec` ist ein Rechteck plus Takt: innerhalb zieht es `period`
Ticks lang **nach oben**, dann ebenso lange normal. Der Zustand ist eine reine
Funktion des Tick-Zählers und ein Ganzzahlvergleich — nichts akkumuliert, also
kann der Takt über einen langen Lauf nicht driften, und jeder Tick ist einzeln
auswertbar. Dieselbe Disziplin wie bei `MoverSpec`.

In `SimWorld.step` **ersetzt** eine gekippte Zone die Schwerkraft, statt etwas
dazuzuaddieren: drinnen *ist* unten oben. Ein Vorzeichen zu wählen ist kein
zusätzlicher Rechenterm, deshalb rechnen Bretter ohne Zone bitgleich weiter — die
gepinnten Fingerprints beweisen es.

**Der Schacht ist absichtlich höher, als eine Aufwärtsphase schafft.** Die Kugel
steigt, der Takt kippt, sie fällt zurück. Zu entkommen heißt, im richtigen Moment
Auftrieb dazuzugeben — dafür ist der Magnet da. Nachgewiesen: 274 gewinnende Pläne
mit Zone, **0 ohne** (`test_10a/b_zone_is_required`).

**Ein Versatz, der aus einer positiven Drift mal Richtungsvorzeichen entsteht,
teleportiert.** Kippt das Vorzeichen, springt der Wert von `-drift` auf `+drift`,
also um das Doppelte — in einem einzigen Frame. Gemessen waren das **62 px pro
Tick**, 1,5-mal pro Sekunde. Das war der Fehler, den der Spieler gesehen hat.

Richtig ist, den Versatz als **Integral einer vorzeichenbehafteten Geschwindigkeit**
zu behandeln. Eine angehobene Kosinuswelle macht das geschlossen: null am
Zyklusanfang, voller Ausschlag am Kippen, zurück auf null am Ende — und ihre
Steigung ist genau dort null, wo die Richtung dreht. Die Strömung bremst also ab,
steht, dreht und beschleunigt wieder. Gemessene Bewegung pro Tick: 2 px statt 62.
`BoardArt.zone_offset()` und `test_the_zone_flow_never_jumps` halten das fest.

**Screenshots können so etwas nicht finden.** Ich habe zweimal daneben diagnostiziert,
weil ich Standbilder verglichen habe — ein Teleport zwischen zwei Frames ist darin
unsichtbar. Was ihn gefunden hat: die gezeichnete Position über 200 aufeinander
folgende Ticks berechnen und den größten Schritt zwischen benachbarten Ticks
ausgeben. Bei jedem zeitlichen Artefakt ist das der Weg, nicht das Bild.

**Zusätzlich gilt bei schnellem Takt: die Fläche trägt den Zustand nicht, die
Details tun es.** Bei 40 Ticks pro Halbphase wechselt der Zustand 1,5-mal pro
Sekunde; solange die *ganze* Zone dabei die Farbe tauschte und ein Blitzring feuerte,
war das ein Stroboskop. Der Körper bleibt jetzt konstant, und nur Pfeilrichtung,
beleuchtete Kante und Leiste kippen. Die Strömung ist aus demselben Grund luftig.

**Die Anzeige muss den Kipp-Moment ankündigen, nicht nur die Richtung.**
`BoardArt.draw_gravity_zone` zeichnet deshalb dreierlei: Pfeile in Wirkrichtung
samt passendem Farbton, eine Countdown-Leiste an der Kante, die sich über die
laufende Halbphase füllt (dazu beschleunigt die Strömung), und einen hellen Ring,
der unmittelbar nach dem Kippen nach innen schnappt. Ohne die Ankündigung wäre
das Brett Raten statt Können — dasselbe Kriterium wie beim Umpol-Fenster.

## Kamera und große Bretter

Bis Level 10 war jede Arena 900×660 und passte genau ins Fenster; das HUD saß bei
`arena.end.x + 30`, was nur funktioniert, solange alle Bretter gleich groß sind.
`PlayScreen.VIEW` ist jetzt der **feste Bildausschnitt** (900×660), rechts davon
das Panel, und die Arena darf beliebig größer sein — Level 11 ist 2200×1200.

Zwei Zustände, beide in `_follow()`:

- **Beim Planen** zoomt die Kamera so weit heraus, dass das ganze Brett zu sehen
  ist (nie größer als 1:1). Ohne das könnte man auf einem Brett, das nicht ins
  Fenster passt, nicht entscheiden, wohin der Magnet soll.
- **Im Lauf** folgt sie der Kugel bei 1:1, geklemmt an die Arenagrenzen, damit nie
  Leere hinter dem Brett auftaucht.

Drei Details, die leicht zu übersehen sind:

- Die Annäherung ist **bildratenunabhängig** (`1 - pow(0.0015, delta)`). Ein fester
  Lerp-Faktor macht die Kamera auf schnellen Rechnern schneller — hier wäre
  „sieht auf einem anderen PC anders aus“ ausnahmsweise ein echter Fehler.
- `draw_set_transform` verschiebt Geometrie, **klippt aber nichts**. Ohne die vier
  Maskenrechtecke nach dem Zurücksetzen der Transformation liefe das Brett quer
  übers Panel, sobald es breiter als das Fenster ist.
- Die Maus muss durch dieselbe Transformation zurück (`_to_board`), sonst landet
  ein Klick beim Herauszoomen an einer ganz anderen Stelle als er aussieht.

Der Hintergrund wird gegen den sichtbaren Ausschnitt gecullt — bei 2200×1200 sind
das sonst über tausend Zellen pro Frame, von denen die meisten hinter dem Panel
liegen.

## Checkpoints

Level 11 ist das erste Brett mit `checkpoints`. Ein `SimLevel.Checkpoint` ist ein
Rechteck plus die Zahl der Magnete, die das Erreichen freischaltet. `SimWorld`
merkt sich nur den Tick — keine Kraft, keine Bremse, kein Eintrag im Checksum.
Beobachtung wie `rode_mover`, also rechnen Bretter ohne Checkpoints bitgleich
weiter; die gepinnten Fingerprints beweisen es — als die Tore dazukamen, blieb
Level 11 auf exakt 284 Ticks / 357888677. (Heute steht dort 299 / 1276947690; das
Brett hat sich seither zweimal geändert, die Tore selbst haben nie etwas
verschoben.)

**Warum überhaupt — und warum das nicht Getting Over It ist.** Dort ist das Fehlen
von Checkpoints das ganze Spiel, und es trägt, weil man ununterbrochen am Steuer
sitzt. POLARIS ist planen-dann-zusehen. Dazu kommt das Argument, das die Sache
entscheidet: **die Simulation ist deterministisch.** Ein bereits gelöster
Abschnitt läuft mit denselben Eingaben Tick für Tick genauso ab — ihn zu
wiederholen ist ein Wartezimmer, keine Prüfung. Checkpoints sind hier deshalb die
*Voraussetzung* für Länge, nicht ihre Abmilderung. Level 11 zeigt auch, warum
Länge sie braucht: knapp fünf Sekunden, getrieben von **einer** Eingabe bei
Tick 15. Ein frischer Magnet pro Abschnitt erzwingt die Dichte, die ein langes
Brett sonst nicht hat.

**Eingabe-Präfix, kein Schnappschuss.** Ein Fehlversuch schneidet die Aufzeichnung
beim Tick des erreichten Tores ab; der nächste Versuch spielt dieses Präfix durch
(`PlayScreen._rewind`: frische Welt, dieselben Masken) und übergibt danach. 300
Ticks nachrechnen kostet Mikrosekunden. Ein Schnappschuss wäre billiger und würde
die Kugel in einen Zustand setzen, den **keine** Eingabefolge erzeugt — und ein
Lauf, der sich nicht als Eingaben beschreiben lässt, ist kein Replay, kein Geist
und kein Bestenlisteneintrag. Der Gewinn daraus ist messbar: ein über zwei
Rückfälle gewonnener Lauf ist eine einzige, vollständige Eingabefolge ab Tick 0
und spielt in einer frischen Welt bitgleich nach (gemessen: 277 Ticks, gleicher
Hash).

**Geschwindigkeit wird mitgenommen.** Am Tor steht die Kugel nicht still; sie
kommt mit dem an, was sie hatte — je nach Anlauf zwischen 270 und 360 px/s am
ersten Tor. Das ist die
Entscheidung, die aus dem Brett eine Reise macht statt einer Level-Auswahl mit
Zwischenschritten — und sie kostet den Beweis: siehe Kriterium 9. Zur Ruhe kommen
wäre beweisbar und wäre ein anderes Spiel.

**Ein am Checkpoint gesetzter Magnet hat einen Geburtstick.**
`MagnetSpec.spawn_tick` — davor existiert er nicht. Ohne ihn hätte ein am Tor
gesetzter Magnet im Abschnitt davor mitgezogen, denn die Welt wird aus der
*ganzen* Platzierungsliste aufgebaut; das Präfix, das der Spieler wiedersieht,
wäre dann nicht mehr der Lauf, den er gemacht hat. Ein Vergleich gegen ein Feld,
das überall sonst 0 ist, also wieder bitgleich. Aus demselben Grund lässt sich ein
Magnet aus einem gelaufenen Abschnitt **nicht** entfernen; dafür gibt es `C`.

**Ein Tor verdient man sich durchs Durchfahren, nicht durchs Sterben danach.**
Das Verbuchen hing zuerst am Verlieren: nur `Outcome.LOST` und die Zeitgrenze
schnitten das Präfix zurecht. Wer die Kugel durchs Tor fliegen sah und dann
ungeduldig `R` drückte, landete wieder bei Tick 0 — mit dem Tor, das er gerade
passiert hatte, vergessen. Genau das hat der Spieler gemeldet. `_carry_checkpoint()`
läuft jetzt immer, wenn ein Versuch endet: durch Niederlage, durch die Uhr oder
weil der Spieler mit `R` oder der Leertaste den nächsten verlangt. **Beide Tasten
entscheiden dasselbe** — vorher waren sie sich uneinig, wo der nächste Versuch
anfängt.

Ein *gewonnener* Versuch geht andersherum: der nächste startet bei Tick 0, und die
an Toren dazugekommenen Magnete gehen mit. Sonst hieße `R` nach einem Sieg „noch
mal, ab einer Sekunde vor dem Ziel“ statt „noch mal, für eine sauberere Zeit“ —
und das Brett stünde mit drei Magneten über seinem eigenen Budget.

**Ein Tor sperrt den Korridor, es steht nicht darin.** Die ersten Tore waren
Kästchen auf dem Boden, 50×150 px. Wer nicht genau dort entlangrollte — flog,
sprang, kam von der Plattform hoch —, ging daran vorbei. Ein Tor reicht jetzt über
die volle freie Höhe seines Durchgangs, von der Decke bis zur Bodenplatte
(`Rect2(1164, 0, 40, 1000)`).

**Unten hört das Tor an der Bodenplatte auf, und das ist Absicht.** Ginge es bis
zum Arenaboden, würde eine Kugel, die in die Brückenlücke gefallen ist und
darunter nach rechts treibt, das Tor noch auslösen — und der Spieler bekäme einen
Checkpoint in einem Zustand, aus dem es keinen Weg gibt. Genau die Sackgasse, die
Kriterium 9 verbietet.

**Ein Tor gehört vor das Risiko, nicht dahinter — und zwei Tore auf einer
Geraden sind nicht zwei Stationen.** Level 11 hatte beides falsch, beides vom
Spieler gemeldet.

Erst stand ein Tor *im* Schacht. Dort war der Lauf längst sicher — verlieren
konnte man nur noch an die Uhr —, also verteilte es einen Magneten für einen
Abschnitt, der keinen brauchte, und nahm dem einzigen Moment mit einer
Entscheidung das Werkzeug weg („ab da kann man eigentlich nicht mehr verlieren").
Jetzt hat der Tunnel **keinen Boden** unter sich, und das Tor steht an seinem Mund
(x 1164–1204). Über dem Nichts entscheidet der Takt: bei Aufwärtsschlag trägt es
dich hoch, bei Abwärtsschlag fällst du aus der Welt.

Und daneben stand eine Weile ein zweites bei x 945, gleich hinter der Brücke —
**eine Dublette**. Beide lagen auf demselben Bodenstück, 49 Ticks auseinander, und
das spätere erspart einem schon alles, was das frühere erspart hätte. Ein Tor
verdient sich seinen Platz dadurch, dass es *vor etwas steht, das schiefgehen
kann*; hinter dem gerade passierten Tor stand nur Rollen. Die 45-Tick-Untergrenze
in `test_the_par_passes_every_checkpoint_in_order` hat das nicht gefangen: 49 lag
darüber. Abstand ist kein Ersatz für einen Grund.

Drei Zahlen, alle gemessen, keine geraten:

- **Der Bodenstreifen im Tunnelmund ist 40 px lang.** Er ist die Bühne, auf der der
  Checkpoint-Magnet arbeitet — dort hält man die Kugel, bis der Takt dreht. Bei
  100 px war das Loch Dekoration: eine Kugel mit ~120 px/s rollt 100 px in genau
  einer Abwärtsphase ab und kann sie einfach aussitzen, nur 7 von 35 Eröffnungen
  starben noch. Mit 40 px sind es 12 von 35. Ganz ohne Streifen sterben 21 — aber
  das Eröffnungsfenster fällt von 22 auf 13 Ticks, unter die Fairness-Schwelle.
- **Die Landestelle musste 120 px nach rechts.** Mit dem Loch verlässt die Kugel
  den Schacht *mit* Geschwindigkeit statt aus der Ruhe gehoben zu werden, und über
  einem Ziel direkt über dem Mund rollte sie einfach hinein: 15 der gewinnenden
  Pläne gewannen auch ohne das fremde Feld. Das hätte Kriterium 7 gerissen — ein
  Brett, das über seinen eigenen Bedarf lügt. Draußen bei x 1560 hat der Zug seine
  Aufgabe zurück, gemessen gewinnt ohne ihn keiner.
- **Das Eröffnungsfenster bleibt bei 24 Ticks** (400 ms), also über der Schwelle.

**Was ein Tor sonst noch sein muss.** Es muss auf der Linie liegen, die die Kugel
wirklich nimmt — nicht auf der, die das Brett zu nehmen scheint. Ein Tor daneben
wäre folgenlos, das Brett wieder ein einziger langer Abschnitt, und **jeder andere
Test bliebe grün**. Zwei Prüfungen dagegen:
`test_the_par_passes_every_checkpoint_in_order` verlangt, dass das Par jedes Tor
durchquert, und begrenzt die Abschnitte auf 45–480 Ticks (zu kurz ist eine
Dublette, zu lang wieder das Wartezimmer). Und `test_11c/d_no_winning_route_skips_a_gate`
verlangt, dass **jeder** gewinnende Lauf durch jedes Tor kam, nicht nur das Par —
dieselbe Lehre wie bei Level 7, wo ein Kriterium nur das Par ansah und deshalb 204
andere Wege übersah. Die Tore von Level 11 wurden nicht geraten, sondern aus dem
Par-Trace abgelesen (Tick 172; Abschnitte 172 / 127 Ticks).

**Die Routen für diesen Beweis kommen aus der Nachbarschaft der Par-Platzierung,
nicht aus einem Raster.** Ein gleichmäßiges Raster gewinnt auf Level 11 **kein
einziges Mal** — der Test lief grün und prüfte nichts, bis ein
`assert winners > 0` das aufdeckte. Verschobene Par-Magnete und Haltefenster
liefern dagegen echte, verschiedene Siegrouten. Dass die Prüfung Zähne hat, ist
nachgewiesen: mit einem Tor, das nur die oberen 200 px sperrt, meldet sie elf
Sieger, die daran vorbeikamen.

**Den Magneten setzt man im Lauf — und das Brett hält dafür niemals an.**
Zuerst wurde die Zugabe eines Tores erst brauchbar, wenn der Versuch vorbei war:
durchqueren, sterben, `R`, setzen, weiter. Damit kostete jeder Checkpoint erst
einmal einen Tod. Jetzt setzt ein Linksklick den freigeschalteten Magneten mitten
im Lauf, und der Lauf läuft weiter.

**Zeitlupe hängt an einem *Ort*, nicht an einem Ereignis.** Zwei Fassungen davor
waren falsch, und beide auf dieselbe Weise:

1. Zeitlupe ab dem Tordurchgang, während der Lauf weiterlief. **Zeitlupe kauft
   Sekunden, keine Strecke** — die Kugel legte dieselben 90 px zurück und fiel aus
   der Welt, während der Spieler noch zielte.
2. Also hielt das Brett für die Platzierung an, und die Zeitlupe folgte danach. Das
   Anhalten wurde daran gebunden, ob die Kugel etwas Festes berührt — und *das* war
   der Fehler: wann der Spieler Zeit braucht, ist eine Frage, die das **Level**
   beantworten muss, nicht eine, die man aus dem Bodenkontakt ableitet.

`SimLevel.slowmo_points` ist deshalb eine eigene Liste von Rechtecken: hindurch —
die Zeit dehnt sich, `SLOW_TICKS` (25) Ticks zu `SLOW_FACTOR` (5) Physik-Frames
pro Tick, gemessen 2,07 s Wanduhr.

**Wie lange gedehnt wird, gehört ebenfalls dem Level** (`SimLevel.slowmo_ticks`,
0 = die 25). Der *Ort* war von Anfang an die Entscheidung des Bretts, die *Länge*
hatte keinen Grund, global zu sein. Level 14 zeigt warum: ein Punkt wird
durchquert, während die Kugel noch an der Plattform vorbei nach oben steigt, und
der Moment, der zählt, kommt erst nach der Landung — gemessen greift das Par dort
**50 Ticks** nach dem Punkt zu, mit der Kugel endlich bei 24 px/s im Stand. Mit 25
Ticks war die Dehnung längst vorbei; das Einzige, was sie einem kaufte, war die
Gelegenheit, zu früh zu drücken und gegen den Schwung zu arbeiten — genau so
gemeldet. Level 14 steht deshalb auf 70, Level 11 bis 13 auf der Vorgabe. Unabhängig von Berührung, unabhängig vom
Setzen, unabhängig vom Checkpoint. Level 11 und 13 legen ihre Punkte auf ihre
Tore, was eine Entscheidung dieser Bretter ist und keine Regel — ein späteres
Brett kann den Punkt weit vor die Gefahr legen, wenn der Anlauf lang ist.

**Anhalten ist ausgeschlossen**, ausdrücklich: ein eingefrorenes Brett ist keine
Zeitlupe, sondern ein Bruch. Wo der Spieler Zeit braucht, gibt es einen Punkt.

`SimWorld` merkt sich nur den Tick, an dem ein Punkt zuerst betreten wurde — genau
wie bei den Toren. Die Regeln sehen davon nichts, ein Lauf ist derselbe Lauf, und
er spielt sich in vollem Tempo zum selben Ergebnis nach.

Warum Level 11 einen Punkt braucht: es durchquert sein Tor mit 183 px/s und hat
dann noch 96 px Bodenstreifen — eine halbe Sekunde, um zu setzen und zu drücken.
Fünffach gedehnt sind das zweieinhalb Sekunden, also eine Entscheidung statt eines
Reflexes.

**Ein Tor wird als *ein* Türrahmen gezeichnet, nicht als zwei Pfosten.** Beide
Kanten gleich stark gezeichnet, 40 px auseinander, lasen sich als **zwei
Checkpoints nebeneinander** — genau so gemeldet. Jetzt ist die nahe Kante das Tor,
die ferne dünn, und Sturz und Schwelle binden sie zu einem Ding zusammen, durch
das man hindurchgeht.

**Sichtbarkeit hängt am Zoom.** `BoardArt.draw_checkpoint` teilt seine
Strichstärken durch `PlayScreen._view_scale` (gedeckelt bei 3×). Beim Planen zoomt
die Kamera auf 0,41 heraus; ein 3-px-Pfosten käme dort mit gut einem Pixel an —
unsichtbar genau in dem Moment, in dem der Spieler entscheidet. Beide Zustände
sind mintgrün: die Farbe *bedeutet* Checkpoint, unterschieden wird über Helligkeit
und Wimpel. Grau war der erste Versuch und las sich als Kulisse — ausgerechnet das
Tor, das noch vor einem liegt, verschwand.

## Der Bau-Modus

`B` im Menü öffnet ihn. Er ist **keine Zeile in der Levelliste**, und das ist
Absicht: die Liste *ist* die Kampagne, und ein Werkzeug, das Level macht, gehört
nicht zwischen die Level.

**Er schreibt Quelltext, keine Speicherdatei.** `E` legt den Entwurf als fertige
`levels.gd`-Funktion in `tools/entwurf.gd.txt`; übernommen wird von Hand. Das ist
dieselbe Form, die der Par-Sucher schon hat, und sie hält die Regel „Level sind
Code" intakt. Ein Speicherformat wäre eine **zweite** Definition dessen, was ein
Level ist — mit Kompatibilitätslast für immer, gekauft für einen Schritt, der zehn
Sekunden dauert. `SimLevel` ist außerdem `RefCounted` und kein `Resource`, also
verschenkt Godots Inspector hier nichts: die inneren Spec-Klassen müssten alle
Resources werden, was reine Datenklassen mit Engine-Typen verseucht.

**Der eigene Sieg ist der Beweis.** Die teure Hälfte einer Level-Pipeline ist der
Nachweis, dass ein Brett gewinnbar ist — und für ein von Hand gebautes Brett
existiert der schon: es ist der Lauf, den man gerade gemacht hat. Leertaste
übergibt den Entwurf ans Spiel, und ein *gewonnener* Versuch kommt als
`par_placements` + `par_holds` zurück, weil `PlayScreen.recording` genau das ist,
was ein Par ist (eine Platzierungsliste plus eine Bitmaske pro Tick).
`LevelSource.holds_from` faltet die Masken zurück in Halteeinträge, und
`test_build.gd` prüft, dass diese Faltung jedes Par der Kampagne exakt
reproduziert — inklusive Level 7, dessen Par einen `INVERT_INPUT`-Eintrag enthält.

Was er von der Spielansicht *erbt* statt neu zu bauen: `BoardArt` zeichnet,
`_to_board` rechnet Klicks zurück aufs Brett, und die Maskenrechtecke halten das
Brett aus dem Panel. Neu ist nur das Bearbeiten — Griffe, Raster, Undo — und die
Leiste.

Vier Sachen, die beim Bauen aufgefallen sind:

- **Der Entwurf gehört `GameRoot`, nicht dem Bau-Bildschirm.** Der wird beim
  Testlauf freigegeben; der Entwurf muss beide Bildschirme überleben.
- **Der gewonnene Lauf wird beim Verlassen gelesen, nicht über `tree_exiting`.**
  `_swap` hängt den neuen Bildschirm ein, *bevor* der alte den Baum verlässt — ein
  verzögerter Handler käme an, nachdem der Bau-Modus schon gefragt hat.
- **Undo schnappt beim ersten *Ziehen*, nicht beim Drücken.** Sonst füllt jeder
  Klick, der nur auswählt, die Historie mit Zuständen, die identisch zu ihrem
  Vorgänger sind, und Rückgängig bedeutet nichts mehr.
- **`thing().vektor.x = wert` tut nicht, wonach es aussieht.** Ein `Vector2` ist
  ein Wert, die Komponente wird auf einer Kopie gesetzt und die Kopie verworfen.
  Herauslesen, ändern, zurückschreiben.

Und eine Regel, die aus der Kampagne kommt: **die Bahn einer Plattform bestimmt
ihren Takt.** Wer den Weg ändert und den alten Takt stehen lässt, ändert
unausgesprochen die *Geschwindigkeit* — doppelt so weit in gleich vielen Ticks ist
doppelt so schnell. Der Bau-Modus setzt deshalb `SimWorld.sweep_ticks(travel)`
nach, so wie `levels.gd` es überall schreibt; einen abweichenden Takt setzt man
danach von Hand, und dann ist er eine Entscheidung statt eines Überbleibsels.

**Das Raster gehört dem Brett, nicht der Geste.** Zehn Pixel, `Alt` schaltet es ab.

Es gab das Raster von Anfang an — aber nur dort, wo die *Maus* gelesen wurde.
Zeichnen, Verschieben, Größe ändern und die Arena-Ecke rasterten; alles andere, was
Geometrie schreibt, rutschte auf eigene Weise wieder heraus. Gemessen an der
Kampagne ist das Raster längst die Konvention: von 386 Koordinaten in `levels.gd`
sind **343 Vielfache von zehn**, elf Vielfache von fünf, 32 krumm. Durchgesetzt war
sie nicht.

Zwei Lecks, beide dort behoben, wo die Zahl *entsteht*:

- **Ein Punkt ist kein Kasten.** Start und eingebautes Feld werden über einen Kasten
  angefasst, der um sie herum gezeichnet wird; gerastert wurde dessen **Ecke**. Bei
  einer halben Kastenbreite von 16 beziehungsweise 18 px landete das, was wirklich
  gesetzt wird — die Mitte — damit zwangsläufig auf …6 und …8, egal wie sorgfältig
  man zielte. `BuildScreen.HALF_POINT` ist jetzt **genau ein Rasterschritt**, also
  rastert die Ecke und die Mitte gleichzeitig. Ein frisch aufgezogenes Feld rastert
  zusätzlich seine Mitte, weil ein gezogener Kasten jede Zahl von Schritten breit
  sein kann und nur eine gerade Anzahl eine Mitte im Raster hat.
- **Eine Vierteldrehung verschiebt eine Ecke um die halbe Seitendifferenz.** Seiten
  sind Vielfache von zehn, die Hälfte also ein Vielfaches von *fünf*: eine
  200×30-Wand bei x=100 landete auf 185, und jede Zahl, die man danach an ihr
  abnahm, lag daneben.

Der zweite Fall ist der interessante, weil die naheliegende Reparatur falsch ist.
**Gerastert wird der Versatz, nicht die Position.** Die Position zu runden wäre
einfacher und würde etwas Besseres kaputt machen: die Hälfte rundet immer in
dieselbe Richtung, also wandert die Form bei vier Drehungen **zwanzig Pixel** über
das Brett — nachgerechnet, nicht befürchtet. Rundet man stattdessen den Versatz
symmetrisch um null, zieht die zweite Drehung genau ab, was die erste addiert hat:
zwei Drehungen sind die Identität, vier also auch. Und weil immer eine **ganze**
Zahl von Schritten addiert wird, bleibt eine mit `Alt` bewusst krumm gesetzte Form
exakt so krumm, wie sie war — das Drehen zieht nichts aufs Raster, was nicht schon
darauf lag.

Symmetrisch ist dabei wörtlich gemeint. Godots `snappedf` rundet Halbe nach *oben*,
macht also aus +85 eine +90 und aus −85 eine −80 — fünf Pixel Asymmetrie pro
Drehung sind die zwanzig Pixel Drift oben. `LevelSource.on_lattice` rundet deshalb
von null weg, und `test_the_lattice_is_symmetric_about_zero` hält es fest.

**Das Ausrichten rastert bewusst nicht.** `Shift+H`/`Shift+V` legt Mitten bündig,
und das *ist* die Zusage der Funktion — sie für das Raster zu brechen häße, eine
Garantie gegen eine Konvention zu tauschen. Bei der Drehung liegt es andersherum:
dort ist „die Mitte bleibt“ nur das Mittel, damit die Form sich *an Ort und Stelle*
aufrichtet statt zu springen, und fünf Pixel geben das nicht aus. Die Kantenvariante
ohne `Shift` — die, die man ohnehin fast immer will — übernimmt die Koordinate der
Ankerform unverändert und ist damit exakt *und* im Raster.

**Was das Raster nicht kann:** zwei weit auseinander liegende Formen bündig machen.
Dass beide auf demselben Gitter sitzen, heißt nicht, dass sie auf derselben Linie
sitzen — dafür sind `H` und `V` da. Und es gibt weiterhin keine Tastatur, mit der
man eine ausgewählte Form um einen Schritt schiebt: die Leiste stellt Takte,
Stärken und die Arena, aber keine x/y/Breite/Höhe. Steht unter „Offen“.

**Drehen: `R`, immer 90° gegen den Uhrzeigersinn.** Ein Kasten bleibt ein Kasten: er wird
nur so weit gedreht, wie er dabei achsenparallel bleibt.

**Eine frühere Fassung dieses Absatzes behauptete, ein freier Winkel hieße ein
anderes Kontaktmodell und jedes Replay neu hergeleitet. Das stimmt nicht**, und es
ist nachgelesen. `_resolve_one` rechnet Abstoß und Reibung schon heute entlang eines
*beliebigen* Normalenvektors; achsenparallel ist allein die Suche nach dem nächsten
Punkt, ein `_clamp` pro Achse. Eine Schräge ist deshalb kein gedrehter Kasten,
sondern eine eigene Form — und die gibt es inzwischen: siehe „Polygone" weiter
unten. Gedreht wird ein Polygon mit `R` genauso wie ein Kasten, nur eben als Umriss.

**Eine Richtung, kein Modifikator.** Viermal Drücken kommt einmal herum, die
Gegenrichtung ist also drei Drücke entfernt — und eine Taste, die unter `Shift`
still das Gegenteil tut, kostet mehr an Überraschung als sie an Tastendrücken
spart.

Die Richtung steht im Code ausgeschrieben, weil die Bildschirmachsen die Intuition
umdrehen: y wächst nach *unten*, also wird aus einer Bahn nach unten eine nach
rechts und aus einer nach rechts eine nach oben. Nachgemessen an einer Plattform:
runter → rechts → hoch → links → runter, auf dem Ziffernblatt 6 → 3 → 12 → 9.

Gedreht wird um die **eigene** Mitte jeder Form, nicht um die der Auswahl — eine
Reihe Wände soll sich an Ort und Stelle aufstellen und nicht um einen gemeinsamen
Punkt schwenken. Bahnen drehen mit ihrem Besitzer: ein Aufzug, der nach dem Kippen
seines Schachts weiter auf und ab führe, wäre eine Überraschung. Die Länge bleibt,
also auch der Takt, den sie impliziert. Der Start wird übersprungen — er ist eine
Position, und eine Position hat keine Ausrichtung.

Gerastert wird der Versatz (siehe oben), also landet viermal Drehen exakt wieder am
Anfang — für jede Seitenlänge, nicht nur für gerade.
Die Variante, die statt der Mitte die *Ecke* festhält, wäre ebenso umkehrbar, ließe
eine Form aber über das Brett springen statt sich aufzurichten.

Ein hübscher Nebeneffekt: `BoardArt.draw_hazard` liest die Richtung seiner Zähne am
Seitenverhältnis ab, also dreht ein gedrehtes Zackenband seine Spitzen von selbst
mit.

**Mehrfachauswahl und Ausrichten.** Shift-Klick wählt eine Form dazu; `H` legt
alle Ausgewählten auf dieselbe Höhe, `V` in dieselbe Spalte, mit `Shift` auf
dieselbe *Mitte* statt Kante. Ein Zug bewegt die ganze Auswahl um ein Delta, `Entf`
löscht sie.

Drei Entscheidungen darin, die nicht beliebig sind:

- **Angelegt wird an der zuletzt gewählten Form**, nicht an einer Hüllbox oder am
  Durchschnitt. Das ist der Unterschied zwischen einer Operation, die man zielen
  kann („diese beiden auf die Höhe von *der da*"), und einer, die man nachmessen
  muss. Sie wird heller gezeichnet als die übrigen, damit sichtbar ist, wohin es
  geht.
- **Shift-Klick zieht nicht.** Ein Griff, der während des Auswählens auch noch
  verschiebt, verrückt Geometrie genau in dem Moment, in dem man sie ordnen will.
- **Gelöscht wird von hinten nach vorn.** `_remove` schiebt jeden späteren Index
  derselben Liste nach unten, also nähme ein Löschen von vorn die falschen Formen
  mit. Aus demselben Grund leeren Löschen und Rückgängig die Auswahl: sie hält
  Indizes, keine Referenzen.

Die Rechnung dahinter steht als `LevelSource.align_to` im Datenteil und nicht im
Bildschirm — sie ist Arithmetik, und der Bildschirm ist genau der Teil, den der
Test-Runner nicht instanziieren kann. Was prüfbar ist, gehört dorthin, wo es
geprüft werden kann.

**Die Arena zieht man an der Ecke unten rechts.** Sie steht auch als Zahlenpaar in
der Leiste, aber das ist für etwas so Grundsätzliches versteckt. Ein *Griff* statt
Anklickbarkeit, weil die Arena das größte Rechteck auf dem Brett ist: würde ihr
Körper getroffen, griffe jedes Ziehen auf freier Fläche die Arena statt eine neue
Form zu zeichnen — und Zeichnen auf freier Fläche ist das, was man am häufigsten
tut. Nur die Ecke unten rechts, weil jedes Brett der Kampagne bei (0,0) anfängt:
mit festem Ursprung ist die Größe *ein* Zahlenpaar, und nichts bereits Gesetztes
verrutscht, wenn das Brett wächst.

**Zwei Stärken statt einer** stehen in der Leiste: „Magnetstärke" für das, was der
Spieler setzt, und „Fremdfeld-Stärke" für die eingebauten Felder. Letztere zeigt
„wie Magnet" statt „Vorgabe", wenn sie nicht gesetzt ist — denn unbestimmt heißt
hier die Zahl des Spielers und nicht die der Kampagne, und die falsche anzuzeigen
schickt einen auf die Fehlersuche.

**Die Welt steht als erstes Feld in der Leiste** und wird mit `←`/`→` durchgeblättert.
Sie landet als `level.theme = "..."` im Export.

**Was er (noch) nicht kann:** speichern und laden, mehrere Entwürfe, ein Brett
bewerten (`test_zy_author.gd` rechnet Fairness je Station und Trägt-jeder-Magnet
schon aus — das im Bau-Modus anzuzeigen wäre der nächste sinnvolle Schritt), und
teilen. Steht unter „Offen".

## Steuerung

Im Menü: `↑`/`↓` (oder `W`/`S`) wählen, `Enter` startet, Maus fährt und klickt
ebenso, `B` öffnet den Bau-Modus, `Esc` beendet.

Im Bau-Modus: die Arena zieht man an der Ecke unten rechts. `Shift`+Linksklick
wählt eine Form dazu, `H` und `V` richten alle Ausgewählten an der zuletzt
gewählten aus (gleiche Höhe bzw. gleiche Spalte), mit `Shift` an deren Mitte, `R`
dreht sie um 90° gegen den Uhrzeigersinn.
`1`–`9` wählen das Werkzeug (Wand, Zacken, Tor, Zeitlupe, Zone,
Plattform, fremdes Feld, Sprungfeld, Polygon), Ziehen auf freier Fläche legt an, Ziehen auf einer Form verschiebt,
Ziehen an einer Ecke ändert die Größe, Rechtsklick oder `Entf` löscht. **Polygon:**
Ecken nacheinander anklicken, die erste Ecke oder `Enter` schließt, Rücktaste oder
Rechtsklick nimmt die letzte zurück, `Esc` bricht ab. An einem ausgewählten Polygon
zieht man Ecken, eine Kantenmitte ziehen fügt eine Ecke ein, Rechtsklick auf eine
Ecke löscht sie. `Tab`
wechselt das Feld in der Leiste, `←`/`→` ändern es (`Shift` gröber), `Alt` schaltet
das 10-px-Raster ab — es gilt für alles, was Geometrie schreibt, das Drehen
eingeschlossen. Mausrad zoomt auf den Zeiger, Mittelklick schiebt, `F` passt
ein. `Strg+Z`/`Strg+Y` rückgängig und wiederholen, Leertaste testet, `E`
exportiert, `N` fängt neu an, `Esc` geht zurück.

Im Level: Linksklick setzt einen Magneten, Rechtsklick entfernt ihn, `Tab` schaltet
die Polarität, Leertaste startet den Lauf, `1`–`6` **gedrückt halten** lässt den
jeweiligen Magneten wirken, **Ziehen** statt Klicken gibt dem Magneten eine Bahn
(nur wo das Level es freischaltet), `Shift` **gedrückt halten** kehrt alle
wirkenden Felder um (ebenso pro Level), `R` startet den nächsten Versuch, `C`
räumt das Brett und fängt das Level von vorn an, `P` zeigt den Musterlauf, `Esc`
geht zurück ins Menü. **Einen an einem Tor freigeschalteten Magneten setzt ein
Linksklick mitten im Lauf** — das Brett hält dafür nie an; wo Zeit gebraucht wird,
legt das Level einen Zeitlupenpunkt. (`Esc` feuert `exit_requested`; unter `game.tscn` hängt die
Wurzel daran. Läuft `play.tscn` allein, hört niemand zu — dann wird beendet,
statt die Taste stumm ins Leere laufen zu lassen.)

Alles wird als roher Tastendruck abgefragt, nicht über die InputMap — die alten
Actions sind aus `project.godot` entfernt. Die Klickposition kommt aus dem
Maus-Event selbst, nicht aus `get_local_mouse_position()`: zwei Quellen für
denselben Klick können auseinanderlaufen, und die zweite ist von außen nicht
ansteuerbar.

## Tests

```
test_sim.gd   Determinismus + jedes Level ist gewinnbar und fair + Polygone (38 Tests)
test_build.gd Bau-Modus: Text, Par aus dem Sieg, Welten, Raster, Kulisse, Umrisse (31 Tests)
```

**Die beiden Suiten müssen einzeln laufen.** `test_run(suite="sim")` braucht 11 s
und ist der Alltag — vorher 6,6, und der Aufschlag geht fast ganz auf die
Fairness-Messung je Station, die jeden Griff eines Pars einzeln durchschiebt statt
nur den ersten. `test_run(suite="zz_find_replays")` braucht rund 200 s —
zusammen sprengen sie das 300-s-Budget des Runners. Der Grund sind die
Rasterbeweise: sie laufen über jedes Level mit Zone, Möblierung oder Bahn, und
Level 11 ist groß und seine Läufe sind lang. Deshalb sind sie in Scheiben à 8–14 s
geschnitten; bei vier Scheiben lagen zwei bei 20,7 s und rissen die Sitzung ab.

Und: **das Beweisraster hängt an der Arenagröße**, nicht an festen 50 px. Vorher
deckte es die ersten 900×650 ab und hätte über die restlichen vier Fünftel eines
2200-px-Bretts nichts bewiesen — wäre aber grün geblieben.

**Ein Rasterbeweis, der nicht passt, wird nicht so getan als ob.** `_no_win_without_furniture`,
`_no_win_without_zone` und `_gates_catch_every_winner` setzen *einen* Magneten und
suchen einen Sieg. Auf einem verketteten Brett, dessen Par fünf braucht, fänden sie
null Sieger mit dem Feature und null ohne — das beweist nichts und kostet Minuten.
Sie überspringen deshalb jedes Brett mit `par_placements.size() > 1`, und Level 15
steht damit unter „Offen" statt unter „bewiesen". Level 11 bleibt drin: sein Par
kommt mit einem Magneten aus, also passt die Maschinerie. Die billigen
Par-Prüfungen in `test_sim.gd` laufen auf allen. Gemessen bleibt die Suite damit
bei 215 s.

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

**`filesystem_manage(op="scan")` lädt GDScript-Klassen nicht zuverlässig neu.**
Das hat zweimal viel Zeit gekostet: der Editor führte weiter die alte `levels.gd`
aus, Suchläufe lieferten stumm 0 Treffer, und auch `reimport` und `script_patch`
halfen nicht. Der einzige Hebel, der hier verlässlich greift, ist ein
**Editor-Neustart** (`editor_manage(op="quit")`, dann die exe mit `--path <projekt>
-e` starten). Externe Bearbeitungen deshalb bündeln und *einmal* neu starten,
statt nach jeder Datei zu scannen.

**Godot headless hilft dabei nicht.** `godot --headless --path . --script res://…`
gibt hier weder Ausgabe noch schreibt es Dateien, weder mit `_init` noch mit
`_initialize`. Das ist zweimal ausprobiert worden (einmal beim Raster-Spiel, einmal
bei der Level-7-Suche); beides Mal umsonst. Alles läuft über den Editor.

## Zacken: die erste Fläche, die tötet

`SimLevel.hazards` ist eine Liste von Rechtecken. Berührt die Kugel eines, ist der
Lauf vorbei.

**Ein reiner Auslöser, kein Körper.** Die Kugel wird nicht abgelenkt, sie ist weg —
es gibt nach der Berührung nichts mehr zu abzuprallen, also wäre eine Oberfläche
Geometrie, der nie jemand begegnet. `test_a_hazard_never_pushes_the_ball_around`
hält das fest.

**Das Rechteck *ist* die Gefahr.** Was `BoardArt.draw_hazard` hineinmalt, ist ein
Bild dieser Regel und nicht die Regel selbst. Deshalb trägt das Band einen warmen
Schleier über seine *ganze* Fläche und die Zähne sitzen obenauf: Zähne allein
würden Sicherheit in den Lücken versprechen, und dort stirbt die Kugel genauso. Eine
Spitze, die über ihr Rechteck hinausragt, verspräche umgekehrt einen Treffer, den
es nicht gibt.

Die Zähne wachsen aus der langen Kante — nach oben bei einem breiten Band, nach
rechts bei einem hohen. Ein Hindernis ist fast immer ein Boden oder eine Wand, und
so trifft die Zeichnung die richtige Wahl, ohne dass das Level sie ansagen muss.

**Vor dem Ziel geprüft.** Liegen Zacken und Ziel näher als eine Kugelbreite
beieinander, tötet es. Wenn beides in einem Tick feuern kann, hat das Brett ein
Problem, und die sichere Lesart ist, dass die Gefahr, die es gezeichnet hat, echt
ist.

Der Rest ist wieder dieselbe Disziplin: eine leere Liste ist eine Schleife, die
nicht läuft, also rechnen alle bisherigen Bretter bitgleich weiter
(`test_a_board_without_hazards_is_untouched`), und `SimWorld.hit_hazard` ist
**Beobachtung** wie `rode_mover` — nichts in den Regeln liest es, es steht in keinem
Checksum.

### Die Explosion

Sie hängt an `hit_hazard` und nicht an „verloren", weil die beiden Tode
unterschiedliche Bilder verdienen: eine Kugel, die aus der Welt fällt, ist *weg* —
eine Explosion unter dem Boden wäre ein Bild von etwas, das nicht passiert ist.
Dafür gibt es längst die eigene Sprache, das rote Band an der offenen Unterkante.

Sie läuft auf der **Wanduhr**, nicht auf Ticks. Der Lauf ist vorbei, wenn sie
spielt, also gibt es keine Simulation mehr, mit der sie sich uneinig sein könnte —
`sin`, `cos` und `delta` sind hier erlaubt. Die Richtungen der Splitter kommen aus
`_hash` ihres Index, nicht aus `randf()`: ein pro Frame gewürfelter Wert ließe die
Teile sechzigmal pro Sekunde neu streuen statt zu fliegen.

Drei Sachen, die beim Bauen nötig wurden:

- **Der Blitz muss kurz und hell sein.** Die erste Fassung hielt ihn dreimal so
  lange, und das ist kein Blitz: Weiß mit wenig Deckkraft auf dunklem Brett ist
  Grau, gezeichnet wurde also eine matte Scheibe an der Stelle, wo die Kugel war.
- **Zwei Ringe, nicht einer.** Der schnelle ist der Schlag, der langsame die Welle.
  Einer allein liest sich als Kräuseln — als etwas, das sich ausbreitet, statt als
  etwas, das zerbricht.
- **Die Kugel bleibt weg.** Die Animation ist nach 0,8 s vorbei, der Versuch nicht.
  Mit nur dem Timer tauchte die Kugel danach wieder auf und saß dort, wo sie eben
  zerschellt war. `_wrecked` hält sie fort bis zum nächsten Versuch.

## Sprungfelder: die erste Fläche, die schiebt

`SimLevel.springs` ist eine Liste aus `BounceSpec` — Rechteck plus `push`, ein
Vektor, der Richtung *und* Stärke in einem trägt, damit Drehen die Platte und das,
was sie tut, gemeinsam dreht.

**Kein Magnet.** Keine Polarität, keine Reichweite, keine Ladung, keine Taste. Ein
Magnet ist ein Feld, das man setzt und verbraucht; das hier ist ein Stück Brett,
um das man eine Route plant.

Die Regel ist ein Satz: **solange die Kugel drin ist, ist ihr Tempo entlang der
Plattenachse genau die Stärke der Platte.** Alles Seitwärtige bleibt unangetastet,
also behält eine heranrollende Kugel ihr Vorwärtstempo und gewinnt Höhe — das ist,
was ein Sprungbrett ist.

**Setzen statt addieren, und das ist die Entscheidung, auf die es ankommt.**
Addieren hieße, der Sprung hängt davon ab, wie schnell die Kugel ankam — dieselbe
Platte schösse eine schnelle Kugel doppelt so weit wie eine langsame, und keine
Route durch sie wäre planbar. Gesetzt ist die Platte eine *Zusage*: von hier gehst
du mit diesem Tempo weg. Nebenbei macht es die Regel idempotent, weshalb es kein
„schon gesprungen"-Flag braucht — und genau so ein Flag wäre das, was man
zurücksetzen, mitreplayen und checksummen müsste.

Eine Folge fürs Bauen: eine *dicke* Platte hält die Kugel so lange auf diesem
Tempo, wie sie drin ist, liest sich also als Dauerschub statt als Tritt. Für ein
Sprungbrett dünn halten.

Angewendet wird nach `_resolve_contacts()`, damit eine Platte, die auf einem Boden
liegt, nicht im selben Tick vom Abprallen des Bodens überschrieben wird. Nur
`sqrt` und die vier Operationen, und eine leere Liste ist eine Schleife, die nicht
läuft — `test_a_board_without_plates_is_untouched` hält es fest.

**Blau, und das ist keine freie Wahl.** Der Spieler hat in Level 1 gelernt, dass
Blau schiebt — es ist die Farbe des Abstoßers. Eine blaue Platte sagt also, was sie
tut, bevor es jemand erklärt. Dass sie *kein* Magnet ist, trägt die Form: ein
Magnet ist eine Scheibe mit ein- oder ausströmendem Feld, das hier ist ein flacher
Amboss mit Lauf und Richtung. Rot, Bernstein und Mint waren ohnehin vergeben — sie
heißen bereits Anziehen, Ziel und Checkpoint.

Zwei Dinge, die erst am Bild klar wurden:

- **Zwei Formen waren eine zu viel.** Die erste Fassung zeichnete Spulenwicklungen
  *quer* durch den Lauf und Pfeile obendrauf. Bei der Tiefe, die ein Sprungbrett
  wirklich hat — zwanzig bis vierzig Pixel — sind drei Querlinien keine Wicklung,
  sondern Streifen, und zusammen mit den Pfeilen las sich die Platte als Gekritzel.
- **Eine dünne Platte bekommt *einen* Pfeil.** Zwei in einem 30-px-Lauf sind je
  dreizehn Pixel hoch, und das ist kein Pfeil, sondern ein Strich. Die Breite ist
  zusätzlich an die Tiefe gekoppelt: ein Pfeil, der breiter als tief ist, zeigt
  seitwärts, so sorgfältig er auch gezielt wurde.

## Polygone: Wände jeder Form

`SimLevel.polygons` ist eine Liste geschlossener Umrisse, jeder eine Folge von
Ecken. Damit gibt es Schrägen, Rampen, Trichter, Schalen und alles dazwischen —
im Bau-Modus als Werkzeug `9`.

**Die Kollision brauchte kein neues Modell, nur eine neue Frage.** `_resolve_one`
rechnete Abstoß, Rückprall und Reibung schon immer entlang eines beliebigen
Normalenvektors; achsenparallel war allein die Suche nach dem nächsten Punkt. Für
ein Polygon ist das der nächste Punkt über alle Kanten — Projektion und Klemmen,
also `+ − * /` und ein `sqrt`, genauso exakt wie beim Kasten. Drinnen oder draußen
sagt ein Kreuzungszähler (gerade/ungerade). Was danach passiert, ist `_push_out`:
der Abstoßcode, **Anweisung für Anweisung** aus `_resolve_one` herausgelöst, damit
beide ihn teilen. Dass das bitgleich ist, sagt nicht ein Kommentar, sondern die
gepinnten Fingerprints — alle fünfzehn Bahnen stehen unverändert.

**Über Ecken, nie über einen Winkel.** Eine Schräge „mit 30 Grad" bräuchte `sin`
und `cos`, um Geometrie zu werden, und beide sind in IEEE 754 nicht exakt. Ecken
auf ganzen Pixeln sind es, und jeder Winkel, den das Spiel kennt, ist der, den sie
ergeben: 1:1, 1:2, 3:1. Im 10er-Raster gezeichnet, ist das die natürliche Auswahl.

**Eine eigene Liste, keine Verallgemeinerung von `solids`.** Die Kästen nehmen
weiter den Kastenweg; ein Brett ohne Polygone läuft durch eine Schleife, die nicht
läuft. Das hält die Kampagne, wo sie ist, und kostet eine Liste mehr.

Fünf Tests in `test_sim.gd`, und jeder hält eine andere Behauptung fest:

- **Ein Polygon als Kasten gezeichnet trägt die Kugel wie der Kasten** — Fall,
  Landung *und* Rollen, damit die Reibung mitgeprüft ist. Nicht bitgleich, und das
  wird auch nicht behauptet: der Kasten klemmt, das Polygon projiziert, und die
  Projektion darf ein letztes Bit daneben liegen. Verlangt wird, dass die beiden
  über vier Sekunden nie mehr als eine hundertstel Pixel auseinanderlaufen.
- **Auf einer Rampe rollt die Kugel hinunter.** Es gibt im Modell keine
  Haftreibung, nur eine Dämpfung des Gleitens — also bleibt auf keiner Schräge
  etwas liegen. Eine Rampe ist immer ein Beschleuniger, nie eine Ablage.
- **Eine Schale wird nach ihrem Umriss beurteilt, nicht nach ihrem Kasten.** Die
  Kugel auf dem Boden einer Schale liegt mitten im Begrenzungsrechteck und klar
  *außerhalb* des Polygons; ein fauler Innentest schösse sie oben hinaus. Dazu
  treffen sich an jeder Innenecke zwei Kanten — genau der Fall, für den der zweite
  Kontaktdurchgang existiert.
- **Durch eine schräge Wand kommt nichts, auch nicht mit Höchsttempo.** Die Kugel
  legt höchstens 18,3 px pro Tick zurück (`MAX_SPEED` / 60) gegen einen Radius von
  15; eine Wand dünner als etwa **6,7 px** kann sie in einem Tick durchqueren und
  wird dann auf der *falschen* Seite hinausgeschoben. Die Testwand ist quer zur
  Schräge 8,9 px dick und wird aus vier Richtungen beschossen.
- **Ein Polygon, das niemand berührt, ändert nichts** — Level 11 mit einer Wand
  weit außerhalb läuft bitgleich.

Zwei Grenzen, die man beim Bauen kennen muss:

- **Spitze Innenecken zittern.** Pro Durchgang wird die nähere Kante gelöst; bei
  einem Innenwinkel deutlich enger als ein rechter kann die Kugel nach zwei
  Durchgängen noch leicht eingesunken sein und erst im nächsten Tick heraus. Exakt
  und reproduzierbar bleibt das — es sieht nur aus wie ein Zucken. Kerben
  rechtwinklig oder weiter bauen.
- **Mindestens 7 px dick.** Aus dem Grund oben. Der Bau-Modus prüft das nicht; bei
  schmalen Spitzen und dünnen Stegen ist es die Sorgfalt des Bauenden.

### Im Bau-Modus

**Klicks, kein Ziehen.** Jedes andere Werkzeug ist *eine* Geste, weil ein Kasten
zwei Zahlen ist. Ein Umriss hat so viele Ecken, wie er hat, und ein Zug liefert nur
zwei. Also ist das Polygon-Werkzeug die eine Stelle, an der ein Klick auf freie
Fläche eine Ecke setzt, und die Zeichnung bleibt offen, bis man sie schließt. Solange
sie offen ist, gehört ihr jeder Klick — auch einer auf eine vorhandene Form, denn
mitten in einem Polygon heißt ein Klick „Ecke hier". `Esc` bricht erst das Zeichnen
ab und erst ein zweites Mal den Bau-Modus: ein Tastendruck soll nie beides wegwerfen.

**Ein kaputter Umriss wird beim Zeichnen abgewiesen, nicht im Lauf entdeckt.**
„Drinnen" bedeutet nur bei einem *einfachen* Polygon etwas. `LevelSource.polygon_problem`
lehnt ab, was sich selbst kreuzt, eine Ecke doppelt hat oder auf sich selbst
zurückläuft, und sagt in einem Satz, was los ist. Die Prüfung ist exakt, weil auf
ganzen Pixeln jedes Kreuzprodukt eine Ganzzahl ist — verglichen werden deren
*Vorzeichen*, nicht ihr Produkt, denn das Produkt zweier solcher Zahlen passt nicht
mehr genau in ein Double.

Beim Ziehen einer Ecke wird erst beim **Loslassen** geprüft, nicht bei jeder
Bewegung: auf dem Weg zu einer gültigen Form kommt eine Ecke oft durch eine
ungültige, und jeden Schritt zu verweigern, ließe sie kleben. Während sie drüben
ist, wird der Umriss **rot** und der Hinweis sagt „Loslassen setzt zurück" — die
Absage ist sichtbar, bevor sie passiert.

**Das hat einen Fehler gefunden, den kein Test sehen konnte.** Ein Umriss, der sich
kreuzt, lässt sich nicht triangulieren, und `draw_polygon` meldet das — jeden Frame.
Ein einziges Ziehen durch eine ungültige Lage erzeugte **412 Fehler**. Die Zeichnung
fragt jetzt vorher `Geometry2D.triangulate_polygon`, das still scheitert, und zeichnet
dann nur die Kontur. Gemessen danach: null.

**Gedreht wird über den Kasten.** `LevelSource.rotated_polygon` schickt das
Begrenzungsrechteck durch `rotated` — und erbt damit alles, was dort richtig sein
musste: es bleibt im Raster, und viermal Drehen landet exakt am Anfang — und setzt
jede Ecke dann per reiner Vierteldrehung ihres Versatzes in den gedrehten Kasten.
Direkt um die eigene Mitte zu drehen wäre kürzer gewesen und wäre gewandert.

Verschieben und Ausrichten gehen über dasselbe Rechteck, also funktionieren `H`,
`V` und Mehrfachauswahl für Polygone ohne eigene Zeile. **Gestreckt** wird ein
Polygon dagegen nie — ein Strecken setzte jede Ecke neben das Raster; umgeformt wird
es an seinen Ecken.

Der Export schreibt jede Ecke aus, auch eine im Ursprung: `_vec` hätte dort
`Vector2.ZERO` geschrieben, was für eine Bahn, die nirgends hinführt, richtig ist
und für eine Ecke falsch.

## Welten: die Kulisse eines Bretts

`SimLevel.theme` nennt eine Welt aus `PolarisTheme.WORLDS`, leer heißt die
Vorgabe. Sieben gibt es, und sie kommen aus der Kampagnenform in
`docs/echtzeit-ideen.md`: Polaris, Werft, Schacht, Reaktor, Wrack,
Sortieranlage, Sturm.

**Eine Welt streicht die Kulisse, nie das Vokabular.** Sie darf Hintergrund, die
fernen Blöcke, die Fläche einer Wand und das Licht am Boden bestimmen — sieben
Farben. Sie darf **nicht** an `PLUS`, `MINUS`, `TARGET`, `ACCENT`, `OK`, `BALL`
oder die Zonenfarben. Rot zieht, Blau stößt, Bernstein ist das Ziel, Mint ist ein
Checkpoint: das hat der Spieler in den ersten zehn Leveln gelernt, und ein Brett,
das es umfärbt, ist keine neue Welt, sondern ein Brett, das man neu lesen lernen
muss. `test_a_world_repaints_scenery_and_not_meaning` hält das fest.

Zwei Folgen davon, beide beim Bauen aufgefallen:

- **Der erste Reaktor war minzgrün** — und damit genau die Farbe, die einen
  Checkpoint bedeutet. Die Tore hörten auf, sich abzuheben. Er ist jetzt olivgrün:
  eine Welt darf *neben* einer Bedeutung stehen, nicht *auf* ihr.
- **Das Panel behält in jeder Welt `BG`.** Es ist Oberfläche, keine Kulisse, und
  eine Welt mit hellem Grund nähme sonst die Lesbarkeit des HUD mit.

Dazu ein Kriterium, das billig zu prüfen ist: **jede Welt trennt den Boden, auf
dem man steht, von dem, auf dem man nicht steht.** Eine Wandfläche dunkler als der
Hintergrund macht aus einer Plattform ein Loch.
`test_every_world_keeps_its_walls_readable` misst die Helligkeiten.

**Es ist Präsentation, strenger als alles andere hier.** `SimWorld` liest das Feld
nicht, also rechnen zwei Bretter, die sich nur in ihrer Welt unterscheiden,
bitgleich — `test_a_world_never_reaches_the_simulation` spielt Level 15 in allen
sechs Welten durch und vergleicht Hash und Tickzahl. Ein unbekannter Name fällt auf
die Vorgabe zurück: ein Tippfehler soll den Look kosten, nicht das Level.

`PolarisTheme.use()` wird aus `_draw` gerufen und nicht einmalig beim Laden. Ein
Level erreicht den Spielbildschirm über mehr als einen Weg, und der Bau-Modus
wechselt die Welt bei offenem Brett; der Aufruf kehrt sofort zurück, wenn sich
nichts geändert hat. Das Menü setzt auf die Vorgabe zurück — es gehört zu keinem
Level, und die Kulisse des zuletzt gespielten Bretts würde die Levelliste wie einen
Teil davon aussehen lassen.

### Das Band, in dem du bist, ist der Ort, an dem du bist

Sieben Farben waren die billige Hälfte. Die andere ist, dass eine Welt aus
**Bändern** besteht: waagerechten Scheiben der Arena, jede mit einem eigenen Motiv,
und wer das Brett hochspielt, geht durch sie hindurch. Eine Werft ist kein Braun,
sondern ein Frachter — unter der Wasserlinie Spanten und Bullaugen mit der See
dahinter, darüber der Laderaum, über dem Deck die Kranausleger.

`PolarisTheme.World.bands` ist die Liste, `WorldArt` zeichnet sie. Die 21 Motive:

| Welt | oben | Mitte | unten |
|---|---|---|---|
| **Polaris** | Sterne, der Polarstern | Rumpfbeplankung | Decksplatten |
| **Werft** | Kranausleger, Haken am Seil | Laderaum: Kisten, Ketten | Spanten, Bullaugen, ein Fisch |
| **Schacht** | Fördergerüst, Leiter | Gestein in Schichten, Sickerwasser | stehendes Wasser, ersoffene Rohre |
| **Reaktor** | Galerie, mitlaufende Lampen | der Kessel, Steuerstäbe | Kühlkreis mit Puls |
| **Wrack** | Sterne, ein Planetenrand | treibende Trümmer | Rumpfbruch, blanke Spanten |
| **Sortieranlage** | Einläufe | Bänder, Rollen, Buchten | gefüllte Schächte |
| **Sturm** | getriebene Wolke, Wetterleuchten | Takelage, Vereisung | Außenhaut, Windstriche |

**Anteile, keine Pixel.** Ein Band ist ein Bruchteil der Arenahöhe, also erzählt
dieselbe Welt dieselbe Geschichte auf 660 px und auf 2400. Ein Brett, das nur je das
unterste Band zeigte, wäre ein Brett, auf dem die Welt unsichtbar ist.
`test_every_world_band_adds_up` verlangt, dass die Anteile genau eins ergeben — zu
wenig lässt eine unbemalte Naht, zu viel schiebt das letzte Band unten heraus — und
dass jeder Motivname auch gezeichnet wird; ein Name ohne Zweig malt einfach nichts
und meldet nie einen Fehler.

**Das zahlt sich erst auf einem hohen Brett aus.** Im Lauf folgt die Kamera bei 1:1,
also *wechselt* die Kulisse während des Versuchs. Sie sagt, wie weit man gekommen
ist, ohne ein Wort — und sie sagt es, während der Spieler beschäftigt ist, was ein
HUD nicht kann.

**Die alte Blocklage bleibt darunter liegen**, und das ist kein Rest: ein Rumpf, ein
Kistenstapel und eine Abschirmung sind alle eckig, also ist sie genau der
Untergrund, auf dem die Motive sitzen, statt etwas, gegen das sie ankämpfen müssen.

### Was die Kulisse nicht darf — und zweimal doch tat

Die Regel „eine Welt streicht die Kulisse, nie das Vokabular" war bisher ein Absatz,
den man sich merken musste. Jetzt ist sie eine **Dateigrenze**: `WorldArt` ist die
Kulisse, `BoardArt` das Vokabular, und `test_scenery_never_borrows_a_meaning` liest
den Quelltext von `world_art.gd` und lehnt jedes `PolarisTheme.PLUS`, `MINUS`,
`TARGET`, `OK`, `ACCENT` oder `BALL` darin ab. Kommentarzeilen werden vorher
abgezogen, weil der Kopf der Datei alle sechs nennt, um zu erklären, dass er sie
nicht benutzen darf.

**Formen sind dabei so gebunden wie Farben, und das habe ich beim Bauen verletzt.**
Der erste Reaktorkern waren konzentrische Ringe um eine leuchtende Scheibe — also
exakt das Bild, mit dem `BoardArt.draw_magnet` ein Feld zeichnet. Die Kulisse stellte
damit auf jedes Brett einen zweiten, riesigen, matten Magneten. **Die Farbe war nie
das Problem, die Form war es.** Der Kern ist jetzt ein stehender, gebänderter
Kessel; ein Rechteck teilt mit einer Scheibe nichts. Aus demselben Grund sind
Pfeile und Sparren verboten (eine kippende Zone zeigt damit ihre Richtung) und
regelmäßige Sägezähne (das sind Zacken) — der Rumpfbruch im Wrack ist deshalb per
Hash gestuft und nicht per Welle.

**Und die Helligkeiten sind auf Strichwerk geeicht, nicht auf Fläche.** Die erste
Fassung war durchweg halb so kräftig und unsichtbar; die zweite malte das Innere des
Kessels mit bis zu 0,45 eines gesättigten Gelbgrüns und schlug damit das Brett, das
davor stand. Eine große Füllung bei derselben Zahl ist eine andere Menge Licht als
eine Linie — der Kessel leuchtet jetzt über zwei schmale Rechtecke statt über eine
Tafel. Dasselbe beim Wetterleuchten im Sturm: es deckt als einzige Form den ganzen
Schirm, ist auf 0,04 gedeckelt und dauert eine Fünftelsekunde. Ein heller wäre ein
Stroboskop, und das ist für manche Leute mehr als eine Lästigkeit.

**Gerastert wird auch hier gegen den Sichtausschnitt.** Jedes wiederholende Motiv
rechnet seine Gitterindizes aus dem sichtbaren Streifen, nicht aus der Arena —
derselbe Fehler, den die Blocklage einmal gemacht hat (bei 2200×1200 über tausend
Zellen pro Frame, die meisten hinter dem Panel). Ein Band, das die Kamera nicht
schneidet, wird ganz übersprungen.

**Noch benutzt kein Kampagnenlevel eine Welt.** Eine Zeile pro Brett
(`level.theme = "Schacht"`) würde das ändern; das ist eine Gestaltungsentscheidung
und keine technische. Ohne sie sieht man die Bänder nur im Bau-Modus, wo `←`/`→`
durch die sieben blättert.

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

- Der Par-Sucher sucht einen Magneten pro Stufe. Bretter mit `budget > 1` *und*
  Toren kann er nicht; das wäre eine Suche über Kombinationen und bisher braucht
  sie kein Level
- Ob fünf Stationen die richtige Länge sind, ist eine Frage ans Spielgefühl. Level
  15 ist genau dafür gebaut: erst spielen, dann entscheiden, ob die Kampagne aus
  solchen Brettern bestehen soll oder aus kurzen
- Waagerecht fahrende Plattformen — brauchen ein Kontaktmodell, das die Kugel
  mitnimmt (siehe oben), nicht nur ein neues Level
- Förderbänder, das nächste Feature-Level
- Polygone gibt es nur als Wände. Zacken, Sprungfelder, Tore und Plattformen sind
  weiter Rechtecke; eine schräge Zackenkante bräuchte vor allem eine Zeichnung, die
  Simulation hat die Abfrage schon. Und die Mindestdicke von 7 px prüft der
  Bau-Modus nicht
- Ein Lauf endet nach `SimWorld.MAX_RUN_TICKS`, wenn der Ball liegen bleibt.
  Das ist bewusst dieselbe Zahl wie offline — aber 20 s auf einen stehenden Ball
  zu warten fühlt sich lang an. Falls das stört, ist die Antwort ein
  *Stillstands*-Kriterium in `SimWorld` (und damit auch in den Tests), kein
  zweiter, kürzerer Timer nur im Spiel.
- Fortschritt speichern — `PlayerProgress` war ans Raster gekoppelt und ist mit
  gelöscht; das Neue braucht einen eigenen Speicher (Bestzeiten pro Level)
- Ein über Checkpoints gewonnener Lauf trägt sich als Bestzeit ein wie ein
  durchgehender. Ehrlich ist das, weil die Aufzeichnung wirklich ein
  gewinnendes Replay ab Tick 0 ist — aber eine Bestenliste wird die beiden
  irgendwann trennen wollen (Rückfälle zählen, oder zwei Spalten)
- Level 12 ist jetzt eine exakte Dublette von Level 11: es war der A/B-Vergleich
  „dasselbe Brett mit Zeitlupe", und seit Level 11 selbst einen Zeitlupenpunkt hat,
  unterscheidet die beiden nichts mehr. Entweder löschen oder ihm eine eigene
  Frage geben
- Level 13, 14 und 15 haben keinen Rückweg-Beweis (Kriterium 9). Der Rasterbeweis
  setzt einen Magneten und sucht einen Sieg; ein verkettetes Brett braucht nach dem
  ersten Tor noch drei bis vier, also müsste die Suche selbst verkettet werden —
  was das Autorenwerkzeug inzwischen kann und der Beweis noch nicht nutzt
- Level 15 hat keinen Rasterbeweis, dass kein gewinnender Weg ein Tor auslässt
  (das, was `test_11c/d` für Level 11 leistet). Ohne ihn ist nicht ausgeschlossen,
  dass eine andere Platzierung die Reise abkürzt
- Level 13 reißt die Fairness-Schwelle an seiner dritten Station (7 statt 15) und
  gibt es in seiner Definition zu. Behoben wäre es nur durch verschobene
  Plattformen — die Suche hat mit Backtracking nichts Robusteres gefunden
- Der Par-Sucher kann pro Stufe nur *eine* vorige Antwort zurücknehmen und sucht
  dann vorwärts weiter. Tiefer zu backtracken wäre möglich, kostet aber Scheiben:
  20 à 14 s stehen gegen das 300-s-Budget des Runners
- Checkpoints hat bisher nur Level 11. Ob die Abschnittslänge stimmt, ist eine
  Frage ans Spielgefühl, nicht an einen Test
- Der Bau-Modus hat keine Tastatur für die Position: `←`/`→` stellen die Zahlen der
  Leiste, aber x, y, Breite und Höhe der ausgewählten Form stehen nicht darin. Eine
  Form lässt sich nur mit der Maus setzen, und um einen einzelnen Rasterschritt zu
  schieben, muss man sie neu greifen
- Der Bau-Modus kann nicht speichern und laden — ein Entwurf lebt in einer
  Sitzung und geht sonst als Quelltext raus. Für mehrere Entwürfe nebeneinander
  bräuchte es ein Format, und damit eine zweite Definition dessen, was ein Level
  ist
- Der Bau-Modus zeigt kein Urteil über das gebaute Brett. `test_zy_author.gd`
  rechnet Fairness je Station und „trägt jeder Magnet" schon aus; das beim Bauen
  anzuzeigen wäre der nächste sinnvolle Schritt und macht aus dem Werkzeug eines,
  das einem sagt, dass das Level unfair ist, *während* man es baut
- Das Menü staucht seine Zeilen, wenn die Liste wächst, statt überzulaufen — bei
  etwa 20 Leveln wird es trotzdem eng und braucht Spalten oder Blättern
- Mehr Level; der Ideenvorrat steht in `docs/echtzeit-ideen.md`
- Ton, Einstellungs-Screen, Steamworks
- Lokalisierung — alle Strings stehen deutsch im Code
