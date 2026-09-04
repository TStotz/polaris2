# POLARIS Echtzeit — Ideensammlung

Backlog für die Physik-Richtung, entstanden nach dem Prototyp
(`scenes/prototype.tscn`).

## Warum plötzlich so viele Ideen möglich sind

Im Raster-Puzzle musste **jede** Mechanik ganzzahlig, deterministisch und
solver-prüfbar sein. Das war der Grund für die Disziplin im Projekt — und
gleichzeitig die Bremse: Eine Idee war nur brauchbar, wenn der Solver sie
verstehen konnte.

In der Physik-Variante fällt diese Fessel weg. Dafür fällt auch der Beweis weg:
Kein Solver sagt mehr „lösbar in 4 Zügen". Das ändert das Bewertungskriterium.

**Alt:** Ist es lösbar, und ist die Lösung knapp?
**Neu:** Ist es **lesbar** (sehe ich, was passieren wird?) und **fair**
(scheitere ich aus einem Grund, den ich verstehe?).

Jede Idee unten ist danach beurteilt. Aufwand grob: **S** = Stunden,
**M** = ein Tag, **L** = mehrere Tage.

---

## A · Der Ball — was du steuerst

**Mehrere Bälle gleichzeitig** · S
Ein Magnet wirkt auf alle in Reichweite.
*Warum:* Die stärkste Mechanik aus dem Raster-Spiel, und in Echtzeit noch besser
— ein Zug, der einem Ball hilft, verreißt den anderen.

**Ballmassen** · S
Schwer = träge, leicht = zappelig. Pro Level oder pro Ball.
*Warum:* Eine Zahl, die das Fahrgefühl komplett umbaut. Billigste Variantenquelle
im ganzen Dokument.

**Polarität am Ball** · S
Manche Bälle reagieren nur auf Anziehen, andere nur auf Abstoßen.
*Warum:* Zwingt zur Auswahl statt zum Dauerhalten, und färbt Bälle sinnvoll ein.

**Zerbrechlicher Ball** · S
Aufprall über Tempo X = kaputt.
*Warum:* Macht Kraft zum zweischneidigen Schwert. Ohne das ist „mehr Kraft" immer
besser, und die Ladung wird zur reinen Fleißaufgabe.

**Aufladung unterwegs** · M
Der Ball sammelt Ladung ein, die seine Magnetisierbarkeit erhöht.
*Warum:* Ein Fortschrittsgefühl innerhalb eines Laufs.

---

## B · Die Magnete — deine Werkzeuge

**Bewegte Magnete** · S — *empfohlen*
Auf Schienen, pendelnd oder kreisend.
*Warum:* Verwandelt Platzierung in Timing — genau die Achse, die der Prototyp
aufgemacht hat. Deine eigene Idee, und die billigste starke.

**Ring-Feld statt Punktfeld** · S — *empfohlen*
Der Magnet zieht den Ball nicht in seinen Mittelpunkt, sondern auf eine
**Kreisbahn** im Radius R.
*Warum:* Aus einem einzigen geänderten Parameter entstehen Orbits und
Schleudern. Größter Ausdruckszuwachs pro Zeile Code im ganzen Dokument — und es
löst nebenbei das Problem, dass ein Anziehmagnet den Ball bei sich parkt.

**Geplante Magnetbahn** · M — **gebaut** (Level 8 „Fahrt“)
Umgesetzt als gerade Pendelstrecke, wie unten empfohlen: Drücken setzt, Ziehen
zeichnet, ein Klick ohne Ziehen lässt den Magneten stehen. Der Polygonzug ist
weiterhin offen. Was sich beim Bauen bestätigt hat, steht in `CLAUDE.md`:
Determinismus kostenlos, Aufwand fast ausschliesslich in der Oberfläche.

**Geplante Magnetbahn — ursprüngliche Bewertung**
In der Planung zeichnest du dem Magneten einen Weg; im Lauf fährt er ihn mit
konstanter Geschwindigkeit ab.
*Warum:* Aus „wo steht der Magnet" wird „wo ist er **wann**". Das ist eine echte
zusätzliche Achse, und sie wertet die Haltezeiten *auf*, statt sie zu ersetzen:
Halten bei Tick 30 bedeutet etwas anderes als bei Tick 90, weil der Magnet
inzwischen woanders steht. Beide Fragen bleiben unabhängig voneinander.
*Determinismus:* praktisch kostenlos. Die Bahn ist Planungsdaten von **vor**
Tick 0, keine Eingabe — die Regel „eine Bitmaske pro Tick" bleibt wörtlich
unberührt, und ein Magnet ohne Bahn ist bitgleich der statische von heute, also
bleiben alle `PAR_FINGERPRINTS` gültig. Position als **reine Funktion des Ticks**
rechnen (Streckenlängen einmal beim Setup), nicht pro Tick aufaddieren, sonst
driftet eine Bahn über lange Läufe. `sqrt` fürs Normalisieren ist erlaubt,
`sin` nicht.
*Kosten:* die Oberfläche, nicht die Simulation. Ein Bahn-Editor braucht
Wegpunkte, Rückgängig, Geschwindigkeit und eine Anzeige, wo der Magnet wann
steht — und das in der Schicht ohne Testabdeckung. **Zuerst die gerade
Pendelstrecke bauen:** Magnet setzen, einmal ziehen, fertig. Das ist eine
zusätzliche Mausgeste und dieselbe Dreieckswelle wie `MoverSpec`. Den Polygonzug
erst, wenn sich das gut spielt.
*Achtung 1:* Eine Live-Vorschau der Ballbahn beim Editieren ist verlockend (die
Simulation kostet Millisekunden), aber sie darf die Haltezeiten **nicht**
einrechnen — sonst ist das Level gelöst, sobald die Linie das Ziel trifft, und
die Ausführung wertlos.
*Achtung 2:* Der Replay-Sucher würfelt keine brauchbaren Bahnen. Bahn von Hand
entwerfen, den Sucher nur noch die Haltezeiten finden lassen.

**Magnete während des Laufs ziehen** · M — *abgeraten*
Nicht nur an/aus, sondern mit der Maus verschieben.
*Warum nicht:* Klingt nach mehr Dynamik, entfernt aber eine Dimension statt eine
hinzuzufügen — wer live korrigieren kann, plant nicht mehr, und übrig bleibt
„zieh den Magneten dorthin, wo der Ball hin soll". Level 4 („ein Feld reicht
400 px, also übergib") wäre damit hinfällig, Level 2 macht den Fallstrick zur
Hauptmechanik. Das Perfide: **die Tests bleiben grün**, weil die Pars keine
Magnete verschieben — die halbe Kampagne verlöre ihre Bedeutung, ohne dass eine
Zusicherung bricht. Falls doch, dann streng begrenzt (ein Umsetzen pro Lauf),
kostenpflichtig (Ladung + tote Ticks) und als Level-Eigenschaft, nie global.
Die geplante Bahn oben erreicht dasselbe Ziel, ohne etwas wegzunehmen.

**Gerichtetes Feld (Kegel/Strahl)** · M
Wirkt nur in eine Richtung, drehbar.
*Warum:* Aus einem Werkzeug wird ein zielbares.

**Nachladende Magnete** · S
Ladung füllt sich beim Loslassen wieder auf, statt einmalig zu sein.
*Warum:* Fördert Pulsen statt Dauerhalten — rhythmischer, weniger Alles-oder-nichts.
**Gegenentwurf zur aktuellen Einweg-Ladung; ausprobieren, welches besser trägt.**

**Globale Energie** · S
Ein Konto für alle Magnete statt eins pro Magnet.
*Warum:* Einfacheres HUD, härtere Entscheidungen. Auch hier: Alternative, nicht
Ergänzung.

**Gekoppelte Magnete** · M
Einer an heißt: ein anderer aus.
*Warum:* Erzwingt Reihenfolge, ohne Regeln zu erfinden.

**Feste Magnete im Level** · S
Teil der Geometrie, immer an, nicht abschaltbar.
*Warum:* Level-Design-Werkzeug: Strömungen, die du umschiffen musst.

---

## C · Das Brett — die Arena

**Platten & Tore** · S — *empfohlen*
Ball rollt über eine Platte, gleichfarbiges Tor öffnet sich.
*Warum:* Ist im Raster-Spiel schon gebaut und durchdacht. In Echtzeit
verschwindet sogar die unelegante Regel „Umschaltung greift erst nach dem Zug" —
hier passiert es einfach sofort, und das ist richtig.

**Bröckelnde Kanten** · S — *empfohlen*
Halten genau einen Durchgang.
*Warum:* Verbietet Herumprobieren an Ort und Stelle. Erzwingt Festlegung.

**Oberflächen: Eis, Klebstoff, Gummi** · S — *empfohlen*
Reibung und Sprungkraft pro Fläche.
*Warum:* Drei Zahlen, sofort lesbar an der Farbe, riesiger Hebel fürs
Level-Design.

**Bewegte Plattformen** · M
Aufzüge, rotierende Balken.
*Warum:* Der Klassiker im Parcours-Genre, und er passt: der Ball wartet nicht.

**Förderbänder** · S
Fläche schiebt den Ball seitlich.
*Warum:* Konstante Kraft, gegen die man arbeitet — billig und deutlich.

**Windzonen / Strömungen** · S
Bereiche mit konstanter Kraft.
*Warum:* Wie Förderbänder, aber im freien Fall statt am Boden.

**Zähe Zonen** · S
Starke Dämpfung, der Ball wird langsam.
*Warum:* Gibt dem Spieler Zeit zurück — dosierbare Entschleunigung an Stellen,
die sonst zu hektisch wären.

**Abstoßende Wände** · S
Wände mit eigenem Magnetfeld.
*Warum:* Sanftes Leiten statt hartes Abprallen.

**Zerbrechliche Wände** · M
Ab Tempo X durchschlägt der Ball sie.
*Warum:* Macht Geschwindigkeit zur Ressource, nicht nur zum Risiko. Kombiniert
stark mit dem zerbrechlichen Ball — beide machen Tempo zur Entscheidung.

**Schwerkraft umlenken** · M
Pro Zone oder per Schalter.
*Warum:* Baut den Parcours um, ohne die Geometrie anzufassen.

---

## D · Gefahr und Scheitern

**Stacheln / Killzonen** · S
*Warum:* Der einfachste Weg, einen Weg wirklich zu verbieten.

**Steigendes Wasser / Lava** · M
Der Level füllt sich von unten.
*Warum:* Zeitdruck, ohne eine Uhr einzublenden. Erzeugt Dringlichkeit statt sie
anzusagen.

**Verfolger** · L
Etwas jagt den Ball.
*Warum:* Stark, aber teuer und leicht unfair. Erst wenn die Basis sitzt.

---

## E · Ziele jenseits von „komm an"

**Kristalle einsammeln** · S
*Warum:* Portiert direkt aus dem Raster-Spiel und definiert die Route neu, ohne
neue Regeln.

**Zeitlimit / Bestzeit** · S
*Warum:* Der natürliche Wiederspiel-Anreiz eines Geschicklichkeitsspiels — und
ersetzt die Sterne sauberer, als die Magnetzahl es je konnte.

**Mit Restladung ankommen** · S
Bewertung nach übriger Energie.
*Warum:* Belohnt Sparsamkeit statt Dauerhalten. Das Effizienz-Scoring, das im
Raster-Spiel über die Magnetzahl lief — hier ist es endlich stufenlos.

**Eskorte** · M
Zweiter Ball muss überleben.
*Warum:* Nutzt die Mehrball-Physik für ein anderes Gefühl.

---

## F · Drumherum

**Bestenlisten / Zeitrennen** · L
*Warum:* Die naheliegende Steam-Meta. **Setzt Determinismus voraus — siehe unten.**

**Geister-Replays** · M
Dein bester Lauf als Schatten.
*Warum:* Billigster Weg zu „nochmal, ich war fast dran".

**Level-Editor + Teilen** · L
*Warum:* Für ein Parcours-Spiel der natürliche Endausbau. Aber erst, wenn der
Kern trägt — sonst baust du Werkzeuge für ein Spiel, das noch nicht steht.

**Ton** · M
Magnetbrummen, dessen Tonhöhe mit der Kraft steigt; Aufprall nach Tempo.
*Warum:* Bei einem unsichtbaren Kraftfeld ist Ton kein Schmuck, sondern
**Information**. Wahrscheinlich der größte Gewinn an Lesbarkeit im ganzen
Dokument.

**Zeitlupe im Beinahe-Moment** · S
*Warum:* Macht knappe Situationen lesbar und fühlbar zugleich.

---

## Die ersten fünf

Billig, wirkungsvoll, ohne Konflikte untereinander:

1. **Ring-Feld** — größter Zuwachs an Ausdruck pro Aufwand
2. **Bewegte Magnete** — Platzierung wird Timing
3. **Oberflächen (Eis/Klebstoff/Gummi)** — Level-Design-Hebel für drei Zahlen
4. **Bröckelnde Kanten** — erzwingt Festlegung
5. **Ton** — macht das unsichtbare Feld hörbar

Danach: Platten & Tore (fast fertig gedacht) und zerbrechlicher Ball
(macht Kraft zur Entscheidung).

## Fallen

**Portale** — billig einzubauen, zerstören aber räumliches Denken. Der Spieler
kann eine Strecke nicht mehr überblicken.

**Ganzes Brett rotieren** — teuer, desorientierend, und es kämpft mit der
Identität: Magnete sollen das Verb sein, nicht die Kamera.

**Feindliche Magnete, die gegen dich arbeiten** — klingt gut, ist in der Praxis
unlesbar. Zwei unsichtbare Kraftfelder, die sich überlagern, kann niemand
auseinanderhalten.

**Ball teilt sich** — vervielfacht, was der Spieler gleichzeitig verfolgen muss.
In Echtzeit ist das Überforderung, nicht Tiefe.

**Alles gleichzeitig** — die eigentliche Falle. Jede dieser Ideen ist eine
Variable im Level-Design. Fünf Mechaniken ergeben mehr spielbare Level als
fünfzehn, weil man fünf noch kombinieren kann und fünfzehn nur noch stapelt.

---

## Eine Entscheidung, die früh fallen muss

**Determinismus.** Float-Physik ist über Maschinen hinweg nicht reproduzierbar.
Solange das so bleibt, gibt es keine verlässlichen Bestenlisten und keine
teilbaren Geisterläufe.

Wer das will, braucht **festen Zeitschritt und Fixpunkt-Arithmetik** — machbar,
aber nur schwer nachrüstbar, wenn schon hundert Level auf dem alten Verhalten
balanciert sind.

Genau diese Sorge stand schon in `POLARIS_CONTEXT.md` §9. Damals galt sie dem
geteilten Tagesrätsel; hier gilt sie den Bestenlisten. Die Antwort ist dieselbe:
vorher entscheiden, nicht hinterher.

---

## Was mit dem Raster-Spiel passiert

Die Kampagne ist unangetastet und bleibt spielbar. Zwei ehrliche Optionen:

**Beides behalten** — der Prototyp ist ein zweiter Modus. Kostet dauerhaft
Pflege für zwei Regelwerke.

**Umschwenken** — dann sterben `movement.gd`, der Solver, der Generator, die
Differential-Fixtures und die Dart-Pipeline. Grob zwei Drittel des Codes. Palette,
Theme, Feldlinien-Darstellung, Menüs und Fortschritt bleiben nutzbar.

Nicht heute entscheiden. Aber bewusst entscheiden, wenn es soweit ist — und nicht
aus Versehen, indem das Raster-Spiel einfach nicht mehr angefasst wird.
