# libdcadec — Herkunft

Dieses Ziel ist **libdcadec** (Alexander E. Patrakov u. a., GitHub
`foo86/dcadec`), unverändert bis auf zwei weggelassene Dateien:
`dca_stream.c` und `dca_waveout.c` lesen Dateien und schreiben WAV — die App
liest Rahmen aus der Matroska und braucht beides nicht.

Lizenz: **LGPL 2.1** (siehe `COPYING.LGPLv2.1`). Für eine kommerzielle
App heißt das: Hinweis in den Lizenzangaben, Quelltext der Bibliothek auf
Anfrage, und die Bibliothek muss austauschbar bleiben — deshalb kapselt
``DTSDecoder`` sie hinter einer schmalen Swift-Schnittstelle, die auch ein
anderer Decoder erfüllen könnte.

Genutzt wird nur der **Kern** (`DCADEC_FLAG_CORE_ONLY`): DTS Digital
Surround bis 5.1 mit 48 kHz. XLL (Master Audio), XBR/X96 und LBR (Express)
liegen zwar mit im Ziel, werden aber nicht angesteuert — der Kern ist in
jeder DTS-HD-Spur enthalten, verlustfrei bringt der AAC-Weg ohnehin nichts.
