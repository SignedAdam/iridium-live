"""Physical-model UI sounds for Iridium Live: three families (nib, wood, tape) x three cues (start, stop, done),
each cue in round-robin variants. Modes are damped resonances excited by a contact pulse (its length sets how hard
the striker is) plus noise grain; a tiny desk/room adds early reflections. No sine beeps, no musical arpeggios."""
import sys
import zlib
from pathlib import Path

import numpy as np
import scipy.signal as ss
import soundfile as sf

SR = 48000
OUT = Path(sys.argv[1] if len(sys.argv) > 1 else "/tmp/ir-sounds/out")
PREVIEW = Path(sys.argv[2]) if len(sys.argv) > 2 else None
VARIANTS = 4


def n(seconds):
    return int(round(seconds * SR))


def tt(seconds):
    return np.arange(n(seconds)) / SR


def place(out, y, at, gain=1.0):
    i = n(at)
    k = min(len(y), len(out) - i)
    out[i:i + k] += gain * y[:k]


def sos_filter(y, kind, f, order=2):
    return ss.sosfilt(ss.butter(order, f, kind, fs=SR, output="sos"), y)


def modes_ir(freqs, amps, taus, rng, dur=0.4, jitter=0.0):
    """Impulse response of a set of damped modes, each starting at zero phase like a struck body. A real solid's
    modes come in near-degenerate pairs, so each ringing mode is two a fraction of a percent apart: a slow beat
    instead of a dead-still synth tone."""
    t = tt(dur)
    y = np.zeros_like(t)
    for f, a, tau in zip(freqs, amps, taus):
        f = f * (1 + rng.normal(0, jitter))
        if f >= SR / 2.2:
            continue
        if tau > 0.004:
            split = rng.uniform(0.003, 0.011)
            share = rng.uniform(0.55, 0.7)
            y += a * share * np.exp(-t / tau) * np.sin(2 * np.pi * f * t)
            y += a * (1 - share) * np.exp(-t / (tau * rng.uniform(0.7, 1.1))) * np.sin(2 * np.pi * f * (1 + split) * t)
        else:
            y += a * np.exp(-t / tau) * np.sin(2 * np.pi * f * t)
    return y


def texture(lo, hi, count, amp, tau_lo, tau_hi, rng):
    """Many faint short modes: the grain a real solid has above its main modes."""
    freqs = np.exp(rng.uniform(np.log(lo), np.log(hi), count))
    taus = rng.uniform(tau_lo, tau_hi, count)
    amps = amp * rng.uniform(0.3, 1.0, count) * (lo / freqs) ** 0.5
    return freqs, amps, taus


def pulse(ms):
    """A half-sine contact force: long for felt or rubber (dull), short for hard on hard (bright)."""
    k = max(1, n(ms / 1000))
    p = np.sin(np.pi * (np.arange(k) + 0.5) / k)
    return p / p.sum()


def strike(ir, contact_ms, rng, grain=0.0, grain_ms=2.0):
    """The body's response to a contact: the pulse, plus a little noise at the contact (surface roughness). Nothing
    real touches for less than about 0.15 ms, and nothing real clicks up to the Nyquist frequency."""
    p = pulse(max(contact_ms, 0.15))
    force = np.zeros(n(0.004) + len(p))
    force[:len(p)] += p
    if grain:
        g = rng.standard_normal(n(grain_ms / 1000)) * np.hanning(n(grain_ms / 1000)) * grain / n(grain_ms / 1000)
        force[:len(g)] += sos_filter(g, "lowpass", 9000, 2)
    return ss.fftconvolve(force, ir)[:len(ir)]


def burst(dur, lo, hi, rng, shape):
    y = rng.standard_normal(n(dur))
    y = sos_filter(y, "bandpass", [lo, hi], 2) if lo else sos_filter(y, "lowpass", hi, 2)
    return y * shape(tt(dur))


def room(y, rng, wet=1.0):
    """A small room around a desk: a few early reflections and a short darkened tail."""
    ir = np.zeros(n(0.09))
    ir[0] = 1.0
    for ms, db in [(1.9, -19), (4.3, -21), (6.8, -24), (10.7, -27), (15.2, -30), (21.0, -33)]:
        ir[n(ms / 1000)] += wet * 10 ** (db / 20) * rng.choice([-1, 1]) * rng.uniform(0.85, 1.15)
    tail = rng.standard_normal(len(ir)) * np.exp(-tt(0.09) / 0.018) * wet * 10 ** (-36 / 20)
    tail[:n(0.003)] = 0
    ir += sos_filter(tail, "lowpass", 4500, 2)
    return ss.fftconvolve(y, ir)


def finish(y, peak_db=None):
    y = sos_filter(sos_filter(y, "highpass", 35, 2), "lowpass", 13000, 2)
    level = np.abs(y)
    above = np.nonzero(level > level.max() * 10 ** (-62 / 20))[0]
    y = y[:above[-1] + n(0.004)] if len(above) else y
    fade = min(n(0.012), len(y) // 4)
    y[-fade:] *= np.cos(np.linspace(0, np.pi / 2, fade)) ** 2
    y[:n(0.0005)] *= np.linspace(0, 1, n(0.0005))
    return y


def loudness_db(y):
    """Short-term loudness proxy: K-weighting-like shelf, loudest 50 ms window, in dB re full scale."""
    shelf = ss.sosfilt(ss.butter(1, 1500, "highpass", fs=SR, output="sos"), y) * 10 ** (4 / 20)
    w = y + shelf * 0.6
    w = sos_filter(w, "highpass", 60, 2)
    win = n(0.05)
    power = np.convolve(w ** 2, np.ones(win) / win, mode="same")
    return 10 * np.log10(power.max() + 1e-12)


TARGET = {"start": -31.0, "stop": -34.0, "done": -29.0}


def level(y, cue):
    y = y * 10 ** ((TARGET[cue] - loudness_db(y)) / 20)
    peak = np.abs(y).max()
    if peak > 10 ** (-3 / 20):
        y *= 10 ** (-3 / 20) / peak
    return y


# ---------------------------------------------------------------- wood: felt mallet on a block, a chess piece set down

FREE_BAR = [1.0, 2.756, 5.404, 8.933]


def wood_block(f1, contact_ms, tau1, rng, bright=1.0):
    freqs = [f1 * r for r in FREE_BAR] + [f1 * 0.61, f1 * 0.29]
    amps = [1.0, 0.34 * bright, 0.12 * bright, 0.04 * bright, 0.5, 0.3]
    taus = [tau1 / r ** 0.9 for r in FREE_BAR] + [tau1 * 0.5, 0.007]
    tf, ta, tu = texture(1800, 9000, 30, 0.07 * bright, 0.0012, 0.005, rng)
    ir = modes_ir(freqs + list(tf), amps + list(ta), taus + list(tu), rng, 0.3, jitter=0.004)
    return strike(ir, contact_ms, rng, grain=0.25 * bright)


def wood(cue, rng):
    j = lambda x, s=0.02: x * (1 + rng.normal(0, s))
    if cue == "start":
        y = wood_block(j(1046), j(0.42, 0.05), j(0.022), rng)
    elif cue == "stop":
        y = wood_block(j(784), j(0.62, 0.05), j(0.017), rng, bright=0.7)
    else:
        board = ([j(188), j(283), j(409), j(566), j(742), j(1003)], [0.55, 0.5, 0.42, 0.3, 0.2, 0.12],
                 [0.042, 0.034, 0.027, 0.02, 0.015, 0.011])
        piece = ([j(1480), j(2260), j(3350), j(4900)], [0.45, 0.32, 0.18, 0.09], [0.009, 0.006, 0.004, 0.003])
        tf, ta, tu = texture(1800, 8000, 20, 0.05, 0.0012, 0.004, rng)
        ir = modes_ir(board[0] + piece[0] + list(tf), board[1] + piece[1] + list(ta), board[2] + piece[2] + list(tu),
                      rng, 0.35, jitter=0.003)
        hit = lambda ms, g: strike(ir, ms, rng, grain=g)
        y = np.zeros(n(0.35))
        edge = j(0.0052, 0.12)
        place(y, hit(0.30, 0.25), 0.0, 0.32)
        place(y, hit(0.26, 0.3), edge, 1.0)
        place(y, hit(0.35, 0.1), edge + j(0.016, 0.15), 0.09)
    return room(y, rng)


# ---------------------------------------------------------------- nib: a fountain pen (iridium is what tips its nib)

def nib(cue, rng):
    j = lambda x, s=0.03: x * (1 + rng.normal(0, s))
    y = np.zeros(n(0.3))
    if cue == "start":
        slide = j(0.024, 0.08)
        rough = 1 + 0.7 * sos_filter(rng.standard_normal(n(slide)), "lowpass", 300, 2) * 8
        place(y, burst(slide, 1500, 7000, rng, lambda t: (t / slide) ** 2) * np.clip(rough, 0, None), 0.0, 0.05)
        cavity = modes_ir([j(1240), j(3850)], [1.0, 0.22], [0.0026, 0.0012], rng, 0.05)
        place(y, strike(cavity, 0.12, rng, grain=0.1), slide, 0.9)
        puff = burst(0.012, 0, 700, rng, lambda t: np.exp(-t / 0.003))
        place(y, puff, slide + 0.0004, 0.16)
        rim = modes_ir([j(3100), j(5050)], [1.0, 0.6], [0.0022, 0.0015], rng, 0.03)
        place(y, strike(rim, 0.06, rng), slide - 0.0015, 0.18)
    elif cue == "stop":
        scratch = j(0.026, 0.1)
        fibres = np.abs(sos_filter(rng.standard_normal(n(scratch)), "lowpass", 900, 2)) * 6
        place(y, burst(scratch, 2200, 8000, rng, lambda t: np.exp(-t / 0.009)) * fibres, 0.0, 0.07)
        tines = modes_ir([j(3480), j(5920), j(8150)], [1.0, 0.5, 0.25], [0.006, 0.004, 0.0025], rng, 0.04)
        place(y, strike(tines, 0.08, rng, grain=0.2), j(0.004, 0.2), 0.55)
    else:
        resin = ([j(2350), j(3720), j(5480), j(7910)], [1.0, 0.7, 0.45, 0.25], [0.009, 0.006, 0.004, 0.0025])
        barrel = ([j(980), j(162)], [0.5, 0.35], [0.014, 0.010])
        tf, ta, tu = texture(3000, 11000, 16, 0.08, 0.001, 0.003, rng)
        ir = modes_ir(resin[0] + barrel[0] + list(tf), resin[1] + barrel[1] + list(ta),
                      resin[2] + barrel[2] + list(tu), rng, 0.08, jitter=0.003)
        seat = j(0.026, 0.08)
        place(y, strike(ir, 0.2, rng, grain=0.2), 0.0, 0.16)
        place(y, strike(ir, 0.07, rng, grain=0.35), seat, 1.0)
        spring = modes_ir([j(4700), j(6600)], [1.0, 0.5], [0.003, 0.002], rng, 0.02)
        place(y, strike(spring, 0.05, rng), seat + j(0.008, 0.15), 0.2)
    return room(y, rng, wet=0.8)


# ---------------------------------------------------------------- tape: the transport of a studio tape deck

def whir(dur, f_from, f_to, rng):
    t = tt(dur)
    k = 0.03
    f = f_to + (f_from - f_to) * np.exp(-t / k) if f_to > f_from else f_from + (f_to - f_from) * (1 - np.exp(-t / k))
    phase = 2 * np.pi * np.cumsum(f) / SR
    tone = sum(np.sin(h * phase + rng.uniform(0, 6.28)) / h ** 1.6 for h in range(1, 8))
    brush = sos_filter(rng.standard_normal(len(t)), "bandpass", [1800, 4500], 2) * (0.6 + 0.4 * np.sin(phase * 2))
    return tone * 0.7 + brush * 0.06


def tape(cue, rng):
    j = lambda x, s=0.03: x * (1 + rng.normal(0, s))
    y = np.zeros(n(0.3))
    latch = ([j(1720), j(2940), j(4380), j(6100)], [1.0, 0.7, 0.5, 0.3], [0.010, 0.007, 0.005, 0.003])
    chassis = ([j(96), j(158)], [0.8, 0.45], [0.020, 0.014])
    if cue == "start":
        place(y, strike(modes_ir(*latch, rng, 0.1, jitter=0.004), 0.1, rng, grain=0.3), 0.0, 0.5)
        place(y, strike(modes_ir(*chassis, rng, 0.15), 1.6, rng), 0.0, 1.0)
        roller = j(0.032, 0.08)
        place(y, strike(modes_ir([j(240), j(410)], [1.0, 0.6], [0.010, 0.007], rng, 0.08), 0.9, rng, grain=0.1),
              roller, 0.45)
        spin = whir(0.11, 35, 118, rng) * np.sin(np.pi * tt(0.11) / 0.11) ** 2
        place(y, spin, roller + 0.004, 0.018)
    elif cue == "stop":
        up = ([f * 1.12 for f in latch[0]], [a * 0.8 for a in latch[1]], latch[2])
        place(y, strike(modes_ir(*up, rng, 0.1, jitter=0.004), 0.12, rng, grain=0.25), 0.0, 0.35)
        place(y, strike(modes_ir(*chassis, rng, 0.15), 2.2, rng), 0.0, 0.45)
        spin = whir(0.1, 118, 30, rng) * np.exp(-tt(0.1) / 0.035)
        place(y, spin, 0.002, 0.014)
        place(y, strike(modes_ir([j(300), j(520)], [1.0, 0.5], [0.008, 0.005], rng, 0.05), 1.0, rng), j(0.038), 0.18)
    else:
        key = ([j(980), j(1650), j(2700)], [0.6, 0.4, 0.25], [0.014, 0.009, 0.006])
        thump = ([j(84), j(141)], [1.0, 0.55], [0.028, 0.018])
        place(y, strike(modes_ir(*thump, rng, 0.2), 1.2, rng), 0.0, 1.0)
        place(y, strike(modes_ir(*key, rng, 0.1, jitter=0.004), 0.35, rng, grain=0.2), 0.0, 0.7)
        t = tt(0.4)
        twang = sum(a * np.exp(-t / tau) * np.sin(2 * np.pi * f * t + 0.004 * np.sin(2 * np.pi * 9 * t) * f / 9)
                    for f, a, tau in [(j(523), 1.0, 0.05), (j(1371), 0.4, 0.025)])
        place(y, twang, 0.002, 0.05)
        back = j(0.058, 0.06)
        place(y, strike(modes_ir([f * 1.3 for f in key[0]], key[1], key[2], rng, 0.08), 0.25, rng, grain=0.2),
              back, 0.28)
    return room(y, rng, wet=0.9)


FAMILIES = {"nib": nib, "wood": wood, "tape": tape}


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    for family, make in FAMILIES.items():
        preview = []
        for cue in ("start", "stop", "done"):
            for v in range(VARIANTS):
                rng = np.random.default_rng(zlib.crc32(f"{family}-{cue}-{v}".encode()))
                y = level(finish(make(cue, rng)), cue)
                sf.write(OUT / f"{family}-{cue}-{v + 1}.wav", y.astype(np.float32), SR, subtype="PCM_24")
                if v == 0:
                    preview += [y, np.zeros(n(0.7))]
        if PREVIEW:
            PREVIEW.mkdir(parents=True, exist_ok=True)
            sf.write(PREVIEW / f"{family}.wav", np.concatenate(preview).astype(np.float32), SR, subtype="PCM_24")
    print(f"wrote {len(list(OUT.glob('*.wav')))} files to {OUT}")


if __name__ == "__main__":
    main()
