# PortaPack Manager – Hilfe

Der PortaPack Manager macht aus einem **HackRF One mit PortaPack** ein
Empfangslabor am Mac: Flugzeuge und Schiffe auf der Karte, Radio und
Fernsehen, Wetterballons und Satellitenbilder, Funksensoren im Haus – und
nebenbei hält er die Mayhem-Firmware des Geräts aktuell. Die App dekodiert
alles selbst, ohne Zusatzprogramme.

Diese Hilfe steht genauso in der App: Menü **Hilfe ▸ PortaPack Manager Hilfe**
(⌘?) oder der **?**-Knopf oben rechts auf jeder Seite.

<a id="start"></a>
## Erste Schritte

1. **PortaPack per USB anschließen und einschalten.** Die App erkennt es von
   selbst – unten links in der Seitenleiste steht dann „Mayhem-Modus“.
2. **Ersteinrichtung** durchgehen (kommt beim ersten Start, sonst über
   Übersicht ▸ Gerät steuern ▸ „Ersteinrichtung …“): Antenne wählen, Standort
   übernehmen, Quarz abgleichen. Dauert etwa eine Minute.
3. **Auf der Startseite eine Kachel anklicken**, zum Beispiel „Flugzeuge“. Die
   App wechselt selbst in den HackRF-Modus und startet den Empfang.

Verstärkung, Frequenzen und Kanäle stellt die App selbst ein – von Hand geht es
trotzdem überall.

### Die zwei Modi des Geräts

| Modus | Wofür | Wie hinein |
|---|---|---|
| **Mayhem-Modus** | Das PortaPack läuft eigenständig mit seinem Display. Die App aktualisiert Firmware, bearbeitet die SD-Karte und spiegelt den Bildschirm. | Gerät normal einschalten oder „Zurück zu Mayhem (Neustart)“ |
| **HackRF-Modus** | Der Mac empfängt selbst – für alle Empfängerseiten. | Automatisch beim Öffnen einer Empfängerseite |

Der Wechsel dauert ein paar Sekunden. Willst du nicht automatisch umschalten:
**Einstellungen ▸ Antenne & Gerät ▸ „Automatisch in den HackRF-Modus
wechseln“** ausschalten.

<a id="overview"></a>
## Startseite (Übersicht)

Hier startest du mit einem Klick und siehst, wie es dem Gerät geht.

- **Was möchtest du sehen?** – Kacheln für die beliebtesten Empfänger. Ein Klick
  öffnet die Seite, wechselt in den HackRF-Modus und startet. Grüne Hinweise
  zeigen, was gerade los ist („8 gerade“, „2 in Reichweite“, „ab 19:37“).
  Kacheln tragen Namen und Symbol der Seite in der Seitenleiste.
- **Verbindung** – in welchem Modus das Gerät ist; **Technische Details**
  (eingeklappt) nennen Firmware, Seriennummer und Funkmodul.
- **Standort** – der eingetragene Standort; ändern über „Einstellungen …“.
- **Gerät steuern** – „Status aktualisieren“ (⌘R), „Uhr stellen“, „Zurück zu
  Mayhem (Neustart)“, „SD-Karte als Laufwerk“ und „Ersteinrichtung …“.
- **Fehlerbehebung** (eingeklappt) – „USB neu anmelden“ (hilft, wenn die
  Verbindung hängt) und „DFU-Modus …“ (nur für Notfälle, wenn das Gerät gar nicht
  mehr startet; Aus- und Einschalten führt zurück).

Läuft gerade ein Empfänger, ein Termin des Empfangsplans oder der Fernzugriff,
fragen Neustart, Moduswechsel, SD-Laufwerk und „USB neu anmelden“ vorher nach
(„Läuft gerade: … – trotzdem?“). Der DFU-Modus fragt immer.

Läuft gerade eine geplante Aufnahme, fragt die Kachel nach, bevor sie das Gerät
übernimmt.

<a id="empfang"></a>
## Empfangen – so funktioniert jede Empfängerseite

Alle Empfängerseiten sind gleich aufgebaut: links Karte, Liste oder Bild, rechts
das **Bedienfeld** (ein- und ausklappen mit „Bedienfeld“ oben rechts). Im
Bedienfeld stehen die Abschnitte immer in derselben Reihenfolge:

1. **Start/Stopp** (bei Radio und DAB+: „Abspielen“), daneben **Leeren** und
   ggf. **Archiv …**.
2. **Kanal** – Frequenz, Band oder Kanal, falls die Seite eine Wahl hat.
3. **Empfang** – Statuszeile, „Signal optimieren“, Verstärkung (siehe unten).
4. **Status** – Zähler und Messwerte.
5. Seitenspezifisches, dann **Anzeige** (Sortierung, Spuren, Filter).
6. **Daten & Export** – Datenbanken, „Im Finder zeigen“, CSV/PCAP sichern.
   Fast jede Seite mit einer Live-Liste (Flugzeuge, Schiffe, ACARS/VDL2, APRS,
   DSC, Funksensoren, Funkruf, Meshtastic, LoRaWAN, Bluetooth, WLAN, Smart Home,
   Zigbee, FT8/WSPR, FLARM) hat dort **Liste als CSV sichern …**: eine Tabelle
   mit Semikolon als Trennzeichen, UTF-8, die Excel, Numbers und LibreOffice
   direkt öffnen. Zeiten stehen in UTC, Zahlen mit Dezimalpunkt. Schlüssel
   (Zigbee, LoRaWAN, Zähler) landen nie in der Datei.
7. **Hinweis** – kurze Tipps zu Antenne und Empfang; auf Seiten, die fremde
   Kommunikation empfangen, auch der Rechtshinweis (siehe „Rechtliches und
   Datenschutz“).

Hast du das Bedienfeld eingeklappt und es tritt ein Fehler auf, erscheint er als
schmales Band über dem Inhalt – mit „Bedienfeld zeigen“ klappst du es wieder auf.

### Tastatur und Eingaben

- **Leertaste** startet und stoppt den Empfang auf jeder Empfängerseite (bei Radio
  und DAB+: Abspielen/Stopp). Im Radio verstellen **← →** die Frequenz um einen
  Schritt, **↑ ↓** um zehn.
- Steht der Cursor in einem Textfeld, gehören Leertaste und Pfeiltasten dem
  Textfeld – du kannst also gefahrlos tippen.
- **Frequenzen** gibst du überall in MHz ein, mit Komma oder Punkt („433,92“ oder
  „433.92“); „kHz“ oder „GHz“ dahinter geht auch. Ungültiges oder außerhalb des
  erlaubten Bereichs wird rot markiert, mit dem Grund darunter.
- **Entf** löscht den gewählten Eintrag in Listen mit Löschen (Aufnahmen,
  Flugfunk-Verlauf, Sondenarchiv, Frequenzspeicher, SD-Karte) – nach Rückfrage.

Löschen fragt überall nach und nennt, was verloren geht: gespeicherte Schlüssel,
Aufnahmen, Bilder, Messungen. „Leeren“ leert nur die Liste auf dem Bildschirm;
die gespeicherte Senderliste von DAB+ und Fernsehen löschst du über
„Senderliste löschen …“.

Allgemeine Einstellungen (Standort, Benachrichtigungen, Online-Dienste …) stehen
nur auf der Seite **Einstellungen**. Eine Seite zeigt dafür höchstens eine Zeile
mit dem Knopf **„Einstellungen …“**, der direkt hinführt.

### Der Abschnitt „Empfang“

- **Statuszeile in Alltagssprache**, z. B. „Empfang läuft – etwa 12 Meldungen
  pro Minute“ oder „Seit 5 min nichts empfangen“ – dann mit einem Tipp, woran es
  liegen kann.
- **Signal optimieren** probiert die Verstärkung durch und übernimmt die beste
  (wenige Sekunden bis eine halbe Minute). Darunter steht das Ergebnis.
- **Verstärkung automatisch nachregeln** (Vorgabe an): Übersteuert der
  Empfänger, nimmt die App die Verstärkung zurück; ist das Signal viel zu leise,
  dreht sie hoch. Der Schalter gilt für alle Seiten.
- **Von Hand einstellen** (eingeklappt) – die Regler:

| Regler | Was er macht | Faustregel |
|---|---|---|
| **LNA** (0–40 dB) | Eingangsverstärkung | Bestimmt am meisten, wie schwache Sender ankommen – zuerst diesen |
| **VGA** (0–62 dB) | Nachverstärkung | Danach |
| **Eingebauter Verstärker (+14 dB)** | Zusätzliche Stufe direkt an der Antenne | Nur bei sehr schwachen Signalen; neben starken Sendern übersteuert er |
| **Antennenspeisung (Bias-Tee)** | 3,3 V an der Antennenbuchse | **Nur** für aktive Antennen oder Vorverstärker, die darüber versorgt werden – sonst kann etwas kaputtgehen |

### Pegel

Unten links in der Seitenleiste zeigt ein **Pegelbalken**, wie stark der
Empfänger ausgesteuert ist und für welche Seite der HackRF gerade empfängt.
Grün passt. Orange („sehr laut“) ist nur ein Hinweis – kommen Meldungen an, ist
alles gut. Rot heißt **übersteuert**: Es entstehen Störungen, und es kommt
weniger an statt mehr. Dann erst den eingebauten Verstärker aus, dann LNA, dann
VGA zurücknehmen – oder „Signal optimieren“.

### Externer LNA

Hängt ein Breitband-Vorverstärker vor dem HackRF, schalte **Einstellungen ▸
Antenne & Gerät ▸ „Externer LNA“** ein. Alle Seiten starten dann mit weniger
Verstärkung und ohne den eingebauten Verstärker; unten in der Seitenleiste
steht „Externer LNA an“.

### Ein Gerät, ein Empfänger

Der HackRF kann immer nur für eine Seite empfangen.

- **Seitenwechsel beendet den Empfang nicht.** Du kannst dich auf anderen Seiten
  umsehen, der Empfänger läuft weiter und sammelt Daten. Ein **grüner Punkt** in
  der Seitenleiste zeigt, welcher gerade empfängt; unten steht „Pegel für …“.
- Startest du auf einer anderen Seite einen Empfang, fragt die App kurz nach:
  „Gerade läuft … Beenden und … starten?“ – **Umschalten** beendet den bisherigen
  Empfänger, **Abbrechen** lässt alles, wie es ist.
- Nimmt der Empfangsplan gerade auf, überspringt „Umschalten“ diesen Termin –
  und es bleibt bei deiner Wahl, der Empfänger von vor dem Termin kommt nicht
  zurück. Nutzt das Handy den HackRF (Fernzugriff), endet der Fernbetrieb.
- Der Fernzugriff und Termine des Empfangsplans fragen nicht – sie übernehmen
  das Gerät selbst. Die Statuszeile sagt dann „Der HackRF empfängt gerade für …“
  – mit **Start** holst du es zurück.
- Nach einem Termin des Empfangsplans startet der Empfänger, der vorher lief,
  von selbst wieder – auch Fernsehen, Bluetooth, GPS oder die Wasserstofflinie.
  Hast du inzwischen etwas anderes gestartet, bleibt es dabei.

<a id="antennaCheck"></a>
## Antennen-Check

Sagt dir in etwa zwei Minuten, wofür deine Antenne taugt: „Gut für UKW,
Flugzeuge, Digitalradio – knapp für Schiffe“, dazu konkrete Tipps (etwa „für
Satelliten einen V-Dipol bauen“).

- **Start** misst nacheinander alle wichtigen Bänder, **Stopp** bricht ab.
- **Antennenspeisung (Bias-Tee)** nur für aktive Antennen einschalten.
- Ein vorher laufender Empfänger startet danach von selbst wieder; während einer
  geplanten Aufnahme wartet der Check.
- **„Keine Aussage“** heißt nur, dass auf dem Band gerade niemand gesendet hat
  (Schiffe, Wetterballons, Satelliten sind nicht ständig zu hören) – kein
  schlechtes Zeichen.

<a id="spectrum"></a>
## Spektrum – „Was funkt hier?“

Zeigt alles, was im gewählten Bereich (2–20 MHz breit) sendet, als Kurve und
Wasserfall.

- Frequenz und **Bandbreite** oben im Bedienfeld wählen, **Start**.
- Ein Klick ins Spektrum oder in den Wasserfall stimmt dorthin ab; **Vorlagen**
  springen zu bekannten Bändern (UKW, Flugfunk, ADS-B, WLAN …).
- **Rechtsklick** auf ein Signal: **Im Radio hören** öffnet das Radio auf genau
  dieser Frequenz – mit passender Betriebsart (Flugfunk AM, UKW-Rundfunk WFM,
  2 m/70 cm und sonst NFM). Läuft dabei noch das Spektrum, fragt die App vor dem
  Umschalten nach. **Merken** legt die Frequenz im Frequenzspeicher ab.
- **Marker:** ⌥-Klick setzt einen Marker (bis zu vier); er rastet auf die Spitze
  daneben ein. Im Bedienfeld unter „Marker & Max-Hold“ stehen Frequenz und Pegel,
  ab dem zweiten Marker der Abstand zu Marker 1 (kHz und dB). **Marker auf
  Spitze** setzt Marker 1 auf das stärkste Signal.
- **Max-Hold** hält als gelbe Linie den höchsten Pegel je Frequenz fest – so
  siehst du auch kurze Aussendungen. **Zurücksetzen** beginnt neu, ein Wechsel
  der Frequenz oder Bandbreite ebenso.
- „Skala automatisch“ folgt dem Rauschen.

Glatte Frequenzen wie 100,000 MHz zeigen oft eine Störlinie des HackRF selbst –
das ist normal.

<a id="radio"></a>
## Radio

UKW mit **Sendernamen, Radiotext (RDS)** und Stereo, dazu AM, Schmalband-FM
(z. B. Flugfunk 118–137 MHz in AM) und für den Amateurfunk **SSB (USB/LSB)** und
**Morsen (CW)**.

- **Abspielen/Stopp** oben im Bedienfeld (Leertaste).
- Frequenz links in der großen Anzeige verstellen: Ziffern mit Mausrad oder
  Klick, ← → ein Schritt, ↑ ↓ zehn Schritte. Betriebsart und Schritt wählst du
  im Bedienfeld.
- **Schnellwahl mit Suchlauf** findet alle Sender eines Bandes (UKW, Flugfunk,
  PMR446 …) und liest ihre Namen. Sie erscheinen links in der Senderliste –
  sortiert nach Stärke, Name oder Frequenz, gemerkte Frequenzen obenauf.
- Der **Stern** merkt die aktuelle Frequenz samt Betriebsart und Schritt im
  **Frequenzspeicher** (links oben in der Liste, umschaltbar zwischen „Radio“ und
  „Alle“). Rechtsklick auf einen Eintrag: bearbeiten oder löschen.
- **Rauschsperre** (AM/NFM) schaltet zwischen Funksprüchen stumm.
- **Filter** wählt die Breite des Empfangsfilters: AM 6/9/10 kHz, SSB
  1,8–3 kHz, CW 250/500/1000 Hz; bei NFM das Kanalraster (6,25/12,5/25 kHz).
  Schmaler dämpft Nachbarn und Rauschen, breiter klingt voller. UKW ist fest.
- **SSB und CW:** USB für Amateurfunk über 10 MHz, LSB darunter. Die Lautstärke
  regelt sich selbst (AGC). Abstimmen in 10-Hz- bis 1-kHz-Schritten; fein
  stimmst du mit dem Mausrad über den kleinsten Ziffern ab. Bei CW hörst du einen
  genau abgestimmten Sender in der eingestellten **Tonhöhe** (Vorgabe 700 Hz).
- **Amateurfunk-Vorlagen** stimmen auf die üblichen Frequenzen ab, z. B. 2 m SSB
  144,300 MHz, 70 cm 432,200 MHz oder 10 m 28,500 MHz.
- **Kurzwelle** (unter 30 MHz): Der HackRF empfängt erst ab 1 MHz und dort nur
  schwach. Mit einem Upconverter oder einer langen Drahtantenne geht es deutlich
  besser.
- **Ton aufnehmen** (Daten & Export) schreibt, was du hörst, als Datei – AAC
  (m4a, klein) oder WAV (verlustfrei); UKW in Stereo, sonst mono. Die Aufnahme
  endet mit „Aufnahme beenden“ oder dem Stopp. Darunter stehen die letzten
  Aufnahmen zum Abspielen, Zeigen im Finder und Löschen.

Tipp: Läuft gerade ein starker UKW-Sender, kannst du daran die Quarzkorrektur
messen (Einstellungen ▸ Antenne & Gerät, siehe Kapitel „Einstellungen“).

<a id="dab"></a>
## Digitalradio (DAB+)

Digitalradio in bester Qualität, mit Radiotext (Titel, Interpret).

- Beim ersten Öffnen sucht die App **selbst alle Sender** (1–2 Minuten). Danach
  genügt ein Klick auf einen Sender in der Liste.
- **Suchlauf** sucht später neue Sender, **Leeren** vergisst alle gefundenen.
- Über der Liste wählst du **Nach Ensemble** oder **Nach Name**.
- Die Statuszeile sagt, wie gut der Empfang ist; Einzelwerte stehen unter
  „Status“.
- **Ton aufnehmen** (Daten & Export) nimmt den laufenden Sender in Stereo auf;
  der Dateiname nennt Sender und Zeit.

Antenne: DAB+ liegt in Band III (174–240 MHz). Eine Stabantenne von etwa 40 cm
bringt deutlich mehr als die Teleskopantenne.

<a id="tv"></a>
## Fernsehen (DVB-T2)

Frei empfangbares Antennenfernsehen (DVB-T2 HD) mit Bild und Ton.

- Beim ersten Öffnen sucht die App alle Kanäle (etwa 1–2 Minuten). Später
  startest du den Suchlauf mit **Kanäle neu durchsuchen**; **Leeren** vergisst
  alle gefundenen Sender.
- DVB-T2 braucht ein **kräftiges Signal**. Die Statuszeile sagt, wie viele
  Datenblöcke fehlerfrei ankommen. Unter etwa 80 % stockt das Bild – dann hilft
  nur eine bessere Antenne (Dach, Fenster Richtung Sender), mehr Verstärkung
  meist nicht.
- Private Sender (freenet TV) sind verschlüsselt und bleiben dunkel.

<a id="adsb"></a>
## Flugzeuge (ADS-B)

Flugzeuge in Funkreichweite auf der Karte – mit Kennzeichen, Typ,
Fluggesellschaft, Strecke und Foto.

- **Start**, dann ein Klick auf ein Flugzeug öffnet die Infokarte.
- **Flugzeugdatenbank** (unter „Daten & Export“ mit **Aktualisieren** laden,
  ≈ 95 MB): Kennzeichen und Typ auch ohne Internet. Unbekannte Flugzeuge,
  Strecken und Fotos fragt die App auf Wunsch online nach – einschalten unter
  **Einstellungen ▸ Online-Dienste**.
- Unter **Anzeige**: metrische Einheiten, Flugspuren und **Flugplätze zeigen**.
- **Flugplätze** auf der Karte: große Flughäfen als gefüllte Kreise, kleine
  Flugplätze als Ringe, Hubschrauberlandeplätze („H“) erst nah herangezoomt.
  Ein Klick zeigt Name, Ort und Höhe. Die Liste (OurAirports, 12 MB) lädst du
  einmal unter „Daten & Export“ mit **Flugplätze laden** – dein Standort geht
  dabei nicht hinaus. Im Fernzugriff schaltet der Kreis-Knopf links auf der
  Karte sie ein und aus.
- **Archiv …** – alle Sichtungen je Tag oder über alle Tage, mit Spur und Foto,
  als CSV exportierbar. Ein Klick auf einen Spaltenkopf sortiert.
- Für Entfernung und Richtung braucht die App deinen Standort (Einstellungen ▸
  Standort).

Reichweite: drinnen oft nur wenige Kilometer, mit Antenne draußen 100 km und
mehr.

<a id="acars"></a>
## Flugzeug-Datenfunk (ACARS & VDL2)

Textnachrichten zwischen Cockpit und Boden – Positionsmeldungen, Wetter,
Abflugzeiten, Lotsenfreigaben (CPDLC).

- Unter **Kanal** das Verfahren wählen: **VDL2** (in Europa üblich, Vorgabe)
  oder ACARS mit seinen Kanälen. Dann **Start**.
- Die Spalte **Deutung** übersetzt die Kürzel in Klartext. Ein Klick öffnet den
  Steckbrief samt „Auf der ADS-B-Karte zeigen“.
- Unter **Anzeige ▸ Sortierung** stellt **Wichtige zuerst** Lotsenmeldungen und
  Positionen nach oben, **Nach Flugzeug** fasst die Meldungen einer Maschine
  zusammen. Filter blenden leere Quittungen und ATN-Verkehr aus.

<a id="ais"></a>
## Schiffe (AIS)

Schiffe mit Name, Typ, Ziel, Ankunftszeit und Foto auf der Karte.

- **Start** – zu hören nur mit **Sicht zu Küste, Fluss oder Hafen**; im
  Binnenland meist nichts.
- Spuren schaltest du unter „Anzeige“, Fotos aus dem Netz (Wikimedia Commons)
  unter **Einstellungen ▸ Online-Dienste**.
- **Archiv …** wie bei den Flugzeugen.

<a id="aprs"></a>
## Funkamateure (APRS)

Positions- und Wettermeldungen von Funkamateuren auf 144,800 MHz, auf der Karte.
Je nach Gegend kommen nur ein paar Pakete pro Stunde. Mit **Kanal mithören**
hörst du die Pakete als Pfeifen; Spuren schaltest du unter „Anzeige“.

<a id="pager"></a>
## Funkruf (POCSAG)

Pager-Nachrichten des Amateurfunknetzes **DAPNET** (439,9875 MHz).

> **Wichtig:** Alarmierungen von Feuerwehr, Rettungsdienst und Polizei abzuhören
> oder weiterzugeben ist verboten (§ 5 TDDDG). Die App bietet deshalb bewusst
> nur DAPNET an und speichert nichts.

<a id="planner"></a>
## Empfangsplan

Empfängt **Wettersatelliten, Amateurfunk-Satelliten und Wetterballons
automatisch** – auch nachts und auch, wenn gerade ein anderer Empfänger oder der
Fernzugriff läuft (der läuft danach von selbst weiter). Du findest den Plan in
der Seitenleiste unter „Werkzeuge“; die Seiten METEOR, Amateurfunk-Satelliten
und Wetterballons führen mit „Empfangsplan …“ hierher.

### So geht's

1. **Standort** eintragen – ohne ihn gibt es keine Vorhersage („Einstellungen …“
   führt hin).
2. Je Bereich den Schalter **„Überflüge automatisch empfangen“** bzw.
   **„Aufstiege automatisch empfangen“** einschalten; bei den
   Amateurfunk-Satelliten wählst du dazu, welche.
3. Mac wach und App offen lassen – solange ein Plan an ist, verhindert die App
   den Ruhezustand.

### Gut zu wissen

- **Satelliten:** Die Liste zeigt die Überflüge der nächsten 48 Stunden mit
  Höhe; aufgenommen wird ab der eingestellten Mindesthöhe, von einer Minute vor
  dem Aufgang bis nach dem Untergang.
- **Wetterballons** steigen zu festen Zeiten (meist 0 und 12 Uhr UTC, manche
  Stationen auch 6 und 18 Uhr). Der Plan schaltet nur um, wenn SondeHub
  tatsächlich einen Ballon in Reichweite meldet, und zeigt vorher, wohin er
  voraussichtlich treibt.
- **Ein Sondenfenster folgt dem Empfang:** Ist am geplanten Ende noch ein
  Ballon zu hören, läuft es weiter, bis 5 Minuten lang nichts mehr kommt. Ist
  ein Ballon gelandet oder außer Reichweite (10 Minuten still) oder kommt
  30 Minuten lang gar keiner, endet es vorzeitig – und was vorher lief, startet
  wieder.
- **Vorrang**, wenn sich Termine überschneiden: METEOR, dann
  Amateurfunk-Satelliten, dann Radiosonden.
- **Überspringen** beendet eine laufende Aufnahme – im roten Band unten, auf
  dieser Seite oder im Fernzugriff. Der Termin startet dann nicht wieder, und
  der vorherige Empfang läuft weiter.
- **Nach jedem Termin** startet wieder, was vorher lief – egal, ob Flugzeuge
  vom Handy oder Fernsehen am Mac. Tippst du in der Zwischenzeit am Handy auf
  Stopp oder startest selbst etwas, kommt nichts von selbst zurück.
- Ergebnisse stehen im **Verlauf**. Auf Wunsch meldet sich die App
  (Einstellungen ▸ Benachrichtigungen).

<a id="sonde"></a>
## Wetterballons (Radiosonden)

Wetterballons senden zwischen 400 und 406 MHz Position, Höhe (bis über 30 km),
Temperatur und Feuchte. Die App sucht das Band selbst ab und hört bis zu vier
Sonden gleichzeitig.

- **Start** zur Aufstiegszeit – oder bequemer: der **Empfangsplan** fängt die
  Ballons automatisch ab.
- **Verlauf** unter Karte und Liste: Höhe, Steigen, Temperatur und Feuchte der
  gewählten Sonde über die Zeit, dazu das **Profil** (Temperatur und Feuchte
  über der Höhe, nur im Aufstieg).
- **Landeschätzung** zeigt im Sinkflug grob, wo der Ballon herunterkommt. Für
  die Bergung sind die Vorhersagen auf SondeHub genauer.
- **Archiv …**: alle bisher empfangenen Flüge mit Gipfelhöhe, Dauer und
  Strecke. Ein Klick zeigt Bahn und Verlauf; „CSV sichern …“ speichert einen
  Flug, „Auf SondeHub“ öffnet ihn dort. **Löschen** (Knopf, Rechtsklick oder
  Entf) entfernt einen Flug nach Rückfrage; ein Flug, der gerade noch empfangen
  wird, lässt sich erst danach löschen. Ins Archiv kommt jede Meldung, die der
  Empfangsplan aufnimmt.
- Kennst du die Frequenz einer Sonde, die die Suche nicht findet, kannst du sie
  unter „Kanäle“ **festhalten**.
- Belegt ein Dauerstörer an deinem Standort immer wieder einen Suchplatz, trag
  ihn in den Einstellungen unter „Antenne & Gerät ▸ Wetterballons:
  Dauerstörer“ ein (eine Frequenz oder ein Bereich in MHz). Ab Werk ist die
  Liste leer; „Ab Werk“ leert sie wieder.

Reichweite: hoch fliegende Ballons sind oft noch in 200 km zu hören, tief
fliegende bis etwa 100 km. Antenne möglichst hoch und draußen, kurzes Kabel.

<a id="meteor"></a>
## Wettersatellit (METEOR)

Wetterbilder direkt vom russischen Satelliten METEOR-M (137,9 MHz), wenn er über
dich hinwegfliegt.

- **Überflüge** zeigt die nächsten Zeiten. Automatisch aufnehmen stellst du im
  **Empfangsplan** ein (Knopf „Empfangsplan …“).
- Fertige Bilder speichert die App als PNG; **Im Finder zeigen** unter „Daten &
  Export“ öffnet den Ordner.

Nötig ist eine **Satellitenantenne** mit freier Sicht zum Himmel: ein V-Dipol
(zwei Stäbe à 53 cm im Winkel von 120°, waagerecht) oder eine QFH.
Teleskop- und Scanner-Antennen hören den Satelliten kaum. Unter etwa 20° Höhe
kommt mit einer einfachen Antenne selten ein Bild.

<a id="flarm"></a>
## FLARM/OGN (Segelflug)

Kollisionswarner von Segelflugzeugen auf 868,2 MHz. Die App erkennt die Rahmen,
kann die (verschleierte) Position aber nicht lesen. Nur nahe Flugplätzen und bei
Flugwetter, meist am Wochenende.

<a id="sensors"></a>
## Funksensoren

Wetterstationen, Funkthermometer, Reifendrucksensoren und andere Geräte auf 433
und 868 MHz. Die meisten senden alle 30–60 Sekunden.

- Oben im Bedienfeld das **Band** wählen (433,92 oder 868,30 MHz), **Start**.
- Unter **Anzeige** suchst du nach Modell, ID oder Wert, sortierst und blendest
  **Reifendruck (TPMS)** aus – die Sensoren vorbeifahrender Autos (anfangs
  ausgeblendet).

<a id="ble"></a>
## Bluetooth-Geräte

Alle Bluetooth-LE-Geräte in der Nähe mit Hersteller und Art (Tracker, Uhren,
Sensoren, Kopfhörer …). Oben wählst du den **Werbekanal** (37, 38, 39 oder im
Wechsel). Viele Geräte wechseln etwa alle 15 Minuten ihre Adresse und tauchen
dann neu auf.

<a id="zigbee"></a>
## Zigbee (Smart Home)

Der Funkverkehr deines Zigbee-Netzes (z. B. Zigbee2MQTT, Hue, IKEA): Geräte,
Netzkarte und Messwerte.

### So geht's

1. **Kanalsuche** findet den Kanal deines Netzes (oder Kanal von Hand wählen),
   dann **Start**.
2. Für lesbare Inhalte den **Netzwerkschlüssel** eintragen – am einfachsten mit
   „Konfiguration importieren …“ aus Zigbee2MQTT. Dann siehst du Schalter,
   Temperaturen, Bewegungsmelder. Schlüssel liegen nur im Schlüsselbund des Mac.

### Netzkarte

Der Koordinator steht in der Mitte, gut verbundene Geräte liegen nah
beieinander, Geräte ohne bekannte Verbindung auf dem Außenring. Gezeigt werden
die zwei besten Verbindungen je Gerät, „Alle Verbindungen“ zeigt alle.

- **3D:** Ziehen dreht, Mausrad zoomt, Klick wählt ein Gerät und zeigt seine
  Verbindungen.
- **2D:** Mausrad zoomt, Ziehen verschiebt, Doppelklick setzt zurück.
- Hört die App mehrere Netze, wählst du oben unter „Netz“.

### Tipps

- **Thread/Matter** wird erkannt. Den Thread-Schlüssel findest du in Home
  Assistant in `/config/.storage/thread.datasets`. Thread funkt oft auf einem
  anderen Kanal als Zigbee.
- **PCAP sichern …** unter „Daten & Export“ schreibt den Mitschnitt für
  Wireshark.
- Welcher Kanal frei ist, zeigt die Seite **WLAN** („Zigbee-Kanäle einzeichnen“).

<a id="wifi"></a>
## WLAN

Zeigt die WLAN-Netze in der Umgebung, wie belegt jeder Kanal ist – mit
Empfehlung des freiesten Kanals, auch für Zigbee – und auf Wunsch die
Verwaltungsrahmen für Wireshark.

- Oben den **Modus** wählen: Belegung messen oder Rahmen mitschneiden, dann
  **Start**.
- Mitgeschnittene Rahmen sicherst du unter „Daten & Export“ mit **PCAP
  sichern …**.
- **Netze suchen** (Abschnitt „Netze (WLAN des Mac)“) fragt das WLAN des Mac ab
  und geht auch ohne PortaPack.

<a id="drones"></a>
## Drohnen (Remote ID)

Neuere Drohnen senden eine **elektronische Kennung** mit Position, Höhe und
Standort des Piloten – per Bluetooth und WLAN. Die App hört alle Wege
gleichzeitig, über den HackRF und den Mac; welche, wählst du oben unter
„Quellen“. Flugspuren und Pilotposition schaltest du unter „Anzeige“. Treffer
gibt es nur, wenn gerade eine Drohne in der Nähe fliegt.

<a id="meshtastic"></a>
## Meshtastic (LoRa)

Nachrichten und Positionen aus dem Meshtastic-Netz (869,525 MHz, LongFast). Der
öffentliche Standardkanal wird entschlüsselt, eigene Kanäle mit ihrem Schlüssel;
Direktnachrichten bleiben privat. Region, Voreinstellung, Schlüssel und Frequenz
stellst du oben unter **Kanal** ein.

<a id="lorawan"></a>
## Funknetz LoRaWAN

Sensoren im LoRaWAN (z. B. The Things Network) auf 868 MHz. Die App hört alle
Spreizfaktoren gleichzeitig. Lesbar sind nur **deine eigenen** Geräte, deren
Sitzungsschlüssel (ABP) du unter „Daten & Export“ hinterlegst.

<a id="smartHome868"></a>
## Smart Home 868 MHz

Funk von Smart-Home-Geräten und Funkzählern um 868 MHz – alles gleichzeitig:

| Funkart | Typische Geräte |
|---|---|
| Z-Wave | Schalter, Thermostate, Sensoren, Zwischenstecker |
| Homematic | Heizkörperthermostate, Fensterkontakte, Wettersensoren |
| EnOcean | batterielose Taster, Raumfühler, Fensterkontakte |
| Wireless M-Bus | Wasser-, Wärme-, Strom- und Gaszähler, Heizkostenverteiler |

> Werte nur **deine eigenen** Geräte aus. Den Funkverkehr fremder Geräte – etwa
> der Zähler deiner Nachbarn – mitzulesen, zu speichern oder weiterzugeben, ist
> nicht erlaubt.

### So geht's

- **Start** – oben erscheinen die **Geräte** mit letztem Wert und Pegel,
  darunter die einzelnen **Rahmen** (ein Klick zeigt alle Felder). Wählst du ein
  Gerät, siehst du nur seine Rahmen; „Alle Rahmen“ hebt das auf.
- Unter **Funkarten** schaltest du ab, was dich nicht interessiert.
- Viele Geräte senden nur bei Änderungen oder alle paar Minuten; Zähler alle
  15 Sekunden bis 15 Minuten.
- Ein Schloss zeigt **verschlüsselte** Inhalte (Z-Wave S0/S2, Homematic IP,
  Zähler ohne Schlüssel).

### Schlüssel für Funkzähler

Den Schlüssel deines Zählers bekommst du vom Versorger, Vermieter oder
Hersteller. Trag ihn unter „Daten & Export“ bei **Zählerschlüssel** ein:
Zählernummer (8 Ziffern, steht auf dem Zähler) und Schlüssel (32 Zeichen
0–9/A–F). Er liegt nur im Schlüsselbund deines Mac.

### EnOcean-Fühler

Temperatur- und Feuchtefühler sagen im Funk nicht, wie ihre Werte zu lesen
sind. Lernst du einen Fühler an, während die Seite läuft, erkennt die App sein
Profil selbst. Sonst wähl das Gerät aus und stell unter **EnOcean-Profil** das
Profil aus der Anleitung ein (z. B. A5-04-01).

<a id="airband"></a>
## Flugfunk

Ein Scanner für den Sprechfunk der Luftfahrt (118–137 MHz, AM). Die App hört
**alle Kanäle deiner Liste gleichzeitig** ab: Sobald auf einem jemand spricht,
hörst du ihn – bei mehreren gleichzeitig den lautesten.

### So geht's

1. Unter **Kanal hinzufügen** den Kanal eintragen, wie er auf Karten steht
   (z. B. „118.005“ oder „121.5“), dazu einen Namen („Turm“). Die Notfrequenz
   121,5 MHz steht schon drin.
2. **Start**.

### In der Kanalliste

- **Stern = Vorrang:** unterbricht jeden anderen Kanal.
- **Schloss = sperren:** nie hörbar – gut für Dauersender wie ATIS.
- **Halten** (Pause-Knopf in der Zeile oder neben Start): nur noch diesen Kanal
  hören, bis „Weiter“.
- **Rauschsperre:** Die App lernt das Rauschen jedes Kanals selbst; der Regler
  sagt, wie weit ein Signal darüber liegen muss. Kleiner = empfindlicher, aber
  öfter Fehlalarm.
- **Ausschnitt:** Die App hört 8 MHz auf einmal. Liegen deine Kanäle weiter
  auseinander, schalte vor dem Start „Breiter Ausschnitt (16 MHz)“ ein (braucht
  mehr Rechenleistung). Kanäle außerhalb nennt das Bedienfeld.

### Aktive Kanäle finden

Die Suche wandert über das ganze Band und merkt sich, wo gesprochen wurde. „Je
Fenster lauschen“ legt fest, wie lange sie an jeder Stelle bleibt – länger
findet auch seltene Kanäle. Funde stehen links mit Zahl der Sprüche; per
Rechtsklick ▸ „Kanal zur Liste hinzufügen“ übernimmst du sie. Ein fast immer
belegter Kanal ist meist ATIS/VOLMET oder eine Störung.

### Verlauf und Mitschnitte

- Der **Verlauf** zeigt jede Übertragung mit Zeit, Kanal, Dauer und Stärke.
  **Nur Sprache zählen** (Vorgabe an) blendet Knackser und Träger ohne Ton aus.
- **Sprüche aufzeichnen** (Vorgabe aus) speichert jeden Spruch als Audiodatei
  zum Nachhören (▶ im Verlauf). Die Dateien bleiben auf deinem Mac („Im Finder
  zeigen“); **Leeren …** entfernt Verlauf und Mitschnitte.
- Die Seite zeigt die letzten 1000 Übertragungen; nur zu diesen bleiben die
  Mitschnitte. Ältere Einträge (ohne Ton) bleiben im Archiv, bis die
  Aufbewahrungsfrist sie löscht.

### Sprüche als Text

Schalte unter **Erkennung** „Sprüche in Text umwandeln“ ein, dann schreibt die
App jeden Spruch als Text in die Spalte **Text** des Verlaufs. Die Erkennung
läuft nur auf deinem Mac – nichts verlässt den Rechner. Dafür musst du nichts
aufzeichnen: Der Ton bleibt nur kurz im Speicher.

- **Sprache:** Englisch für den normalen Sprechfunk, Deutsch für Sichtflug an
  kleinen Plätzen und Rettungshubschrauber. „Automatisch“ versucht beides und
  nimmt das sicherere Ergebnis.
- Beim ersten Einschalten lädt macOS das Sprachmodell einmalig herunter (der
  Fortschritt steht im Bedienfeld). Auf macOS 15 fragt das System außerdem
  nach der Erlaubnis für die Spracherkennung.
- **Blasser Text** heißt: Die Erkennung war sich unsicher. Fahr mit der Maus
  über den Text, dann siehst du den Rohtext, so wie ihn die Erkennung geliefert
  hat. In der Spalte stehen Zahlwörter schon als Ziffern („flight level eight
  zero“ → „flight level 80“, „one two three decimal eight seven five“ →
  „123.875“).
- Ein **blaues Rufzeichen** vorne (z. B. DLH4AB) heißt: Im Spruch kam ein
  Flugzeug vor, das die App per ADS-B kennt – aus der laufenden ADS-B-Seite oder
  den Sichtungen der letzten drei Stunden. Rechtsklick ▸ „Flugzeug … zeigen“
  springt zur Karte.
- **Suchen:** Das Feld über dem Verlauf durchsucht die Texte aller gespeicherten
  Sprüche, auch älterer. Mehrere Wörter müssen alle vorkommen; ein Rufzeichen
  wie „DLH4AB“ findet auch die Sprüche, in denen es erkannt wurde.
- Per Rechtsklick kopierst du den Text oder den Rohtext.
- Kommen mehr Sprüche, als der Mac schafft, fallen die ältesten wartenden weg
  („Verworfen“ im Bedienfeld). Sprüche unter 0,8 Sekunden werden nicht erkannt.

Erwarte keine perfekte Abschrift: Flugfunk ist schnell, verrauscht und voller
Fachbegriffe. Gut klappen Zahlen, Pisten und Flugflächen; Airline-Namen und
Buchstaben gehen bei schwachem Signal oft daneben.

Reichweite: Flugzeuge in der Luft oft 100 km und mehr, den Boden (Turm,
Vorfeld) meist nur in Flughafennähe.

> **Recht:** Flugfunk ist nicht für die Allgemeinheit bestimmt. Ob schon das
> Mithören erlaubt ist, wird in Deutschland unterschiedlich gesehen; klar
> verboten ist, Inhalte oder auch nur die Tatsache des Empfangs weiterzugeben
> (§ 5 TDDDG). Die App teilt deshalb nichts, und Mitschnitte bleiben auf deinem
> Mac. Höre nur für dich.

<a id="vor"></a>
## Funkfeuer (VOR)

VOR-Funkfeuer (108–118 MHz) verraten jedem Empfänger, in welcher Richtung vom
Funkfeuer er steht – das **Radial**. Die App misst das Radial, liest die
Morse-Kennung und bestimmt aus zwei Funkfeuern deinen Standort.

### So geht's

1. Beim ersten Mal **„Datenbank laden“** (Knopf in der leeren Liste): alle
   Funkfeuer von OurAirports, ≈ 3 MB. Später unter „Daten & Export“ mit
   **Aktualisieren** erneuern. Dein Standort wird dabei nicht gesendet.
2. Unten stehen die nächsten Funkfeuer zu deinem Standort. Ein Klick (Liste oder
   Karte) stimmt ab. Ohne Datenbank trägst du die Frequenz von Hand ein.
3. **Start** – die große Zahl ist das Radial in Grad, bezogen auf magnetisch
   Nord wie in der Luftfahrt üblich; darunter die geografische Richtung.

### Was du siehst

- **Güte:** „gut“, wenn das Signal sauber ist und das Radial kaum schwankt. Bei
  „unbrauchbar“ ist das Funkfeuer zu weit weg oder gestört.
- **Kennung:** die drei Morsebuchstaben; „passt“, wenn sie zum gewählten
  Funkfeuer gehören. „Ton hören“ spielt sie ab.
- **Kreuzpeilung:** Steht die Güte, merkt sich die App das Radial. Wähl ein
  zweites Funkfeuer – auf der Karte erscheinen beide Linien und ihr
  Schnittpunkt. Am genauesten bei etwa rechtem Winkel; unter 30° warnt die App.

Reichweite: am Boden oft nur 30–80 km, mit Antenne draußen und hoch mehr.

> Nur zum Ausprobieren – nicht zur Navigation verwenden.

<a id="dsc"></a>
## Seefunk-Notruf (DSC)

Schiffe und Küstenfunkstellen rufen sich auf **UKW-Kanal 70 (156,525 MHz)**
digital an. Darüber läuft auch der **Notruf**: Die rote Taste am Funkgerät
sendet Kennung (MMSI), Art des Notfalls und Position. Die Seite hört Kanal 70 ab
und zeigt jeden Ruf.

- **Liste:** Notrufe stehen **rot**, Dringlichkeit orange, Sicherheit gelb.
  „Wdh.“ zählt Wiederholungen – ein Notruf wiederholt sich alle paar Minuten.
- Ein Klick zeigt alle Angaben (Absender und Ziel mit Land, Art des Notfalls,
  Position, Folgekanal). Rufe mit Position erscheinen auf der Karte.
- **Schiffsnamen** kommen aus AIS: Kennt die AIS-Seite oder ihr Archiv der
  letzten Woche das Schiff, steht der Name statt der Nummer.
- **Benachrichtigung** bei einem Notruf: Einstellungen ▸ Benachrichtigungen.

Die meisten Rufe sind Tests und Routinerufe. Zu hören nur mit Sicht zu Küste,
Fluss oder Hafen, am besten mit einer Antenne für das Seefunkband. DSC und AIS
laufen nicht gleichzeitig.

> **Wichtig:** Einen Notruf **niemals selbst beantworten** – das ist Sache der
> Seenotleitung (Bremen Rescue) und der Schiffe in der Nähe. Die App sendet
> ohnehin nichts. Inhalte nicht weitergeben. Siehst du einen Notfall selbst,
> wähl **112** bzw. von See **124 124**.

<a id="amateurSat"></a>
## Amateurfunk-Satelliten & ISS

Bilder und Funkpakete aus dem Weltraum: Die ISS sendet an bestimmten Tagen
**SSTV-Bilder**, ihr APRS-Digipeater gibt fast immer Pakete von Funkamateuren
weiter, kleine Satelliten schicken **Telemetrie**.

### So geht's

1. Oben den **Satelliten** wählen. Wann er über dem Horizont steht, zeigt
   **Überflüge**.
2. **Start**, wenn er aufgeht – oder im **Empfangsplan** „Überflüge automatisch
   empfangen“ einschalten (Knopf „Empfangsplan …“).

| Satellit | Frequenz | Was kommt |
|---|---|---|
| ISS | 145,800 MHz | SSTV-Bilder (nur bei ARISS-Aktionen) |
| ISS | 145,825 MHz | APRS-Pakete |
| PCSAT (NO-44) | 145,827 MHz | APRS-Pakete, nur zeitweise |
| GRBBeta | 436,785 MHz | Telemetrie |

Bei der ISS hört die App SSTV und APRS gleichzeitig. Unter **Eigener Satellit**
trägst du weitere ein (Katalognummer, Frequenz, Betriebsart).

### SSTV-Bilder der ISS

- SSTV läuft **nur an angekündigten Terminen** – die kündigt ARISS auf seiner
  Webseite an. Sonst ist auf 145,800 MHz Funkstille.
- Die App erkennt den Bildanfang selbst und zeigt das Bild Zeile für Zeile.
  Starte daher rechtzeitig vor dem Überflug – ohne Bildanfang kein Bild.
- Fertige Bilder landen in der **Galerie** unten (Doppelklick öffnet) und als
  PNG im Ordner „SSTV“ („Im Finder zeigen“). Abgebrochene Bilder heißen
  „_teilweise“.

### Pakete

Jedes Paket erscheint unter „Rahmen“ mit Absender, Ziel und Inhalt
(Rechtsklick kopiert). **Leeren** leert die Liste; die Galerie bleibt.

### Antenne

Für die ISS reicht eine **2-m-Antenne** mit freier Sicht zum Himmel
(Groundplane, Dipol oder kleine Yagi). Je höher der Überflug (ab etwa 30°),
desto besser. Für GRBBeta brauchst du eine 70-cm-Antenne. Die
**Doppler-Korrektur** gleicht die Frequenzverschiebung beim Vorbeiflug aus; dafür
muss dein Standort eingetragen sein.

<a id="ft8"></a>
## Amateurfunk FT8/WSPR

Funkamateure tauschen mit **FT8** kurze Meldungen aus (Rufzeichen, Locator,
Rapport) und senden mit **WSPR** Baken. Beides kommt noch weit unter dem
Rauschen an – deshalb siehst du oft Stationen in Hunderten Kilometern
Entfernung. Die App empfängt nur und meldet nichts weiter.

### So geht's

1. **Band** wählen (2 m, 6 m oder 70 cm).
2. **Betriebsart** wählen: FT8, WSPR oder beides. **Tiefe Dekodierung (OSD)**
   findet noch schwächere FT8-Signale.
3. **Start**. Nach jedem Takt erscheinen die gehörten Stationen: bei FT8 alle
   15 Sekunden, bei WSPR alle zwei Minuten.

### Was du siehst

- **Liste** mit Zeit (UTC), Rauschabstand (um −20 dB ist bei FT8 normal),
  Nachricht und – wenn der Locator bekannt ist – Entfernung und Richtung.
  CQ-Rufe sind grün; „Nur CQ-Rufe zeigen“ blendet den Rest aus.
- **Karte** mit allen Stationen; ein Klick zieht eine Linie von dir aus.
- **Wasserfall** der letzten Minute (FT8) bzw. zwei Minuten (WSPR); grüne Rahmen
  markieren dekodierte Signale.

### Tipps

- **Antenne** für das gewählte Band, draußen und hoch – sonst bleibt FT8 auf
  2 m oft still. Auf 6 m ist im Sommer am meisten los.
- **Uhr:** FT8 verträgt nur etwa ±2 Sekunden Abweichung. Geht die Mac-Uhr
  falsch, zeigt die App einen Hinweis. Abhilfe: Systemeinstellungen ▸
  Allgemein ▸ Datum & Uhrzeit ▸ „Automatisch einstellen“.
- **Quarz:** Für WSPR lohnt der Quarzabgleich (Einstellungen ▸ Antenne &
  Gerät). Ohne ihn sucht die App breiter, die angezeigten Hertz stimmen dann
  nicht genau.
- **Aufwärmen:** Ein HackRF ohne TCXO läuft in den ersten 15–20 Minuten nach
  dem Einschalten weg – auf 2 m schnell einige zehn Hertz pro Minute. Lass ihn
  vorher warmlaufen, oder nutze einen TCXO bzw. einen externen 10-MHz-Takt an
  CLKIN (die App zeigt unter „Hinweis“, ob einer erkannt wird).
- **Quarzdrift nachführen** (Vorgabe an): Hört die App mindestens drei
  Stationen mehrmals, schätzt sie aus deren Frequenz, wie weit der HackRF seit
  dem Start weggelaufen ist, und schiebt das Audioband zurück. Unter „Status“
  stehen dann „Drift: … Hz/min“ und „Abweichung seit Start“. Den Quarzabgleich
  ersetzt das nicht – es misst nur die Änderung seit dem Start.

<a id="hydrogen"></a>
## Wasserstofflinie

Radioastronomie mit dem HackRF: Wasserstoffgas in der Milchstraße strahlt bei
1420,4 MHz. Aus der Verschiebung der Linie liest du ab, wie schnell sich
Spiralarme auf uns zu oder von uns weg bewegen.

### Was du brauchst

- Eine **Schüssel** (ab etwa 1 m) oder eine **Hornantenne** für 1420 MHz – eine
  Stabantenne reicht nicht.
- Direkt an der Antenne einen **rauscharmen Vorverstärker mit Bandfilter**
  („H-Line-LNA“), versorgt über die **Antennenspeisung (Bias-Tee)**. Ohne ihn
  siehst du nichts.

### So geht's

1. **Standort** eintragen (Einstellungen ▸ Standort).
2. **Azimut und Elevation** der Antenne eingeben (0° Nord, 90° Ost). Der Link
   „Milchstraße am höchsten“ übernimmt die Richtung, in der die Linie meist am
   kräftigsten ist.
3. **Start** und warten – zehn Minuten sind ein guter Anfang, länger heißt
   weniger Rauschen. Die Messung wird am Ende von selbst gespeichert.

### Was du siehst

- Die Kurve über **Geschwindigkeit** (km/s, positiv = entfernt sich) oder
  **Frequenz**. Erd- und Sonnenbewegung sind schon herausgerechnet.
- **Störabstand** oben: ab etwa 5 ist die Linie sicher da.
- **Glättung** und **Grundlinie** machen die Kurve ruhiger.
- Unter „Daten & Export“ speicherst du **Messreihen**, legst mehrere übereinander
  und exportierst sie als CSV – auch ohne angeschlossenes Gerät.
- **Neu beginnen** fängt von vorn an. Verlässt du die Seite, läuft die Messung
  weiter; nimmt eine andere Seite den HackRF, pausiert sie bis **Fortsetzen**.

Die Verstärkung regelt hier bewusst keine Automatik nach – sie muss während der
Messung gleich bleiben. Ein Pegel um −30 dBFS ist ideal.

### Technik

Als **Verfahren** gibt es die Frequenzumschaltung (der HackRF hört abwechselnd
neben der Linie, nichts weiter zu tun) und die Referenzmessung (zuerst auf
„leeren“ Himmel oder einen 50-Ω-Abschluss **Referenz aufnehmen**, dann auf die
Quelle richten). Die Geschwindigkeit ist auf das lokale Ruhesystem (LSR)
bezogen.

<a id="cells"></a>
## Mobilfunkzellen (LTE)

Sucht die LTE-Basisstationen (4G) in deiner Umgebung und zeigt, was sie für jedes
Handy ausstrahlen: Zellnummer, Bandbreite, Pegel und – wenn es klappt –
Netzbetreiber und Zellkennung.

> Gelesen werden nur die öffentlichen Rundsendungen der Basisstation. Gespräche,
> Daten oder Signale von Handys empfängt die App nicht.

### So geht's

1. **Antenne anschließen.** Die Teleskopantenne geht für 800/900 MHz, für
   1800–2600 MHz ist eine kurze Mobilfunkantenne besser. Am Fenster findest du
   deutlich mehr.
2. Oben die **Bänder** wählen und **Start** („Suchlauf starten“). Je Band dauert
   es einige Sekunden; oben siehst du Fortschritt und Spektrum.
3. Ist **„Netzbetreiber lesen (SIB1)“** an, prüft die App jede gefundene Zelle
   noch einzeln und liest Betreiber und Kennung.

Übersieht der Suchlauf etwas, trag unter **Einzelne Frequenz** die Frequenz
(z. B. 806) oder Kanalnummer (EARFCN, z. B. 6300) ein. Die Verstärkung regelt
der Suchlauf je Band selbst.

### Was die Spalten bedeuten

| Spalte | Bedeutung |
|---|---|
| Band, EARFCN, MHz | Frequenzband, Kanalnummer und Frequenz |
| PCI | Zellnummer (0–503), unterscheidet benachbarte Zellen |
| Breite, Ant. | Bandbreite und Zahl der Sendeantennen |
| RSRP | Pegel in dBFS – relativ, kein geeichter Wert |
| Qualität | Störabstand; grün ab 13 dB, orange ab 3 dB |
| Betreiber, TAC, Zell-ID | Netzbetreiber, Gebiet und Standort/Sektor (aus SIB1) |

Ein Strich bei Betreiber heißt: nicht fehlerfrei gelesen; der Grund steht im
Tooltip.

### Zelle beobachten

Wähl eine Zelle und drücke **„Zelle beobachten“**: Die App zeichnet Pegel und
Qualität laufend auf – so richtest du eine Antenne aus oder findest den besten
Platz am Fenster. Der „Quarz-Restfehler“ unter „Status“ zeigt nebenbei, wie
genau dein Quarzabgleich ist.

<a id="occupancy"></a>
## Belegungsmonitor

Wer funkt wann auf welcher Frequenz? Der Belegungsmonitor beobachtet ein Band
über **Stunden oder Tage** und zeigt, welche Kanäle wie oft belegt sind.

### So geht's

1. Unter **Band** eine Vorlage wählen (433 MHz, 868 MHz, 2 m, 70 cm, PMR446,
   Flugfunk, Seefunk, Freenet, CB-Funk) oder Von/Bis selbst eintragen. Das
   **Raster** bestimmt, wie fein die Frequenzen aufgeteilt werden.
2. **Start** – und laufen lassen.

### Was du siehst

- **Wärmebild:** oben die neueste Zeit, hell = viel los. Ziehen verschiebt,
  Mausrad blättert durch die Zeit, ⌘ + Mausrad zoomt die Frequenz, ⌥ + Mausrad
  die Zeit.
- **Belegung je Frequenz** und **Aktivste Frequenzen** mit den letzten
  Sendezeiten.
- Ein Klick wählt eine Frequenz; **Im Radio anhören** (oder Doppelklick in der
  Liste) öffnet sie im Radio – der Monitor pausiert dann.

**Schwelle** (Vorgabe 10 dB über dem Rauschen) legt fest, ab wann ein Kanal als
belegt gilt; **Zeitscheibe** (z. B. 1 Minute), wie fein die Zeit gespeichert
wird; **Wärmebild zeigt** wählt Belegung, Spitze oder Mittelwert.

### Aufzeichnung und Export

- Jede Messung wird laufend gespeichert und übersteht einen Neustart:
  **Fortsetzen** hängt an, **Neu beginnen** startet eine neue.
- Unter „Daten & Export“ öffnest du **gespeicherte Aufzeichnungen** (auch ohne
  Gerät), begrenzt die **Größte Dateigröße** und exportierst CSV und PNG.
- Der Monitor läuft weiter, wenn du die Seite verlässt (wie jeder Empfänger).
  Startest du eine andere Empfängerseite, pausiert er bis **Fortsetzen**.
- Die Verstärkung bleibt während einer Aufzeichnung fest, damit die Werte über
  Stunden vergleichbar bleiben.

<a id="dcf77"></a>
## Funkuhr (DCF77)

Das Zeitzeichen aus Mainflingen (77,5 kHz) – mit Vergleich gegen die Uhr des
Mac. Braucht eine lange Drahtantenne oder eine aktive Rahmenantenne; übliche
Antennen und die Ferritantenne einer Funkuhr fangen das Signal kaum.

- **Sekunden der laufenden Minute:** ein Kästchen je Sekunde – grau = 0,
  blau = 1, grün = Minutenmarke, rot = unlesbar. Nach einer vollständigen
  Minute stehen oben Datum und Uhrzeit, dazu, wie weit die Mac-Uhr abweicht.
- **Hüllkurve (letzte 20 s):** die Signalstärke mit einem Strich je Sekunde.
  Jede Sekunde sinkt der Träger kurz ab – 100 ms für eine 0, 200 ms für eine 1;
  in der letzten Sekunde der Minute fehlt die Absenkung (Minutenmarke).
- Unter „Träger 77,5 kHz“ und „Sekundentakt“ stehen Rauschabstand, „Tiefe der
  Marke“ und wie viele Minuten gültig waren. Bleibt der Sekundentakt „wird
  gesucht“, ist das Signal zu schwach oder gestört – oft durch Netzteile,
  Ladegeräte oder Bildschirme in der Nähe.

Auch Minuten mit Schaltsekunde (61 Sekunden lang, vorher angekündigt) liest die
App richtig.

<a id="gps"></a>
## GPS-Ortung

Bestimmt deine Position direkt aus den GPS-Satelliten. Am besten mit einer
**aktiven GPS-Antenne mit freiem Himmel** – dafür „Antennenspeisung (Bias-Tee)“
einschalten. Die erste Position dauert etwa eine Minute. **Als eigenen Standort
übernehmen** übernimmt sie für alle Karten.

### Schwache Signale (Fenster, Balkon, Bäume)

- Die **Schwachsignal-Suche** (unter „Von Hand einstellen“, ab Werk an) sucht
  Satelliten, die die schnelle Suche nicht findet, mit langer Integration. Sie
  findet Satelliten etwa zehnmal schwächer als die schnelle Suche; das kostet
  etwas Rechenzeit, und die erste Position dauert dann eher zwei Minuten.
- Ein Satellit mit dem Hinweis **„schwach“** wird mit langer Integration
  verfolgt – er zählt trotzdem für die Position, nur etwas ungenauer.
- Die App merkt sich Bahndaten, Almanach und die letzte Position. Beim nächsten
  Start sagt sie damit voraus, welche Satelliten am Himmel stehen, und sucht
  gezielt („Suche: gezielt …“). Ohne gespeicherte Position nimmt sie deinen
  Standort aus den Einstellungen. Sind die Bahndaten noch keine zwei Stunden
  alt, kommt die erste Position nach gut zehn Sekunden (**Heißstart**).

> Tief im Haus reicht es meist trotzdem nicht. Je näher am Fenster und je mehr
> freier Himmel, desto besser – und eine aktive Antenne hilft immer.

<a id="recorder"></a>
## Aufnahme

Rohdaten (IQ) aufnehmen und später auswerten – um etwas in Ruhe zu untersuchen
oder eine Aufnahme weiterzugeben.

- Eine **Vorlage** wählen (ADS-B, GPS, DVB-T2-Kanal, DAB-Block, Zigbee-Kanal) –
  sie stellt Frequenz und Datenrate passend ein. Unter „Status“ stehen
  Datenrate und maximale Dauer.
- **Aufnahme starten**; später **Abspielen & auswerten** (Spektrum, ADS-B, GPS,
  DVB-T2, DAB+, Zigbee) – das geht auch ohne angeschlossenes Gerät.

### SigMF – Aufnahmen mit anderen Programmen tauschen

SigMF ist das übliche Format für IQ-Aufnahmen: die Abtastwerte in
`.sigmf-data`, daneben eine kleine Beschreibung `.sigmf-meta` (Abtastrate,
Frequenz, Zeit, Gerät). GNU Radio, inspectrum, SigDigger und viele andere
Programme lesen es.

- **Als SigMF aufnehmen** (unter „Daten & Export“) schreibt neue Aufnahmen
  gleich in diesem Format.
- **Als SigMF exportieren …** (Kontextmenü der Aufnahme oder Knopf unter
  „Daten & Export“) sichert eine vorhandene Aufnahme als die zwei Dateien.
- **SigMF öffnen …** übernimmt eine fremde Aufnahme in deine Liste – wähle die
  `.sigmf-meta`-Datei, die `.sigmf-data` muss daneben liegen. Möglich sind
  `ci8` (HackRF), `cu8` (rtl_sdr), `ci16` und `cf32` (z. B. GNU Radio); breite
  Formate werden auf 8 Bit umgerechnet, so dass die lauteste Stelle am Anfang
  gut in den Bereich passt. Ein Archiv `.sigmf` entpackst du vorher im Finder.
- Die Dekoder brauchen die Abtastrate und Mitte ihrer Vorlage. Passt eine
  fremde Aufnahme zu keiner, sagt die App das nach dem Öffnen – das Spektrum
  geht immer.

> Die Beschreibung enthält Gerät und Software, aber **nie deinen Standort**.
> Bringt eine fremde Datei einen Standort mit, übernimmt die App ihn nicht.

<a id="remote"></a>
## Fernzugriff (Handy, unterwegs)

Eine Webseite für Handy und Tablet mit fast allen Empfängern der App – Karte der
Flugzeuge und Schiffe, Radio mit Ton, Wetter, Smart Home und mehr. Einschalten
unter **Einstellungen ▸ Fernzugriff**.

### So geht's

1. **„Fernzugriff einschalten“**.
2. Eine der **Adressen** am Handy öffnen – am einfachsten über **QR-Code**. Die
   Adresse enthält den Zugangsschlüssel; ohne ihn zeigt die Seite nichts.
3. Auf dem iPhone über „Teilen ▸ Zum Home-Bildschirm“ als App ablegen.

**Unterwegs nur über VPN:** Tailscale auf Mac und Handy installieren und die
Tailscale-Adresse (100.x.y.z) nutzen – oder dich per VPN ins Heimnetz einwählen
(z. B. WireGuard der FRITZ!Box). Ab Werk ist **„Nur Heimnetz und VPN“** an: Der
Mac nimmt nur Geräte aus dem eigenen Netz (auch mit IPv6) und aus dem VPN an und
weist alles aus dem Internet sofort ab. Eine Portfreigabe im Router funktioniert deshalb nicht –
und wäre auch keine gute Idee, denn Seite und Ton gingen unverschlüsselt durchs
Netz. Fragt macOS beim ersten Mal nach eingehenden Verbindungen, mit „Erlauben“
bestätigen.

### Bedienung auf dem Handy

- Oben links öffnet der Knopf mit dem Namen des Empfängers das Menü mit allen
  Reitern: Flugzeuge, Flugzeug-Datenfunk, Flugfunk, Schiffe, Seefunk-Notruf,
  Wetter & Satelliten, Digitalradio, Radio, Spektrum, Belegungsmonitor,
  Funksensoren, Smart Home 868, Zigbee und FT8/WSPR.
- **Start** schaltet den HackRF auf diesen Empfänger um, **Stopp** beendet ihn.
  Das Quadrat oben rechts beendet jeden Empfang – auch einen am Mac gestarteten,
  danach startet nichts von selbst wieder. Die Antenne daneben ist „Signal
  optimieren“.
- Bei Radio, Digitalradio und Flugfunk spielt **Hier anhören** den Ton auf dem
  Handy; **Ton aus** stellt nur den Ton ab, der Empfang läuft weiter.
- Die Kästen klappst du mit einem Tipp auf die Überschrift auf und zu.
- Frequenzspeicher, Flugfunk-Kanalliste und Empfangsplan teilen sich Mac und Handy.
  Im Reiter Radio steht der Frequenzspeicher zum Antippen und Abstimmen;
  bearbeiten und löschen geht am Mac.
  Unter **Wetter & Satelliten** schaltest du den Empfangsplan ein und aus und
  überspringst Termine.

### Gut zu wissen

- Solange der Fernzugriff an ist, bleibt der Mac wach.
- **Neu erzeugen** macht einen neuen Schlüssel und sperrt alle bisher geöffneten
  Seiten aus. Der Browser merkt sich den Schlüssel und nimmt ihn aus der
  Adresszeile – ein Bildschirmfoto verrät ihn dann nicht.
- Schlüssel (Zigbee, Zähler) werden nie über die Webseite übertragen; die
  trägst du am Mac ein.
- Unter **Zuletzt abgewiesen** siehst du, wenn jemand von außerhalb anklopfen
  wollte. Nutzt dein VPN ungewöhnliche Adressen, kannst du „Nur Heimnetz und VPN“
  ausschalten.
- Ist der Schlüsselbund einmal nicht lesbar, setzt der Fernzugriff aus und zeigt
  das unter Einstellungen ▸ Fernzugriff an. Sobald der Schlüssel wieder lesbar
  ist, geht es von selbst weiter – mit demselben Schlüssel, deine Handys bleiben
  angemeldet.

<a id="sharing"></a>
## Daten teilen

Gib empfangene Daten an Gemeinschaftsnetze oder dein Home Assistant weiter. Zu
finden unter **Einstellungen ▸ Daten teilen**; alles ist **aus**, bis du es
einschaltest. Gesendet wird nur, solange die jeweilige Seite (oder Fernzugriff
bzw. Empfangsplan) empfängt.

- **Flugzeuge (ADS-B)** an adsb.fi, airplanes.live oder eigene Ziele – ohne
  Standort. Dazu auf Wunsch eine zufällige Stationskennung, an der dich die
  Dienste wiedererkennen (airplanes.live verlangt sie).
- **Schiffe (AIS)** als NMEA an AISHub, MarineTraffic, VesselFinder o. Ä. –
  Adresse und Port nennt der Dienst bei der Anmeldung.
- **Wetterballons** an SondeHub (braucht ein Rufzeichen; Standort nur auf Wunsch
  und auf etwa 1 km gerundet).
- **Home Assistant (MQTT):** Funksensoren, Smart Home 868 MHz, Zigbee-Geräte,
  Radiosonden und die Zahl der Flugzeuge an deinen eigenen MQTT-Broker; Home
  Assistant legt die Geräte selbst an. Mit „Nur Geräte mit …“ gibst du nur
  ausgewählte Geräte weiter – fremde Geräte (Nachbars Wetterstation) bitte
  nicht. Ohne diese Liste gehen höchstens 20 neue Geräte pro Stunde an Home
  Assistant (am Anfang etwas mehr) – so kann niemand per Funk Hunderte erfundene
  Geräte anlegen. Zurückgehaltene Geräte zählt das Formular; trag sie in die
  Liste ein, dann kommen sie sofort. Verdrängte Geräte (mehr als 1000) entfernt
  die App auch aus Home Assistant. Ohne TLS gehen Benutzer und Passwort im
  Klartext übers Netz – das Formular weist darauf hin.

Was die App aus dem Netz *holt* (Flugzeugdaten, Fotos), stellst du unter
Online-Dienste ein.

<a id="firmware"></a>
## Firmware

Hält die Mayhem-Firmware des PortaPack aktuell – Nightly (täglich neu) oder
Stabil.

### So geht's

1. Oben die **Ausgabe** wählen (Nightly oder Stabil), links ein Release,
   **Installieren**.
2. Die App lädt das Paket, prüft es, kopiert es auf die SD-Karte und lässt
   Mayhem flashen. **Währenddessen nicht abstecken.** Solange nur
   heruntergeladen wird, kannst du mit „Download abbrechen“ aufhören – am Gerät
   hat sich dann noch nichts geändert.
3. Das Gerät startet neu, die App prüft die neue Version.

Steht das Gerät im HackRF-Modus, bietet die Seite „Zurück in den Mayhem-Modus“
an.

### Weitere Wege

- **Nur Apps aktualisieren** – erneuert die Apps auf der SD-Karte.
- **Gerät komplett erneuern** – Firmware **und** alle Dateien der SD-Karte
  (≈ 25 Minuten über „SD over USB“). Hängt dabei das Auswerfen: Gerät aus- und
  einschalten und „Erneuern abschließen“ wählen.
- **Lokale Datei …** installiert ein heruntergeladenes Paket.
- **Gerätetyp:** Meldet das Gerät keinen Typ (ältere Firmware), fragt die Seite
  danach – bitte richtig wählen (HackRF One / Pro / PortaRF).
- **Flash löschen und neu schreiben** (unter „Weg“, im HackRF-Modus): nur als
  Rettung, wenn nichts anderes mehr geht.

<a id="screen"></a>
## Bildschirm & Steuerung

Spiegelt das PortaPack-Display live auf den Mac. Klicks wirken als Touch,
Pfeiltasten und Enter wie die Tasten am Gerät, Text tippst du direkt ein.
Bildschirmfotos per Knopf. Nur im Mayhem-Modus – steht das Gerät im
HackRF-Modus, wechselt die Seite von selbst zurück, sofern gerade nichts
empfängt; sonst bietet sie „Trotzdem zurück in den Mayhem-Modus“ an.

<a id="files"></a>
## SD-Karte

Dateien auf der SD-Karte des PortaPack ansehen, herunter- und hochladen (mit
Prüfsumme), Ordner anlegen, löschen. Übertragungen lassen sich mit „Abbrechen“
beenden; eine halb hochgeladene Datei entfernt die App wieder. Für große Mengen
schneller: Übersicht ▸ „SD-Karte als Laufwerk“. Im HackRF-Modus wechselt die
Seite wie „Bildschirm & Steuerung“ zurück in den Mayhem-Modus.

<a id="console"></a>
## Konsole

Freie Befehle an die Mayhem-Shell und ein Protokoll aller Befehle der App – für
Fortgeschrittene und zur Fehlersuche.

<a id="settings"></a>
## Einstellungen

Alles, was für die ganze App gilt, steht auf der Seite **Einstellungen** – in
der Seitenleiste unter „Gerät“ oder mit **⌘,**. Oben wählst du den Bereich.
Andere Seiten zeigen nur eine kurze Zeile mit dem Knopf **„Einstellungen …“**,
der direkt zum passenden Bereich springt.

| Bereich | Was du dort einstellst |
|---|---|
| **Allgemein** | Die Sprache der App, Start beim Anmelden, Hintergrundbetrieb, Symbol in der Menüleiste (siehe unten). |
| **Standort** | Dein Standort – von Hand oder über „Meinen Standort übernehmen“. Für Karten, Entfernungen und den Empfangsplan; er bleibt auf diesem Mac. |
| **Antenne & Gerät** | „Externer LNA“, „Verstärkung automatisch nachregeln“, „Automatisch in den HackRF-Modus wechseln“, „Display am Gerät“ und die Quarzkorrektur. |
| **Frequenzen** | Der Frequenzspeicher: alle gemerkten Frequenzen suchen, bearbeiten, löschen, als CSV ein- und auslesen (siehe unten). |
| **Fernzugriff** | Die Webseite fürs Handy (Kapitel „Fernzugriff“). |
| **Daten teilen** | Weitergabe an ADS-B-/AIS-Netze, SondeHub und Home Assistant (Kapitel „Daten teilen“). |
| **Benachrichtigungen** | Mitteilungen am Mac und aufs Handy – und wofür (siehe unten). |
| **Online-Dienste** | Flugzeugdaten, Strecken und Fotos online nachschlagen (ADS-B), Schiffsfotos (AIS). |
| **Archiv** | Was im Archiv steht, wie lange es aufbewahrt wird, Sicherung und Einspielen; Knöpfe öffnen die Archive. |

### Frequenzspeicher

Auf jeder Seite mit Frequenzfeld (Radio, Spektrum, Funkruf, Funksensoren,
Wetterballons, Aufnahme, Meshtastic, Funkfeuer, Belegung) steht im Bedienfeld
der Abschnitt **Frequenzspeicher**:

- **Merken …** legt die eingestellte Frequenz ab – mit Name und Ordner, wenn du
  magst. Gemerkt wird auch die Seite; die Liste zeigt „Diese Seite“ oder „Alle“.
- Ein **Klick** auf einen Eintrag stimmt darauf ab. Einträge außerhalb des
  Bereichs der Seite (z. B. 433 MHz auf der VOR-Seite) sind ausgegraut. In der
  Belegung öffnet ein Klick das Radio.
- Unter **Einstellungen ▸ Frequenzen** stehen alle Einträge in einer Tabelle:
  suchen, mit Doppelklick bearbeiten (Name, Frequenz, Betriebsart, Bandbreite,
  Seite, Ordner, Notiz), mit Entf löschen (die App fragt nach).
- **Exportieren …/Importieren …** als CSV mit den Spalten
  `Name;Frequenz (MHz);Modus;Bandbreite (kHz);Notiz;Gruppe;Seite`. Beim Einlesen
  gehen auch Listen aus SDR++ oder CHIRP mit diesen Spalten (auch englisch
  benannt), Komma oder Punkt als Dezimaltrenner und Frequenzen in Hz. Was schon
  vorhanden ist, wird übersprungen.

Die früheren Radio-Favoriten sind beim ersten Start automatisch im
Frequenzspeicher gelandet.

### Im Hintergrund weiterlaufen

Schließt du das Fenster, läuft die App weiter – Empfang, Aufnahmen, Empfangsplan
und Fernzugriff auch. Ohne offenes Fenster verschwindet das Dock-Symbol
(abschaltbar: „Dock-Symbol nur mit offenem Fenster“). Zurück kommst du über das
**Symbol in der Menüleiste** ▸ „PortaPack Manager öffnen“ oder indem du die App
noch einmal öffnest.

Das Symbol in der Menüleiste zeigt den Zustand: Antenne = bereit, gefüllt =
empfängt, roter Punkt = nimmt auf (auch ein Plan-Termin), orangefarbenes
Warndreieck = Problem mit dem Gerät. Im Menü stehen der laufende Empfänger mit
Frequenz und Pegel, der nächste Plan-Termin, Fernzugriff samt Zahl der Hörer und
der Gerätezustand; dazu „Empfang stoppen“, „Empfangsplan pausieren“ (keine neuen
Termine, bis du fortsetzt – nach einem Neustart plant die App wieder),
„Einstellungen …“ und „Beenden“.

**Beenden (⌘Q):** Läuft gerade etwas (Empfänger, Plan-Termin, Aufnahme,
Belegungsaufzeichnung, Fernzugriff mit Hörern), fragt die App: „Im Hintergrund
weiterlaufen“ (Eingabetaste), „Beenden“ oder „Abbrechen“. Läuft nichts, beendet
⌘Q sofort. Während einer Firmware-Installation lässt sich die App nicht
beenden. Beim Abmelden oder Ausschalten fragt sie nicht.

### Beim Anmelden starten

**Beim Anmelden starten** trägt die App als Anmeldeobjekt ein (zu sehen unter
Systemeinstellungen ▸ Allgemein ▸ Anmeldeobjekte; verlangt macOS dort eine
Freigabe, führt dich ein Knopf hin). **Beim automatischen Start** legt fest, was
dann passiert:

| Auswahl | Was startet |
|---|---|
| **Aufnahme fortsetzen** (Vorgabe) | Der Empfänger, der zuletzt lief – auch wenn du die App mit laufendem Empfang beendet hast. Hast du ihn selbst gestoppt, startet nichts. |
| **Nur Empfangsplan** | Nur die geplanten Termine. |
| **Bestimmte Seite starten …** | Die gewählte Seite (z. B. Flugzeuge). |
| **Nichts starten** | Nur die App. |

Der Empfangsplan läuft in jedem Fall. Die App wartet bis zu 3 Minuten auf den
HackRF und wechselt selbst in den HackRF-Modus; das Menü in der Menüleiste zeigt
solange „Warte auf den HackRF …“. Läuft gerade ein Plan-Termin, startet der
Empfänger danach. Den Fernzugriff schaltet der Anmeldestart nicht ein (er läuft
nur, wenn du ihn eingeschaltet hast), und eine Auswahl vom Handy wird nicht
wiederhergestellt. **Im Hintergrund starten** (Vorgabe an) öffnet dabei kein
Fenster. Öffnest du die App selbst, startet nichts von allein.

### Quarzkorrektur

Der Quarz im HackRF geht etwas falsch – wie eine Uhr, die vorgeht. Das stört vor
allem bei schmalen Signalen (FT8/WSPR, Satelliten). **Automatisch abgleichen**
sucht den stärksten UKW-Sender und misst daran (etwa eine Minute); was vorher
lief, startet danach wieder. Spielt das Radio gerade einen starken UKW-Sender,
misst die App an genau diesem. Die Korrektur gilt für alle Empfänger.

### Benachrichtigungen

Mitteilungen am Mac und/oder aufs Handy über die kostenlose App **ntfy**: dort
„Thema abonnieren“ und das angezeigte Thema eintragen oder den QR-Code scannen.
Wählbar sind Wetterballons in Reichweite, Satellitenüberflüge, Ergebnisse
geplanter Aufnahmen, „Gerät nicht erreichbar“ und Seefunk-Notrufe. Aufs Handy
gehen nur kurze Meldungstexte ohne Entfernungen oder Positionen, aus denen sich
dein Standort errechnen ließe. **Testnachricht senden** prüft den Weg.

### Archiv und Ablage

- Flugzeuge, Schiffe, Radiosonden und der Flugfunk-Verlauf stehen in einer
  Datenbank (`Archiv.sqlite`), Bilder, Mitschnitte und Messreihen daneben als
  Dateien – alles unter *Library ▸ Application Support ▸
  de.christiangolz.portapackmanager*, also auch in deinem Time-Machine-Backup.
- **Umstellung:** Beim ersten Start mit der Datenbank übernimmt die App die
  bisherigen Tagesdateien im Hintergrund (Fortschritt unter Einstellungen ▸
  Archiv). Sie prüft jeden Eintrag und legt die alten Dateien erst danach in den
  Ordner „Archiv-vor-Datenbank“ – gelöscht wird nichts. Wenn du magst, entfernst
  du sie dort mit **Alte Dateien löschen …**. Klappt die Übernahme nicht, bleiben
  die Dateien liegen, und die App versucht es beim nächsten Start erneut.
- **Aufbewahrung:** unbegrenzt (Vorgabe), 2 Jahre, 1 Jahr, 90 oder 30 Tage. Bei
  einer kürzeren Frist fragt die App nach und nennt, wie viele Einträge wegfallen.
- **Sicherung:** eine ZIP-Datei mit einer Kopie der Datenbank und den übrigen
  Dateien. Einspielen fügt nur hinzu, was fehlt – auch aus älteren Sicherungen
  mit Tagesdateien. Vorhandenes wird nie überschrieben.
- Was jederzeit neu geladen werden kann (Flugzeugdatenbank, Funkfeuer,
  Bahndaten), liegt im Cache und nicht im Backup.

<a id="fehler"></a>
## Wenn etwas nicht klappt

| Problem | Was hilft |
|---|---|
| Gerät wird nicht erkannt | Anderes USB-Kabel (Datenkabel!), Gerät aus/ein, Übersicht ▸ „USB neu anmelden“ |
| Seite zeigt „HackRF-Modus nötig“ | „In HackRF-Modus wechseln“ – oder das Gerät steckt nicht bzw. ist aus |
| Nichts wird empfangen | Statuszeile lesen; „Signal optimieren“; Antennen-Check; Antenne nach draußen und höher |
| „Übersteuert“ | Automatik an lassen, eingebauten Verstärker aus; bei externem Vorverstärker „Externer LNA“ einschalten |
| „Der HackRF empfängt gerade für …“ | Eine andere Seite, der Fernzugriff oder der Empfangsplan nutzt das Gerät – „Start“ holt es zurück |
| Fernzugriff geht nicht | Mac und Handy im selben Netz bzw. beide in Tailscale; die vollständige Adresse aus Einstellungen ▸ Fernzugriff verwenden |
| Firmware-Update bricht ab | Nicht abstecken, erneut versuchen. Hilft nichts mehr: „Gerät komplett erneuern“ |

**Faustregel:** Fast immer liegt es an der Antenne, nicht an der App. Eine
Antenne draußen und so hoch wie möglich bringt mehr als jede Einstellung.

<a id="recht"></a>
## Rechtliches und Datenschutz

- Die App **empfängt nur**; sie sendet nichts über Funk.
- Empfangen ist in Deutschland weitgehend erlaubt. Nachrichten, die nicht für
  dich bestimmt sind (z. B. Funkrufe von Behörden), darfst du weder auswerten
  noch weitergeben (§ 5 TDDDG). Verschlüsseltes bleibt verschlüsselt – außer in
  deinen eigenen Netzen mit deinen Schlüsseln.
- **Abhör- und Mitteilungsverbot:** Was nicht für dich bestimmt ist – etwa
  Flugfunk, ACARS/CPDLC, Funkrufe, Seefunk oder fremde Smart-Home- und
  LoRa-Netze –, darfst du weder aufzeichnen noch weitergeben, auch nicht die
  Tatsache, dass du es empfangen hast. Das gilt auch für Fernzugriff, „Daten
  teilen“ und das Archiv. Die betroffenen Seiten erinnern im Abschnitt
  „Hinweis“ kurz daran.
- **Was die App ins Internet schickt** – nur für die jeweilige Funktion und ohne
  deinen Standort, außer du gibst ihn ausdrücklich frei:
  - Firmware-Downloads von GitHub,
  - die Flugzeugdatenbank (OpenSky Network) – nur wenn du sie lädst,
  - Flugzeugdaten und Fotos (hexdb.io, adsbdb.com, planespotters.net – nur
    Flugzeugadresse bzw. Rufzeichen),
  - Schiffsfotos (Wikimedia Commons, nur die IMO-Nummer),
  - die Listen der Flugplätze und Funkfeuer (OurAirports),
  - Satellitenbahnen (CelesTrak) und Wetterballon-Daten (SondeHub),
  - was du unter „Daten teilen“ und „Benachrichtigungen“ selbst einschaltest.
- Kartenkacheln kommen von OpenStreetMap.
- Für „Sprüche in Text umwandeln“ (Flugfunk) lädt macOS einmalig ein
  Sprachmodell von Apple; die Erkennung selbst läuft auf dem Mac.
