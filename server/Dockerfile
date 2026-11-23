# Der Kern steckt im Bild, die Portale liegen daneben im Band.
# Ein neues Portal ist damit ein Ordner und ein Neustart — kein neuer Bau.
# ── The console (React + Vite), built in its own stage (rebuild 09.11.2026) ──
# Only the finished files go into the image; Node never reaches the runtime.
FROM node:22.11.0-alpine AS console
WORKDIR /src/console-app
COPY console-app/package.json console-app/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY console-app/ ./
RUN mkdir -p /src/cinelounge/web && npm run build

FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    TZ=Europe/Berlin \
    CL_DATA=/data

WORKDIR /app

# Der Unterbau des Dienstes. Was eine Erweiterung darueber hinaus braucht,
# bringt ihr eigenes Abbild mit.
#
# KEIN Kommentar innerhalb der Fortsetzung: Ein `#` hinter einem Backslash
# kommentiert den Rest des zusammengefuegten Befehls weg. Genau so ist beim
# ersten Anlauf ein Paket still nicht installiert worden, und der Bau meldete
# trotzdem Erfolg.
COPY pyproject.toml ./
RUN pip install --no-cache-dir \
        "fastapi==0.121.2" "uvicorn[standard]==0.42.0" "pyyaml==6.0.3" \
        "requests==2.32.5" "argon2-cffi==23.1.0" "pynacl==1.5.0"

COPY cinelounge/ ./cinelounge/
COPY --from=console /src/cinelounge/web/console/ ./cinelounge/web/console/
COPY scripts/ ./scripts/

# **Die mitgelieferten Portale gehoeren ins Abbild.** Der Dienst liest sie aus
# `/data/portals`; ohne sie startet ein frischer Container mit null Portalen
# und sieht kaputt aus. Wer den Quellbaum einhaengt, merkt das nicht — wer
# nur `docker compose up` tippt, hatte nichts.
#
# 641 KB, sechs Ordner, alles eigener Code: ARD, ZDF, arte, 3sat, SVT und die
# SDK-Vorlage. **Kein fremder Portal-Code** — der kommt ueber den Marktplatz,
# und genau deshalb liegt er nicht hier.
COPY portals/ ./portals/

# Kein root. Der Dienst liest Ordner und spricht HTTP; 1000:1000 ist der
# uebliche erste Benutzer eines Linux-Hosts, dem eingehaengte Datenordner
# meist gehoeren.
# **`/data` liegt im Abbild, und zwar mit den richtigen Rechten.**
#
# Ein leeres benanntes Volume erbt beim ersten Einhaengen Eigentuemer und
# Rechte des Verzeichnisses, das im Abbild darunter liegt. Ohne dieses `mkdir`
# gehoert es `root`, der Dienst laeuft als 1000:1000 — und der erste Start
# endet mit `sqlite3.OperationalError: unable to open database file`.
#
# Gemessen am 11.09.2026 beim ersten ehrlichen `docker compose up` in einem
# fremden Verzeichnis: Der Container startete, starb an dieser Zeile und war
# damit genau das, was ein Fremder als Ersten Eindruck bekommen haette.
RUN mkdir -p /data && chown 1000:1000 /data

USER 1000:1000

EXPOSE 8099

# Der Zustand ist eine Adresse, also soll Docker sie auch abfragen. Die Bruecke
# hat /health seit dem Anfang und keinen HEALTHCHECK — dieselbe Luecke nicht
# noch einmal.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8099/health',timeout=4).status==200 else 1)"

# `--proxy-headers`, und der Grund ist kein Schoenheitsfehler:
#
# Ein Reverse Proxy beendet TLS und reicht danach Klartext weiter. Ohne diese
# Schalter haelt sich der Dienst fuer `http://` — und `/play` gibt eine
# `http`-Adresse zurueck, obwohl die Seite unter `https://` steht. Gemessen im
# Browser:
#
#   Refused to connect ... violates the Content Security Policy directive
#   "connect-src 'self'"
#
# Der Abspieler bekaeme kein Bild, und niemand saehe warum: Der Server
# antwortet mit 200, der Browser wirft es weg. Wer den Dienst direkt ueber
# den offenen Port anspricht, merkt es nie, weil dort ohnehin Klartext laeuft.
#
# **Wem wir als Proxy glauben: nur dem, den der Betreiber nennt.**
#
# `request.client.host` ist die Herkunft, nach der `/join` und
# `/device/enroll` drosseln.
# Mit `--forwarded-allow-ips "*"` koennte jeder ein `X-Forwarded-For`
# mitschicken und sich je Versuch eine neue Herkunft ausdenken.
#
# Die Vorgabe glaubt deshalb nur der eigenen Maschine. Wer einen Reverse
# Proxy davorstellt, setzt `FORWARDED_ALLOW_IPS` in der Compose-Datei auf
# dessen Netz (uvicorn liest die Variable), statt das Abbild umzubauen.
# Glauben wir niemandem, wird nichts falsch, nur ungenauer: Hinter dem Proxy
# stuende dann dessen Adresse als Herkunft — die Drossel wird strenger, nie
# offener.
ENV FORWARDED_ALLOW_IPS="127.0.0.1"
CMD ["uvicorn", "cinelounge.web.main:app", "--host", "0.0.0.0", "--port", "8099",      "--proxy-headers"]
