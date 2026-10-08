# -*- coding: utf-8 -*-
"""POLARIS' Musik und Effekte, als Quelltext.

    python tools/musik.py                  alles rendern (rund 8 Sekunden)
    python tools/musik.py werft            nur diese eine Welt
    python tools/musik.py sfx              nur die Effekte
    python tools/musik.py werft -p         rendern *und* gleich abspielen

Heraus kommen WAVs in `tools/audio/` — nicht im Git, das sind Zwischenstaende.
Geschrieben wird immer; `-p` (oder `--hoeren`) haengt das Abspielen hinten dran,
in der Reihenfolge der Tabelle. Abbrechen mit Strg+C.

## Was du wo drehst

Jede Welt ist eine Funktion, `world_werft()` und so weiter. Darin:

  root      Die Tonart, in Hertz: der Grundton, auf den sich alles bezieht.
            110 Hz ist A2. Verdoppeln heisst eine Oktave hoeher.
  chords    Die Harmonie, als Halbtonschritte ueber `root`. `[0, 3, 7, 14]` ist
            Grundton, kleine Terz, Quinte, None — Moll mit Farbe. Eine 4 statt
            der 3 macht daraus Dur. Die Liste wird ueber den Loop verteilt, ein
            Akkord je Viertel.
  cut=      Wie hell das Bett ist, in Hertz. Kleiner = dumpfer, weiter weg.
  harmonics=  Wie viele Obertoene der Saegezahn hat. Mehr = schaerfer.
  detune=   Wie weit die Stimmen gegeneinander verstimmt sind. Das ist der
            Unterschied zwischen einem Ton und einem Pad; hochdrehen macht es
            schwebend, uebertreiben macht es seekrank.
  reverb(x, sekunden, anteil)   Wie gross der Raum ist. Der Schacht klingt wie
            ein Schacht, weil sein Nachhall lang und dunkel ist.
  LOOP      Laenge des Loops in Sekunden, fuer alle Welten gemeinsam.

Die Puls-Schleifen (Werft, Reaktor, Sortieranlage) haben zusaetzlich `bpm` und
teils ein `pattern`; `place(x, zeitpunkt, klang, lautstaerke)` setzt einen Klang
an eine Stelle im Loop.

Die Effekte stehen unten als `sfx_*`. Dieselben Bausteine, nur kuerzer.

## Warum das hier Python ist und nicht GDScript

Weil du es nach Gehoer aenderst, und dafuer brauchst du eine Schleife von
Sekunden, nicht von Spielstarts. Die Betten sind sechzehn Sekunden Stimmung —
nichts daran muss einem Tick folgen, also duerfen sie fertig gerendert mitreisen
und diese Datei ist ihre Quelle.

Die **Effekte** gehen den anderen Weg: das Magnetbrummen muss der Feldstaerke
stufenlos folgen, und das kann kein Sample. Die gehoeren zur Laufzeit in
GDScript, in einen `AudioStreamGenerator`. Hier stehen sie, damit man sie hoeren
und entscheiden kann, bevor sie dorthin wandern.

## Was die Zahlen am Ende bedeuten

Ein Ohr entscheidet, ob etwas gut ist; diese Zahlen fangen nur, was seiner Welt
offen widerspricht. Die Werft mass beim ersten Durchgang 2024 Hz Schwerpunkt und
sieben Prozent unter 200 Hz — das ist ein Blechdach, keine Werft.
"""

import os
import subprocess
import sys
import time
import wave

import numpy as np

SR = 44100
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "audio")


# --- the smallest synth that can carry this -------------------------------

def t_axis(dur):
    return np.arange(int(dur * SR)) / SR


def saw(hz, dur, harmonics=8, detune=0.0035, voices=3):
    """An additive saw: bright, band-limited by construction, no aliasing.

    Three slightly detuned copies, because one is a tone and three are a pad —
    the beating between them is most of what makes a held chord sound alive.
    """
    t = t_axis(dur)
    out = np.zeros_like(t)
    for v in range(voices):
        spread = (v - (voices - 1) / 2.0) * detune
        f = hz * (1.0 + spread)
        for h in range(1, harmonics + 1):
            out += np.sin(2.0 * np.pi * f * h * t) / h
    return out / (voices * harmonics)


def sine(hz, dur, detune=0.0):
    t = t_axis(dur)
    return np.sin(2.0 * np.pi * hz * (1.0 + detune) * t)


def tri(hz, dur, harmonics=6):
    """Odd harmonics only, falling off fast: hollow and soft, good for bells."""
    t = t_axis(dur)
    out = np.zeros_like(t)
    for k in range(harmonics):
        h = 2 * k + 1
        out += ((-1) ** k) * np.sin(2.0 * np.pi * hz * h * t) / (h * h)
    return out * 0.81


def noise(dur, seed=0):
    return np.random.default_rng(seed).normal(0.0, 1.0, int(dur * SR))


def adsr(dur, a=0.01, d=0.1, s=0.7, r=0.3):
    n = int(dur * SR)
    env = np.zeros(n)
    na, nd = int(a * SR), int(d * SR)
    nr = int(r * SR)
    ns = max(0, n - na - nd - nr)
    i = 0
    if na:
        env[i:i + na] = np.linspace(0.0, 1.0, na)
        i += na
    if nd:
        env[i:i + nd] = np.linspace(1.0, s, nd)
        i += nd
    if ns:
        env[i:i + ns] = s
        i += ns
    if nr and i < n:
        env[i:n] = np.linspace(s, 0.0, n - i)
    return env


def lowpass(x, cut_hz, slope=2.0):
    """Filtering in the frequency domain.

    A one-pole IIR would be the usual answer and needs a sample loop, which in
    Python is slower than the whole rest of this file. An FFT and a smooth
    rolloff does the same job here and costs a millisecond.
    """
    n = len(x)
    spec = np.fft.rfft(x)
    f = np.fft.rfftfreq(n, 1.0 / SR)
    roll = 1.0 / (1.0 + (f / max(1.0, cut_hz)) ** (2.0 * slope))
    return np.fft.irfft(spec * roll, n)


def highpass(x, cut_hz, slope=2.0):
    n = len(x)
    spec = np.fft.rfft(x)
    f = np.fft.rfftfreq(n, 1.0 / SR)
    roll = 1.0 - 1.0 / (1.0 + (f / max(1.0, cut_hz)) ** (2.0 * slope))
    return np.fft.irfft(spec * roll, n)


def reverb(x, seconds=1.8, mix=0.35, seed=7):
    """Convolution with a synthetic decaying-noise impulse.

    Cheap, and it is what gives every world its sense of *size* — the shaft
    sounds like a shaft because its tail is long and dark.
    """
    n_ir = int(seconds * SR)
    rng = np.random.default_rng(seed)
    ir = rng.normal(0.0, 1.0, n_ir) * np.exp(-np.linspace(0.0, 6.0, n_ir))
    ir = lowpass(ir, 3200.0)
    ir /= np.max(np.abs(ir)) + 1e-9
    full = np.fft.irfft(
        np.fft.rfft(x, len(x) + n_ir) * np.fft.rfft(ir, len(x) + n_ir),
        len(x) + n_ir,
    )
    # Auch die Hallfahne laeuft um. Sie einfach abzuschneiden hiesse, den Raum am
    # Loop-Punkt zuzuschlagen — und ein Raum, der sich alle sechzehn Sekunden
    # schliesst, ist kein Raum.
    wet = full[: len(x)].copy()
    tail = full[len(x):]
    k = 0
    while k < len(tail):
        take = min(len(tail) - k, len(x))
        wet[:take] += tail[k:k + take]
        k += take
    wet /= np.max(np.abs(wet)) + 1e-9
    return (1.0 - mix) * x + mix * wet * np.max(np.abs(x))


def play_file(path, seconds):
    """Spielt eine WAV ab und wartet, bis sie durch ist.

    Auf Windows ueber `winsound` aus der Standardbibliothek, sonst ueber das
    erstbeste Kommandozeilenwerkzeug, das da ist. Kein Paket zu installieren —
    ein Anhoerwerkzeug, das erst eine Abhaengigkeit verlangt, benutzt man nicht.

    Abgespielt wird asynchron und die Wartezeit in kleinen Schritten
    abgesessen, damit Strg+C sofort ankommt statt erst nach sechzehn Sekunden.
    """
    if sys.platform == "win32":
        import winsound

        winsound.PlaySound(path, winsound.SND_FILENAME | winsound.SND_ASYNC)
        try:
            left = seconds + 0.3
            while left > 0.0:
                time.sleep(0.1)
                left -= 0.1
        except KeyboardInterrupt:
            winsound.PlaySound(None, winsound.SND_PURGE)
            raise
        return True

    for cmd in (["afplay", path], ["paplay", path], ["aplay", "-q", path]):
        try:
            subprocess.run(cmd, check=True, capture_output=True)
            return True
        except (OSError, subprocess.CalledProcessError):
            continue
    return False


def place(track, at_s, chunk, gain=1.0):
    """Setzt einen Klang in den Loop — und laesst ihn ueber das Ende hinaus in
    den Anfang hineinlaufen.

    Ohne das Umlaufen wird alles hart abgeschnitten, was spaet im Loop anfaengt,
    und beim Wiederholen knackt es. Gemessen: Schacht und Werft sprangen am
    Loop-Punkt um 0,44 beziehungsweise 0,39, wo ein gewoehnlicher Schritt
    zwischen zwei Samples 0,002 betraegt.

    Umlaufend klingt eine Glocke bei Sekunde 15 in die naechste Runde hinein.
    Das ist kein Trick, sondern was ein Loop bedeutet.
    """
    n = len(track)
    m = len(chunk)
    if n <= 0 or m <= 0:
        return
    pos = int(at_s * SR) % n
    k = 0
    while k < m:
        take = min(m - k, n - pos)
        track[pos:pos + take] += chunk[k:k + take] * gain
        k += take
        pos = (pos + take) % n


def hz(root, semi):
    return root * (2.0 ** (semi / 12.0))


def stereo(mono, width=0.25, seed=3):
    """Widened by delaying and tilting the sides a few milliseconds apart."""
    d = int(0.011 * SR)
    left = mono.copy()
    right = mono.copy()
    left[d:] += mono[:-d] * width
    right[: len(mono) - d] += mono[d:] * width
    return left, right


def write_wav(path, left, right=None):
    if right is None:
        right = left
    peak = max(np.max(np.abs(left)), np.max(np.abs(right)), 1e-9)
    left = left / peak * 0.89
    right = right / peak * 0.89
    inter = np.empty(len(left) * 2)
    inter[0::2] = left
    inter[1::2] = right
    data = (np.clip(inter, -1.0, 1.0) * 32767.0).astype("<i2")
    with wave.open(path, "wb") as f:
        f.setnchannels(2)
        f.setsampwidth(2)
        f.setframerate(SR)
        f.writeframes(data.tobytes())
    spec = np.abs(np.fft.rfft(left))
    freqs = np.fft.rfftfreq(len(left), 1.0 / SR)
    rms = float(np.sqrt(np.mean(left ** 2)))
    return dict(
        peak=float(peak),
        rms=rms,
        dc=float(np.mean(left)),
        seconds=len(left) / SR,
        # Spectral centre, and how much sits below 200 Hz: "bright or dark" and
        # "heavy or thin" as numbers. They cannot say a sound is good. They can
        # say it contradicts the world it belongs to.
        centroid=float((spec * freqs).sum() / (spec.sum() + 1e-9)),
        low=float(spec[freqs < 200.0].sum() / (spec.sum() + 1e-9)),
        crest=float(np.max(np.abs(left)) / (rms + 1e-9)),
    )


# --- the worlds -----------------------------------------------------------
#
# One bed per world in `PolarisTheme.WORLDS`. They share a shape — a slow chord
# bed, optionally a pulse, optionally a texture — and differ in root, mode,
# tempo, timbre and whether there is a pulse at all. That is deliberate: seven
# unrelated pieces would make the campaign sound like seven games.

LOOP = 16.0


def bed(root, chords, dur_each, build, cut=1400.0, seed=1):
    """A chord bed: each chord held, overlapping into the next."""
    # Genau einen Loop lang: was der letzte Akkord ueberhaengt, laeuft durch
    # `place` in den Anfang zurueck, statt abgeschnitten zu werden.
    track = np.zeros(int(LOOP * SR))
    for i, ch in enumerate(chords):
        at = i * dur_each
        for semi in ch:
            v = build(hz(root, semi), dur_each + 1.6)
            v *= adsr(dur_each + 1.6, a=0.9, d=0.4, s=0.75, r=1.4)
            place(track, at, v, 1.0 / max(1, len(ch)))
    return lowpass(track, cut)


def world_polaris():
    root = 110.0  # A2
    chords = [[0, 3, 7, 14], [0, 3, 10, 14], [-2, 5, 12, 15], [0, 3, 7, 10]]
    x = bed(root, chords, LOOP / 4, lambda f, d: saw(f, d, harmonics=7), cut=1300.0)
    # Zwei ruhige Glocken wie gehabt, und danach eine Linie, die **faellt** —
    # jeder Ton tiefer als der davor — bis sie in einer Triole auf dem Grundton
    # landet, also auf dem Ton, mit dem das Stueck anfaengt.
    #
    # Ein Eintrag je Glocke: (Sekunde, Halbtoene ueber A4, Lautstaerke, Laenge).
    # Eine Zeile mehr ist eine Glocke mehr.
    #
    # Die Halbtoene stammen aus a-Moll, also aus derselben Menge wie `chords`
    # darueber: 0 A, 2 H, 3 C, 5 D, 7 E, 10 G, 12 A, 14 H. Ein Ton von ausserhalb
    # (1, 6, 8) klingt gegen das Bett.
    opening = (
        (1.50,  7, 0.05, 3.0),   # E5
        (9.50, 14, 0.05, 3.0),   # H5
    )
    # Der Abstieg setzt unter der zweiten Glocke an und geht von dort nur noch
    # nach unten.
    descent = (
        (10.60, 12, 0.05, 2.4),  # A5
        (11.50, 10, 0.05, 2.4),  # G5
        (12.40,  7, 0.05, 2.4),  # E5
        (13.30,  5, 0.05, 2.4),  # D5
        # Die Triole: drei gleich weit auseinander (0,34 s), kurz gehalten, weil
        # drei Toene in sieben Zehnteln mit langem Ausklang zu Brei werden. Der
        # Schlusston darf wieder stehen — er soll ankommen, und er laeuft in die
        # naechste Runde des Loops hinein.
        (14.20,  3, 0.05, 1.8),  # C5
        (14.54,  2, 0.05, 1.8),  # H4
        (14.88,  0, 0.05, 3.0),  # A4 — der erste Ton des Stuecks
    )
    # Dass diese Linie faellt, ist der ganze Einfall. Ein spaeterer Eingriff, der
    # das bricht, soll es sagen und nicht darauf hoffen, dass jemand hinhoert.
    # Die beiden Eroeffnungsglocken stehen absichtlich ausserhalb: die zweite
    # liegt hoeher als die erste.
    assert all(a[1] > b[1] for a, b in zip(descent, descent[1:])), "Die Linie faellt nicht"
    for at, semi, level, dur in opening + descent:
        b = tri(hz(root * 4, semi), dur) * adsr(dur, a=0.005, d=1.2, s=0.15, r=1.6)
        place(x, at, b, level)
    return reverb(x, 2.4, 0.42, seed=11)


def world_werft():
    root = 73.42  # D2
    chords = [[0, 3, 7, 12], [0, 3, 8, 12], [-3, 4, 7, 12], [0, 3, 7, 10]]
    x = bed(root, chords, LOOP / 4, lambda f, d: saw(f, d, harmonics=10), cut=2200.0)
    # An engine under the floor. Without it this world measured 2024 Hz of
    # spectral centre and 7% below 200 Hz — which is a tin roof, not a shipyard.
    # A yard is *heavy*; the weight has to be in the sound before the hammers are.
    for i, ch in enumerate(chords):
        sub_v = sine(hz(root, ch[0] - 12), LOOP / 4 + 1.0) * 0.8
        sub_v += saw(hz(root, ch[0] - 12), LOOP / 4 + 1.0, harmonics=3) * 0.4
        sub_v *= adsr(LOOP / 4 + 1.0, a=0.6, d=0.3, s=0.85, r=0.9)
        place(x, i * LOOP / 4, lowpass(sub_v, 260.0), 0.85)
    # A clank on the beat, metal on metal. Noise through a narrow band is a
    # hammer; a tone would be a bell, and a bell is a church.
    bpm = 84.0
    beat = 60.0 / bpm
    n = int(LOOP / beat)
    for i in range(n):
        hit = noise(0.22, seed=100 + i)
        hit = highpass(lowpass(hit, 1900.0), 480.0)
        hit *= adsr(0.22, a=0.001, d=0.06, s=0.12, r=0.14)
        place(x, i * beat, hit, 0.34 if i % 4 == 0 else 0.15)
    return reverb(x, 1.4, 0.3, seed=12)


def world_schacht():
    root = 41.20  # E1 — down where you feel it more than hear it
    chords = [[0, 7], [0, 7], [-1, 6], [0, 7]]
    x = bed(root, chords, LOOP / 4, lambda f, d: sine(f, d) * 0.7 + saw(f, d, 4) * 0.3,
            cut=520.0)
    # Drips, irregular. The descent is quiet; what breaks the quiet should be
    # small and far away, never a beat — a beat would give you something to hold
    # on to, and this world is about not having that.
    for at, semi in ((2.3, 36), (5.1, 43), (7.9, 36), (11.4, 40), (13.8, 31)):
        d = tri(hz(root, semi), 1.6) * adsr(1.6, a=0.002, d=0.5, s=0.08, r=1.0)
        place(x, at, d, 0.16)
    return reverb(x, 3.4, 0.5, seed=13)


def world_reaktor():
    root = 65.41  # C2
    chords = [[0, 3, 6, 10], [0, 3, 7, 10], [0, 4, 6, 11], [0, 3, 6, 10]]
    x = bed(root, chords, LOOP / 4, lambda f, d: saw(f, d, harmonics=12), cut=1800.0)
    # Everything here runs on a beat, so the music does too — and it is the only
    # world with a pulse fast enough to feel like pressure.
    bpm = 108.0
    step = 60.0 / bpm / 2.0
    n = int(LOOP / step)
    for i in range(n):
        # An octave above where it started. Down at root+12 the pulse sat inside
        # the pad and read as part of the chord; pressure has to be *above* the
        # bed to be felt as pressure.
        p = saw(hz(root, 24), 0.13, harmonics=6) * adsr(0.13, a=0.002, d=0.05, s=0.2, r=0.07)
        place(x, i * step, lowpass(p, 3400.0), 0.24 if i % 2 == 0 else 0.11)
    return reverb(x, 1.2, 0.26, seed=14)


def world_wrack():
    root = 92.50  # F#2
    chords = [[0, 5, 10, 17], [0, 5, 12, 19], [-2, 3, 10, 15], [0, 5, 10, 14]]
    # Weightless: no pulse at all, and the detune pushed far enough that the
    # chord never quite settles. Drifting is the whole brief.
    x = bed(root, chords, LOOP / 4,
            lambda f, d: saw(f, d, harmonics=6, detune=0.011, voices=4), cut=1100.0)
    return reverb(x, 3.0, 0.5, seed=15)


def world_sortieranlage():
    root = 98.00  # G2
    chords = [[0, 4, 7, 11], [0, 4, 9, 14], [2, 6, 9, 13], [0, 4, 7, 12]]
    # The pad sits an octave up and stays thin: this world measured 409 Hz and 52%
    # below 200 Hz on its first pass, which is a cellar. It is the *clean* one —
    # the place where things are sorted — and it has to sound like daylight.
    x = bed(root * 2.0, chords, LOOP / 4, lambda f, d: tri(f, d, harmonics=5), cut=4200.0)
    x = highpass(x, 190.0)
    # Orderly: a running arpeggio in even eighths. This is the only world where
    # things are *sorted*, and the music is the one place that can say so
    # without a label.
    bpm = 96.0
    step = 60.0 / bpm / 2.0
    pattern = [0, 4, 7, 11, 14, 11, 7, 4]
    n = int(LOOP / step)
    for i in range(n):
        semi = pattern[i % len(pattern)] + 24
        a = tri(hz(root, semi), 0.4) * adsr(0.4, a=0.004, d=0.12, s=0.25, r=0.24)
        place(x, i * step, a, 0.26)
    return reverb(x, 1.6, 0.34, seed=16)


def world_sturm():
    root = 58.27  # Bb1
    chords = [[0, 7, 10], [0, 7, 10], [-2, 5, 10], [0, 7, 12]]
    x = bed(root, chords, LOOP / 4, lambda f, d: saw(f, d, harmonics=5, detune=0.006),
            cut=800.0)
    # Wind: filtered noise that swells and falls, its band wandering. Two swells
    # over the loop, deliberately out of step with the chords so nothing lands
    # on a grid.
    for at, dur, cut in ((0.5, 7.5, 900.0), (6.8, 8.5, 1500.0)):
        w = noise(dur, seed=200 + int(at))
        w = highpass(lowpass(w, cut), 220.0)
        w *= adsr(dur, a=dur * 0.45, d=dur * 0.1, s=0.6, r=dur * 0.4)
        place(x, at, w, 0.30)
    return reverb(x, 2.2, 0.38, seed=17)


WORLDS = {
    "polaris": world_polaris,
    "werft": world_werft,
    "schacht": world_schacht,
    "reaktor": world_reaktor,
    "wrack": world_wrack,
    "sortieranlage": world_sortieranlage,
    "sturm": world_sturm,
}


# --- the effects ----------------------------------------------------------
#
# These are the ones that carry *information*, which is the whole argument for
# sound in this game: the field is invisible, so the ear can say what the eye
# needs a second ring to say.

def sfx_magnet_hum():
    """One file, three distances: far, closer, at lifting range.

    Pitch and brightness rise as the field beats gravity. That is the number the
    inner ring draws, made audible — and unlike the ring it is still there when
    you are looking at the ball instead.
    """
    out = np.zeros(int(6.6 * SR))
    for k, (base, cut, level) in enumerate(
        ((70.0, 500.0, 0.28), (104.0, 1100.0, 0.55), (150.0, 2400.0, 0.85))
    ):
        dur = 1.8
        v = saw(base, dur, harmonics=9, detune=0.004) * 0.7 + sine(base * 2, dur) * 0.3
        # A slow wobble, so a held magnet sounds alive rather than like a sine
        # left switched on.
        t = t_axis(dur)
        v *= 1.0 + 0.06 * np.sin(2.0 * np.pi * 5.5 * t)
        v = lowpass(v, cut)
        v *= adsr(dur, a=0.12, d=0.2, s=0.85, r=0.5)
        place(out, k * 2.2, v, level)
    return reverb(out, 1.0, 0.2, seed=21)


def sfx_impact():
    """Three landings: gentle, solid, hard. Pitch falls and the body shortens."""
    out = np.zeros(int(3.2 * SR))
    for k, (cut, dur, level) in enumerate(((900.0, 0.30, 0.35), (1700.0, 0.22, 0.6),
                                           (3200.0, 0.16, 0.95))):
        n = noise(dur, seed=300 + k)
        body = sine(160.0 - 40.0 * k, dur) * np.exp(-np.linspace(0, 14, int(dur * SR)))
        s = lowpass(n, cut) * 0.6 + body * 0.7
        s *= adsr(dur, a=0.001, d=0.05, s=0.1, r=dur * 0.7)
        place(out, 0.2 + k * 0.9, s, level)
    return out


def sfx_zone_tick():
    """The gravity beat. Two ticks: down-phase, then up-phase, a fifth apart.

    The board already announces the flip with a bar and a ring. This is the same
    information for someone watching the ball instead of the zone.
    """
    out = np.zeros(int(2.6 * SR))
    for k, semi in enumerate((0, 7)):
        c = tri(hz(330.0, semi), 0.5) * adsr(0.5, a=0.001, d=0.16, s=0.06, r=0.3)
        place(out, 0.3 + k * 1.1, c, 0.6)
    return reverb(out, 1.2, 0.3, seed=22)


def sfx_spring():
    """The launch plate. A rising sweep, because it *throws* — and it is blue on
    the board, which already means push."""
    dur = 0.5
    t = t_axis(dur)
    f = 180.0 * np.exp(np.linspace(0.0, 1.7, len(t)))
    ph = 2.0 * np.pi * np.cumsum(f) / SR
    s = np.sin(ph) * 0.6 + np.sin(2 * ph) * 0.25
    s += lowpass(noise(dur, seed=400), 4000.0) * 0.18
    s *= adsr(dur, a=0.004, d=0.1, s=0.5, r=0.3)
    out = np.zeros(int(1.2 * SR))
    place(out, 0.1, s, 0.9)
    return reverb(out, 0.9, 0.22, seed=23)


def sfx_shatter():
    """The ball on spikes. Matches the picture: a crack, then pieces."""
    out = np.zeros(int(1.6 * SR))
    crack = highpass(noise(0.09, seed=500), 1200.0)
    crack *= adsr(0.09, a=0.0005, d=0.02, s=0.1, r=0.06)
    place(out, 0.05, crack, 1.0)
    rng = np.random.default_rng(501)
    for i in range(14):
        at = 0.05 + abs(rng.normal(0.06, 0.09))
        d = 0.14
        p = tri(float(rng.uniform(700.0, 2600.0)), d)
        p *= adsr(d, a=0.001, d=0.05, s=0.1, r=0.09)
        place(out, at, p, 0.14)
    return reverb(out, 1.3, 0.3, seed=24)


def sfx_gate():
    """A checkpoint. Mint green on the board; a rising two-note figure here —
    it has to read as *kept*, not as a reward, so it stays small."""
    out = np.zeros(int(1.8 * SR))
    for k, semi in enumerate((0, 7)):
        n = tri(hz(523.25, semi), 1.0) * adsr(1.0, a=0.004, d=0.3, s=0.2, r=0.6)
        place(out, 0.08 + k * 0.13, n, 0.5)
    return reverb(out, 1.6, 0.4, seed=25)


def sfx_slowmo():
    """Slowed time. Everything bends down and the room opens up — the one cue
    the board currently gives with a frame and nothing else."""
    dur = 1.2
    t = t_axis(dur)
    f = 440.0 * np.exp(-np.linspace(0.0, 1.1, len(t)))
    ph = 2.0 * np.pi * np.cumsum(f) / SR
    s = np.sin(ph) * 0.5 + np.sin(1.5 * ph) * 0.2
    s *= adsr(dur, a=0.01, d=0.4, s=0.4, r=0.6)
    out = np.zeros(int(2.2 * SR))
    place(out, 0.05, s, 0.8)
    return reverb(out, 2.2, 0.45, seed=26)


def sfx_win():
    """The goal. Amber on the board; the only sound allowed to resolve."""
    out = np.zeros(int(3.0 * SR))
    for k, semi in enumerate((0, 4, 7, 12)):
        v = tri(hz(392.0, semi), 2.2) * adsr(2.2, a=0.01, d=0.6, s=0.35, r=1.4)
        place(out, 0.05 + k * 0.09, v, 0.4)
    return reverb(out, 2.6, 0.45, seed=27)


SFX = {
    "magnet_hum": sfx_magnet_hum,
    "impact": sfx_impact,
    "zone_tick": sfx_zone_tick,
    "spring": sfx_spring,
    "shatter": sfx_shatter,
    "gate": sfx_gate,
    "slowmo": sfx_slowmo,
    "win": sfx_win,
}


def main():
    os.makedirs(OUT, exist_ok=True)
    args = [a.lower() for a in sys.argv[1:]]
    listen = any(a in ("-p", "--hoeren", "--play") for a in args)
    rest = [a for a in args if not a.startswith("-")]
    want = rest[0] if rest else ""

    rows = []
    for name, fn in WORLDS.items():
        if want and want not in ("welt", "welten") and want != name:
            continue
        mono = fn()
        l, r = stereo(mono)
        path = os.path.join(OUT, "welt_%s.wav" % name)
        rows.append((path, write_wav(path, l, r)))
    for name, fn in SFX.items():
        if want and want != "sfx" and want != name:
            continue
        mono = fn()
        l, r = stereo(mono, width=0.15)
        path = os.path.join(OUT, "sfx_%s.wav" % name)
        rows.append((path, write_wav(path, l, r)))

    if not rows:
        print("Nichts gefunden fuer %r. Bekannt: %s"
              % (want, ", ".join(list(WORLDS) + list(SFX) + ["welten", "sfx"])))
        return

    print("%-28s %11s %11s %7s %7s"
          % ("datei", "schwerpunkt", "tiefanteil", "crest", "sek"))
    for path, m in rows:
        print("%-28s %10.0fHz %10.0f%% %7.1f %7.2f"
              % (os.path.basename(path), m["centroid"], m["low"] * 100.0,
                 m["crest"], m["seconds"]))
    print("geschrieben nach", OUT)
    bad = [os.path.basename(p) for p, m in rows
           if abs(m["dc"]) > 0.01 or m["rms"] < 0.005]
    print("\nauffaellig:", bad if bad else "nichts")

    if not listen:
        return

    total = sum(m["seconds"] for _, m in rows)
    print("")
    print("Abspielen: %d Datei(en), %.0f Sekunden. Strg+C bricht ab."
          % (len(rows), total))
    for path, m in rows:
        print("  %-26s %5.1f s" % (os.path.basename(path), m["seconds"]),
              flush=True)
        try:
            if not play_file(path, m["seconds"]):
                print("  Kein Abspieler gefunden. Datei liegt hier:", path)
                return
        except KeyboardInterrupt:
            print("  abgebrochen")
            return


if __name__ == "__main__":
    main()
