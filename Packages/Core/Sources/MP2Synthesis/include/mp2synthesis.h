// Die Synthese-Filterbank des Layer-II-Decoders — der heiße Kern in C.
//
// Warum C mitten in einem Swift-Projekt (Gerätebefund 22.08., abends):
// Die Filterbank macht ~190 000 Multiplikationen je Rahmen, und Swift zahlt
// im Debug-Bau — dem Bau, mit dem device.sh aufs Gerät geht — für jeden
// Zugriff Prüf- und Verwaltungskosten. Gemessen: 23,7 ms je 24-ms-Rahmen auf
// dem RECHNER, auf dem Apple TV entsprechend schlimmer (Anlauf 14 s, Ton
// 6,7 s hinter dem Bild). C kennt diese Kosten nicht; dieselbe Schleife
// bleibt auch ohne Optimierer weit unter dem Budget. Alles andere — Kopf,
// Bitleser, Zuteilung, Skalenfaktoren — bleibt Swift: dort ist die Arbeit
// leicht und die Lesbarkeit wertvoller.
//
// Die Arithmetik ist die der Referenz (kjmp2, Martin J. Fiedler, zlib-artige
// Lizenz) in Festkomma — bitgleich mit der Swift-Fassung, die sie ablöst.

#ifndef MP2_SYNTHESIS_H
#define MP2_SYNTHESIS_H

#include <stdint.h>

/// Synthetisiert eine Gruppe: 3 × 32 Teilbandwerte je Kanal werden
/// 96 Stereo-PCM-Werte.
///
/// - v:        Verzögerungsregister, 2 × 1024 (Kanal 1 ab Index 1024).
/// - voffset:  Laufender Versatz im Register; wird fortgeschrieben.
/// - samples:  Zurückgerechnete Werte, Anordnung [ch*96 + sb*3 + nr].
/// - n:        Matrizierung, 64 × 32, wie von der Norm vorgegeben.
/// - window:   Synthese-Fenster, 512 Werte.
/// - pcm:      Ausgabe, 192 Werte (96 Stereo-Paare), verschränkt.
void mp2_synthesize_granule(
    int32_t *v, int32_t *voffset, const int32_t *samples,
    const int32_t *n, const int32_t *window, int16_t *pcm);

#endif
