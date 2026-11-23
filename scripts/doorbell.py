#!/usr/bin/env python3
"""Generates the intro's doorbell sound: a ding-dong, about one second (AP51).

Decision 5 of 25.09.2026: generated synthetically so that there is no license question.
Two tones a major third apart, descending (E5, then C5) — the sound of an ordinary
doorbell. Each tone carries two overtones and decays exponentially; a five-millisecond
attack prevents the click at the start, a fade-out over the last eighty milliseconds the
one at the end.

The computation involves no randomness: The same call yields the same bytes. Then
`afconvert` (present on every Mac) converts the WAV file to AAC in an m4a container.

Usage:   python3 scripts/doorbell.py            → App/Resources/Intro/doorbell.m4a
         python3 scripts/doorbell.py --wav-only   → only the WAV file, for listening
"""
import math
import os
import struct
import subprocess
import sys
import tempfile
import wave

SAMPLE_RATE = 44_100
DURATION = 1.05

# (start in seconds, fundamental frequency in Hz, volume)
TONES = [
    (0.00, 659.26, 0.55),  # E5 — "Ding"
    (0.32, 523.25, 0.60),  # C5 — "Dong"
]

# Overtones of a bell shell, relative to the fundamental: (factor, share, own decay)
OVERTONES = [
    (1.0, 1.00, 3.2),
    (2.0, 0.28, 5.5),
    (3.0, 0.10, 8.0),
]

ATTACK = 0.005
FADE_OUT = 0.08

TARGET = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "App", "Resources", "Intro", "doorbell.m4a")


def sample(t):
    value = 0.0
    for start, fundamental, volume in TONES:
        s = t - start
        if s < 0:
            continue
        envelope = min(1.0, s / ATTACK)
        for factor, share, decay in OVERTONES:
            value += volume * share * envelope * math.exp(-decay * s) * math.sin(
                2 * math.pi * fundamental * factor * s)
    remaining = DURATION - t
    if remaining < FADE_OUT:
        value *= max(0.0, remaining / FADE_OUT)
    return value


def write_wav(path):
    count = int(DURATION * SAMPLE_RATE)
    values = [sample(i / SAMPLE_RATE) for i in range(count)]
    peak = max(abs(v) for v in values) or 1.0
    scale = 0.8 / peak
    with wave.open(path, "wb") as file:
        file.setnchannels(1)
        file.setsampwidth(2)
        file.setframerate(SAMPLE_RATE)
        file.writeframes(b"".join(struct.pack("<h", int(v * scale * 32767)) for v in values))


def main():
    if "--wav-only" in sys.argv:
        path = os.path.abspath("klingel.wav")
        write_wav(path)
        print(path)
        return
    with tempfile.TemporaryDirectory() as folder:
        wav = os.path.join(folder, "klingel.wav")
        write_wav(wav)
        target = os.path.abspath(TARGET)
        subprocess.run(
            ["afconvert", "-f", "m4af", "-d", "aac", "-b", "96000", wav, target], check=True)
    print(f"{target}: {os.path.getsize(target)} B")


if __name__ == "__main__":
    main()
