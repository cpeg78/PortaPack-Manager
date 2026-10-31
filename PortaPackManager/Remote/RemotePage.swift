import Foundation

/// Die Webseite des Fernzugriffs: eine Datei, Karte über Leaflet (aus dem App-Bundle)
/// und OpenStreetMap-Kacheln, die der Browser selbst lädt. Texte aus dem
/// Funk (Schiffsnamen, Radiotext, Rufzeichen) gehen nur über `esc()` bzw.
/// `textContent` in die Seite – AIS-Namen sind frei wählbar.
enum RemotePage {
    /// Sprache der Seite = Sprache der App: "en", wenn die App englisch läuft, sonst "de".
    /// Die Seite hat keinen eigenen Sprachschalter.
    static var language: String {
        Bundle.main.preferredLocalizations.first?.hasPrefix("en") == true ? "en" : "de"
    }

    /// Zahlenformat der Texte, die der Server für die Seite fertig formatiert.
    static var locale: Locale { Locale(identifier: language == "en" ? "en_US" : "de_DE") }

    /// Die ausgelieferte Seite: angemeldetes Konto (`__USER__`, nur `[A-Za-z0-9._-]`,
    /// siehe `RemoteAccountBook.isValidName`), Rolle (`__ROLE__`), Sprache (`__LANG__`)
    /// und – für Englisch – das Wörterbuch (`__I18N__`, JSON in einem
    /// `<script type="application/json">`; `JSONSerialization` maskiert `/`, ein
    /// `</script>` im Text kann den Block nicht schließen).
    static func page(user: String, role: RemoteAccount.Role, language: String = RemotePage.language) -> String {
        let user = RemoteAccountBook.isValidName(user) ? user : ""
        let lang = language == "en" ? "en" : "de"
        var dictionary = "{}"
        if lang == "en", let data = try? JSONSerialization.data(withJSONObject: RemotePageEnglish.dictionary, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            dictionary = text
        }
        return html
            .replacingOccurrences(of: "__I18N__", with: dictionary)
            .replacingOccurrences(of: "__LANG__", with: lang)
            .replacingOccurrences(of: "__USER__", with: user)
            .replacingOccurrences(of: "__ROLE__", with: role.rawValue)
    }

    /// Web-App-Manifest (Android/Chrome; iOS nutzt die Meta-Tags). Die Web-App
    /// meldet sich beim ersten Start selbst an (eigene Cookies).
    static func manifest(language: String = RemotePage.language) -> String {
        let name = language == "en" ? "PortaPack Remote Access" : "PortaPack Fernzugriff"
        return """
        {"name":"\(name)","short_name":"PortaPack","start_url":"/","scope":"/",
         "display":"standalone","background_color":"#000000","theme_color":"#1c1c1e",
         "icons":[{"src":"/icon-180.png","sizes":"180x180","type":"image/png"},
                  {"src":"/icon-512.png","sizes":"512x512","type":"image/png","purpose":"any"}]}
        """
    }

    /// Anmeldeseite (auch statt der Seite, solange niemand angemeldet ist). Ein echtes
    /// Formular, damit iOS und Browser anbieten, das Passwort zu sichern.
    /// `message`: Fehlertext; `noAccounts`: am Mac ist noch kein Konto angelegt.
    static func login(language: String = RemotePage.language, message: String? = nil, name: String = "",
                      noAccounts: Bool = false) -> String {
        let en = language == "en"
        let title = en ? "PortaPack Remote Access" : "PortaPack Fernzugriff"
        let info = noAccounts
            ? (en ? "No account has been set up yet. Create one on the Mac under <b>Remote Access ▸ Accounts</b>."
                  : "Es ist noch kein Konto angelegt. Leg am Mac unter <b>Fernzugriff ▸ Konten</b> eines an.")
            : (en ? "Sign in with an account created on the Mac under Remote Access."
                  : "Melde dich mit einem Konto an, das am Mac unter Fernzugriff angelegt ist.")
        let error = message.map { "<p class=\"err\">\(escape($0))</p>" } ?? ""
        let form = noAccounts ? "" : """
            <form method="post" action="/login">
            <label>\(en ? "User name" : "Benutzername")<input name="name" autocomplete="username" autocapitalize="none" autocorrect="off" spellcheck="false" required maxlength="32" value="\(escape(name))"></label>
            <label>\(en ? "Password" : "Passwort")<input name="password" type="password" autocomplete="current-password" required maxlength="200"></label>
            <button type="submit">\(en ? "Sign in" : "Anmelden")</button>
            </form>
            """
        return """
        <!doctype html><html lang="\(en ? "en" : "de")"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <meta name="apple-mobile-web-app-capable" content="yes"><meta name="mobile-web-app-capable" content="yes">
        <meta name="apple-mobile-web-app-title" content="PortaPack"><meta name="theme-color" content="#1c1c1e">
        <link rel="manifest" href="/manifest.webmanifest"><link rel="apple-touch-icon" href="/icon-180.png">
        <title>PortaPack</title>
        <style>
        :root { color-scheme: light dark; --bg:#f2f2f7; --card:#fff; --text:#1c1c1e; --muted:#6e6e73; --line:#d1d1d6; --accent:#0a84ff; }
        @media (prefers-color-scheme: dark) { :root { --bg:#000; --card:#1c1c1e; --text:#f2f2f7; --muted:#98989d; --line:#38383a; } }
        body { margin:0; min-height:100vh; display:flex; align-items:center; justify-content:center; background:var(--bg); color:var(--text); font:16px -apple-system, system-ui, sans-serif; padding:16px; box-sizing:border-box; }
        main { width:100%; max-width:360px; background:var(--card); border-radius:16px; padding:24px; box-sizing:border-box; }
        h1 { font-size:22px; margin:0 0 8px; } p { color:var(--muted); margin:0 0 18px; line-height:1.4; }
        label { display:block; font-size:14px; color:var(--muted); margin-bottom:14px; }
        input { display:block; width:100%; box-sizing:border-box; margin-top:6px; padding:12px; font-size:17px; border:1px solid var(--line); border-radius:10px; background:var(--bg); color:var(--text); }
        button { width:100%; padding:13px; font-size:17px; font-weight:600; border:0; border-radius:10px; background:var(--accent); color:#fff; cursor:pointer; margin-top:6px; }
        .err { color:#ff3b30; }
        </style></head><body><main>
        <h1>\(title)</h1>
        \(error)<p>\(info)</p>
        \(form)
        </main></body></html>
        """
    }

    /// HTML-Maskierung für Texte, die in die Anmeldeseite eingesetzt werden.
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    static let html = #"""
    <!doctype html>
    <html lang="__LANG__">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
    <meta name="theme-color" content="#1c1c1e">
    <meta name="apple-mobile-web-app-capable" content="yes">
    <meta name="mobile-web-app-capable" content="yes">
    <meta name="apple-mobile-web-app-title" content="PortaPack">
    <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
    <link rel="apple-touch-icon" href="/icon-180.png">
    <link rel="icon" type="image/png" href="/icon-180.png">
    <link rel="manifest" href="/manifest.webmanifest">
    <title>PortaPack</title>
    <meta name="referrer" content="no-referrer">
    <link rel="stylesheet" href="/leaflet.css">
    <script src="/leaflet.js"></script>
    <style>
    :root { --bg:#f2f2f7; --card:#fff; --text:#1c1c1e; --muted:#6e6e73; --line:#d1d1d6; --accent:#0a84ff; --sel:#ff9f0a; --ok:#30a14e; --warn:#d70015; }
    @media (prefers-color-scheme: dark) { :root { --bg:#000; --card:#1c1c1e; --text:#f2f2f7; --muted:#98989d; --line:#38383a; --accent:#0a84ff; } }
    * { box-sizing:border-box; }
    html, body { margin:0; height:100%; background:var(--bg); color:var(--text); font:15px -apple-system, system-ui, sans-serif; }
    /* Safari vergrößert die Schrift sonst beim Drehen ins Querformat. */
    html { -webkit-text-size-adjust:100%; text-size-adjust:100%; }
    /* Die Web-App reicht unten nicht ganz bis zum Rand (Home-Leiste) – dort scheint html durch.
       In Listenfarbe läuft die Liste optisch bis unten durch (vorher grauer Streifen). */
    @media (max-width: 760px) { html { background:var(--card); } }
    header { display:flex; gap:8px; align-items:center; padding:10px 12px; padding-top:calc(env(safe-area-inset-top) + 14px); background:var(--card); border-bottom:1px solid var(--line); flex-wrap:wrap; }
    header h1 { font-size:16px; margin:0 8px 0 0; }
    /* Menü statt Reiterleiste (28.10.2026: acht Empfänger passten nicht mehr in eine Zeile). */
    #menubtn { display:flex; align-items:center; gap:8px; border:0; background:var(--bg); color:var(--text); border-radius:9px; padding:6px 12px; font:600 16px -apple-system, system-ui, sans-serif; cursor:pointer; }
    #menubtn #menuicon { font-size:20px; line-height:1; display:flex; }
    #menubtn .chev { color:var(--muted); font-size:13px; }
    .tabs { display:none; position:fixed; z-index:3000; left:10px; top:calc(env(safe-area-inset-top) + 64px); flex-direction:column; gap:2px; background:var(--card); border-radius:14px; padding:6px; box-shadow:0 8px 30px rgba(0,0,0,.25); min-width:220px; max-height:calc(100% - 90px); overflow:auto; }
    .tabs.open { display:flex; }
    .tabs button { border:0; background:transparent; color:var(--text); padding:10px 12px; border-radius:9px; font:20px/1 -apple-system, system-ui, sans-serif; cursor:pointer; display:grid; grid-template-columns:28px 1fr; justify-items:center; align-items:center; gap:10px; text-align:left; }
    .tabs button small { justify-self:start; }
    .tabs button > :first-child, .tabs button { min-width:0; }
    .tabs button small { font-size:16px; line-height:1.2; font-weight:500; color:var(--text); white-space:nowrap; }
    .tabs button.on { background:var(--accent); color:#fff; }
    .tabs button.on small { color:#fff; }
    .iconbtn { border:0; border-radius:8px; background:var(--line); color:var(--text); width:34px; height:28px; margin-left:6px; display:inline-flex; align-items:center; justify-content:center; cursor:pointer; vertical-align:middle; padding:0; }
    .iconbtn.on { background:var(--accent); color:#fff; }
    /* Konto unten im Menü; „Nur ansehen“ blendet Start/Stopp, Optimieren und das globale Stopp aus. */
    .tabs .who { display:flex; align-items:center; gap:10px; border-top:1px solid var(--line); margin-top:4px; padding:10px 12px 4px; }
    .tabs .who span { flex:1; min-width:0; color:var(--muted); font-size:14px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
    .tabs .who input { border:0; border-radius:8px; background:var(--line); color:var(--text); padding:7px 12px; font:14px -apple-system, system-ui, sans-serif; cursor:pointer; }
    .viewer #runbar [data-run], .viewer [data-stop], .viewer [data-gain] { display:none !important; }
    .status { margin-left:auto; color:var(--muted); font-size:14px; }
    @media (max-width: 560px) {
      /* Kompakt (27.10.2026: Reiter, Statuszeile und Optimieren-Leiste nahmen der Karte zu viel Höhe). */
      /* Oben 16 px Luft: iOS 26 legt unter die Statusleiste einen Unschärfe-Streifen,
         mit 4 px verschwamm die obere Hälfte der Reitersymbole (28.10.2026). */
      header { gap:6px; padding:6px 10px; padding-top:calc(env(safe-area-inset-top) + 16px); }
      header h1 { display:none; }
      .tabs { top:calc(env(safe-area-inset-top) + 58px); }
      .status { width:100%; margin-left:0; font-size:13px; }
      .meter { width:50px; }
    }
    .dot { display:inline-block; width:8px; height:8px; border-radius:50%; background:var(--muted); margin-right:5px; }
    .dot.on { background:var(--ok); }
    .level { margin-left:10px; white-space:nowrap; }
    .meter { display:inline-block; position:relative; width:70px; height:6px; border-radius:3px; background:var(--line); margin-right:6px; vertical-align:middle; overflow:hidden; }
    .meter i { position:absolute; left:0; top:0; bottom:0; border-radius:3px; }
    .meter b { position:absolute; top:0; bottom:0; width:2px; margin-left:-1px; background:var(--text); opacity:.6; }
    /* Kopf jedes Empfänger-Reiters: großer Start-/Stopp-Knopf und was gerade läuft
       (29.10.2026, ersetzt das Banner „Auf X umschalten“). */
    #runbar { display:none; align-items:center; gap:6px 10px; flex-wrap:wrap; padding:8px 12px; background:var(--card); border-bottom:1px solid var(--line); min-width:0; }
    #runbar.plan { background:#fff4d6; color:#5c4400; }
    @media (prefers-color-scheme: dark) { #runbar.plan { background:#3a2e00; color:#ffd60a; } }
    #runbar .runbtn { flex:none; border:0; border-radius:10px; padding:8px 18px; min-width:120px; font:600 16px -apple-system, system-ui, sans-serif; cursor:pointer; background:var(--ok); color:#fff; }
    #runbar .runbtn.stop { background:var(--warn); }
    #runbar .runbtn:disabled { opacity:.55; cursor:default; }
    #runbar .runinfo { flex:1 1 160px; min-width:0; font-size:13px; color:var(--muted); overflow-wrap:anywhere; }
    #runbar .runinfo b { color:var(--text); font-weight:600; }
    #runbar.plan .runinfo, #runbar.plan .runinfo b { color:inherit; }
    @media (max-width: 560px) { #runbar { padding:6px 10px; } #runbar .runbtn { padding:7px 14px; min-width:104px; font-size:15px; } }
    .btn { border:0; background:var(--accent); color:#fff; padding:6px 12px; border-radius:8px; font:inherit; cursor:pointer; margin-left:8px; }
    .btn.secondary { background:var(--line); color:var(--text); }
    .stopbtn { background:var(--line); color:var(--text); }
    .stopbtn { border:0; border-radius:7px; padding:3px 9px; margin-left:8px; font:13px -apple-system, system-ui, sans-serif; cursor:pointer; vertical-align:1px; }
    .stopbtn.on { background:var(--accent); color:#fff; }
    #gainbar { display:none; padding:6px 12px; background:var(--card); border-bottom:1px solid var(--line); font-size:13px; }
    #gainbar .gline { display:flex; flex-wrap:wrap; gap:6px 12px; align-items:center; }
    #gainbar .btn { margin-left:0; padding:5px 10px; font-size:14px; }
    #gainbar .gstat { color:var(--accent); font-variant-numeric:tabular-nums; }
    #gainbar label { display:flex; gap:6px; align-items:center; color:var(--text); cursor:pointer; }
    #gainbar input[type=checkbox] { width:18px; height:18px; margin:0; }
    #gainbar .hint { margin-top:3px; }
    /* Fest am Bildschirm: iOS schiebt sonst die ganze Seite samt Kopf unter die Statusleiste. */
    body { position:fixed; inset:0; overflow:hidden; display:flex; flex-direction:column; }
    header, #runbar, #gainbar { flex:none; }
    main { display:flex; flex:1; min-height:0; }
    #mapwrap { flex:1; position:relative; min-height:300px; }
    #map { position:absolute; inset:0; }
    #side { width:360px; overflow:auto; background:var(--card); border-left:1px solid var(--line); }
    @media (max-width: 760px) { main { flex-direction:column; } #mapwrap { flex:none; height:50%; } #side { width:auto; flex:1; min-height:0; border-left:0; border-top:1px solid var(--line); padding-bottom:env(safe-area-inset-bottom); } }
    .row { padding:9px 12px; border-bottom:1px solid var(--line); cursor:pointer; display:flex; gap:8px; align-items:baseline; }
    .row:hover { background:var(--bg); }
    .row.sel { background:rgba(255,159,10,.15); }
    .row .t { font-weight:600; font-family:ui-monospace, Menlo, monospace; }
    .row .s { color:var(--muted); font-size:13px; flex:1; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
    .row .r { color:var(--muted); font-size:13px; white-space:nowrap; }
    .empty { padding:24px 12px; color:var(--muted); }
    #card { position:absolute; top:10px; right:10px; z-index:1000; width:320px; max-height:calc(100% - 20px); overflow:auto; background:var(--card); color:var(--text); border-radius:12px; box-shadow:0 4px 18px rgba(0,0,0,.3); padding:10px 12px; display:none; border:1px solid var(--sel); }
    /* Schmal: eigenes Blatt über Karte und Liste, unten angedockt. */
    @media (max-width: 760px) { #card { position:fixed; left:0; right:0; bottom:0; top:auto; width:auto; max-height:72%; z-index:2000; border-radius:16px 16px 0 0; border:0; border-top:2px solid var(--sel); padding:8px 16px calc(14px + env(safe-area-inset-bottom)); box-shadow:0 -6px 24px rgba(0,0,0,.35); font-size:16px; -webkit-overflow-scrolling:touch; }
      #card::before { content:''; display:block; width:40px; height:5px; border-radius:3px; background:var(--line); margin:0 auto 8px; }
      #card h3 { font-size:20px; } #card img { max-height:190px; object-fit:cover; } }
    #card h3 { margin:0; font-family:ui-monospace, Menlo, monospace; display:flex; justify-content:space-between; }
    #card h3 button { border:0; background:none; color:var(--muted); font-size:18px; cursor:pointer; }
    #card .sub { color:var(--muted); font-size:12px; margin-bottom:6px; }
    #card img { width:100%; border-radius:8px; display:block; margin:6px 0 2px; }
    #card .credit { font-size:11px; color:var(--muted); }
    #card .credit a { color:var(--muted); }
    #card table { border-collapse:collapse; width:100%; margin-top:6px; }
    #card td { padding:2px 0; vertical-align:top; }
    #card td:first-child { color:var(--muted); padding-right:10px; white-space:nowrap; }
    .sym { display:block; overflow:visible; filter:drop-shadow(0 0 1px rgba(255,255,255,.95)) drop-shadow(0 1px 1px rgba(0,0,0,.35)); }
    .lbl { font:600 11px -apple-system, system-ui; color:#000; background:rgba(255,255,255,.8); padding:0 3px; border-radius:3px; white-space:nowrap; position:absolute; top:20px; left:50%; transform:translateX(-50%); }
    .stale .lbl { color:#666; }
    #radio { flex:1; overflow:auto; padding:12px; padding-bottom:max(12px, env(safe-area-inset-bottom)); display:none; }
    /* Senderfeld bleibt stehen, die Liste läuft darunter durch; die Hülle in Hintergrundfarbe deckt den Rand ab. */
    /* top −12px: der Haftrand zählt ab der Innenkante (Polsterung von #radio). */
    .nowwrap { position:sticky; top:-12px; z-index:2; margin:-12px -12px 0; padding:12px; background:var(--bg); }
    .now { background:var(--card); border-radius:12px; padding:14px; }
    .now .name { font-size:20px; font-weight:600; }
    .now .dls { color:var(--muted); margin:6px 0 10px; min-height:1.2em; }
    .now audio { width:100%; }
    .ens { background:var(--card); border-radius:12px; margin-bottom:12px; overflow:hidden; }
    .ens h4 { margin:0; padding:8px 12px; font-size:13px; color:var(--muted); border-bottom:1px solid var(--line); }
    .svc { padding:10px 12px; border-bottom:1px solid var(--line); cursor:pointer; display:flex; justify-content:space-between; }
    .svc.on { color:var(--accent); font-weight:600; }
    .svc:last-child { border-bottom:0; }
    .hint { color:var(--muted); font-size:13px; }
    #acars { flex:1; overflow:auto; display:none; background:var(--card); padding-bottom:env(safe-area-inset-bottom); }
    .msg { padding:8px 12px; border-bottom:1px solid var(--line); cursor:pointer; }
    .msg .head { display:flex; gap:8px; align-items:baseline; }
    .msg .reg { font-family:ui-monospace, Menlo, monospace; font-weight:600; }
    .msg .flt { color:var(--muted); font-size:13px; }
    .msg .lab { font-size:11px; background:var(--bg); border-radius:4px; padding:1px 5px; color:var(--muted); }
    .msg .time { margin-left:auto; color:var(--muted); font-size:13px; font-variant-numeric:tabular-nums; white-space:nowrap; }
    .msg .sum { margin-top:2px; font-size:15px; }
    .msg .sum.opaque { color:var(--muted); }
    .msg .more { display:none; margin-top:6px; font-size:14px; }
    .msg.open .more { display:block; }
    .msg .more table { border-collapse:collapse; }
    .msg .more td { padding:1px 0; vertical-align:top; } .msg .more td:first-child { color:var(--muted); padding-right:10px; white-space:nowrap; }
    .msg .raw { font-family:ui-monospace, Menlo, monospace; font-size:12px; white-space:pre-wrap; word-break:break-all; background:var(--bg); border-radius:6px; padding:6px; margin-top:6px; }
    .msg .up { color:var(--accent); }
    #spec { flex:1; flex-direction:column; min-height:0; display:none; background:var(--card); padding-bottom:env(safe-area-inset-bottom); }
    .specbar { display:flex; flex-wrap:wrap; gap:6px; padding:8px; border-bottom:1px solid var(--line); align-items:center; }
    .specbar select, .specbar input { font:15px -apple-system, system-ui, sans-serif; padding:5px; border-radius:7px; border:1px solid var(--line); background:var(--bg); color:var(--text); }
    .specbar select#sppreset { flex:1 1 100%; min-width:0; max-width:100%; box-sizing:border-box; }
    .specbar input#spmhz { width:96px; }
    .specbar button { border:0; background:var(--bg); color:var(--text); padding:6px 10px; border-radius:7px; font:15px -apple-system, system-ui, sans-serif; cursor:pointer; }
    .specbar label { font-size:13px; color:var(--muted); display:flex; gap:4px; align-items:center; }
    #spinfo { padding:4px 10px; font-size:13px; color:var(--muted); font-variant-numeric:tabular-nums; }
    #spcanvas { width:100%; height:190px; display:block; touch-action:manipulation; cursor:crosshair; }
    #wfcanvas { width:100%; flex:1; min-height:120px; display:block; background:#000; }
    #wx { flex:1; overflow:auto; padding:12px; padding-bottom:max(12px, env(safe-area-inset-bottom)); display:none; }
    .box { background:var(--card); border-radius:12px; margin-bottom:12px; overflow:hidden; }
    .box h4 { margin:0; padding:8px 12px; font-size:13px; color:var(--muted); border-bottom:1px solid var(--line); }
    /* Einklappbare Kästen im Wetter-Reiter (<details>). */
    details.box > summary { list-style:none; cursor:pointer; -webkit-user-select:none; user-select:none; }
    details.box > summary::-webkit-details-marker { display:none; }
    details.box > summary h4 { display:flex; justify-content:space-between; align-items:center; }
    details.box > summary h4::after { content:'›'; font-size:18px; line-height:1; transform:rotate(90deg); transition:transform .15s; }
    details.box:not([open]) > summary h4 { border-bottom:0; }
    details.box:not([open]) > summary h4::after { transform:rotate(0deg); }
    details.box > summary .count { margin-left:auto; margin-right:8px; font-weight:400; }
    .item { padding:9px 12px; border-bottom:1px solid var(--line); display:flex; gap:10px; align-items:center; }
    .item:last-child { border-bottom:0; }
    .item .grow { flex:1; min-width:0; }
    .item .sub { color:var(--muted); font-size:13px; }
    .item .el { font-variant-numeric:tabular-nums; }
    .rec { color:var(--accent); }
    .sw { display:flex; justify-content:space-between; align-items:center; padding:10px 12px; border-bottom:1px solid var(--line); }
    .sw input[type=checkbox] { width:22px; height:22px; }
    .sw select { font:inherit; }
    .gallery { display:grid; grid-template-columns:repeat(auto-fill, minmax(150px, 1fr)); gap:8px; padding:8px; }
    .gallery figure { margin:0; cursor:pointer; }
    .gallery img { width:100%; aspect-ratio:1; object-fit:cover; border-radius:8px; background:#000; display:block; }
    .gallery figcaption { font-size:12px; color:var(--muted); margin-top:3px; }
    .running { padding:10px 12px; color:var(--warn); font-weight:600; }
    .running .skip { border:0; border-radius:8px; padding:6px 12px; background:var(--bg); color:var(--text); font:600 14px -apple-system, system-ui, sans-serif; cursor:pointer; }
    #viewer { position:fixed; inset:0; z-index:3000; background:#000; display:none; flex-direction:column; }
    #viewer img { flex:1; min-height:0; width:100%; object-fit:contain; }
    #viewer .cap { color:#ddd; padding:10px 14px calc(10px + env(safe-area-inset-bottom)); font-size:14px; }
    .mapbtns { display:flex; flex-direction:column; }
    .mapbtns a { width:34px; height:34px; line-height:34px; text-align:center; font-size:18px; background:var(--card); color:var(--text); text-decoration:none; border-bottom:1px solid var(--line); cursor:pointer; }
    .mapbtns a:last-child { border-bottom:0; }
    .mapbtns a.on { background:var(--accent); color:#fff; }
    .archbar { padding:8px 12px; border-bottom:1px solid var(--line); display:flex; gap:8px; align-items:center; position:sticky; top:0; background:var(--card); z-index:1; }
    .archbar select { font:inherit; flex:1; }
    .daypick { position:relative; flex:1; min-width:0; }
    .daypick span { display:block; text-align:center; font-weight:600; padding:4px 6px; border-radius:8px; background:var(--line); white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
    .daypick input { position:absolute; inset:0; width:100%; height:100%; opacity:0; border:0; padding:0; margin:0; cursor:pointer; }
    .archbar .iconbtn { margin-left:0; flex:none; font-size:18px; }
    .archbar .iconbtn:disabled { opacity:.35; cursor:default; }
    .sortbar { display:flex; gap:4px; padding:6px 8px; border-bottom:1px solid var(--line); position:sticky; top:0; background:var(--card); z-index:1; }
    .sortbar button { flex:1; border:0; background:var(--bg); color:var(--text); padding:6px 4px; border-radius:7px; font:13px -apple-system, system-ui, sans-serif; cursor:pointer; }
    .sortbar button.on { background:var(--accent); color:#fff; font-weight:600; }
    /* Zigbee: Netzkarte (Canvas) und Geräteliste, Aufteilung wie Karte/Liste. */
    #zb { flex:1; display:none; min-height:0; }
    .xtab { flex:1; min-width:0; overflow:auto; padding:12px; padding-bottom:max(12px, env(safe-area-inset-bottom)); display:none; }
    .xtab .item .grow { min-width:0; overflow:hidden; text-overflow:ellipsis; }
    #ab { flex:1; min-width:0; overflow:auto; padding:12px; padding-bottom:max(12px, env(safe-area-inset-bottom)); display:none; }
    .abadd { display:flex; gap:6px; padding:8px; flex-wrap:wrap; }
    .abadd input { flex:1; min-width:120px; font:16px -apple-system, system-ui, sans-serif; border:1px solid var(--line); border-radius:8px; padding:7px 9px; background:var(--bg); color:var(--text); }
    .abadd .btn { margin-left:0; }
    .abtx { margin:2px 0; line-height:1.3; }
    #ab .item .grow { min-width:0; overflow:hidden; text-overflow:ellipsis; }
    .abch .lvl { width:70px; height:6px; border-radius:3px; background:var(--line); overflow:hidden; flex:none; }
    .abch .lvl i { display:block; height:100%; background:var(--ok); }
    .abch.open { background:color-mix(in srgb, var(--ok) 14%, transparent); }
    .abch.aud { background:color-mix(in srgb, var(--accent) 18%, transparent); }
    .abch .tools { display:flex; gap:4px; }
    .abch .tools button, .abfind button { border:0; background:var(--bg); color:var(--text); border-radius:7px; padding:5px 8px; font:14px -apple-system, system-ui, sans-serif; cursor:pointer; }
    .abch .tools button.on { background:var(--accent); color:#fff; }
    .abbar { display:flex; gap:8px; align-items:center; flex-wrap:wrap; padding:10px 12px; }
    .abbar .btn { margin-left:0; }
    #zbmapwrap { flex:1; position:relative; min-height:260px; background:var(--card); overflow:hidden; }
    #zbcanvas { position:absolute; inset:0; width:100%; height:100%; display:block; touch-action:none; cursor:grab; }
    #zbtools { position:absolute; top:10px; left:10px; z-index:2; border-radius:8px; overflow:hidden; box-shadow:0 1px 4px rgba(0,0,0,.3); }
    #zblegend { position:absolute; left:8px; bottom:8px; z-index:2; font-size:12px; color:var(--muted); background:var(--card); border:1px solid var(--line); border-radius:8px; padding:4px 8px; display:flex; gap:4px 10px; flex-wrap:wrap; align-items:center; max-width:calc(100% - 16px); }
    #zblegend i { display:inline-block; width:9px; height:9px; border-radius:50%; margin-right:4px; vertical-align:-1px; }
    @media (max-width: 560px) { #zblegend .wide { display:none; } }
    #zblegend label { display:flex; gap:4px; align-items:center; color:var(--text); }
    #zblist { width:360px; overflow:auto; background:var(--card); border-left:1px solid var(--line); }
    #zblist .sortbar select { flex:1; min-width:0; font:13px -apple-system, system-ui, sans-serif; border:0; border-radius:7px; background:var(--bg); color:var(--text); padding:6px 4px; }
    @media (max-width: 760px) { #zb { flex-direction:column; } #zbmapwrap { flex:none; height:50%; } #zblist { width:auto; flex:1; min-height:0; border-left:0; border-top:1px solid var(--line); padding-bottom:env(safe-area-inset-bottom); } }
    #zbcard { position:absolute; top:10px; right:10px; z-index:3; width:300px; max-height:calc(100% - 20px); overflow:auto; background:var(--card); border-radius:12px; box-shadow:0 4px 18px rgba(0,0,0,.3); padding:10px 12px; display:none; border:1px solid var(--sel); }
    @media (max-width: 760px) { #zbcard { position:fixed; left:0; right:0; bottom:0; top:auto; width:auto; max-height:60%; z-index:2000; border-radius:16px 16px 0 0; border:0; border-top:2px solid var(--sel); padding:8px 16px calc(14px + env(safe-area-inset-bottom)); box-shadow:0 -6px 24px rgba(0,0,0,.35); font-size:16px; }
      #zbcard::before { content:''; display:block; width:40px; height:5px; border-radius:3px; background:var(--line); margin:0 auto 8px; } }
    #zbcard h3 { margin:0; display:flex; justify-content:space-between; gap:8px; }
    #zbcard h3 button { border:0; background:none; color:var(--muted); font-size:18px; cursor:pointer; }
    #zbcard .sub { color:var(--muted); font-size:13px; margin-bottom:6px; }
    #zbcard table { border-collapse:collapse; width:100%; margin-top:4px; }
    #zbcard td { padding:2px 0; vertical-align:top; }
    #zbcard td:first-child { color:var(--muted); padding-right:10px; white-space:nowrap; }
    #err { position:fixed; bottom:12px; left:50%; transform:translateX(-50%); background:var(--warn); color:#fff; padding:8px 14px; border-radius:8px; display:none; z-index:2000; }
      .trkarrow{background:none;border:0}.trkarrow div{font-size:10px;line-height:12px;text-align:center;text-shadow:0 0 2px rgba(0,0,0,.6)}
    /* Flugplätze auf der Flugzeugkarte: dezent, Kennung rechts daneben. */
    .leaflet-tooltip.aplbl { background:rgba(255,255,255,.8); color:#3a3a3c; border:0; box-shadow:none; padding:0 3px; font-size:10px; line-height:13px; }
    .leaflet-tooltip.aplbl::before { display:none; }
    .aph { background:none; border:0; }
    .aph div { width:12px; height:12px; border-radius:50%; background:rgba(255,255,255,.8); border:1px solid #5e5ce6; color:#5e5ce6; font:700 8px/12px -apple-system, system-ui, sans-serif; text-align:center; box-sizing:border-box; }
    .appop b { font-variant-numeric:tabular-nums; }
    .appop .hint { color:#6e6e73; font-size:12px; }
    </style>
    </head>
    <body>
    <header>
      <h1>PortaPack</h1>
      <button id="menubtn" aria-label="Empfänger wählen" aria-haspopup="true" aria-expanded="false"><span id="menuicon"></span><span id="menutitle"></span><span class="chev">▾</span></button>
      <nav class="tabs" id="menu">
        <button data-tab="adsb" title="Flugzeuge" aria-label="Flugzeuge">✈︎<small>Flugzeuge</small></button>
        <button data-tab="acars" title="ACARS & VDL2 (Datenfunk der Flugzeuge)" aria-label="ACARS"><svg width="24" height="20" viewBox="0 0 24 20" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linejoin="round" style="vertical-align:-3px"><path d="M3 2h18v12H9l-5 4v-4H3z"/><path d="M7 6h10M7 10h6" stroke-linecap="round"/></svg><small>Flugzeug-Datenfunk</small></button>
        <button data-tab="airband" title="Flugfunk: Sprechfunk 118–137 MHz" aria-label="Flugfunk"><svg width="24" height="20" viewBox="0 0 24 20" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" style="vertical-align:-3px"><path d="M4 14v-3a8 8 0 0 1 16 0v3"/><rect x="2.5" y="12" width="4.5" height="7" rx="1.5" fill="currentColor"/><rect x="17" y="12" width="4.5" height="7" rx="1.5" fill="currentColor"/></svg><small>Flugfunk (Sprechfunk)</small></button>
        <button data-tab="ais" title="Schiffe" aria-label="Schiffe">⚓︎<small>Schiffe</small></button>
        <button data-tab="dsc" title="Seefunk-Notruf (DSC)" aria-label="Seefunk-Notruf (DSC)"><b style="font:800 13px -apple-system,system-ui,sans-serif;letter-spacing:-.5px">SOS</b><small>Seefunk-Notruf (DSC)</small></button>
        <button data-tab="wx" title="Wetter: Satelliten und Sonden" aria-label="Wetter"><svg width="26" height="20" viewBox="0 0 26 20" fill="currentColor" style="vertical-align:-3px"><path d="M7 19a6 6 0 0 1-.6-12A7.5 7.5 0 0 1 20.6 8.2 5.5 5.5 0 0 1 20 19z"/></svg><small>Wetter & Satelliten</small></button>
        <button data-tab="dab" title="Digitalradio (DAB+)" aria-label="Digitalradio (DAB+)">♫<small>Digitalradio</small></button>
        <button data-tab="fm" title="Radio (UKW/AM)" aria-label="Radio (UKW/AM)"><svg width="24" height="20" viewBox="0 0 24 20" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="vertical-align:-3px"><rect x="2.5" y="7" width="19" height="11" rx="2"/><path d="M6 7l11-5"/><circle cx="16" cy="12.5" r="2.4"/><path d="M5.5 11h5M5.5 14h5"/></svg><small>Radio (UKW/AM)</small></button>
        <button data-tab="spectrum" title="Spektrum" aria-label="Spektrum"><svg width="24" height="20" viewBox="0 0 24 20" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linejoin="round" stroke-linecap="round" style="vertical-align:-3px"><path d="M1 17h3l2-4 2 3 3-13 3 13 2-5 2 6h5"/></svg><small>Spektrum</small></button>
        <button data-tab="occupancy" title="Belegungsmonitor" aria-label="Belegungsmonitor"><svg width="24" height="20" viewBox="0 0 24 20" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="vertical-align:-3px"><path d="M4 18V11M9 18V5M14 18V9M19 18V13"/></svg><small>Belegungsmonitor</small></button>
        <button data-tab="sensors" title="Funksensoren" aria-label="Funksensoren"><svg width="24" height="20" viewBox="0 0 24 20" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="vertical-align:-3px"><path d="M10 3a2 2 0 0 1 4 0v9.5a4 4 0 1 1-4 0z"/><path d="M12 9v6"/></svg><small>Funksensoren</small></button>
        <button data-tab="smart868" title="Smart Home 868 MHz" aria-label="Smart Home 868 MHz"><svg width="24" height="20" viewBox="0 0 24 20" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="vertical-align:-3px"><path d="M3 10l9-7 9 7"/><path d="M5.5 8.5V18h13V8.5"/><path d="M10 18v-5h4v5"/></svg><small>Smart Home 868</small></button>
        <button data-tab="zigbee" title="Zigbee: Geräte und Netzkarte" aria-label="Zigbee"><svg width="24" height="20" viewBox="0 0 24 20" fill="currentColor" stroke="currentColor" stroke-width="1.8" style="vertical-align:-3px"><path d="M12 4L5 15M12 4l7 11M5 15h14" fill="none"/><circle cx="12" cy="4" r="3"/><circle cx="5" cy="15" r="3"/><circle cx="19" cy="15" r="3"/></svg><small>Zigbee</small></button>
        <button data-tab="ft8" title="FT8/WSPR" aria-label="FT8/WSPR"><svg width="24" height="20" viewBox="0 0 24 20" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="vertical-align:-3px"><circle cx="12" cy="10" r="8"/><path d="M4 10h16M12 2c3 3 3 13 0 16M12 2c-3 3-3 13 0 16"/></svg><small>FT8/WSPR</small></button>
        <form class="who" method="post" action="/logout"><span id="whoami"></span><input type="submit" id="logoutbtn" value="Abmelden"></form>
      </nav>
      <span class="status" id="status"></span>
    </header>
    <div id="runbar"></div>
    <div id="gainbar"></div>
    <main>
      <div id="mapwrap"><div id="map"></div><div id="card"></div></div>
      <div id="side"></div>
      <div id="radio"></div>
      <div id="acars"></div>
      <div id="spec">
        <div class="specbar">
          <select id="sppreset"><option value="">Vorlage wählen …</option></select>
          <button id="spdown" aria-label="Tiefer">◀︎</button>
          <input id="spmhz" type="number" inputmode="decimal" step="0.001" min="1" max="6000" aria-label="Mitte in MHz">
          <button id="spup" aria-label="Höher">▶︎</button>
          <select id="spbw" aria-label="Bandbreite"></select>
          <label>LNA <select id="splna"></select></label>
          <label>VGA <select id="spvga"></select></label>
          <label><input type="checkbox" id="spamp"> Eingebauter Verstärker (+14 dB)</label>
        </div>
        <div id="spinfo"></div>
        <canvas id="spcanvas"></canvas>
        <canvas id="wfcanvas"></canvas>
      </div>
      <div id="wx"></div>
      <div id="x-fm" class="xtab"></div>
      <div id="x-sensors" class="xtab"></div>
      <div id="x-smart868" class="xtab"></div>
      <div id="x-dsc" class="xtab"></div>
      <div id="x-ft8" class="xtab"></div>
      <div id="x-occupancy" class="xtab"></div>
      <div id="ab">
        <div id="abhead"></div>
        <div class="box abadd">
          <input id="abnew" inputmode="decimal" placeholder="Kanal oder MHz, z. B. 124.315" aria-label="Kanal">
          <input id="abname" placeholder="Name (optional)" aria-label="Name">
          <button class="btn" id="abaddbtn">Hinzufügen</button>
        </div>
        <div id="ablist"></div>
        <div class="box abadd">
          <input id="absearch" type="search" placeholder="In Abschriften suchen" aria-label="In Abschriften suchen">
          <button class="btn" id="absearchbtn">Suchen</button>
        </div>
        <div id="abresults"></div>
      </div>
      <div id="zb">
        <div id="zbmapwrap">
          <canvas id="zbcanvas"></canvas>
          <div id="zbtools" class="mapbtns">
            <a id="zbin" title="Vergrößern" aria-label="Vergrößern">+</a>
            <a id="zbout" title="Verkleinern" aria-label="Verkleinern">−</a>
            <a id="zbreset" title="Ganzes Netz zeigen" aria-label="Ganzes Netz zeigen">⤢</a>
          </div>
          <div id="zblegend">
            <span><i style="background:#ff9f0a"></i>Koordinator</span>
            <span><i style="background:#0a84ff"></i>Router</span>
            <span><i style="background:#30a14e"></i>Endgerät</span>
            <span class="wide">Linie grün = gut, rot = schlecht</span>
            <label><input type="checkbox" id="zball"> Alle Verbindungen</label>
          </div>
          <div id="zbcard"></div>
        </div>
        <div id="zblist"></div>
      </div>
    </main>
    <div id="viewer"><img alt=""><div class="cap"></div></div>
    <div id="err"></div>
    <script type="application/json" id="i18n">__I18N__</script>
    <script>
    // Angemeldetes Konto und Rolle (RemotePage.page). „view“ = nur ansehen: Der Mac
    // lehnt jedes Umschalten ab, die Seite blendet die Bedienknöpfe aus.
    const USER = '__USER__';
    const ROLE = '__ROLE__' === 'view' ? 'view' : 'control';
    if (ROLE === 'view') document.documentElement.classList.add('viewer');
    // Sprache der App, beim Ausliefern eingesetzt (RemotePage.page): Deutsch ist
    // Schlüssel und Rückfall, Englisch kommt als Wörterbuch (RemotePageEnglish).
    // t("Text mit {0}", x) setzt Platzhalter ein – Sätze immer als Ganzes übersetzen.
    // t() liefert HTML: eingesetzte Werte gehen immer durch esc(), nur raw('<b>…</b>')
    // bleibt, wie es ist. tt() liefert Klartext (für textContent oder ein äußeres esc()).
    const LANG = '__LANG__' === 'en' ? 'en' : 'de';
    const LOCALE = LANG === 'en' ? 'en-US' : 'de-DE';
    const EN = (() => { if (LANG !== 'en') return {}; try { return JSON.parse(document.getElementById('i18n').textContent); } catch (e) { return {}; } })();
    // Dezimaltrenner der Sprache für schon formatierte Zahlen ('12.5' → '12,5').
    const dec = s => LANG === 'en' ? String(s) : String(s).replace('.', ',');
    function tt(s, ...a) {
      const r = (LANG === 'en' && EN[s]) || s;
      return a.length ? r.replace(/\{(\d+)\}/g, (m, i) => a[i] == null ? '' : String(a[i])) : r;
    }
    class Raw { constructor(html) { this.html = html; } toString() { return this.html; } }
    const raw = html => new Raw(html);
    function t(s, ...a) {
      return tt(s, ...a.map(x => x == null ? x : x instanceof Raw ? x.html : esc(x)));
    }
    // Feste Texte im HTML (Menü, Spektrumleiste, Flugfunk, Zigbee-Legende) einmal übersetzen.
    (function localizeStatic(root) {
      if (LANG !== 'en') return;
      const w = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
      for (let n = w.nextNode(); n; n = w.nextNode()) {
        const s = n.nodeValue.trim();
        if (s && EN[s]) n.nodeValue = n.nodeValue.replace(s, () => EN[s]);
      }
      root.querySelectorAll('[title],[aria-label],[placeholder]').forEach(el => ['title', 'aria-label', 'placeholder'].forEach(a => {
        const v = el.getAttribute(a); if (v && EN[v]) el.setAttribute(a, EN[v]);
      }));
    })(document.body);
    // Angemeldet ist, wer das Sitzungs-Cookie hat (vom Server gesetzt, HttpOnly,
    // SameSite=Strict) – Skripte kommen nicht daran.
    // Namen wie im Menü (Kopf „Gerade läuft: …“).
    const TITLES = { adsb: t('Flugzeuge'), ais: t('Schiffe'), dab: t('Digitalradio (DAB+)'), acars: t('Flugzeug-Datenfunk'), spectrum: t('Spektrum'), wx: t('Wetter & Satelliten'), zigbee: 'Zigbee', airband: t('Flugfunk (Sprechfunk)'),
      fm: t('Radio (UKW/AM)'), sensors: t('Funksensoren'), smart868: t('Smart Home 868'), dsc: t('Seefunk-Notruf (DSC)'), ft8: 'FT8/WSPR', occupancy: t('Belegungsmonitor') };
    const TABS = ['adsb', 'acars', 'airband', 'ais', 'dsc', 'wx', 'dab', 'fm', 'spectrum', 'occupancy', 'sensors', 'smart868', 'zigbee', 'ft8'];
    // Weitere Reiter (28.10.2026): je ein Bereich <div id="x-<tab>"> und ein Block
    // „---------- <Name> ----------“ mit loadX/renderX/xStatus.
    const EXTRA_TABS = ['fm', 'sensors', 'smart868', 'dsc', 'ft8', 'occupancy'];
    // Reiter: aus der Adresse (#ais), sonst gemerkt, sonst beim ersten Abruf der laufende Empfänger.
    let tab = TABS.includes(location.hash.slice(1)) ? location.hash.slice(1) : localStorage.getItem('tab');
    let tabFromState = !tab;
    if (!tab) tab = 'adsb';
    let sel = null, state = null, fitted = { adsb: false, ais: false };
    const $ = id => document.getElementById(id);
    function esc(s) { return String(s ?? '').replace(/[&<>"']/g, c => ({ '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;' }[c])); }

    // Jede Anfrage an /api/ trägt den eigenen Kopf X-PortaPack: 1. Ohne ihn lehnt der
    // Mac ab – ein <img> oder Formular einer anderen Seite (auch eines anderen Ports
    // derselben Adresse) kann ihn nicht setzen.
    async function api(path, params = {}) {
      const r = await fetch(path + '?' + new URLSearchParams(params), { credentials: 'same-origin', headers: { 'X-PortaPack': '1' } });
      // Abgemeldet (Passwort geändert, Konto gelöscht): zurück zur Anmeldung.
      if (r.status === 401) { location.replace('/'); throw new Error(tt('Bitte neu anmelden.')); }
      if (!r.ok) throw new Error(await r.text());
      return r.json();
    }
    function showError(e) { const el = $('err'); el.textContent = e.message || e; el.style.display = 'block'; setTimeout(() => el.style.display = 'none', 5000); }

    // ---------- Karte ----------
    const map = L.map('map', { zoomControl: true }).setView([53.5, 10], 7);
    // Die Liste wächst und schrumpft mit – die Karte muss ihre Größe neu lesen.
    new ResizeObserver(() => map.invalidateSize()).observe(document.getElementById('mapwrap'));
    L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', { maxZoom: 18, attribution: '© OpenStreetMap' }).addTo(map);
    const layer = L.layerGroup().addTo(map);
    // Knöpfe unter dem Zoom: alle zeigen, Archiv.
    const MapButtons = L.Control.extend({ options: { position: 'topleft' }, onAdd() {
      const box = L.DomUtil.create('div', 'leaflet-bar mapbtns');
      box.innerHTML = '<a id="fitall" title="' + t('Alle zeigen') + '" aria-label="' + t('Alle zeigen') + '">⤢</a><a id="archbtn" title="' + t('Archiv') + '" aria-label="' + t('Archiv') + '">🕘</a>' +
        '<a id="apbtn" title="' + t('Flugplätze zeigen') + '" aria-label="' + t('Flugplätze zeigen') + '"><svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" style="vertical-align:-3px" aria-hidden="true"><circle cx="12" cy="12" r="7"/><path d="M12 2v20"/></svg></a>';
      L.DomEvent.disableClickPropagation(box);
      return box;
    } });
    map.addControl(new MapButtons());
    $('fitall').onclick = () => fitAll();
    $('archbtn').onclick = () => toggleArchive();
    function fitAll() {
      let pts;
      if (archive.on && archive.track && archive.track.length) pts = archive.track;
      else pts = items().filter(it => it.lat != null).map(it => [it.lat, it.lon]);
      if (state && state.home) pts = pts.concat([state.home]);
      if (pts.length) map.fitBounds(pts, { padding: [30, 30], maxZoom: 12 });
    }
    // Richtungspfeile entlang einer Bahn ([[lat, lon], …]) in eine Layer-Gruppe der
    // Karte `m`. Fester Abstand auf dem Bildschirm (ARROW_SPACING Pixel) wie in der
    // Mac-App (ppm-map.js): herausgezoomt weniger, hineingezoomt mehr Pfeile – bei
    // jedem „zoomend“ neu gesetzt (Nutzerwunsch 30.10.2026; vorher fester km-Abstand).
    const ARROW_SPACING = 60;
    function arrowMarks(pixels, spacing, limit) {
      const out = [];
      if (!pixels || pixels.length < 2 || !(spacing > 0)) return out;
      let next = spacing / 2, walked = 0;
      for (let i = 1; i < pixels.length && out.length < limit; i++) {
        const a = pixels[i - 1], b = pixels[i], dx = b[0] - a[0], dy = b[1] - a[1];
        const len = Math.sqrt(dx * dx + dy * dy);
        if (!len) continue;
        const angle = Math.atan2(dx, -dy) * 180 / Math.PI;
        while (walked + len >= next && out.length < limit) {
          const f = (next - walked) / len;
          out.push({ x: a[0] + dx * f, y: a[1] + dy * f, angle });
          next += spacing;
        }
        walked += len;
      }
      return out;
    }
    function placeTrackArrows(set) {
      set.layer.clearLayers();
      const z = set.map.getZoom();
      const px = set.pts.map(p => { const q = set.map.project(L.latLng(p[0], p[1]), z); return [q.x, q.y]; });
      for (const a of arrowMarks(px, ARROW_SPACING, set.limit)) {
        L.marker(set.map.unproject(L.point(a.x, a.y), z), { interactive: false, keyboard: false,
          icon: L.divIcon({ className: 'trkarrow', iconSize: [12, 12],
            html: '<div style="transform:rotate(' + a.angle.toFixed(0) + 'deg);color:' + set.color + '">▲</div>' }) }).addTo(set.layer);
      }
    }
    function trackArrows(pts, color, group, limit, m) {
      m = m || map;
      if (!pts || pts.length < 2) return;
      const set = { pts, color, map: m, limit: limit || 200, layer: L.layerGroup().addTo(group) };
      placeTrackArrows(set);
      if (!m._ppmArrows) {
        m._ppmArrows = new Set();
        // Bahnen, deren Gruppe nicht mehr auf der Karte liegt, fallen dabei heraus.
        m.on('zoomend', () => { for (const s of m._ppmArrows) { if (m.hasLayer(s.layer)) placeTrackArrows(s); else m._ppmArrows.delete(s); } });
      }
      m._ppmArrows.add(set);
    }
    // ---------- Archiv ----------
    const archive = { on: false, data: null, sel: null, track: null, line: null };
    function toggleArchive() {
      archive.on = !archive.on; archive.sel = null; archive.track = null;
      if (archive.line) { map.removeLayer(archive.line); archive.line = null; }
      $('archbtn').classList.toggle('on', archive.on);
      layer.clearLayers(); markers = new Map(); trail = null; sel = null;
      if (archive.on) loadArchive(); else render();
    }
    async function loadArchive(day, id) {
      try {
        const params = { kind: tab };
        if (day || (archive.data && archive.data.day)) params.day = day || archive.data.day;
        if (id) params.id = id;
        const data = await api('/api/archive', params);
        if (id) {
          archive.track = data.track || [];
          if (archive.line) map.removeLayer(archive.line);
          archive.line = null;
          if (archive.track.length) {
            archive.line = L.layerGroup([L.polyline(archive.track, { color: '#ff9f0a', weight: 3 })]).addTo(map);
            trackArrows(archive.track, '#ff9f0a', archive.line);
          }
          if (archive.track.length) map.fitBounds(archive.track, { padding: [30, 30], maxZoom: 12 });
        }
        archive.data = data; renderArchive();
      } catch (e) { showError(e); }
    }
    // Während eine Auswahlliste im Bereich offen ist, nicht neu zeichnen – das
    // innerHTML schloss sie sonst bei jeder Abfrage wieder (Fund 28.10.2026).
    function selecting(box) { const a = document.activeElement; return !!a && (a.tagName === 'SELECT' || a.type === 'date') && box.contains(a); }
    function renderArchive() {
      const d = archive.data, side = $('side');
      if (!d) { side.innerHTML = '<div class="empty">' + t('Lade Archiv …') + '</div>'; return; }
      if (selecting(side)) return;
      const dayTitle = s => { const dt = new Date(s + 'T12:00'); const today = new Date(); const y = new Date(Date.now() - 864e5);
        return dt.toDateString() === today.toDateString() ? t('Heute') : dt.toDateString() === y.toDateString() ? t('Gestern') : dt.toLocaleDateString(LOCALE, { weekday: 'short', day: 'numeric', month: 'short' }); };
      // Tag blättern statt einer immer längeren Auswahlliste (Nutzer 31.10.2026: „wird
      // schnell unübersichtlich“): ‹ › springen zum vorigen/nächsten Tag mit Daten, der
      // Tag selbst öffnet den Kalender des Systems; ein Tag ohne Daten springt zum nächstliegenden.
      const at = d.days.indexOf(d.day);   // days: neuester zuerst
      const older = at >= 0 && at < d.days.length - 1 ? d.days[at + 1] : null;
      const newer = at > 0 ? d.days[at - 1] : null;
      const dayBtn = (to, sym, title) => '<button class="iconbtn" data-day="' + esc(to || '') + '" title="' + title + '" aria-label="' + title + '"' + (to ? '' : ' disabled') + '>' + sym + '</button>';
      let html = '<div class="archbar">' + dayBtn(older, '‹', t('Vorheriger Tag')) +
        '<label class="daypick"><span>' + esc(dayTitle(d.day)) + '</span><input type="date" id="archday" value="' + esc(d.day) + '"' +
        (d.days.length ? ' min="' + esc(d.days[d.days.length - 1]) + '" max="' + esc(d.days[0]) + '"' : '') + ' aria-label="' + t('Tag wählen') + '"></label>' +
        dayBtn(newer, '›', t('Nächster Tag')) + '<span class="hint">' + (tab === 'adsb' ? t('{0} Flugzeuge', d.items.length) : t('{0} Schiffe', d.items.length)) + '</span></div>';
      if (!d.items.length) html += '<div class="empty">' + t('An diesem Tag nichts empfangen.') + '</div>';
      html += d.items.map(it => {
        const sub = [it.type, it.route, fmtTime(it.first) + '–' + fmtTime(it.last),
          tab === 'adsb' ? (it.maxAltitudeM != null ? tt('max. {0} m', it.maxAltitudeM) : null) : (it.maxSpeed != null ? it.maxSpeed.toFixed(1) + ' kn' : null)].filter(Boolean).join(' · ');
        return '<div class="row' + (archive.sel === it.id ? ' sel' : '') + '" data-id="' + esc(it.id) + '"><span class="t">' + esc(it.name || it.key) + '</span><span class="s">' + esc(sub) + '</span>' +
          '<span class="r">' + (it.minDistanceKm != null ? it.minDistanceKm.toFixed(0) + ' km' : '') + '</span></div>';
      }).join('');
      const top = side.scrollTop; side.innerHTML = html; side.scrollTop = top;
      const goDay = day => { archive.sel = null; archive.track = null; if (archive.line) { map.removeLayer(archive.line); archive.line = null; } side.scrollTop = 0; loadArchive(day); };
      $('archday').onchange = e => {
        e.target.blur();
        const want = e.target.value;
        if (!want || !d.days.length) return;
        const dist = x => Math.abs(new Date(x + 'T12:00') - new Date(want + 'T12:00'));
        goDay(d.days.reduce((best, x) => dist(x) < dist(best) ? x : best, d.days[0]));
      };
      side.querySelectorAll('[data-day]').forEach(el => el.onclick = () => { if (el.dataset.day) goDay(el.dataset.day); });
      side.querySelectorAll('.row').forEach(el => el.onclick = () => { archive.sel = el.dataset.id; loadArchive(d.day, el.dataset.id); });
    }
    let markers = new Map(), trail = null, homeMarker = null;
    // Dieselben Symbole wie die Mac-Karte (ppm-map.js): dunkle Kontur, damit Flugzeuge
    // und Schiffe auf Wasser, Wald und Wiesen nicht untergehen (30.10.2026).
    const EDGE = ' stroke="#1d1d1f" stroke-opacity=".7" stroke-width="1.4" stroke-linejoin="round"';
    const ARCS = d => '<path d="' + d + '" fill="none" stroke="#1d1d1f" stroke-opacity=".7" stroke-width="4.4" stroke-linecap="round"/>' +
      '<path d="' + d + '" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round"/>';
    const SYM = {
      plane: '<path d="M12 1.5c.9 0 1.5.9 1.5 2V9l8 4.6v2.2l-8-2.4v5l2.6 2v1.7L12 21.2l-4.1.9v-1.7l2.6-2v-5l-8 2.4v-2.2l8-4.6V3.5c0-1.1.6-2 1.5-2z"' + EDGE + '/>',
      hull: '<path d="M12 1.5c2.6 2.4 4.2 5.3 4.2 8.8V21.3a1.2 1.2 0 0 1-1.2 1.2H9a1.2 1.2 0 0 1-1.2-1.2V10.3c0-3.5 1.6-6.4 4.2-8.8z"' + EDGE + ' stroke-width="1.6"/>',
      dot: '<circle cx="12" cy="12" r="7"' + EDGE + '/>',
      antenna: '<circle cx="12" cy="12" r="3.1"' + EDGE + '/>' + ARCS('M8.2 8a5.5 5.5 0 0 0 0 8M15.8 8a5.5 5.5 0 0 1 0 8M5 5a9.8 9.8 0 0 0 0 14M19 5a9.8 9.8 0 0 1 0 14'),
      beacon: '<path d="M10 9.5h4l1.6 11.5H8.4z"' + EDGE + '/><rect x="9" y="3" width="6" height="5" rx="1"' + EDGE + '/>' + ARCS('M5.5 4.5l-2-1M18.5 4.5l2-1M5.5 7.5H3M18.5 7.5H21'),
      balloon: '<path d="M12 18.5v4" fill="none" stroke="#1d1d1f" stroke-opacity=".7" stroke-width="2.6" stroke-linecap="round"/><path d="M12 18.5v4" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/>' +
        '<ellipse cx="12" cy="9" rx="7" ry="8"' + EDGE + '/><path d="M10.6 16.6h2.8L12 18.8z"' + EDGE + '/>',
      descent: '<circle cx="12" cy="12" r="10.5"' + EDGE + '/><path d="M12 6v10M7.5 11.5L12 16l4.5-4.5" fill="none" stroke="#fff" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"/>'
    };
    function symSvg(name, size, color, rot) {
      return '<svg class="sym" width="' + size + '" height="' + size + '" viewBox="0 0 24 24" fill="currentColor" style="color:' + color +
        (rot ? ';transform:rotate(' + rot + 'deg)' : '') + '">' + SYM[name] + '</svg>';
    }
    function icon(kind, it, color, label, stale) {
      let name, size, rot = 0;
      if (kind === 'adsb') { name = 'plane'; size = 26; rot = it.track ?? 90; }
      else if (it.fixed) { name = it.fixed === 'base' ? 'antenna' : 'beacon'; size = 20; }
      else if (it.heading == null) { name = 'dot'; size = 14; }
      else { name = 'hull'; size = 26; rot = it.heading; }
      return L.divIcon({ className: stale ? 'stale' : '', iconSize: [size, size], iconAnchor: [size / 2, size / 2],
        html: symSvg(name, size, color, rot) + (label ? '<span class="lbl" style="top:' + (size - 2) + 'px">' + esc(label) + '</span>' : '') });
    }
    function items() {
      if (!state) return [];
      return tab === 'adsb' ? state.adsb.aircraft : tab === 'ais' ? state.ais.vessels : [];
    }
    function label(it) { return tab === 'adsb' ? (it.callsign || it.id) : (it.name || String(it.id)); }
    function stale(it) { return it.age > (tab === 'adsb' ? 60 : 600); }

    function renderMap() {
      const list = items().filter(it => it.lat != null && it.lon != null);
      const seen = new Set();
      for (const it of list) {
        const key = tab + ':' + it.id; seen.add(key);
        const isSel = sel === key;
        const color = isSel ? '#ff9f0a' : stale(it) ? '#8e8e93' : '#0a84ff';
        const ic = icon(tab, it, color, label(it), stale(it));
        let m = markers.get(key);
        if (!m) { m = L.marker([it.lat, it.lon], { icon: ic }).addTo(layer); m.on('click', () => select(key)); markers.set(key, m); }
        else { m.setLatLng([it.lat, it.lon]); m.setIcon(ic); }
        m.setZIndexOffset(isSel ? 1000 : 0);
      }
      for (const [key, m] of markers) if (!seen.has(key)) { layer.removeLayer(m); markers.delete(key); }
      if (trail) { layer.removeLayer(trail); trail = null; }
      const cur = list.find(it => tab + ':' + it.id === sel);
      if (cur && cur.trail && cur.trail.length > 1) {
        trail = L.layerGroup([L.polyline(cur.trail, { color: '#ff9f0a', weight: 3 })]).addTo(layer);
        trackArrows(cur.trail, '#ff9f0a', trail);
      }
      if (state.home && !homeMarker) homeMarker = L.circleMarker(state.home, { radius: 6, color: '#a2845e', fillOpacity: .8 }).addTo(map).bindTooltip(t('Standort'));
      if (!fitted[tab] && list.length) {
        const pts = list.map(it => [it.lat, it.lon]); if (state.home) pts.push(state.home);
        map.fitBounds(pts, { padding: [30, 30], maxZoom: 11 }); fitted[tab] = true;
      }
    }

    function km(it) {
      if (!state.home || it.lat == null) return null;
      const R = 6371, r = Math.PI / 180, [a, b] = state.home;
      const d = Math.sin((it.lat - a) * r / 2) ** 2 + Math.cos(a * r) * Math.cos(it.lat * r) * Math.sin((it.lon - b) * r / 2) ** 2;
      return 2 * R * Math.asin(Math.sqrt(d));
    }

    // Sortierung je Reiter, im Browser gemerkt.
    const SORTS = { adsb: [['age', t('Zuletzt')], ['dist', t('Entfernung')], ['alt', t('Höhe')], ['name', t('Name')]],
                    ais: [['age', t('Zuletzt')], ['dist', t('Entfernung')], ['speed', t('Fahrt')], ['name', t('Name')]] };
    const stored = (k, d) => { try { return localStorage.getItem(k) || d; } catch (e) { return d; } };
    const sortBy = { adsb: stored('sort-adsb', 'age'), ais: stored('sort-ais', 'age') };
    // Richtung: +1 = Grundrichtung (Zeit/Entfernung/Name aufsteigend, Höhe/Fahrt absteigend), −1 umgekehrt.
    const sortDir = { adsb: Number(stored('sortdir-adsb', '1')), ais: Number(stored('sortdir-ais', '1')) };
    function sortValue(it) {
      switch (sortBy[tab]) {
        case 'dist': return km(it);
        case 'alt': return it.altitudeM == null ? null : -it.altitudeM;
        case 'speed': return it.speedKn == null ? null : -it.speedKn;
        case 'name': return null;
        default: return it.age;
      }
    }
    function compare(x, y) {
      if (sortBy[tab] === 'name') return sortDir[tab] * label(x).localeCompare(label(y), LOCALE, { numeric: true, sensitivity: 'base' });
      const a = sortValue(x), b = sortValue(y);
      if (a == null || b == null) return (a == null) - (b == null);   // fehlende Werte immer ans Ende
      return sortDir[tab] * (a - b);
    }
    // Rechte Spalte: der Wert, nach dem sortiert wird.
    function rightValue(it) {
      if (sortBy[tab] === 'alt') return it.altitudeM != null ? it.altitudeM + ' m' : '';
      if (sortBy[tab] === 'speed') return it.speedKn != null ? it.speedKn.toFixed(1) + ' kn' : '';
      if (sortBy[tab] === 'age') return it.age < 60 ? it.age + ' s' : Math.round(it.age / 60) + ' min';
      const d = km(it); return d != null ? d.toFixed(0) + ' km' : '';
    }
    function renderList() {
      const list = [...items()].sort(compare);
      const side = $('side');
      const arrow = k => { const up = (k === 'alt' || k === 'speed') ? sortDir[tab] < 0 : sortDir[tab] > 0; return up ? ' ↑' : ' ↓'; };
      const bar = '<div class="sortbar">' + SORTS[tab].map(([k, lbl]) => '<button data-sort="' + k + '"' + (sortBy[tab] === k ? ' class="on"' : '') + '>' + lbl + (sortBy[tab] === k ? arrow(k) : '') + '</button>').join('') + '</div>';
      if (!list.length) {
        side.innerHTML = '<div class="empty">' + (state.mode === tab ? t('Noch nichts empfangen.') : tab === 'adsb' ? t('Tippe oben auf „Start“, um Flugzeuge zu empfangen.') : t('Tippe oben auf „Start“, um Schiffe zu empfangen.')) + '</div>';
        return;
      }
      side.innerHTML = bar + list.map(it => {
        const key = tab + ':' + it.id, d = km(it);
        const sub = tab === 'adsb'
          ? [it.type, it.from && it.to ? it.from + ' → ' + it.to : null, it.altitudeM != null ? it.altitudeM + ' m' : null].filter(Boolean).join(' · ')
          : [it.type, it.destination ? '→ ' + it.destination : null, it.speedKn != null ? it.speedKn.toFixed(1) + ' kn' : null].filter(Boolean).join(' · ');
        return '<div class="row' + (sel === key ? ' sel' : '') + '" data-key="' + esc(key) + '"><span class="t">' + esc(label(it)) + '</span><span class="s">' + esc(sub) + '</span><span class="r">' + esc(rightValue(it)) + '</span></div>';
      }).join('');
      side.querySelectorAll('.row').forEach(el => el.onclick = () => select(el.dataset.key, true));
      side.querySelectorAll('.sortbar button').forEach(b => b.onclick = () => {
        // Zweiter Tipp auf den aktiven Knopf dreht die Richtung um.
        if (sortBy[tab] === b.dataset.sort) sortDir[tab] = -sortDir[tab];
        else { sortBy[tab] = b.dataset.sort; sortDir[tab] = 1; }
        try { localStorage.setItem('sort-' + tab, sortBy[tab]); localStorage.setItem('sortdir-' + tab, String(sortDir[tab])); } catch (e) {}
        side.scrollTop = 0; renderList();
      });
    }

    function renderCard() {
      const card = $('card');
      const it = items().find(i => tab + ':' + i.id === sel);
      if (!it) { card.style.display = 'none'; card.dataset.key = ''; return; }
      const rows = [];
      const add = (k, v) => { if (v != null && v !== '') rows.push('<tr><td>' + esc(k) + '</td><td>' + esc(v) + '</td></tr>'); };
      const d = km(it);
      if (tab === 'adsb') {
        add(t('Kennzeichen'), it.registration); add(t('Typ'), it.type); add(t('Betreiber'), it.operatorName);
        add(t('Gesellschaft'), it.airline); add(t('Von'), it.from); add(t('Nach'), it.to);
        add(t('Höhe'), it.altitudeM != null ? it.altitudeM + ' m' : null); add(t('Tempo'), it.speedKmh != null ? it.speedKmh + ' km/h' : null);
        add(t('Kurs'), it.track != null ? Math.round(it.track) + '°' : null); add(t('Steigen'), it.climbMs != null ? it.climbMs.toFixed(1) + ' m/s' : null);
      } else {
        add(t('Typ'), it.type); add(t('Status'), it.status); add(t('Fahrt'), it.speedKn != null ? it.speedKn.toFixed(1) + ' kn' + (it.course != null ? ' · ' + Math.round(it.course) + '°' : '') : null);
        add(t('Ziel'), it.destination); add(t('Ankunft'), it.eta); add(t('Größe'), it.length ? it.length + ' × ' + it.beam + ' m' : null);
        add(t('Tiefgang'), it.draught != null ? it.draught.toFixed(1) + ' m' : null); add(t('Rufzeichen'), it.callsign); add('IMO', it.imo);
      }
      add(t('Entfernung'), d != null ? d.toFixed(1) + ' km' : null);
      add(tt('Kontakt'), tt('vor {0} s', it.age));
      const photo = it.photo ? '<a href="' + esc(it.photo.page) + '" target="_blank" rel="noopener"><img src="' + esc(it.photo.url) + '" alt=""></a><div class="credit"><a href="' + esc(it.photo.page) + '" target="_blank" rel="noopener">' + esc(it.photo.credit) + '</a></div>' : '';
      const link = tab === 'adsb' ? 'https://www.flightradar24.com/' + encodeURIComponent(it.callsign || it.id) : 'https://www.marinetraffic.com/en/ais/details/ships/mmsi:' + encodeURIComponent(it.id);
      const head = '<h3><span>' + esc(label(it)) + '</span><button id="close" aria-label="' + t('Schließen') + '">✕</button></h3>' +
        '<div class="sub">' + esc(tab === 'adsb' ? 'ICAO ' + it.id : 'MMSI ' + it.id) + '</div><div id="cphoto"></div><div id="crows"></div>';
      // Nur Geändertes neu setzen: sonst lädt das Foto bei jeder Abfrage neu und die Karte springt nach oben.
      if (card.dataset.key !== sel) {
        card.dataset.key = sel; card.dataset.photo = ''; card.innerHTML = head; card.scrollTop = 0;
        $('close').onclick = () => { sel = null; render(); };
      } else card.querySelector('h3 span').textContent = label(it);
      if (card.dataset.photo !== photo) {
        card.dataset.photo = photo; $('cphoto').innerHTML = photo;
        // Das Foto vergrößert das Blatt – die eben gewählte Position wieder in den freien Teil holen.
        const img = card.querySelector('img');
        if (img && centered) img.onload = () => { if (centered) centerVisible(centered); centered = null; };
      }
      $('crows').innerHTML = '<table>' + rows.join('') + '</table><div style="margin-top:6px"><a href="' + link + '" target="_blank" rel="noopener">' + (tab === 'adsb' ? 'Flightradar24' : 'MarineTraffic') + '</a></div>';
      card.style.display = 'block';
    }

    // Mitte des sichtbaren Kartenteils – auf dem Handy deckt das Infoblatt den unteren Teil ab.
    let centered = null;
    function centerVisible(ll) {
      const r = $('mapwrap').getBoundingClientRect(), c = $('card').getBoundingClientRect();
      const bottom = window.innerWidth <= 760 && c.height ? Math.min(r.bottom, c.top) : r.bottom;
      const p = map.latLngToContainerPoint(ll);
      map.panBy([p.x - r.width / 2, p.y - Math.max(40, bottom - r.top - 30) / 2]);
    }

    function select(key, center) {
      sel = key; centered = null; render(); poll(true);
      if (center) { const it = items().find(i => tab + ':' + i.id === key); if (it && it.lat != null) { centered = [it.lat, it.lon]; centerVisible(centered); } }
    }

    // ---------- Digitalradio ----------
    // Gemeinsamer Ton für Digitalradio, Radio (UKW/AM) und Flugfunk (/audio.aac).
    const player = new Audio(); player.preload = 'none';
    function startAudio() { player.src = '/audio.aac?t=' + Date.now(); player.play().catch(showError); }
    function stopAudio() { player.pause(); player.removeAttribute('src'); player.load(); }
    // Anhören im Browser endet mit „Ton aus“ – „Stopp“ heißt nur das Beenden des Empfangs (Kopf oben).
    const audioLabel = () => player.paused ? t('🔈 Hier anhören') : t('🔇 Ton aus');
    function toggleAudio() { if (player.paused) startAudio(); else stopAudio(); setTimeout(render, 50); }
    function updateNowPlaying() {
      if (!('mediaSession' in navigator) || !state) return;
      navigator.mediaSession.metadata = new MediaMetadata({ title: state.dab.playing || 'DAB+', artist: state.dab.dynamicLabel || '', album: 'PortaPack · ' + state.dab.channel,
        artwork: [{ src: '/icon-512.png', sizes: '512x512', type: 'image/png' }] });
    }
    function renderRadio() {
      const d = state.dab, box = $('radio');
      const active = state.mode === 'dab';
      let html = '<div class="nowwrap"><div class="now"><div class="name">' + esc(d.playing || t('Kein Sender gewählt')) + '</div>' +
        '<div class="dls">' + esc(d.dynamicLabel) + '</div>' +
        '<div class="hint">' + (active ? t('Kanal {0}', d.channel) + ' · ' + (d.synchronized ? t('synchron · SNR {0} dB', d.snr.toFixed(1)) : t('sucht Signal …')) : t('Digitalradio ist aus – oben „Start“ tippen.')) + '</div>' +
        '<div style="margin-top:10px"><button class="btn" id="play" style="margin-left:0">' + audioLabel() + '</button>' +
        '<button class="btn secondary" id="scan">' + (d.scanning ? t('Suchlauf {0} %', Math.round(d.scanProgress * 100)) : t('Suchlauf')) + '</button></div>' +
        '<div class="hint" style="margin-top:8px">' + t('Solange hier jemand zuhört, bleibt der Mac stumm.') + '</div></div></div>';
      if (!d.ensembles.length) html += '<div class="empty">' + t('Noch keine Sender bekannt – Suchlauf starten (dauert etwa eine Minute).') + '</div>';
      // Alle Sender alphabetisch in einer Liste; ein Sender auf mehreren Kanälen
      // erscheint einmal, bevorzugt auf dem gerade empfangenen Kanal.
      const byID = new Map();
      for (const e of d.ensembles) for (const s of e.services) {
        const known = byID.get(s.id);
        if (!known || (e.channel === d.channel && known.channel !== d.channel)) byID.set(s.id, { ...s, channel: e.channel });
      }
      const services = [...byID.values()].sort((a, b) => a.label.localeCompare(b.label, LOCALE, { sensitivity: 'base' }));
      if (services.length) html += wxBox('dab-list', t('Sender'), services.map(s =>
        '<div class="svc' + (s.id === d.playingID ? ' on' : '') + '" data-ch="' + esc(s.channel) + '" data-id="' + s.id + '"><span>' + esc(s.label) + '</span><span class="hint">' + esc(s.channel) + ' · ' + s.bitrate + ' kbit/s</span></div>').join(''), services.length);
      box.innerHTML = html;
      updateNowPlaying();
      $('play').onclick = toggleAudio;
      $('scan').onclick = () => api('/api/dab/scan').then(s => { state = s; render(); }).catch(showError);
      box.querySelectorAll('.svc').forEach(el => el.onclick = async () => {
        try { state = await api('/api/dab/play', { ch: el.dataset.ch, id: el.dataset.id }); render(); if (player.paused) startAudio(); else startAudio(); } catch (e) { showError(e); }
      });
    }

    // ---------- Wetter ----------
    let plan = null;
    const fmtDay = ms => new Date(ms).toLocaleDateString(LOCALE, { weekday: 'short', day: 'numeric', month: 'short' });
    const fmtTime = ms => new Date(ms).toLocaleTimeString(LOCALE, { hour: '2-digit', minute: '2-digit' });
    async function loadPlan(params = {}) {
      try { plan = await api('/api/plan', params); if (tab === 'wx') renderWeather(); } catch (e) { showError(e); }
    }
    // Einklappbare Kästen (<details>) in allen Reitern, auf-/zugeklappt je Kasten im
    // Browser gemerkt (übersteht Neuzeichnen und Neuladen). Schlüssel je Reiter mit
    // Präfix (ab-, dab-, fm-, sens-, sh-, dsc-, ft8-, occ-); die Wetter-Kästen ohne.
    // Vorgabe offen, nur Einstellungen (WX_CLOSED) zu.
    const wxOpen = (() => { try { return JSON.parse(localStorage.getItem('wxOpen') || '{}'); } catch (e) { return {}; } })();
    const WX_CLOSED = ['gain', 'log'];
    const boxOpen = key => key in wxOpen ? wxOpen[key] : !WX_CLOSED.includes(key);
    // Ein Zuhörer für alle: „toggle“ steigt nicht auf, kommt aber in der Einfangphase an.
    document.addEventListener('toggle', e => {
      const d = e.target;
      // Nur echte Abweichungen merken (beim Einhängen offener Kästen feuert „toggle“ auch).
      if (!(d instanceof HTMLDetailsElement) || !d.classList.contains('box') || !d.dataset.k || boxOpen(d.dataset.k) === d.open) return;
      wxOpen[d.dataset.k] = d.open;
      try { localStorage.setItem('wxOpen', JSON.stringify(wxOpen)); } catch (x) {}
    }, true);
    function wxBox(key, title, body, count) {
      const open = boxOpen(key);
      return '<details class="box" data-k="' + key + '"' + (open ? ' open' : '') + '><summary><h4><span>' + esc(title) + '</span>' +
        (count != null ? '<span class="count">' + count + '</span>' : '') + '</h4></summary>' + body + '</details>';
    }
    // Wetterballons: Karte und Diagramm stehen in einem festen Element außerhalb des
    // per innerHTML ersetzten Bereichs. renderBalloons legt nur einen Platzhalter fester
    // Höhe an (hält die Bildlaufposition), danach – als Mikroaufgabe, also nach dem
    // innerHTML in renderWeather – wird das Element wieder eingehängt. Zoom und
    // Ausschnitt bleiben so erhalten; die Karte entsteht erst bei offenem Kasten.
    const sondeUI = { panel: null, map: null, live: null, track: null, liveData: null, liveAt: 0, liveLoading: false,
                      fitted: false, sel: null, selData: null, selLoading: false };
    document.head.insertAdjacentHTML('beforeend', '<style>' +
      '.sp-panel { display:flex; flex-direction:column; gap:8px; padding:8px 12px; min-width:0; box-sizing:border-box; }' +
      '.sp-map { height:280px; border-radius:10px; overflow:hidden; border:1px solid var(--line); min-width:0; box-sizing:border-box; }' +
      '.sp-detail { height:340px; display:flex; flex-direction:column; gap:6px; min-width:0; }' +
      '.sp-detail[hidden] { display:none; }' +
      '.sp-cap { display:flex; align-items:center; gap:8px; font-size:13px; min-width:0; height:28px; }' +
      '.sp-cap span { flex:1; min-width:0; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }' +
      '.sp-cap .btn { margin:0; padding:4px 10px; }' +
      '.sp-detail canvas { width:100%; height:150px; display:block; background:var(--bg); border-radius:8px; }' +
      '.item.sp-pick { cursor:pointer; }' +
      '.item.sp-on { box-shadow:inset 3px 0 0 var(--sel); }' +
      '.sp-tip { font-size:11px; padding:1px 5px; }' +
      '.fmbands{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:6px;padding:8px}.fmbands button{border:0;border-radius:9px;background:var(--bg);color:var(--text);padding:8px 10px;text-align:left;cursor:pointer;font:14px -apple-system,system-ui,sans-serif;min-width:0}.fmbands button b{display:block;font-weight:600}.fmbands button span{display:block;color:var(--muted);font-size:12px;margin-top:2px}</style>');
    // Mindesthöhe des Platzhalters = Höhe des Elements (Ränder 8, Karte 280, Diagramme 340).
    const sondeSlotHeight = () => sondeUI.sel ? 8 + 280 + 8 + 340 + 8 : 8 + 280 + 8;
    const sondeColor = name => getComputedStyle(document.documentElement).getPropertyValue(name).trim() || '#0a84ff';
    function sondePanel() {
      if (sondeUI.panel) return sondeUI.panel;
      const p = document.createElement('div');
      p.className = 'sp-panel';
      p.innerHTML = '<div class="sp-map"></div><div class="sp-detail" hidden><div class="sp-cap"><span></span>' +
        '<button class="btn secondary" type="button">' + t('Schließen') + '</button></div><canvas class="sp-alt"></canvas><canvas class="sp-temp"></canvas></div>';
      p.querySelector('.sp-cap .btn').onclick = () => sondeSelect(null);
      sondeUI.panel = p;
      return p;
    }
    function sondeEnsureMap() {
      if (sondeUI.map) return;
      const el = sondePanel().querySelector('.sp-map');
      if (!el.isConnected || !el.offsetWidth) return;
      const m = L.map(el, { zoomControl: true }).setView([53.5, 10], 7);
      L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', { maxZoom: 18, attribution: '© OpenStreetMap' }).addTo(m);
      sondeUI.map = m;
      sondeUI.live = L.layerGroup().addTo(m);
      sondeUI.track = L.layerGroup().addTo(m);
      if (sondeUI.liveData) sondeDrawLive();
      if (sondeUI.selData) sondeDrawTrack(true);
    }
    async function sondeLoadLive() {
      if (sondeUI.liveLoading) return;
      sondeUI.liveLoading = true;
      try { sondeUI.liveData = await api('/api/sondes'); sondeUI.liveAt = Date.now(); sondeDrawLive(); }
      catch (e) { showError(e); }
      sondeUI.liveLoading = false;
    }
    function sondeDrawLive() {
      const d = sondeUI.liveData, m = sondeUI.map;
      if (!d || !m) return;
      const g = sondeUI.live; g.clearLayers();
      const accent = sondeColor('--accent'), warn = sondeColor('--warn'), bounds = [];
      if (d.home) {
        L.circleMarker([d.home.lat, d.home.lon], { radius: 6, color: '#fff', weight: 2, fillColor: sondeColor('--ok'), fillOpacity: 1 })
          .bindTooltip(t('Heimatstandort'), { className: 'sp-tip' }).addTo(g);
        bounds.push([d.home.lat, d.home.lon]);
      }
      for (const s of d.live) {
        if (s.track.length > 1) {
          const tp = s.track.map(q => [q[0], q[1]]);
          L.polyline(tp, { color: accent, weight: 3, opacity: 0.8 }).addTo(g);
          trackArrows(tp, accent, g, 0, m);
        }
        if (s.lat == null || s.lon == null) continue;
        bounds.push([s.lat, s.lon]);
        if (s.landing) {
          L.polyline([[s.lat, s.lon], [s.landing.lat, s.landing.lon]], { color: warn, weight: 1.5, dashArray: '5 4' }).addTo(g);
          L.circleMarker([s.landing.lat, s.landing.lon], { radius: 5, color: warn, weight: 2, fillOpacity: 0.2 })
            .bindTooltip(esc(tt('Landung ≈ {0} in {1} min', s.serial, s.landing.minutes)), { className: 'sp-tip' }).addTo(g);
          bounds.push([s.landing.lat, s.landing.lon]);
        }
        const alt = s.altitude == null ? '' : ' · ' + (s.altitude / 1000).toFixed(1) + ' km';
        const vs = s.verticalSpeed == null ? '' : ' ' + (s.verticalSpeed > 0 ? '↑' : '↓') + Math.abs(s.verticalSpeed).toFixed(1) + ' m/s';
        L.marker([s.lat, s.lon], { keyboard: false, icon: L.divIcon({ className: '', iconSize: [26, 26], iconAnchor: [13, 13],
            html: symSvg(s.burst ? 'descent' : 'balloon', 26, s.burst ? warn : accent) }) })
          .bindTooltip(esc(s.serial + alt + vs), { permanent: true, direction: 'right', offset: [12, 0], className: 'sp-tip' }).addTo(g);
      }
      // Nur beim ersten Mal einpassen – danach bleibt der Ausschnitt des Nutzers.
      if (!sondeUI.fitted && !sondeUI.selData && m.getContainer().offsetWidth) {
        sondeUI.fitted = true;
        if (bounds.length > 1) m.fitBounds(bounds, { padding: [30, 30], maxZoom: 10 });
        else if (bounds.length) m.setView(bounds[0], 8);
      }
    }
    async function sondeSelect(serial) {
      if (serial && !/^[A-Z0-9]{1,16}$/.test(serial)) return;
      if (serial === sondeUI.sel) serial = null;
      sondeUI.sel = serial; sondeUI.selData = null;
      if (sondeUI.track) sondeUI.track.clearLayers();
      sondeUI.selLoading = !!serial;
      sondeShowDetail();
      if (tab === 'wx') renderWeather();
      if (!serial) return;
      try { const d = await api('/api/sondes', { serial }); if (sondeUI.sel === serial) { sondeUI.selData = d; sondeDrawTrack(true); } }
      catch (e) { showError(e); }
      if (sondeUI.sel === serial) { sondeUI.selLoading = false; sondeShowDetail(); }
    }
    function sondeDrawTrack(fit) {
      const d = sondeUI.selData, m = sondeUI.map;
      if (!d || !m) return;
      sondeUI.track.clearLayers();
      const pts = d.points.filter(q => q.lat != null && q.lon != null).map(q => [q.lat, q.lon]);
      if (!pts.length) return;
      const sel = sondeColor('--sel');
      L.polyline(pts, { color: sel, weight: 3 }).addTo(sondeUI.track);
      trackArrows(pts, sel, sondeUI.track, 0, m);
      L.circleMarker(pts[0], { radius: 5, color: sel, weight: 2, fillColor: '#fff', fillOpacity: 1 })
        .bindTooltip(t('Erster Empfang'), { className: 'sp-tip' }).addTo(sondeUI.track);
      L.circleMarker(pts[pts.length - 1], { radius: 5, color: '#fff', weight: 2, fillColor: sel, fillOpacity: 1 })
        .bindTooltip(esc(d.serial + ' · ' + t('letzter Empfang')), { className: 'sp-tip' }).addTo(sondeUI.track);
      if (fit && m.getContainer().offsetWidth) m.fitBounds(pts, { padding: [30, 30], maxZoom: 12 });
    }
    function sondeShowDetail() {
      const p = sondePanel(), det = p.querySelector('.sp-detail'), cap = p.querySelector('.sp-cap span');
      det.hidden = !sondeUI.sel;
      if (!sondeUI.sel) return;
      const d = sondeUI.selData;
      cap.textContent = !d ? sondeUI.sel + ' · ' + (sondeUI.selLoading ? t('lade …') : t('keine Daten'))
        : d.serial + ' · ' + d.type + ' · ' + fmtDay(d.start) + ' ' + fmtTime(d.start) + '–' + fmtTime(d.end) +
          (d.peak != null ? ' · ' + tt('Gipfel {0} km', (d.peak / 1000).toFixed(1)) : '') + ' · ' + tt('{0} Meldungen', d.total);
      p.querySelectorAll('canvas').forEach(cv => { if (!d && cv.width) cv.getContext('2d').clearRect(0, 0, cv.width, cv.height); });
      sondeCharts();
    }
    // Kleines Liniendiagramm ohne Bibliothek (Canvas, scharf auf Retina).
    function sondeChart(cv, pts, o) {
      const dpr = window.devicePixelRatio || 1, w = cv.clientWidth, h = cv.clientHeight;
      if (!w || !h) return;
      cv.width = Math.round(w * dpr); cv.height = Math.round(h * dpr);
      const c = cv.getContext('2d'); c.setTransform(dpr, 0, 0, dpr, 0, 0); c.clearRect(0, 0, w, h);
      const muted = sondeColor('--muted'), line = sondeColor('--line');
      c.font = '11px -apple-system, system-ui, sans-serif'; c.fillStyle = muted; c.textAlign = 'left';
      c.fillText(o.title, 8, 14);
      if (pts.length < 2) { c.fillText(t('Zu wenige Messpunkte'), 8, h / 2); return; }
      const left = 40, right = 10, top = 22, bottom = 20;
      let x0 = Infinity, x1 = -Infinity, y0 = Infinity, y1 = -Infinity;
      for (const q of pts) { x0 = Math.min(x0, q.x); x1 = Math.max(x1, q.x); y0 = Math.min(y0, q.y); y1 = Math.max(y1, q.y); }
      if (o.yZero) y0 = Math.min(0, y0);
      // Mindestbreite der x-Achse (Temperaturprofil), sonst wirkt jedes Zehntelgrad riesig.
      if (o.xMinSpan && x1 - x0 < o.xMinSpan) { const m = (x0 + x1) / 2; x0 = m - o.xMinSpan / 2; x1 = m + o.xMinSpan / 2; }
      if (x1 === x0) x1 = x0 + 1;
      if (y1 === y0) y1 = y0 + 1;
      const X = x => left + (x - x0) / (x1 - x0) * (w - left - right), Y = y => h - bottom - (y - y0) / (y1 - y0) * (h - top - bottom);
      c.strokeStyle = line; c.lineWidth = 1; c.textAlign = 'right';
      for (let i = 0; i <= 3; i++) {
        const v = y0 + (y1 - y0) * i / 3, yy = Math.round(Y(v)) + 0.5;
        c.beginPath(); c.moveTo(left, yy); c.lineTo(w - right, yy); c.stroke();
        c.fillText(o.yFmt(v), left - 4, yy + 4);
      }
      c.textAlign = 'left'; c.fillText(o.xFmt(x0), left, h - 5);
      c.textAlign = 'right'; c.fillText(o.xFmt(x1), w - right, h - 5);
      c.strokeStyle = o.color; c.lineWidth = 2; c.lineJoin = 'round'; c.beginPath();
      pts.forEach((q, i) => i ? c.lineTo(X(q.x), Y(q.y)) : c.moveTo(X(q.x), Y(q.y)));
      c.stroke();
    }
    // Höhe über Zeit; Temperatur über Höhe nur im Aufstieg (bis zum höchsten Punkt),
    // Temperatur waagerecht, Höhe senkrecht – wie ein Aufstiegsprofil.
    function sondeCharts() {
      const d = sondeUI.selData, p = sondePanel();
      if (!d || !sondeUI.sel) return;
      const alt = d.points.filter(q => q.alt != null);
      sondeChart(p.querySelector('.sp-alt'), alt.map(q => ({ x: q.t, y: q.alt / 1000 })),
        { title: t('Höhe (km) über Zeit'), color: sondeColor('--sel'), yZero: true, xFmt: fmtTime, yFmt: v => v.toFixed(1) });
      let peak = 0;
      alt.forEach((q, i) => { if (q.alt > alt[peak].alt) peak = i; });
      const rise = alt.slice(0, peak + 1).filter(q => q.temp != null);
      // Mittel je 250-m-Schicht: in der Stratosphäre ändert sich die Temperatur kaum,
      // jedes Zehntelgrad Rauschen wurde sonst zu einem waagerechten Zacken.
      const layers = new Map();
      for (const q of rise) {
        const k = Math.round(q.alt / 250);
        const l = layers.get(k) || { s: 0, n: 0 }; l.s += q.temp; l.n++; layers.set(k, l);
      }
      const profile = [...layers.entries()].sort((a, b) => a[0] - b[0]).map(([k, l]) => ({ x: l.s / l.n, y: k * 0.25 }));
      sondeChart(p.querySelector('.sp-temp'), profile,
        { title: t('Temperatur über Höhe (km), Aufstieg'), color: sondeColor('--warn'), yZero: true, xMinSpan: 30,
          xFmt: v => Math.round(v) + ' °C', yFmt: v => v.toFixed(1) });
    }
    window.addEventListener('resize', () => { if (sondeUI.sel && tab === 'wx') sondeCharts(); });
    // Nach dem Neuzeichnen: Element in den Platzhalter hängen, Knöpfe verdrahten.
    function sondeMount() {
      const box = $('wx'), slot = box.querySelector('.sp-slot');
      if (!slot) return;
      const panel = sondePanel();
      if (panel.parentNode !== slot) slot.replaceChildren(panel);
      const det = slot.closest('details');
      if (det && !det.dataset.sp) {
        det.dataset.sp = '1';
        det.addEventListener('toggle', () => {
          if (!det.open) return;
          sondeEnsureMap();
          if (sondeUI.map) sondeUI.map.invalidateSize({ pan: false });
          sondeLoadLive();
        });
      }
      box.querySelectorAll('[data-sonde]').forEach(el => el.onclick = () => sondeSelect(el.dataset.sonde));
      box.querySelectorAll('[data-live]').forEach(el => el.onclick = e => {
        if (e.target.closest('a') || !sondeUI.map) return;
        const s = sondeUI.liveData && sondeUI.liveData.live.find(x => x.serial === el.dataset.live);
        if (s && s.lat != null) sondeUI.map.setView([s.lat, s.lon], Math.max(sondeUI.map.getZoom(), 9));
      });
      if (!det || !det.open) return;
      sondeEnsureMap();
      if (sondeUI.map) sondeUI.map.invalidateSize({ pan: false });
      if (Date.now() - sondeUI.liveAt > 8000) sondeLoadLive();
    }
    // Statuszeile im Wetter-Reiter: der nächste Termin, den der Plan wirklich
    // aufnimmt – ein geplanter Überflug (nicht schon begonnen) oder, wenn
    // Radiosonden an sind, das nächste Sondenfenster. Vorher stand hier der erste
    // Überflug der Liste, auch ein laufender oder gar nicht geplanter (Fund 30.10.2026).
    function wxNext() {
      const now = Date.now();
      const pass = (plan.passes || []).find(x => x.planned && x.start > now);
      const win = plan.autoSonde ? (plan.sondeWindows || []).find(x => x.end > now) : null;
      if (win && (!pass || win.start <= pass.start)) {
        return win.start <= now ? tt('Sondenfenster bis {0}', fmtTime(win.end)) : tt('Nächstes Sondenfenster {0}', fmtTime(win.start));
      }
      if (pass) return tt('Nächster Überflug {0}', fmtTime(pass.start));
      return plan.autoMeteor || plan.autoAmateur || plan.autoSonde ? tt('Kein Termin geplant') : tt('Empfangsplan aus');
    }
    function renderBalloons(p) {
      const live = p.balloons || [], flights = p.flights || [];
      queueMicrotask(sondeMount);
      let body = '<div class="sp-slot" style="min-height:' + sondeSlotHeight() + 'px"></div>';
      if (live.length) body += live.map(b => {
        const alt = b.altitude == null ? '–' : (b.altitude / 1000).toFixed(1) + ' km';
        const vs = b.verticalSpeed == null ? '' : ' · ' + (b.verticalSpeed > 0 ? '+' : '') + b.verticalSpeed.toFixed(1) + ' m/s';
        const wx = b.temperature == null ? '' : ' · ' + b.temperature.toFixed(1) + ' °C' + (b.humidity == null ? '' : ' · ' + Math.round(b.humidity) + ' %');
        const where = b.distanceKm == null ? '' : ' · ' + b.distanceKm.toFixed(0) + ' km ' + (b.direction || '');
        const age = b.age < 60 ? tt('gerade') : tt('vor {0} min', Math.round(b.age / 60));
        return '<div class="item sp-pick" data-live="' + esc(b.serial) + '"><span>' + (b.burst ? '🪂' : '🎈') + '</span><div class="grow"><div>' + esc(b.serial + ' · ' + b.type + ' · ' + b.frequency.toFixed(3) + ' MHz') + '</div>' +
          '<div class="sub">' + esc(alt + vs + wx + where + ' · ' + age) + '</div></div>' +
          '<a class="el" href="https://sondehub.org/' + encodeURIComponent(b.serial) + '" target="_blank" rel="noopener">↗</a></div>';
      }).join('');
      else body += '<div class="empty">' + t('Gerade keine Sonde zu hören.') + '</div>';
      const done = flights.filter(f => !live.some(b => b.serial === f.serial));
      if (done.length) body += '<div class="sub" style="padding:8px 12px 2px">' + t('Archiv – antippen zeigt Bahn und Profil') + '</div>' + done.slice(0, 15).map(f =>
        (/^[A-Z0-9]{1,16}$/.test(f.serial) ? '<div class="item sp-pick' + (f.serial === sondeUI.sel ? ' sp-on' : '') + '" data-sonde="' + esc(f.serial) + '">' : '<div class="item">') + '<span>' + (f.burst ? '🪂' : '🎈') + '</span><div class="grow"><div>' + esc(f.serial + ' · ' + f.type) + '</div>' +
        '<div class="sub">' + esc(fmtDay(f.start) + ' ' + fmtTime(f.start) + '–' + fmtTime(f.end) +
          (f.peak != null ? ' · ' + tt('Gipfel {0} km', (f.peak / 1000).toFixed(1)) : '') +
          (f.minTemperature != null ? ' · ' + tt('bis {0} °C', Math.round(f.minTemperature)) : '') +
          (f.distanceKm != null ? ' · ' + tt('{0} km Strecke', f.distanceKm) : '') + ' · ' + tt('{0} Meldungen', f.samples)) + '</div></div></div>').join('');
      // „live“ nur, was in den letzten 5 min zu hören war (wie der Nachlauf des
      // Plans) – der Empfänger behält Sonden nach Fensterende in der Liste.
      const heard = live.filter(b => b.age < 300).length;
      return wxBox('balloons', t('Wetterballons'), body, heard ? t('{0} live', heard) : (flights.length || null));
    }
    function renderWeather() {
      const box = $('wx');
      if (!plan) { box.innerHTML = '<div class="empty">' + t('Lade Plan …') + '</div>'; return; }
      if (selecting(box)) return;
      const p = plan;
      let html = '';
      if (p.status) html += '<div class="box"><div class="running" style="display:flex;align-items:center;gap:8px"><span style="flex:1">● ' + esc(p.status) + '</span>' +
        '<button id="skipjob" class="skip">' + t('Überspringen') + '</button></div></div>';
      html += '<div class="box"><h4>' + t('Automatisch empfangen') + '</h4>' +
        '<label class="sw"><span>' + t('🛰 Wettersatelliten (METEOR)') + '</span><input type="checkbox" id="am"' + (p.autoMeteor ? ' checked' : '') + '></label>' +
        '<label class="sw"><span>' + t('Mindesthöhe') + '</span><select id="minel">' + [10,15,20,25,30,35,40,50,60].map(v => '<option' + (v === p.minElevation ? ' selected' : '') + ' value="' + v + '">' + v + '°</option>').join('') + '</select></label>' +
        '<label class="sw"><span>' + t('🎈 Radiosonden') + '</span><input type="checkbox" id="as"' + (p.autoSonde ? ' checked' : '') + '></label>' +
        '<label class="sw"><span>' + esc(t('📡 ISS & Amateurfunksatelliten')) + '</span><input type="checkbox" id="aa"' + (p.autoAmateur ? ' checked' : '') + '></label></div>';
      html += renderBalloons(p);
      // Bilder je Überflug gruppiert, bevorzugt das Farbbild als Vorschau.
      const groups = new Map();
      for (const img of p.images) { if (!groups.has(img.pass)) groups.set(img.pass, []); groups.get(img.pass).push(img); }
      let imgs = '';
      if (!groups.size) imgs += '<div class="empty">' + t('Noch keine Bilder.') + '</div>';
      else imgs += '<div class="gallery">' + [...groups.values()].map(list =>
        list.map(img => '<figure data-name="' + esc(img.name) + '" data-cap="' + esc(fmtDay(img.date) + ' ' + fmtTime(img.date) + ' · ' + img.composite) + '">' +
          '<img loading="lazy" src="/img?w=360&n=' + encodeURIComponent(img.name) + '" alt="">' +
          '<figcaption>' + esc(fmtDay(img.date) + ' ' + fmtTime(img.date)) + '<br>' + esc(img.composite) + '</figcaption></figure>').join('')).join('') + '</div>';
      html += wxBox('images', t('Empfangene Bilder'), imgs, groups.size || null);
      let passes = '';
      if (!p.homeSet) passes += '<div class="empty">' + t('Für die Vorhersage fehlt der Standort in der App.') + '</div>';
      else if (!p.passes.length) passes += '<div class="empty">' + esc(p.tleError || t('Bahndaten werden geladen …')) + '</div>';
      passes += p.passes.map(x => '<div class="item"><span>' + (x.daylight ? '☀︎' : '☾') + '</span><div class="grow"><div>' + esc(x.satellite) + '</div>' +
        '<div class="sub">' + esc(fmtDay(x.start) + ' · ' + fmtTime(x.start) + '–' + fmtTime(x.end) + ' · ' + x.from + ' → ' + x.to) + '</div></div>' +
        '<span class="el">' + x.maxElevation + '°</span>' + (x.planned ? '<span class="rec" title="' + t('wird aufgenommen') + '">●</span>' : '') + '</div>').join('');
      html += wxBox('passes', t('Überflüge (nächste 48 h)'), passes, p.passes.length || null);
      html += wxBox('windows', t('Sondenfenster'), (p.sondeWindows.length ? p.sondeWindows.map(w =>
        '<div class="item"><span>🎈</span><div class="grow">' + esc(fmtDay(w.start) + ' · ' + fmtTime(w.start) + '–' + fmtTime(w.end)) + '</div>' + (p.autoSonde ? '<span class="rec">●</span>' : '') + '</div>').join('')
        : '<div class="empty">' + t('Keine Startzeiten gewählt.') + '</div>') +
        ((p.sondeForecast || []).length ? '<div class="sub" style="margin-top:6px">' + t('Vorhersage (SondeHub-Bahnrechner):') + '</div>' + p.sondeForecast.map(f =>
          '<div class="item"><span>' + (f.from ? '✓' : '✗') + '</span><div class="grow"><div>' + esc(f.site + (f.frequency ? ' · ' + f.frequency.toFixed(1) + ' MHz' : '')) + '</div>' +
          '<div class="sub">' + esc((f.from ? tt('in Reichweite {0}–{1}', fmtTime(f.from), fmtTime(f.to)) : tt('nicht in Reichweite')) + ' · ' +
          tt('nächster Punkt {0} km um {1} in {2} km Höhe', f.closestKm, fmtTime(f.closestAt), (f.closestAltitude / 1000).toFixed(1)) + ' · ' + tt('Landung {0} km', f.landingKm)) + '</div></div></div>').join('') : ''), p.sondeWindows.length || null);
      const g = p.sondeGain;
      if (g) {
        const clip = g.clipped == null ? '' : ' · ' + tt('{0} % am Anschlag', (g.clipped * 100).toFixed(2));
        html += wxBox('gain', t('Sondenempfang'),
          '<label class="sw"><span>LNA</span><select id="slna">' + [0,8,16,24,32,40].map(v => '<option' + (v === g.lna ? ' selected' : '') + ' value="' + v + '">' + v + ' dB</option>').join('') + '</select></label>' +
          '<label class="sw"><span>VGA</span><select id="svga">' + Array.from({ length: 32 }, (_, i) => i * 2).map(v => '<option' + (v === g.vga ? ' selected' : '') + ' value="' + v + '">' + v + ' dB</option>').join('') + '</select></label>' +
          '<label class="sw"><span>' + t('Verstärkung automatisch nachregeln') + '</span><input type="checkbox" id="sauto"' + (g.auto ? ' checked' : '') + '></label>' +
          '<div class="sub">' + esc(g.rms == null ? tt('Kein Sondenempfang – die Werte gelten beim nächsten Fenster.') : tt('Pegel {0} dBFS', g.rms.toFixed(1)) + clip) + '</div>' +
          (g.note ? '<div class="sub">' + esc(tt('Zuletzt automatisch: {0}', g.note)) + '</div>' : ''));
      }
      html += wxBox('log', t('Verlauf'), p.history.length ? p.history.map(h =>
        '<div class="item"><div class="grow"><div>' + esc(h.title) + '</div><div class="sub">' + esc(fmtDay(h.date) + ' ' + fmtTime(h.date) + ' · ' + h.result) + '</div></div></div>').join('')
        : '<div class="empty">' + t('Noch nichts aufgenommen.') + '</div>', p.history.length || null);
      html += '<div class="hint">' + t('Satellitenzeiten in Ortszeit des Handys. Die Termine laufen in der App auf dem Mac – er muss wach bleiben.') + '</div>';
      // Beim Neuzeichnen die Bildlaufposition halten (Abfrage alle paar Sekunden).
      const top = box.scrollTop; box.innerHTML = html; box.scrollTop = top;
      if ($('skipjob')) $('skipjob').onclick = e => { e.target.disabled = true; e.target.textContent = t('Beende …'); loadPlan({ skip: 1 }); setTimeout(() => loadPlan(), 2500); };
      $('am').onchange = e => loadPlan({ meteor: e.target.checked ? 1 : 0 });
      $('as').onchange = e => loadPlan({ sonde: e.target.checked ? 1 : 0 });
      $('aa').onchange = e => loadPlan({ amateur: e.target.checked ? 1 : 0 });
      $('minel').onchange = e => { e.target.blur(); loadPlan({ minel: e.target.value }); };
      if ($('slna')) {
        $('slna').onchange = e => { e.target.blur(); loadPlan({ slna: e.target.value }); };
        $('svga').onchange = e => { e.target.blur(); loadPlan({ svga: e.target.value }); };
        $('sauto').onchange = e => loadPlan({ sauto: e.target.checked ? 1 : 0 });
      }
      box.querySelectorAll('figure').forEach(f => f.onclick = () => {
        const v = $('viewer');
        v.querySelector('img').src = '/img?w=1600&n=' + encodeURIComponent(f.dataset.name);
        v.querySelector('.cap').textContent = f.dataset.cap + ' – ' + t('zum Schließen tippen');
        v.style.display = 'flex';
      });
    }
    $('viewer').onclick = () => { $('viewer').style.display = 'none'; $('viewer').querySelector('img').removeAttribute('src'); };

    // ---------- ACARS & VDL2 ----------
    // Liste neueste zuerst; aufgeklappte Einträge bleiben beim Nachladen offen.
    let acars = null; const acarsOpen = new Set();
    // ATN (X.25-Daten der Lotsen, Inhalt nicht lesbar) standardmäßig ausgeblendet.
    let showATN = localStorage.getItem('acars-atn') === '1';
    async function loadACARS() {
      try { acars = await api('/api/acars'); if (tab === 'acars') renderACARS(); } catch (e) { showError(e); }
    }
    const fmtClock = ms => new Date(ms).toLocaleTimeString(LOCALE, { hour: '2-digit', minute: '2-digit', second: '2-digit' });
    function renderACARS() {
      const box = $('acars');
      if (!acars) { box.innerHTML = '<div class="empty">' + t('Lade …') + '</div>'; return; }
      const atnCount = acars.items.filter(m => m.label === 'ATN').length;
      const bar = '<div class="sortbar"><button data-atn' + (showATN ? ' class="on"' : '') + '>' + t('ATN-Verkehr') + (atnCount ? ' (' + atnCount + ')' : '') + '</button>' +
        '<span class="hint" style="flex:2;align-self:center;padding-left:6px">' + t('Routing, Quittungen und Verbindungsaufbau (X.25/ATN)') + '</span></div>';
      const items = acars.items.filter(m => showATN || m.label !== 'ATN');
      if (!items.length) {
        box.innerHTML = bar + '<div class="empty">' + (acars.running ? t('Noch keine Nachricht. VDL2 sendet in Schüben – meist einige pro Minute.') : t('Flugzeug-Datenfunk ist aus – oben „Start“ tippen.')) + '</div>';
        box.querySelector('[data-atn]').onclick = () => { showATN = !showATN; localStorage.setItem('acars-atn', showATN ? '1' : '0'); renderACARS(); };
        return;
      }
      box.innerHTML = bar + items.map(m => {
        const rows = m.rows.map(r => '<tr><td>' + esc(r[0]) + '</td><td>' + esc(r[1]) + '</td></tr>').join('');
        const meta = [m.labelName ? 'Label ' + m.label + ' – ' + m.labelName : 'Label ' + m.label, m.f.toFixed(3) + ' MHz',
                      m.blocks > 1 ? tt('{0} Blöcke', m.blocks) : null, m.icao ? 'ICAO ' + m.icao : null].filter(Boolean).join(' · ');
        return '<div class="msg' + (acarsOpen.has(m.id) ? ' open' : '') + '" data-id="' + m.id + '">' +
          '<div class="head"><span class="reg">' + esc(m.reg) + '</span>' + (m.flight ? '<span class="flt">' + esc(m.flight) + '</span>' : '') +
          '<span class="lab">' + esc(m.label) + (m.down ? '' : ' <span class="up">↓</span>') + '</span><span class="time">' + fmtClock(m.t) + '</span></div>' +
          '<div class="sum' + (m.opaque ? ' opaque' : '') + '">' + esc(m.summary) + '</div>' +
          '<div class="more"><div class="hint">' + esc(meta) + '</div>' + (rows ? '<table>' + rows + '</table>' : '') +
          (m.onMap ? '<div style="margin:6px 0"><button class="btn" style="margin:0" data-map="' + esc(m.icao) + '">' + t('Auf der Karte zeigen') + '</button></div>' : '') +
          (m.text && m.text !== m.summary ? '<div class="raw">' + esc(m.text) + '</div>' : '') + '</div></div>';
      }).join('');
      box.querySelector('[data-atn]').onclick = () => { showATN = !showATN; localStorage.setItem('acars-atn', showATN ? '1' : '0'); renderACARS(); };
      box.querySelectorAll('.msg').forEach(el => el.onclick = e => {
        if (e.target.dataset.map) { e.stopPropagation(); tab = 'adsb'; localStorage.setItem('tab', tab); sel = 'adsb:' + e.target.dataset.map; render(); select(sel, true); return; }
        const id = Number(el.dataset.id);
        if (acarsOpen.has(id)) acarsOpen.delete(id); else acarsOpen.add(id);
        el.classList.toggle('open');
      });
    }

    // ---------- Spektrum ----------
    // Eigener, schneller Abruf (≈ 3/s) nur bei offenem Reiter; Wasserfall
    // entsteht hier aus den abgerufenen Zeilen. Tippen ins Spektrum stimmt dorthin ab.
    let spec = null, specTimer = null, specPresets = null, specScale = null;
    const BWS = [2, 4, 8, 10, 16, 20];
    $('spbw').innerHTML = BWS.map(b => '<option value="' + b + '">' + b + ' MHz</option>').join('');
    $('splna').innerHTML = [0, 8, 16, 24, 32, 40].map(v => '<option>' + v + '</option>').join('');
    $('spvga').innerHTML = Array.from({ length: 32 }, (_, i) => i * 2).map(v => '<option>' + v + '</option>').join('');
    async function specSet(params) {
      try {
        if (state && state.mode !== 'spectrum') { state = await api('/api/mode', { m: 'spectrum' }); render(); }
        spec = await api('/api/spectrum', params); specScale = null; drawSpec(); specControls(true);
      } catch (e) { showError(e); }
    }
    async function loadSpecPresets() {
      try {
        specPresets = await api('/api/spectrum/presets');
        $('sppreset').innerHTML = '<option value="">' + t('Vorlage wählen …') + '</option>' + specPresets.map((g, gi) =>
          '<optgroup label="' + esc(g.title) + '">' + g.presets.map((p, pi) => '<option value="' + gi + ':' + pi + '">' + esc(p.name) + '</option>').join('') + '</optgroup>').join('');
      } catch (e) { showError(e); }
    }
    $('sppreset').onchange = e => {
      if (!e.target.value) return;
      const [gi, pi] = e.target.value.split(':').map(Number), p = specPresets[gi].presets[pi];
      specSet({ mhz: p.mhz, bw: p.bw });
    };
    $('spmhz').onchange = e => { const v = parseFloat(e.target.value); if (v >= 1 && v <= 6000) specSet({ mhz: v }); };
    $('spdown').onclick = () => spec && specSet({ mhz: Math.max(1, spec.centerMHz - spec.rateMHz / 2) });
    $('spup').onclick = () => spec && specSet({ mhz: Math.min(6000, spec.centerMHz + spec.rateMHz / 2) });
    $('spbw').onchange = e => specSet({ bw: e.target.value });
    $('splna').onchange = e => specSet({ lna: e.target.value });
    $('spvga').onchange = e => specSet({ vga: e.target.value });
    $('spamp').onchange = e => specSet({ amp: e.target.checked ? 1 : 0 });
    $('spcanvas').onclick = e => {
      if (!spec || !spec.running) return;
      const r = e.target.getBoundingClientRect(), x = (e.clientX - r.left) / r.width;
      specSet({ mhz: Math.round((spec.centerMHz + (x - 0.5) * spec.rateMHz) * 1000) / 1000 });
    };
    // Bedienelemente nur setzen, wenn niemand gerade darin tippt.
    function specControls(force) {
      if (!spec) return;
      const set = (id, v) => { const el = $(id); if (force || document.activeElement !== el) el.value = v; };
      set('spmhz', spec.centerMHz.toFixed(3)); set('spbw', String(BWS.includes(spec.rateMHz) ? spec.rateMHz : 20));
      set('splna', String(spec.lna)); set('spvga', String(spec.vga)); $('spamp').checked = spec.amplifier;
    }
    function fitCanvas(c) {
      const dpr = window.devicePixelRatio || 1, w = Math.round(c.clientWidth * dpr), h = Math.round(c.clientHeight * dpr);
      if (c.width !== w || c.height !== h) { c.width = w; c.height = h; return true; }
      return false;
    }
    const WF = [[0, 0, 0], [0, 0, .6], [0, .7, .9], [.95, .9, .1], [.95, .15, .1], [1, 1, 1]];
    function wfColor(t) {
      const x = Math.max(0, Math.min(1, t)) * (WF.length - 1), i = Math.min(Math.floor(x), WF.length - 2), f = x - i;
      return WF[i].map((a, k) => Math.round((a + (WF[i + 1][k] - a) * f) * 255));
    }
    function drawSpec() {
      const c = $('spcanvas'), w = $('wfcanvas');
      if (!spec || $('spec').style.display === 'none') return;
      fitCanvas(c);
      const ctx = c.getContext('2d'), W = c.width, H = c.height, dpr = window.devicePixelRatio || 1, b = spec.bins;
      const css = getComputedStyle(document.body);
      ctx.clearRect(0, 0, W, H);
      const info = $('spinfo');
      if (!spec.running || !b.length) { info.textContent = spec.error || t('Spektrum läuft nicht.'); return; }
      // Skala: Rauschboden (10 %) bis Höchstwert, sanft nachgeführt.
      const sorted = [...b].sort((x, y) => x - y), lo = sorted[Math.floor(sorted.length * .1)] - 6, hi = sorted[sorted.length - 1] + 6;
      specScale = specScale ? { lo: specScale.lo * .8 + lo * .2, hi: specScale.hi * .8 + hi * .2 } : { lo, hi: Math.max(hi, lo + 20) };
      const span = Math.max(20, specScale.hi - specScale.lo), y = v => H - (v - specScale.lo) / span * H;
      // Raster: Frequenzen
      ctx.strokeStyle = css.getPropertyValue('--line'); ctx.fillStyle = css.getPropertyValue('--muted'); ctx.lineWidth = 1;
      ctx.font = (11 * dpr) + 'px -apple-system, system-ui, sans-serif';
      for (let k = 0; k <= 4; k++) {
        const x = Math.round(k / 4 * (W - 1)) + .5;
        ctx.beginPath(); ctx.moveTo(x, 0); ctx.lineTo(x, H); ctx.stroke();
        const f = (spec.centerMHz + (k / 4 - .5) * spec.rateMHz).toFixed(spec.rateMHz < 5 ? 3 : 2);
        ctx.textAlign = k === 0 ? 'left' : k === 4 ? 'right' : 'center'; ctx.fillText(f, x + (k === 0 ? 3 : k === 4 ? -3 : 0), H - 4 * dpr);
      }
      ctx.textAlign = 'left'; ctx.fillText(Math.round(specScale.hi) + ' dB', 3 * dpr, 12 * dpr);
      // Kurve
      ctx.beginPath();
      b.forEach((v, i) => { const x = i / (b.length - 1) * W; i ? ctx.lineTo(x, y(v)) : ctx.moveTo(x, y(v)); });
      ctx.strokeStyle = css.getPropertyValue('--accent'); ctx.lineWidth = 1.5 * dpr; ctx.stroke();
      ctx.lineTo(W, H); ctx.lineTo(0, H); ctx.closePath(); ctx.globalAlpha = .15; ctx.fillStyle = css.getPropertyValue('--accent'); ctx.fill(); ctx.globalAlpha = 1;
      // Spitze ohne DC-Spitze in der Mitte
      let best = 0; const mid = b.length / 2;
      b.forEach((v, i) => { if (Math.abs(i - mid) > 2 && v > b[best]) best = i; });
      const pf = spec.centerMHz + (best / b.length - .5) * spec.rateMHz;
      info.textContent = tt('Mitte {0} MHz · {1} MHz breit · Spitze {2} MHz, {3} dB · Tippen stimmt ab', spec.centerMHz.toFixed(3), spec.rateMHz, pf.toFixed(3), b[best]);
      // Wasserfall: eine Zeile nach unten schieben, neue oben
      const wctx = w.getContext('2d');
      if (fitCanvas(w)) { wctx.fillStyle = '#000'; wctx.fillRect(0, 0, w.width, w.height); }
      const rowH = Math.max(1, Math.round(2 * dpr));
      wctx.drawImage(w, 0, 0, w.width, w.height - rowH, 0, rowH, w.width, w.height - rowH);
      const img = wctx.createImageData(b.length, 1);
      b.forEach((v, i) => { const [r, g, bl] = wfColor((v - specScale.lo) / span); img.data.set([r, g, bl, 255], i * 4); });
      const tmp = document.createElement('canvas'); tmp.width = b.length; tmp.height = 1; tmp.getContext('2d').putImageData(img, 0, 0);
      wctx.imageSmoothingEnabled = false; wctx.drawImage(tmp, 0, 0, w.width, rowH);
    }
    async function specPoll() {
      clearTimeout(specTimer);
      if (tab !== 'spectrum') return;
      try { spec = await api('/api/spectrum'); drawSpec(); specControls(false); } catch (e) {}
      specTimer = setTimeout(specPoll, 300);
    }

    // ---------- Zigbee ----------
    // Geräteliste und Netzkarte (`/api/zigbee`). Die Anordnung rechnet die App
    // (dasselbe Kräftemodell wie dort, Koordinator in der Mitte); hier wird nur
    // gezeichnet. Ziehen verschiebt, zwei Finger/Mausrad zoomen, Tippen wählt.
    // Namen und Typen gehen nur über esc() ins HTML (Canvas-Text ist kein HTML).
    let zb = null, zbSel = null, zbPan = null;
    let zbAll = false; try { zbAll = localStorage.getItem('zbAll') === '1'; } catch (e) {}
    let zbSort = 'name'; try { zbSort = localStorage.getItem('zbSort') || 'name'; } catch (e) {}
    const zbView = { scale: 1, x: 0, y: 0 };
    const ZB_COLORS = { coordinator: '#ff9f0a', router: '#0a84ff', end: '#30a14e' };
    async function loadZigbee(params = {}) {
      if (zbPan) params.pan = zbPan;
      try { zb = await api('/api/zigbee', params); if (tab === 'zigbee') render(); } catch (e) { showError(e); }
    }
    function zigbeeStatus() {
      if (!zb) return 'Zigbee';
      const n = tt('{0} Geräte', zb.devices.length);
      return zb.running ? n + ' · ' + tt('{0} Rahmen/s', zb.rate.toFixed(1)) + ' · ' + tt('Kanal {0}', zb.channel) : tt('Zigbee aus') + ' · ' + n;
    }
    function zbLabel(d) { return d.name || (d.role === 'coordinator' ? t('Koordinator') : d.addr); }
    function zbAge(s) { return s < 60 ? s + ' s' : s < 3600 ? Math.round(s / 60) + ' min' : Math.round(s / 3600) + ' h'; }
    function zbGeom() {
      const c = $('zbcanvas'), r = c.getBoundingClientRect(), dpr = window.devicePixelRatio || 1;
      const w = Math.round(r.width * dpr), h = Math.round(r.height * dpr);
      if (c.width !== w || c.height !== h) { c.width = w; c.height = h; }
      // Außenring (1,12) mit Rand im Bild; höchstens 1,6 : 1 verzerrt wie in der App.
      const fx = Math.max(30, (r.width / 2 - 24) / 1.15), fy = Math.max(30, (r.height / 2 - 34) / 1.15);
      const sx = Math.min(fx, fy * 1.6), sy = Math.min(fy, fx * 1.6);
      return { c, w: r.width, h: r.height, dpr, sx: sx * zbView.scale, sy: sy * zbView.scale,
               cx: r.width / 2 + zbView.x, cy: r.height / 2 + zbView.y - 8 };
    }
    function zbPoint(g, d) { return d.x == null ? null : [g.cx + d.x * g.sx, g.cy + d.y * g.sy]; }
    function zbRadius(d) {
      const base = d.role === 'coordinator' ? 12 : (d.role === 'router' ? 6 : 4.5) + Math.min(5, d.links * 0.35);
      return base * Math.max(1, Math.sqrt(zbView.scale));
    }
    function drawZigbee() {
      if (!zb || tab !== 'zigbee') return;
      const g = zbGeom(), ctx = g.c.getContext('2d');
      const css = getComputedStyle(document.documentElement);
      ctx.setTransform(g.dpr, 0, 0, g.dpr, 0, 0);
      ctx.clearRect(0, 0, g.w, g.h);
      ctx.setLineDash([4, 6]); ctx.lineWidth = 1; ctx.strokeStyle = 'rgba(128,128,128,.35)';
      ctx.beginPath(); ctx.ellipse(g.cx, g.cy, 1.12 * g.sx, 1.12 * g.sy, 0, 0, 2 * Math.PI); ctx.stroke(); ctx.setLineDash([]);
      const byAddr = new Map(zb.devices.map(d => [d.addr, d]));
      const near = new Set();
      if (zbSel) zb.edges.forEach(e => { if (e.a === zbSel) near.add(e.b); if (e.b === zbSel) near.add(e.a); });
      // Kanten: schwache dünn und blass, gute kräftig; die des gewählten Geräts hervorgehoben.
      const edges = zb.edges.filter(e => zbAll || e.top || (zbSel && (e.a === zbSel || e.b === zbSel))).sort((a, b) => a.q - b.q);
      for (const e of edges) {
        const a = byAddr.get(e.a), b = byAddr.get(e.b);
        const pa = a && zbPoint(g, a), pb = b && zbPoint(g, b);
        if (!pa || !pb) continue;
        const touches = zbSel && (e.a === zbSel || e.b === zbSel);
        const alpha = zbSel ? (touches ? 0.95 : 0.08) : 0.3 + 0.5 * e.q;
        ctx.strokeStyle = 'hsla(' + Math.round(e.q * 120) + ',75%,45%,' + alpha + ')';
        ctx.lineWidth = touches ? 2.5 : 0.8 + 2 * e.q;
        ctx.beginPath(); ctx.moveTo(pa[0], pa[1]); ctx.lineTo(pb[0], pb[1]); ctx.stroke();
      }
      const importance = d => (d.role === 'coordinator' ? 1e4 : 0) + (d.name ? 1e3 : 0) + (d.role === 'router' ? 500 : 0) + d.links;
      const labels = [];
      ctx.font = '12px -apple-system, system-ui, sans-serif';
      for (const d of zb.devices.slice().sort((a, b) => importance(b) - importance(a))) {
        const p = zbPoint(g, d);
        if (!p) continue;
        const r = zbRadius(d);
        ctx.globalAlpha = zbSel && zbSel !== d.addr && !near.has(d.addr) ? 0.35 : 1;
        ctx.fillStyle = ZB_COLORS[d.role] || '#888';
        ctx.beginPath(); ctx.arc(p[0], p[1], r, 0, 2 * Math.PI); ctx.fill();
        ctx.lineWidth = d.addr === zbSel ? 3 : 1;
        ctx.strokeStyle = d.addr === zbSel ? css.getPropertyValue('--sel').trim() : 'rgba(0,0,0,.5)';
        ctx.stroke();
        ctx.globalAlpha = 1;
        const text = zbLabel(d), w = ctx.measureText(text).width + 10;
        labels.push({ d, text, x: p[0] - w / 2, y: p[1] + r + 3, w, h: 16 });
      }
      // Beschriftungen: wichtige zuerst, überlappende entfallen; die gewählte immer.
      const i = labels.findIndex(l => l.d.addr === zbSel);
      if (i > 0) labels.unshift(labels.splice(i, 1)[0]);
      const placed = [];
      ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
      for (const l of labels) {
        if (placed.some(o => l.x < o.x + o.w + 2 && o.x < l.x + l.w + 2 && l.y < o.y + o.h + 1 && o.y < l.y + l.h + 1)) continue;
        placed.push(l);
        ctx.fillStyle = css.getPropertyValue('--card').trim();
        ctx.globalAlpha = l.d.addr === zbSel ? 0.95 : 0.78;
        if (ctx.roundRect) { ctx.beginPath(); ctx.roundRect(l.x, l.y, l.w, l.h, 4); ctx.fill(); } else ctx.fillRect(l.x, l.y, l.w, l.h);
        ctx.globalAlpha = 1;
        ctx.fillStyle = css.getPropertyValue('--text').trim();
        ctx.font = (l.d.addr === zbSel ? '600 ' : '') + '12px -apple-system, system-ui, sans-serif';
        ctx.fillText(l.text, l.x + l.w / 2, l.y + l.h / 2 + 0.5);
      }
      if (!zb.devices.length) {
        ctx.fillStyle = css.getPropertyValue('--muted').trim(); ctx.font = '14px -apple-system, system-ui, sans-serif';
        ctx.fillText(zb.running ? t('Noch keine Geräte – die Karte braucht Nachbartabellen.') : t('Zigbee empfängt gerade nicht.'), g.w / 2, g.h / 2);
      }
    }
    function renderZigbee() {
      if (!zb) { $('zblist').innerHTML = '<div class="empty">' + t('Lade …') + '</div>'; return; }  // entfernt auch #zbbar
      $('zball').checked = zbAll;
      // Kopf: Netz (bei mehreren) und Kanal; darunter Sortierung und Geräte.
      const nets = zb.networks.length > 1
        ? '<select id="zbnet" aria-label="' + t('Netz') + '">' + zb.networks.map(n => '<option value="' + esc(n.pan) + '"' + (n.pan === zb.pan ? ' selected' : '') + '>' + t('Netz {0}', n.pan) + ' · ' + n.devices + (n.onChannel ? '' : ' · ' + t('anderer Kanal')) + '</option>').join('') + '</select>'
        : '';
      // Kanal auch ohne Empfang wählbar: der Mac merkt ihn sich, „Start“ nutzt ihn
      // (setChannel stimmt nur den eigenen Strom um).
      let channels = '<select id="zbch" aria-label="' + t('Kanal') + '">';
      for (let c = 11; c <= 26; c++) channels += '<option value="' + c + '"' + (c === zb.channel ? ' selected' : '') + '>' + t('Kanal {0}', c) + '</option>';
      channels += '</select>';
      const sorts = [['name', t('Name')], ['rssi', t('Pegel')], ['age', t('Zuletzt')]];
      const bar = '<div class="sortbar">' + nets + channels + '</div><div class="sortbar">' +
        sorts.map(([k, lbl]) => '<button data-zbsort="' + k + '"' + (zbSort === k ? ' class="on"' : '') + '>' + lbl + '</button>').join('') + '</div>';
      const list = zb.devices.slice().sort((a, b) =>
        zbSort === 'rssi' ? (b.rssi ?? -999) - (a.rssi ?? -999)
        : zbSort === 'age' ? a.age - b.age
        : (a.role === 'coordinator' ? -1 : 0) - (b.role === 'coordinator' ? -1 : 0) || zbLabel(a).localeCompare(zbLabel(b), LOCALE, { numeric: true, sensitivity: 'base' }));
      const rows = list.map(d => {
        const sub = [d.type, d.addr, d.lqi != null ? 'LQI ' + d.lqi : null].filter(Boolean).join(' · ');
        const right = (d.rssi != null ? d.rssi + ' dB · ' : '') + zbAge(d.age);
        return '<div class="row' + (d.addr === zbSel ? ' sel' : '') + '" data-zb="' + esc(d.addr) + '">' +
          '<span style="color:' + (ZB_COLORS[d.role] || '#888') + '">●</span><span class="t">' + esc(zbLabel(d)) + '</span>' +
          '<span class="s">' + esc(sub) + '</span><span class="r">' + esc(right) + '</span></div>';
      }).join('');
      const empty = '<div class="empty">' + (zb.running ? t('Noch keine Geräte gehört.') : t('Zigbee empfängt gerade nicht – Kanal wählen und oben „Start“ tippen.')) + '</div>';
      // Kopf (Netz, Kanal, Sortierung) und Geräte getrennt: Mit einem
      // gemeinsamen innerHTML schloss jede Abfrage eine gerade geöffnete
      // Auswahlliste wieder (Fund 28.10.2026, iPhone). Der Kopf wird nur neu
      // gebaut, wenn er sich ändert und keine seiner Auswahllisten bedient wird.
      const list$ = $('zblist');
      if (!$('zbbar')) { list$.innerHTML = '<div id="zbbar"></div><div id="zbrows"></div>'; }
      const head = $('zbbar'), active = document.activeElement;
      const busy = active && active.tagName === 'SELECT' && head.contains(active);
      if (head.dataset.html !== bar && !busy) {
        head.dataset.html = bar; head.innerHTML = bar;
        if ($('zbnet')) $('zbnet').onchange = e => { zbPan = e.target.value; zbSel = null; zbView.scale = 1; zbView.x = zbView.y = 0; e.target.blur(); loadZigbee(); };
        $('zbch').onchange = e => { e.target.blur(); loadZigbee({ ch: e.target.value }); };
      }
      $('zbrows').innerHTML = rows || empty;
      renderZbCard();
      drawZigbee();
    }
    function renderZbCard() {
      const card = $('zbcard'), d = zb && zb.devices.find(x => x.addr === zbSel);
      if (!d) { card.style.display = 'none'; return; }
      const names = new Map(zb.devices.map(x => [x.addr, zbLabel(x)]));
      const links = zb.edges.filter(e => e.a === d.addr || e.b === d.addr).sort((a, b) => b.q - a.q);
      const rows = [
        [tt('Adresse'), d.addr + (zb.pan ? ' · ' + tt('Netz {0}', zb.pan) : '')],
        ['IEEE', d.ieee],
        [t('Pegel'), d.rssi != null ? d.rssi + ' dB' : null],
        ['LQI', d.lqi != null ? tt('{0} von 255', d.lqi) : null],
        [tt('Zuletzt gehört'), tt('vor {0}', zbAge(d.age))],
        [t('Rahmen'), d.heard ? String(d.heard) : null],
        [t('Versorgung'), d.power],
        [t('Zustand'), d.state],
        [t('Verbindungen'), links.length ? links.slice(0, 6).map(e => (names.get(e.a === d.addr ? e.b : e.a) || '') + ' – ' + Math.round(e.q * 100) + ' %').join('\n') : null]
      ].filter(r => r[1]);
      card.innerHTML = '<h3><span>' + esc(zbLabel(d)) + '</span><button id="zbclose" aria-label="' + t('Schließen') + '">✕</button></h3>' +
        '<div class="sub">' + esc(d.type) + '</div><table>' +
        rows.map(r => '<tr><td>' + esc(r[0]) + '</td><td style="white-space:pre-line">' + esc(r[1]) + '</td></tr>').join('') + '</table>';
      card.style.display = 'block';
      $('zbclose').onclick = () => zbSelect(null);
    }
    function zbSelect(addr) { zbSel = addr; renderZigbee(); }
    $('zblist').onclick = e => {
      const s = e.target.closest('[data-zbsort]');
      if (s) { zbSort = s.dataset.zbsort; try { localStorage.setItem('zbSort', zbSort); } catch (x) {} renderZigbee(); return; }
      const row = e.target.closest('[data-zb]');
      if (row) zbSelect(row.dataset.zb === zbSel ? null : row.dataset.zb);
    };
    $('zball').onchange = e => { zbAll = e.target.checked; try { localStorage.setItem('zbAll', zbAll ? '1' : '0'); } catch (x) {} drawZigbee(); };
    // Zoomen um einen Punkt: der Punkt darunter bleibt stehen (dx/dy: Verschiebung beim Pinch).
    function zbZoomAt(px, py, scale, from) {
      const g = zbGeom(), next = Math.min(8, Math.max(0.4, scale));
      const k = next / from.scale;
      zbView.x = px - g.w / 2 - (px - g.w / 2 - from.x) * k + (from.dx || 0);
      zbView.y = py - g.h / 2 - (py - g.h / 2 - from.y) * k + (from.dy || 0);
      zbView.scale = next;
    }
    $('zbin').onclick = () => { const g = zbGeom(); zbZoomAt(g.w / 2, g.h / 2, zbView.scale * 1.4, { ...zbView }); drawZigbee(); };
    $('zbout').onclick = () => { const g = zbGeom(); zbZoomAt(g.w / 2, g.h / 2, zbView.scale / 1.4, { ...zbView }); drawZigbee(); };
    $('zbreset').onclick = () => { zbView.scale = 1; zbView.x = zbView.y = 0; drawZigbee(); };
    (() => {
      const c = $('zbcanvas'), pts = new Map();
      let start = null, moved = false;
      const begin = () => { start = { view: { ...zbView }, pts: [...pts.values()].map(p => p.slice()) }; };
      const pos = e => { const r = c.getBoundingClientRect(); return [e.clientX - r.left, e.clientY - r.top]; };
      c.addEventListener('pointerdown', e => { try { c.setPointerCapture(e.pointerId); } catch (x) {} pts.set(e.pointerId, pos(e)); if (pts.size === 1) moved = false; begin(); });
      c.addEventListener('pointermove', e => {
        if (!pts.has(e.pointerId) || !start) return;
        pts.set(e.pointerId, pos(e));
        const now = [...pts.values()];
        if (now.length === 1 && start.pts.length === 1) {
          const dx = now[0][0] - start.pts[0][0], dy = now[0][1] - start.pts[0][1];
          if (Math.hypot(dx, dy) > 4) moved = true;
          if (moved) { zbView.x = start.view.x + dx; zbView.y = start.view.y + dy; drawZigbee(); }
        } else if (now.length >= 2 && start.pts.length >= 2) {
          moved = true;
          const [a0, b0] = start.pts, [a1, b1] = now;
          const d0 = Math.hypot(a0[0] - b0[0], a0[1] - b0[1]) || 1, d1 = Math.hypot(a1[0] - b1[0], a1[1] - b1[1]);
          const m0 = [(a0[0] + b0[0]) / 2, (a0[1] + b0[1]) / 2], m1 = [(a1[0] + b1[0]) / 2, (a1[1] + b1[1]) / 2];
          zbZoomAt(m0[0], m0[1], start.view.scale * d1 / d0, { ...start.view, dx: m1[0] - m0[0], dy: m1[1] - m0[1] });
          drawZigbee();
        }
      });
      const end = e => {
        if (!pts.has(e.pointerId)) return;
        const p = pos(e);
        pts.delete(e.pointerId);
        if (!moved && pts.size === 0 && zb) {
          // Tippen: nächstes Gerät in Fingerreichweite wählen, sonst Auswahl aufheben.
          const g = zbGeom();
          let best = null, bestDist = 26;
          for (const d of zb.devices) {
            const q = zbPoint(g, d);
            if (!q) continue;
            const dist = Math.hypot(q[0] - p[0], q[1] - p[1]) - zbRadius(d);
            if (dist < bestDist) { best = d.addr; bestDist = dist; }
          }
          zbSelect(best);
        }
        begin();
      };
      c.addEventListener('pointerup', end);
      c.addEventListener('pointercancel', end);
      c.addEventListener('wheel', e => {
        e.preventDefault();
        const p = pos(e);
        zbZoomAt(p[0], p[1], zbView.scale * Math.exp(-e.deltaY * 0.0015), { ...zbView });
        drawZigbee();
      }, { passive: false });
      c.addEventListener('dblclick', () => { zbView.scale = 1; zbView.x = zbView.y = 0; drawZigbee(); });
      new ResizeObserver(() => drawZigbee()).observe($('zbmapwrap'));
      matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => drawZigbee());
    })();

    // ---------- Radio (UKW/AM) ----------
    // UKW/NFM/AM: großer Frequenzanzeiger, Schritte, Betriebsart, Rauschsperre, RDS,
    // Favoriten und der letzte Suchlauf. Der Ton läuft über den gemeinsamen Strom
    // /audio.aac. Kopf und Eingabefeld werden einmal gebaut und danach nur befüllt –
    // sonst verlöre das Feld beim Polling Fokus und Eingabe.
    let fmData = null;
    document.head.insertAdjacentHTML('beforeend', '<style>' +
      '.fmnow { padding:14px 12px; text-align:center; }' +
      '.fmfreq { font:600 46px/1.1 ui-monospace, Menlo, monospace; font-variant-numeric:tabular-nums; letter-spacing:-1px; overflow-wrap:anywhere; }' +
      '.fmfreq small { font:500 16px -apple-system, system-ui, sans-serif; color:var(--muted); letter-spacing:0; }' +
      '.fmbadges { min-height:20px; margin-top:4px; }' +
      '.fmbadges span { display:inline-block; font-size:11px; border:1px solid var(--line); border-radius:4px; padding:1px 6px; margin:0 2px; color:var(--muted); }' +
      '.fmbadges span.on { color:var(--ok); border-color:var(--ok); }' +
      '.fmname { font-size:20px; font-weight:600; min-height:1.3em; margin-top:6px; overflow-wrap:anywhere; }' +
      '.fmtext { color:var(--muted); font-size:14px; min-height:1.2em; overflow-wrap:anywhere; }' +
      '.fmrow { display:flex; gap:8px; justify-content:center; align-items:center; flex-wrap:wrap; margin-top:12px; }' +
      '.fmrow .btn { margin-left:0; }' +
      '.fmrow .btn:disabled, .fmin .btn:disabled { opacity:.4; cursor:default; }' +
      '#fmprev, #fmnext { min-width:56px; font-size:18px; }' +
      '#fmplay { min-width:150px; }' +
      '.fmseg { display:flex; gap:3px; margin:12px auto 0; max-width:320px; background:var(--bg); border-radius:9px; padding:3px; }' +
      '.fmseg button { flex:1; min-width:0; border:0; background:none; color:var(--text); padding:7px 4px; border-radius:7px; font:600 14px -apple-system, system-ui, sans-serif; cursor:pointer; }' +
      '.fmseg button.on { background:var(--accent); color:#fff; }' +
      '.fmsq b { min-width:52px; display:inline-block; }' +
      '.fmsq .dot { display:inline-block; width:9px; height:9px; border-radius:50%; background:var(--line); margin-right:4px; }' +
      '.fmsq .dot.open { background:var(--ok); }' +
      '.fmin { display:flex; gap:6px; padding:8px; }' +
      '.fmin input { flex:1; min-width:0; font:16px -apple-system, system-ui, sans-serif; border:1px solid var(--line); border-radius:8px; padding:7px 9px; background:var(--bg); color:var(--text); }' +
      '.fmin .btn { margin-left:0; }' +
      '.fmst { cursor:pointer; }' +
      '.fmst.on { background:color-mix(in srgb, var(--accent) 18%, transparent); }' +
      '.fmst .db { color:var(--muted); font-size:13px; font-variant-numeric:tabular-nums; flex:none; }' +
      '</style>');
    const FM_MODES = { wfm: t('UKW'), nfm: 'NFM', am: 'AM', usb: 'USB', lsb: 'LSB', cw: 'CW' };
    const FM_SSB = { usb: 1, lsb: 1, cw: 1 };
    function fmFmt(mhz, mode) {
      return mode === 'wfm' ? mhz.toFixed(2) : FM_SSB[mode] ? mhz.toFixed(5) : mhz.toFixed(4).replace(/0$/, '');
    }
    // Filterbreite: „250 Hz“, „2,4 kHz“.
    const fmHz = v => v < 1000 ? v.toFixed(0) + ' Hz'
      : (v / 1000).toLocaleString(LOCALE, { minimumFractionDigits: 0, maximumFractionDigits: 2 }) + ' kHz';
    async function loadFM(params = {}) {
      try {
        const d = await api('/api/fm', params);
        fmData = d;
        if (d.notice) showError(d.notice);
        if (tab === 'fm') render();
      } catch (e) { showError(e); }
    }
    function fmStatus() {
      if (state.mode !== 'fm' || !fmData || !fmData.running) return t('Radio aus');
      return fmFmt(fmData.mhz, fmData.mode) + ' MHz · ' + FM_MODES[fmData.mode] +
        (fmData.rdsName ? ' · ' + fmData.rdsName : '') + (fmData.scanning ? ' · ' + t('Suchlauf') : '');
    }
    function fmFavorite() {
      return fmData && fmData.favorites.find(f => Math.abs(f.mhz - fmData.mhz) < 0.00005);
    }
    function fmBuild() {
      if ($('fmhead')) return;
      $('x-fm').innerHTML =
        '<div class="box fmnow" id="fmhead">' +
          '<div class="fmfreq"><span id="fmmhz">–</span><small> MHz</small></div>' +
          '<div class="fmbadges" id="fmbadges"></div>' +
          '<div class="fmname" id="fmname"></div>' +
          '<div class="fmtext" id="fmtext"></div>' +
          '<div class="fmrow">' +
            '<button class="btn secondary" id="fmprev" aria-label="' + t('Schritt zurück') + '">◀︎</button>' +
            '<button class="btn" id="fmplay">' + t('🔈 Hier anhören') + '</button>' +
            '<button class="btn secondary" id="fmnext" aria-label="' + t('Schritt vor') + '">▶︎</button>' +
          '</div>' +
          '<div class="fmseg" id="fmseg">' + Object.keys(FM_MODES).map(m => '<button data-m="' + m + '">' + FM_MODES[m] + '</button>').join('') + '</div>' +
          '<div class="fmseg" id="fmbw" aria-label="' + t('Filterbreite') + '"></div>' +
          '<div class="fmrow fmsq" id="fmsq"><span class="hint">' + t('Rauschsperre') + '</span>' +
            '<button class="btn secondary" data-sq="-1" aria-label="' + t('Rauschsperre kleiner') + '">−</button><b id="fmsqv"></b>' +
            '<button class="btn secondary" data-sq="1" aria-label="' + t('Rauschsperre größer') + '">+</button><span class="hint" id="fmsqst"></span></div>' +
          '<div class="fmrow"><button class="btn secondary" id="fmstar">' + t('☆ Merken') + '</button></div>' +
          '<div class="hint" id="fmhint" style="margin-top:10px"></div>' +
        '</div>' +
        '<div class="box fmin"><input id="fmf" inputmode="decimal" enterkeyhint="go" autocomplete="off" placeholder="' + t('Frequenz in MHz, z. B. 99.2') + '" aria-label="' + t('Frequenz in MHz') + '">' +
          '<button class="btn" id="fmgo">' + t('Abstimmen') + '</button></div>' +
        '<div id="fmlist"></div>';
      const tune = () => {
        const v = $('fmf').value.trim().replace(',', '.');
        if (!v) return;
        if (!isFinite(Number(v))) { showError(t('Bitte eine Frequenz in MHz eingeben.')); return; }
        $('fmf').blur();
        loadFM({ f: v }).then(() => { if (fmData && !fmData.notice) $('fmf').value = ''; });
      };
      $('fmgo').onclick = tune;
      $('fmf').addEventListener('keydown', e => { if (e.key === 'Enter') { e.preventDefault(); tune(); } });
      $('fmprev').onclick = () => loadFM({ step: -1 });
      $('fmnext').onclick = () => loadFM({ step: 1 });
      $('fmplay').onclick = toggleAudio;
      $('fmseg').querySelectorAll('[data-m]').forEach(b => b.onclick = () => loadFM({ mode: b.dataset.m }));
      $('fmsq').querySelectorAll('[data-sq]').forEach(b => b.onclick = () => {
        if (fmData) loadFM({ squelch: fmData.squelch + Number(b.dataset.sq) });
      });
      $('fmstar').onclick = () => {
        if (!fmData) return;
        const fav = fmFavorite();
        loadFM(fav ? { delfav: fav.id } : { addfav: 1 });
      };
    }
    function renderFM() {
      fmBuild();
      const d = fmData;
      if (!d) { $('fmlist').innerHTML = '<div class="empty">' + t('Lade …') + '</div>'; return; }
      const active = state.mode === 'fm' && d.running;
      // Ohne laufendes Radio schaltet der Mac beim Abstimmen selbst um (ein Tippen genügt).
      const canTune = !d.scanning;
      $('fmmhz').textContent = fmFmt(d.mhz, d.mode);
      $('fmbadges').innerHTML = '<span>' + FM_MODES[d.mode] + '</span>' +
        (d.mode === 'wfm' && active ? '<span' + (d.stereo ? ' class="on"' : '') + '>' + (d.stereo ? t('Stereo') : t('Mono')) + '</span>' : '') +
        (d.programType ? '<span>' + esc(d.programType) + '</span>' : '') +
        (active && d.signalDB != null ? '<span>' + d.signalDB.toFixed(0) + ' dB</span>' : '');
      $('fmname').textContent = d.rdsName || '';
      $('fmtext').textContent = d.rdsText || '';
      $('fmplay').textContent = audioLabel();
      $('fmprev').disabled = $('fmnext').disabled = $('fmgo').disabled = !canTune;
      $('fmseg').querySelectorAll('[data-m]').forEach(b => b.classList.toggle('on', b.dataset.m === d.mode));
      // Filterbreiten der Betriebsart (UKW: fest, Zeile ausgeblendet); nur bei neuer Auswahl neu bauen.
      const bws = d.bandwidths || [];
      const bwBox = $('fmbw');
      bwBox.style.display = bws.length ? '' : 'none';
      const bwKey = bws.join(',');
      if (bwBox.dataset.k !== bwKey) {
        bwBox.dataset.k = bwKey;
        bwBox.innerHTML = bws.map(v => '<button data-bw="' + v + '">' + fmHz(v) + '</button>').join('');
        bwBox.querySelectorAll('[data-bw]').forEach(b => b.onclick = () => loadFM({ bw: b.dataset.bw }));
      }
      bwBox.querySelectorAll('[data-bw]').forEach(b => b.classList.toggle('on', Number(b.dataset.bw) === d.bandwidth));
      const sqUsed = d.mode === 'nfm' || d.mode === 'am';
      $('fmsq').style.display = sqUsed ? '' : 'none';
      $('fmsqv').textContent = d.squelch > 0 ? d.squelch.toFixed(0) + ' dB' : t('aus');
      $('fmsqst').innerHTML = active && d.squelch > 0
        ? '<span class="dot' + (d.squelchOpen ? ' open' : '') + '"></span>' + (d.squelchOpen ? t('offen') : t('zu')) +
          (d.aboveFloor != null ? ' · ' + t('{0} dB über Rauschen', d.aboveFloor.toFixed(0)) : '')
        : '';
      $('fmstar').textContent = fmFavorite() ? t('★ Gemerkt') : t('☆ Merken');
      $('fmhint').textContent =
        d.notice ? d.notice
        : state.mode !== 'fm' ? t('Das Radio ist aus – „Start“ oben, Abstimmen, ein Favorit oder ein Suchlauf schaltet es ein.')
        : d.scanning ? (d.scanStatus || t('Suchlauf läuft …')) + ' · ' + Math.round(d.scanProgress * 100) + ' %'
        : !d.owned ? t('Der HackRF ist gerade von einer anderen Seite belegt.')
        : t('Solange hier jemand zuhört, bleibt der Mac stumm.') + (sqUsed ? '' : ' ' + t('Die Rauschsperre gilt nur für NFM und AM.'));
      // Favoriten und Suchlauf: nur bei geändertem Inhalt neu setzen.
      const near = m => Math.abs(m - d.mhz) < 0.00005;
      let html = wxBox('fm-scan', t('Suchlauf'), d.scanning
          ? '<div class="abbar"><span class="hint" style="flex:1">' + esc((d.scanBand ? d.scanBand + ' · ' : '') + (d.scanStatus || t('läuft …'))) +
            ' · ' + Math.round(d.scanProgress * 100) + ' %</span><button class="btn secondary" id="fmscanstop">' + t('Abbrechen') + '</button></div>'
          : '<div class="fmbands">' + (d.bands || []).map(b => '<button data-band="' + b.i + '"><b>' + esc(b.name) + '</b><span>' + esc(b.range + ' · ' + FM_MODES[b.mode]) + '</span></button>').join('') + '</div>');
      // Frequenzspeicher (gemeinsam mit dem Mac): hier nur anzeigen und abstimmen, bearbeiten am Mac.
      html += wxBox('fm-fav', t('Frequenzspeicher'), d.favorites.length ? d.favorites.map(f =>
        '<div class="item fmst' + (near(f.mhz) ? ' on' : '') + '" data-fav="' + f.id + '"><div class="grow"><div>' +
          esc((f.name ? f.name + ' · ' : '') + fmFmt(f.mhz, f.mode) + ' MHz') + '</div>' +
          '<div class="sub">' + esc((f.kind && f.kind !== FM_MODES[f.mode] ? f.kind + ' · ' : '') + (FM_MODES[f.mode] || f.mode)) + '</div></div></div>').join('')
        : '<div class="empty">' + t('Noch keine Favoriten – oben „☆ Merken“ tippen.') + '</div>', d.favorites.length || null);
      if (d.stations.length) {
        html += wxBox('fm-found', t('Letzter Suchlauf') + (d.scanBand ? ' · ' + d.scanBand : ''),
          d.stations.map(s => '<div class="item fmst' + (near(s.mhz) ? ' on' : '') + '" data-f="' + s.mhz + '"><div class="grow"><div>' +
            esc((s.name ? s.name + ' · ' : '') + fmFmt(s.mhz, d.scanMode || d.mode) + ' MHz') + '</div>' +
            (s.spur ? '<div class="sub">' + t('vielleicht Störlinie des HackRF') + '</div>' : '') + '</div>' +
            '<span class="db">' + s.db.toFixed(0) + ' dB</span></div>').join(''), d.stations.length);
      }
      const list = $('fmlist');
      if (list.dataset.html !== html) {
        list.dataset.html = html; list.innerHTML = html;
        list.querySelectorAll('[data-fav]').forEach(r => r.onclick = () => loadFM({ fav: r.dataset.fav }));
        list.querySelectorAll('[data-band]').forEach(b => b.onclick = () => loadFM({ scan: b.dataset.band }));
        if ($('fmscanstop')) $('fmscanstop').onclick = () => loadFM({ scancancel: 1 });
        list.querySelectorAll('[data-f]').forEach(r => r.onclick = () =>
          loadFM(fmData.scanMode && fmData.scanMode !== fmData.mode ? { mode: fmData.scanMode, f: r.dataset.f } : { f: r.dataset.f }));
      }
      if ('mediaSession' in navigator && !player.paused && active) {
        const title = d.rdsName || fmFmt(d.mhz, d.mode) + ' MHz';
        const artist = d.rdsText || FM_MODES[d.mode] + ' · ' + fmFmt(d.mhz, d.mode) + ' MHz';
        const meta = navigator.mediaSession.metadata;
        if (!meta || meta.title !== title || meta.artist !== artist) {
          navigator.mediaSession.metadata = new MediaMetadata({ title, artist, album: 'PortaPack · Radio',
            artwork: [{ src: '/icon-512.png', sizes: '512x512', type: 'image/png' }] });
        }
      }
    }
    // ---------- Ende Radio (UKW/AM) ----------

    // ---------- Funksensoren ----------
    // Liste aller gehörten Sensoren (nur lesen). Sortierung, Suche und der
    // TPMS-Filter laufen hier im Browser; Antippen klappt alle Werte auf.
    let sensData = null;
    const sensOpen = new Set();
    const sensPref = (k, d) => { try { const v = localStorage.getItem(k); return v == null ? d : v; } catch (e) { return d; } };
    const sensSave = (k, v) => { try { localStorage.setItem(k, v); } catch (e) {} };
    let sensSort = sensPref('sensSort', 'last'), sensQuery = '', sensHideTPMS = sensPref('sensHideTPMS', '1') === '1';
    async function loadSensors(params = {}) {
      try {
        sensData = await api('/api/sensors', params);
        if (sensData.notice) showError(sensData.notice);
        if (tab === 'sensors') render();
      } catch (e) { showError(e); }
    }
    // Gemeinsame Hilfen der Reiter Funksensoren und Smart Home 868 (Darstellung).
    function rsAgo(ms) {
      const s = Math.max(0, Math.round((Date.now() - ms) / 1000));
      if (s < 60) return tt('vor {0} s', s);
      if (s < 3600) return tt('vor {0} min', Math.floor(s / 60));
      if (s < 86400) return tt('vor {0} h', Math.floor(s / 3600));
      return new Date(ms).toLocaleDateString(LOCALE, { day: 'numeric', month: 'short' });
    }
    const rsClock = ms => new Date(ms).toLocaleTimeString(LOCALE, { hour: '2-digit', minute: '2-digit', second: '2-digit' });
    const rsNum = (x, d) => Number(x).toLocaleString(LOCALE, { minimumFractionDigits: d, maximumFractionDigits: d });
    function rsStyle() {
      if ($('rs-style')) return;
      document.head.insertAdjacentHTML('beforeend', '<style id="rs-style">' +
        '.rs-head { display:flex; flex-wrap:wrap; gap:8px 10px; padding:10px 12px; align-items:center; }' +
        '.rs-head input[type=search] { flex:1 1 160px; min-width:0; font:inherit; padding:6px 10px; border-radius:8px; border:1px solid var(--line); background:var(--bg); color:var(--text); }' +
        '.rs-head select { font:inherit; padding:5px 6px; border-radius:8px; border:1px solid var(--line); background:var(--bg); color:var(--text); min-width:0; }' +
        '.rs-head label { display:flex; gap:6px; align-items:center; font-size:14px; min-width:0; }' +
        '.rs-head + .rs-head { padding-top:0; }' +
        '.rs-head input.rs-mhz { width:6.5em; min-width:0; font:inherit; padding:5px 8px; border-radius:8px; border:1px solid var(--line); background:var(--bg); color:var(--text); }' +
        '.rs-dev { border-bottom:1px solid var(--line); cursor:pointer; }' +
        '.rs-dev:last-child { border-bottom:0; }' +
        '.rs-dev > .item { border-bottom:0; }' +
        '.rs-dev.open > .item { padding-bottom:4px; }' +
        '.rs-right { flex:none; text-align:right; font-size:12px; color:var(--muted); font-variant-numeric:tabular-nums; }' +
        '.rs-right b { display:block; font-size:15px; color:var(--text); font-weight:600; }' +
        '.rs-vals { display:grid; grid-template-columns:auto minmax(0,1fr); gap:3px 12px; margin:0; padding:0 12px 10px 12px; font-size:13px; }' +
        '.rs-vals dt { color:var(--muted); } .rs-vals dd { margin:0; overflow-wrap:anywhere; }' +
        '.rs-chips { display:flex; flex-wrap:wrap; gap:6px; padding:10px 12px; }' +
        '.rs-chips button { border:1px solid var(--line); background:var(--bg); color:var(--text); border-radius:14px; padding:4px 10px; font:inherit; font-size:13px; cursor:pointer; }' +
        '.rs-chips button.on { background:var(--accent); border-color:var(--accent); color:#fff; }' +
        '.rs-tag { display:inline-block; font-size:11px; padding:0 6px; border-radius:6px; background:var(--line); color:var(--text); margin-left:6px; vertical-align:1px; }' +
        '.rs-frame { padding:6px 12px; border-top:1px solid var(--line); font-size:13px; }' +
        '.rs-frame .sub { color:var(--muted); font-size:12px; }' +
        '.rs-bad { color:var(--warn); }' +
        '</style>');
    }
    function sensorsStatus() {
      if (state.mode !== 'sensors' || !sensData || !sensData.running) return t('Funksensoren aus');
      return tt('{0} Sensoren · {1} Rahmen · {2} MHz', sensData.total, sensData.packets, rsNum(sensData.mhz, 2));
    }
    function sensName(s) { return s.tpms ? t('Reifendrucksensor') : s.model; }
    function sensIdText(s) { return 'ID ' + s.sid + (s.ch != null ? ' · ' + tt('Kanal {0}', s.ch) : ''); }
    function renderSensors() {
      rsStyle();
      const box = $('x-sensors');
      if (!$('senshead')) {
        // Band/Frequenz wie die Bandwahl am Mac; ohne Empfang gilt sie beim nächsten Start.
        box.innerHTML = '<div class="box"><div class="rs-head" id="senshead">' +
          '<label>' + t('Band') + ' <select id="sensband" aria-label="' + t('Band') + '"></select></label>' +
          '<label><input id="sensmhz" class="rs-mhz" inputmode="decimal" enterkeyhint="go" autocomplete="off" aria-label="' + t('Frequenz in MHz') + '"> MHz</label></div>' +
          '<div class="rs-head">' +
          '<input type="search" id="sensq" placeholder="' + t('Suchen (Modell, ID, Wert)') + '" autocomplete="off">' +
          '<select id="senssort" aria-label="' + t('Sortierung') + '"><option value="last">' + t('Zuletzt gehört') + '</option><option value="name">' + t('Name') + '</option><option value="temp">' + t('Temperatur') + '</option></select>' +
          '<label><input type="checkbox" id="senstpms"> ' + t('Reifendruck (TPMS) ausblenden') + '</label></div></div><div id="senslist"></div>';
        $('sensq').value = sensQuery;
        $('senssort').value = sensSort;
        $('senstpms').checked = sensHideTPMS;
        $('sensband').onchange = e => { e.target.blur(); if (e.target.value) loadSensors({ mhz: e.target.value }); };
        $('sensmhz').addEventListener('keydown', e => { if (e.key === 'Enter') { e.preventDefault(); e.target.blur(); } });
        $('sensmhz').onchange = e => {
          const v = e.target.value.trim().replace(',', '.');
          if (!v) return;
          if (!isFinite(Number(v))) { showError(t('Bitte eine Frequenz in MHz eingeben.')); return; }
          loadSensors({ mhz: v });
        };
        $('sensq').oninput = e => { sensQuery = e.target.value; renderSensors(); };
        $('senssort').onchange = e => { sensSort = e.target.value; sensSave('sensSort', sensSort); e.target.blur(); renderSensors(); };
        $('senstpms').onchange = e => { sensHideTPMS = e.target.checked; sensSave('sensHideTPMS', sensHideTPMS ? '1' : '0'); renderSensors(); };
        $('senslist').onclick = e => {
          const el = e.target.closest('[data-skey]'); if (!el) return;
          const k = el.dataset.skey;
          if (sensOpen.has(k)) sensOpen.delete(k); else sensOpen.add(k);
          renderSensors();
        };
      }
      const list = $('senslist');
      if (!sensData) { list.innerHTML = '<div class="box"><div class="empty">' + t('Lade …') + '</div></div>'; return; }
      // Bandwahl nur befüllen, solange sie niemand bedient.
      const bandSel = $('sensband'), mhzIn = $('sensmhz'), bands = sensData.bands || [];
      const known = bands.find(b => Math.abs(b.mhz - sensData.mhz) < 0.001);
      const opts = bands.map(b => '<option value="' + b.mhz + '">' + esc(b.name) + '</option>').join('') + (known ? '' : '<option value="">' + t('Eigene') + '</option>');
      if (document.activeElement !== bandSel) {
        if (bandSel.dataset.html !== opts) { bandSel.dataset.html = opts; bandSel.innerHTML = opts; }
        bandSel.value = known ? String(known.mhz) : '';
      }
      if (document.activeElement !== mhzIn) mhzIn.value = dec(sensData.mhz.toFixed(3));
      const q = sensQuery.trim().toLowerCase();
      let rows = sensData.sensors.filter(s => !(sensHideTPMS && s.tpms));
      if (q) rows = rows.filter(s => (sensName(s) + ' ' + s.model + ' ' + sensIdText(s) + ' ' + s.values.map(v => v.n + ' ' + v.v).join(' ')).toLowerCase().includes(q));
      if (sensSort === 'name') rows.sort((a, b) => sensName(a).localeCompare(sensName(b), LOCALE) || String(a.sid).localeCompare(String(b.sid), LOCALE, { numeric: true }) || (a.ch ?? 0) - (b.ch ?? 0));
      else if (sensSort === 'temp') rows.sort((a, b) => (b.temp ?? -Infinity) - (a.temp ?? -Infinity) || b.t - a.t);
      else rows.sort((a, b) => b.t - a.t);
      const hidden = sensHideTPMS ? sensData.tpms : 0;
      let html = '';
      if (!sensData.sensors.length) {
        html += '<div class="empty">' + (state.mode === 'sensors' && sensData.running
          ? t('Noch kein Sensor gehört. Wetterstationen und Thermometer senden meist alle 30–60 Sekunden – etwas Geduld.')
          : t('Noch keine Sensoren. Tippe oben auf „Start“, dann erscheinen hier Wetterstationen, Thermometer und andere Funksensoren in der Nähe.')) + '</div>';
      } else if (!rows.length) {
        html += '<div class="empty">' + (q ? t('Kein Sensor passt zur Suche.') : t('Bisher nur Reifendrucksensoren gehört ({0}) – schalte den Filter oben aus, um sie zu sehen.', hidden)) + '</div>';
      }
      html += rows.map(s => {
        const open = sensOpen.has(s.key);
        // Der Mac schickt den Namen in seiner Sprache (String(localized:) – „Temperatur“).
        const temp = s.values.find(v => v.n === 'Temperatur' || v.n === t('Temperatur'));
        const short = s.values.filter(v => v !== temp).slice(0, 3).map(v => v.n + ' ' + v.v).join(' · ');
        let h = '<div class="rs-dev' + (open ? ' open' : '') + '" data-skey="' + esc(s.key) + '"><div class="item">' +
          '<div class="grow"><div>' + esc(sensName(s)) + (s.tpms ? '<span class="rs-tag">TPMS</span>' : '') + '</div>' +
          '<div class="sub">' + esc(sensIdText(s) + (short ? ' · ' + short : '')) + '</div></div>' +
          '<div class="rs-right">' + (temp ? '<b>' + esc(temp.v) + '</b>' : '') + esc(rsAgo(s.t)) + '<br>' + esc(rsNum(s.rssi, 0) + ' dB') + '</div></div>';
        if (open) {
          const rows2 = s.values.concat([
            { n: t('Modell'), v: s.model }, { n: t('Kennung'), v: sensIdText(s) },
            { n: tt('Pegel'), v: tt('{0} dB · Störabstand {1} dB', rsNum(s.rssi, 1), rsNum(s.snr, 1)) },
            { n: t('Frequenz'), v: rsNum(s.mhz, 2) + ' MHz' }, { n: t('Rahmen'), v: String(s.count) },
            { n: t('Zuletzt gehört'), v: rsClock(s.t) + ' (' + rsAgo(s.t) + ')' }, { n: t('Zuerst gehört'), v: rsClock(s.first) },
            { n: t('Absicherung'), v: s.integrity }]);
          h += '<dl class="rs-vals">' + rows2.map(v => '<dt>' + esc(v.n) + '</dt><dd>' + esc(v.v) + '</dd>').join('') + '</dl>';
        }
        return h + '</div>';
      }).join('');
      html = wxBox('sens-list', t('Sensoren'), html, rows.length || null);
      const info = [];
      if (hidden && rows.length) info.push(tt('{0} Reifendrucksensoren ausgeblendet.', hidden));
      if (sensData.total > sensData.sensors.length) info.push(tt('Gezeigt werden die {0} zuletzt gehörten von {1} Sensoren.', sensData.sensors.length, sensData.total));
      if (sensData.error) info.push(tt('Fehler: {0}', sensData.error));
      if (info.length) html += '<div class="hint" style="padding:0 4px 12px">' + esc(info.join(' ')) + '</div>';
      if (list.dataset.html === html) return;
      list.dataset.html = html;
      const top = box.scrollTop; list.innerHTML = html; box.scrollTop = top;
    }
    // ---------- Ende Funksensoren ----------

    // ---------- Smart Home 868 ----------
    // Geräte je Funkart (nur lesen). Antippen fragt die letzten Rahmen des Geräts
    // mit ab (?dev=). Schlüssel liefert der Server nie aus.
    let smartData = null, smartOpen = null;
    let smartRadio = (() => { try { return localStorage.getItem('smartRadio') || ''; } catch (e) { return ''; } })();
    async function loadSmart(params = {}) {
      try {
        smartData = await api('/api/smart868', Object.assign(smartOpen ? { dev: smartOpen } : {}, params));
        if (tab === 'smart868') render();
      } catch (e) { showError(e); }
    }
    function smartStatus() {
      if (state.mode !== 'smart868' || !smartData || !smartData.running) return t('Smart Home 868 aus');
      return tt('{0} Geräte', smartData.total) + ' · ' + tt('{0} Rahmen', smartData.frames);
    }
    const smartShort = r => r === 'Wireless M-Bus' ? 'wM-Bus' : r;
    function renderSmart() {
      rsStyle();
      const box = $('x-smart868');
      if (!$('smarthead')) {
        box.innerHTML = '<div class="box"><div class="rs-chips" id="smarthead"></div></div><div id="smartlist"></div>';
        $('smarthead').onclick = e => {
          const b = e.target.closest('[data-radio]'); if (!b) return;
          smartRadio = b.dataset.radio;
          try { localStorage.setItem('smartRadio', smartRadio); } catch (err) {}
          renderSmart();
        };
        $('smartlist').onclick = e => {
          const el = e.target.closest('[data-dev]'); if (!el) return;
          smartOpen = smartOpen === el.dataset.dev ? null : el.dataset.dev;
          renderSmart();
          if (smartOpen) loadSmart();
        };
      }
      const head = $('smarthead'), list = $('smartlist');
      if (!smartData) { list.innerHTML = '<div class="box"><div class="empty">' + t('Lade …') + '</div></div>'; return; }
      if (smartRadio && !smartData.radios.some(r => r.name === smartRadio)) smartRadio = '';
      const headHTML = '<button data-radio=""' + (smartRadio ? '' : ' class="on"') + '>' + t('Alle ({0})', smartData.total) + '</button>' +
        smartData.radios.map(r => '<button data-radio="' + esc(r.name) + '"' + (smartRadio === r.name ? ' class="on"' : '') + '>' +
          esc(smartShort(r.name)) + ' (' + r.devices + ')</button>').join('');
      if (head.dataset.html !== headHTML) { head.dataset.html = headHTML; head.innerHTML = headHTML; }
      const rows = smartData.devices.filter(d => !smartRadio || d.radio === smartRadio);
      const off = smartData.radios.filter(r => !r.on).map(r => smartShort(r.name));
      let html = '';
      if (!smartData.devices.length) {
        html += '<div class="empty">' + (state.mode === 'smart868' && smartData.running
          ? t('Noch kein Gerät gehört. Thermostate und Zähler senden oft nur alle paar Minuten – etwas Geduld.')
          : t('Noch keine Geräte. Tippe oben auf „Start“, dann erscheinen hier Z-Wave-, Homematic-, EnOcean- und Funkzähler-Geräte in der Nähe.')) + '</div>';
      } else if (!rows.length) {
        const r = smartData.radios.find(x => x.name === smartRadio);
        html += '<div class="empty">' + esc(r && !r.on ? tt('{0} ist am Mac abgeschaltet.', smartShort(smartRadio)) : tt('Bisher kein {0}-Gerät gehört.', smartShort(smartRadio))) + '</div>';
      }
      html += rows.map(d => {
        const open = smartOpen === d.id;
        let h = '<div class="rs-dev' + (open ? ' open' : '') + '" data-dev="' + esc(d.id) + '"><div class="item">' +
          '<div class="grow"><div>' + esc(d.type || smartShort(d.radio)) + '<span class="rs-tag">' + esc(smartShort(d.radio)) + '</span>' + (d.enc ? '<span class="rs-tag">🔒</span>' : '') + '</div>' +
          '<div class="sub">' + esc(d.addr + (d.last ? ' · ' + d.last : '')) + '</div></div>' +
          '<div class="rs-right">' + esc(rsAgo(d.t)) + '<br>' + esc(rsNum(d.rssi, 0) + ' dB · ' + d.count + '×') + '</div></div>';
        if (open) {
          const facts = d.values.concat([
            { n: t('Funkart'), v: d.radio }, { n: t('Adresse'), v: d.addr },
            { n: tt('Pegel'), v: tt('{0} dB · Störabstand {1} dB', rsNum(d.rssi, 1), rsNum(d.snr, 1)) },
            { n: t('Rahmen'), v: String(d.count) }, { n: t('Zuletzt gehört'), v: rsClock(d.t) + ' (' + rsAgo(d.t) + ')' },
            { n: t('Zuerst gehört'), v: rsClock(d.first) }]);
          if (d.enc) facts.push({ n: t('Verschlüsselt'), v: d.values.length ? t('ja – mit Schlüssel am Mac gelesen') : t('ja – ohne Schlüssel nicht lesbar') });
          h += '<dl class="rs-vals">' + facts.map(v => '<dt>' + esc(v.n) + '</dt><dd>' + esc(v.v) + '</dd>').join('') + '</dl>';
          const hist = smartData.dev === d.id ? smartData.history : null;
          if (!hist) h += '<div class="rs-frame"><span class="sub">' + t('Lade letzte Rahmen …') + '</span></div>';
          else if (!hist.length) h += '<div class="rs-frame"><span class="sub">' + t('Keine Rahmen mehr im Speicher.') + '</span></div>';
          else h += hist.map(f => '<div class="rs-frame"><div>' + esc(f.kind) + (f.ok ? '' : ' <span class="rs-bad">' + t('Prüfsumme falsch') + '</span>') + (f.enc ? ' 🔒' : '') + '</div>' +
            '<div class="sub">' + esc(rsClock(f.t) + ' · ' + f.mode + (f.dest ? ' → ' + f.dest : '') + ' · ' + rsNum(f.rssi, 0) + ' dB') + '</div>' +
            (f.summary ? '<div>' + esc(f.summary) + '</div>' : '') +
            (f.values.length ? '<div class="sub">' + esc(f.values.map(v => v.n + ' ' + v.v).join(' · ')) + '</div>' : '') +
            (f.fields.length ? '<div class="sub">' + esc(f.fields.map(v => v.n + ': ' + v.v).join(' · ')) + '</div>' : '') + '</div>').join('');
        }
        return h + '</div>';
      }).join('');
      html = wxBox('sh-list', smartRadio ? smartShort(smartRadio) : t('Geräte'), html, rows.length || null);
      const info = [];
      if (off.length) info.push(tt('Am Mac abgeschaltet: {0}.', off.join(', ')));
      if (smartData.noise.length && state.mode === 'smart868') info.push(tt('Rauschen: {0}.', smartData.noise.map(n => n.n + ' ' + n.v).join(' · ')));
      if (smartData.total > smartData.devices.length) info.push(tt('Gezeigt werden die {0} zuletzt gehörten von {1} Geräten.', smartData.devices.length, smartData.total));
      if (smartData.error) info.push(tt('Fehler: {0}', smartData.error));
      if (info.length) html += '<div class="hint" style="padding:0 4px 12px">' + esc(info.join(' ')) + '</div>';
      if (list.dataset.html === html) return;
      list.dataset.html = html;
      const top = box.scrollTop; list.innerHTML = html; box.scrollTop = top;
    }
    // ---------- Ende Smart Home 868 ----------

    // ---------- Seefunk-Notruf ----------
    // Rufliste von UKW-Kanal 70 (Notrufe oben, rot), eigene Leaflet-Karte mit den
    // Positionen und Gebieten, Antippen zeigt die Einzelheiten. Nur Anzeige.
    let dscData = null, dscSel = null, dscMap = null, dscLayer = null, dscSig = '', dscFitted = false;
    document.head.insertAdjacentHTML('beforeend', '<style>' +
      '#x-dsc .dscwarn { padding:10px 12px; color:var(--warn); font-size:13px; font-weight:600; }' +
      '#x-dsc .dscmap { height:min(40vh, 340px); border-radius:12px; margin-bottom:12px; z-index:0; }' +
      '#x-dsc .item { cursor:pointer; }' +
      '#x-dsc .item.sos { box-shadow:inset 4px 0 0 var(--warn); background:color-mix(in srgb, var(--warn) 10%, transparent); }' +
      '#x-dsc .item.sos .kind { color:var(--warn); font-weight:700; }' +
      '#x-dsc .item.test .kind { color:var(--muted); }' +
      '#x-dsc .item.on { background:color-mix(in srgb, var(--accent) 16%, transparent); }' +
      '#x-dsc .item .t { color:var(--muted); font-size:13px; font-variant-numeric:tabular-nums; flex:none; text-align:right; }' +
      '#x-dsc .dsccard table { width:100%; border-collapse:collapse; font-size:14px; table-layout:fixed; }' +
      '#x-dsc .dsccard td { padding:5px 12px; vertical-align:top; border-bottom:1px solid var(--line); overflow-wrap:anywhere; }' +
      '#x-dsc .dsccard td:first-child { color:var(--muted); width:8.5em; }' +
      '#x-dsc .dsccard h4 { display:flex; align-items:center; gap:8px; }' +
      '#x-dsc .dsccard h4 span { flex:1; min-width:0; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }' +
      '#x-dsc .dsccard h4 button { border:0; background:var(--line); color:var(--text); border-radius:6px; padding:2px 8px; cursor:pointer; font:inherit; }' +
      '#x-dsc .dscbar { display:flex; gap:8px; align-items:center; padding:8px 12px; flex-wrap:wrap; }' +
      '#x-dsc .dscbar .hint { flex:1; min-width:0; }' +
      '#x-dsc .dscbar .btn { margin-left:0; }' +
      '</style>');
    async function loadDSC(params = {}) {
      try { dscData = await api('/api/dsc', params); if (tab === 'dsc') render(); } catch (e) { showError(e); }
    }
    function dscStatus() {
      const d = dscData;
      if (state.mode !== 'dsc') return tt('Seefunk-Notruf aus') + (d && d.calls ? ' · ' + tt('{0} Rufe', d.calls) : '');
      if (!d) return t('Seefunk-Notruf läuft');
      return tt('Kanal {0}', 70) + ' · ' + (d.calls === 1 ? tt('1 Ruf') : tt('{0} Rufe', d.calls)) + (d.distressCount ? ' · ' + tt('{0} Notfall', d.distressCount) : '');
    }
    const dscClock = ms => new Date(ms).toLocaleTimeString(LOCALE, { hour: '2-digit', minute: '2-digit', second: '2-digit' });
    const dscWhen = ms => (new Date(ms).toDateString() === new Date().toDateString() ? '' : new Date(ms).toLocaleDateString(LOCALE, { day: 'numeric', month: 'short' }) + ' ') + dscClock(ms);
    // Station: Name (MMSI) · Art, Land – Namen stammen aus AIS, daher immer über esc().
    function dscStation(s) {
      if (!s) return '';
      const extra = [s.kind, s.country].filter(Boolean).join(', ');
      return (s.name ? s.name + ' (' + s.mmsi + ')' : s.mmsi) + (extra ? ' · ' + extra : '');
    }
    function dscTarget(e) { return e.toStation ? dscStation(e.toStation) : e.to === 'Gebiet' ? t('Gebiet') + (e.area ? ' ' + e.area.text : '') : t('Alle Schiffe'); }
    function dscSummary(e) {
      return [e.inDistress ? tt('Schiff in Not: {0}', dscStation(e.inDistress)) : '', e.nature || e.command || '', e.freq || '', e.next ? tt('weiter: {0}', e.next) : '']
        .filter(Boolean).join(' · ');
    }
    // Karte einmal anlegen (eigene Instanz im eigenen Bereich), danach nur Ebenen tauschen.
    function dscEnsure() {
      if (dscMap) return;
      $('x-dsc').innerHTML = '<div class="box"><div class="dscwarn">' + t('⚠︎ Notrufe niemals selbst beantworten oder bestätigen – das ist Sache der Küstenfunkstellen und Schiffe mit Funkzeugnis. Gehörtes nicht weitergeben.') + '</div></div>' +
        '<div class="dscmap" id="dscmap"></div><div id="dsccard"></div><div id="dsclist"></div>';
      dscMap = L.map('dscmap', { zoomControl: true }).setView([54.2, 9], 6);
      L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', { maxZoom: 18, attribution: '© OpenStreetMap' }).addTo(dscMap);
      dscLayer = L.layerGroup().addTo(dscMap);
      new ResizeObserver(() => dscMap.invalidateSize()).observe($('dscmap'));
    }
    function dscSelect(id, pan) {
      dscSel = dscSel === id ? null : id;
      renderDSC();
      const e = dscSel != null && dscData && dscData.entries.find(x => x.id === dscSel);
      if (e && pan) {
        if (e.lat != null) dscMap.setView([e.lat, e.lon], Math.max(dscMap.getZoom(), 8));
        else if (e.area) dscMap.fitBounds([[e.area.s, e.area.w], [e.area.n, e.area.e]], { padding: [20, 20] });
      }
      if (e) $('dsccard').scrollIntoView({ block: 'nearest', behavior: 'smooth' });
    }
    function dscRenderMap() {
      const d = dscData;
      const sig = JSON.stringify([dscSel, d.home, d.entries.map(e => [e.id, e.lat, e.lon, e.area && e.area.text, e.distress])]);
      if (sig === dscSig) return;
      dscSig = sig; dscLayer.clearLayers();
      const css = getComputedStyle(document.documentElement);
      const color = e => e.id === dscSel ? '#ff9f0a' : e.distress ? css.getPropertyValue('--warn').trim() : e.test ? '#8e8e93' : css.getPropertyValue('--accent').trim();
      const pts = [];
      if (d.home) L.circleMarker(d.home, { radius: 5, color: '#8b5a2b', fillOpacity: 1, weight: 2 }).bindTooltip(t('Standort')).addTo(dscLayer);
      for (const e of d.entries) {
        if (!e.area) continue;
        pts.push([e.area.s, e.area.w], [e.area.n, e.area.e]);
        const r = L.rectangle([[e.area.s, e.area.w], [e.area.n, e.area.e]], { color: color(e), weight: e.id === dscSel ? 2 : 1, fillOpacity: e.id === dscSel ? .2 : .06 }).addTo(dscLayer);
        r.on('click', () => dscSelect(e.id, false));
      }
      // Ausgewählter Ruf und Notrufe zuletzt, damit sie oben liegen.
      const order = d.entries.filter(e => e.lat != null).sort((a, b) => (a.id === dscSel) - (b.id === dscSel) || a.distress - b.distress);
      for (const e of order) {
        pts.push([e.lat, e.lon]);
        const m = L.circleMarker([e.lat, e.lon], { radius: e.distress || e.id === dscSel ? 9 : 6, color: '#fff', weight: 2, fillColor: color(e), fillOpacity: 1 })
          .bindTooltip(esc(e.kind + ' · ' + (e.from.name || e.from.mmsi))).addTo(dscLayer);
        m.on('click', () => dscSelect(e.id, false));
      }
      if (!dscFitted && pts.length) {
        dscFitted = true;
        dscMap.fitBounds(d.home ? pts.concat([d.home]) : pts, { padding: [30, 30], maxZoom: 10 });
      } else if (!dscFitted && d.home) dscMap.setView(d.home, 8);
    }
    function dscCard() {
      const card = $('dsccard');
      const e = dscSel != null && dscData.entries.find(x => x.id === dscSel);
      if (!e) { if (card.innerHTML) { card.innerHTML = ''; card.dataset.html = ''; } return; }
      const rows = [
        [tt('Zeit'), dscWhen(e.t) + (e.rep > 1 ? ' · ' + tt('{0}× gehört, zuerst {1}', e.rep, dscWhen(e.first)) : '')],
        [t('Art'), e.kind],
        [tt('Format'), e.format + (e.category ? ' · ' + tt('Kategorie {0}', e.category) : '')],
        [t('Von'), dscStation(e.from)],
        [t('An'), dscTarget(e)],
        [t('Schiff in Not'), e.inDistress ? dscStation(e.inDistress) : ''],
        [t('Notfall'), e.nature || ''],
        [t('Befehl'), [e.command, e.command2].filter(Boolean).join(' · ')],
        [t('Position'), e.pos ? e.pos + (e.posTime ? ' (' + e.posTime + ')' : '') : e.posUnknown ? t('unbekannt') : ''],
        [t('Gebiet'), e.area ? e.area.text : ''],
        [t('Folgeverkehr'), e.next || ''],
        [t('Kanal/Frequenz'), e.freq || ''],
        [t('Quittung'), e.ack || ''],
        [tt('Korrigiert'), e.corrected ? tt('{0} Zeichen über Zweitkopie/Prüfzeichen', e.corrected) : ''],
      ].filter(r => r[1]);
      const html = '<div class="box dsccard"><h4><span>' + esc(e.kind + ' · ' + (e.from.name || e.from.mmsi)) + '</span><button id="dscclose" aria-label="' + t('Schließen') + '">✕</button></h4>' +
        '<table>' + rows.map(r => '<tr><td>' + esc(r[0]) + '</td><td>' + esc(r[1]) + '</td></tr>').join('') + '</table>' +
        (e.distress ? '<div class="dscwarn">' + t('Nicht antworten – zuständig sind die Seenotleitung (MRCC) und Schiffe in der Nähe mit Funkzeugnis.') + '</div>' : '') + '</div>';
      if (card.dataset.html === html) return;
      card.dataset.html = html; card.innerHTML = html;
      $('dscclose').onclick = () => { dscSel = null; renderDSC(); };
    }
    function renderDSC() {
      dscEnsure();
      const list = $('dsclist'), d = dscData;
      if (!d) { list.innerHTML = '<div class="empty">' + t('Lade …') + '</div>'; return; }
      if (dscSel != null && !d.entries.some(e => e.id === dscSel)) dscSel = null;
      dscRenderMap();
      dscCard();
      let html = '';
      if (!d.entries.length) {
        html += '<div class="empty">' + (state.mode === 'dsc'
          ? t('Noch kein Ruf auf Kanal 70 (156,525 MHz). DSC-Rufe sind selten – in Küsten- oder Flussnähe einige pro Stunde, meist Tests und Routinerufe.')
          : t('Keine Rufe. Tippe oben auf „Start“, dann hört der HackRF UKW-Kanal 70 ab.')) + '</div>';
      }
      html += d.entries.map(e => {
        const cls = 'item' + (e.distress ? ' sos' : '') + (e.test ? ' test' : '') + (e.id === dscSel ? ' on' : '');
        const sum = dscSummary(e);
        return '<div class="' + cls + '" data-dsc="' + e.id + '"><span>' + (e.distress ? '🆘' : e.lat != null ? '📍' : '·') + '</span>' +
          '<div class="grow"><div><span class="kind">' + esc(e.kind) + '</span> · ' + esc(dscStation(e.from)) + '</div>' +
          '<div class="sub">' + esc(tt('an {0}', dscTarget(e)) + (sum ? ' · ' + sum : '') + (e.pos ? ' · ' + e.pos : e.posUnknown ? ' · ' + tt('Position unbekannt') : '')) + '</div></div>' +
          '<span class="t">' + esc(dscClock(e.t)) + (e.rep > 1 ? '<br>' + e.rep + '×' : '') + '</span></div>';
      }).join('');
      html = wxBox('dsc-list', t('Rufe auf Kanal 70'), html, d.entries.length || null);
      html += '<div class="box"><div class="dscbar"><span class="hint">' + esc(tt('{0} Rufe · {1} Notfall · {2} korrigierte Zeichen', d.calls, d.distressCount, d.corrected) +
        (d.signal != null ? ' · ' + tt('Kanal 70 {0} dBFS', Math.round(d.signal)) : '') + (d.error ? ' · ' + tt('Fehler: {0}', d.error) : '')) + '</span>' +
        (d.calls ? '<button class="btn secondary" id="dscclear">' + t('Leeren') + '</button>' : '') + '</div></div>';
      if (list.dataset.html === html) return;
      list.dataset.html = html; list.innerHTML = html;
      list.querySelectorAll('[data-dsc]').forEach(el => el.onclick = () => dscSelect(Number(el.dataset.dsc), true));
      if ($('dscclear')) $('dscclear').onclick = () => { if (confirm(t('Alle empfangenen DSC-Rufe aus der Liste entfernen?'))) { dscSel = null; loadDSC({ clear: 1 }); } };
    }
    // ---------- Ende Seefunk-Notruf ----------

    // ---------- FT8/WSPR ----------
    // Dekodierliste, eigene Leaflet-Karte der Stationen (Locator-Mitte) mit Linie
    // vom Standort zum gewählten Spot, Band und Betriebsart, Zyklusstand.
    let ft8Data = null, ft8Sel = null, ft8Map = null, ft8Layer = null, ft8Sig = '', ft8Fitted = false, ft8Skew = 0;
    let ft8CQ = false;
    try { ft8CQ = localStorage.getItem('ft8cq') === '1'; } catch (e) {}
    document.head.insertAdjacentHTML('beforeend', '<style>' +
      '#x-ft8 .ft8map { height:min(38vh, 320px); border-radius:12px; margin-bottom:12px; z-index:0; }' +
      '#x-ft8 .ft8bar { display:flex; gap:8px; align-items:center; padding:10px 12px; flex-wrap:wrap; }' +
      '#x-ft8 .ft8bar select { font:inherit; padding:4px 6px; border-radius:8px; border:1px solid var(--line); background:var(--bg); color:var(--text); }' +
      '#x-ft8 .ft8seg { display:inline-flex; border-radius:8px; overflow:hidden; border:1px solid var(--line); }' +
      '#x-ft8 .ft8seg button { border:0; background:var(--card); color:var(--text); padding:5px 10px; font:inherit; cursor:pointer; }' +
      '#x-ft8 .ft8seg button + button { border-left:1px solid var(--line); }' +
      '#x-ft8 .ft8seg button.on { background:var(--accent); color:#fff; }' +
      '#x-ft8 .ft8bar label { display:flex; gap:6px; align-items:center; }' +
      '#x-ft8 .ft8cyc { padding:0 12px 10px; font-size:13px; color:var(--muted); font-variant-numeric:tabular-nums; }' +
      '#x-ft8 .ft8cyc .warn { color:var(--warn); }' +
      '#x-ft8 .ft8prog { display:inline-block; width:60px; height:6px; border-radius:3px; background:var(--line); vertical-align:middle; margin:0 6px; overflow:hidden; }' +
      '#x-ft8 .ft8prog i { display:block; height:100%; background:var(--accent); }' +
      '#x-ft8 .item { cursor:pointer; }' +
      '#x-ft8 .item.on { background:color-mix(in srgb, var(--accent) 16%, transparent); }' +
      '#x-ft8 .item .msg { font-family:ui-monospace, Menlo, monospace; font-size:14px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }' +
      '#x-ft8 .item .msg .cq { color:var(--ok); font-weight:600; }' +
      '#x-ft8 .item .snr { flex:none; font-variant-numeric:tabular-nums; text-align:right; font-size:13px; }' +
      '#x-ft8 .item .wspr { color:#a05cd6; }' +
      '</style>');
    async function loadFT8(params = {}) {
      if (ft8CQ) params.cq = 1;
      try {
        const t0 = Date.now();
        ft8Data = await api('/api/ft8', params);
        // Abstand Mac-Uhr ↔ Browser-Uhr, damit der Zyklusstand zur Mac-Uhr passt.
        ft8Skew = ft8Data.now - (t0 + Date.now()) / 2;
        if (tab === 'ft8') render();
      } catch (e) { showError(e); }
    }
    const ft8Modes = { ft8: 'FT8', wspr: 'WSPR', both: 'FT8 + WSPR' };
    function ft8Status() {
      const d = ft8Data;
      if (state.mode !== 'ft8') return t('FT8/WSPR aus');
      if (!d) return t('FT8/WSPR läuft');
      return d.band + ' · ' + ft8Modes[d.modes] + ' · ' + tt('{0} Dekodierungen', d.decodes);
    }
    const ft8UTC = ms => new Date(ms).toISOString().slice(11, 19);
    // Zyklusstand: Sekunde im laufenden FT8- (15 s) bzw. WSPR-Zyklus (120 s, gerade Minute).
    function ft8Cycles() {
      const d = ft8Data, now = Date.now() + ft8Skew;
      if (!d.running) return '<div class="ft8cyc">' + esc(state.mode === 'ft8' ? t('Startet …') : t('Empfang aus – oben „Start“ tippen.')) + '</div>';
      return '<div class="ft8cyc">' + d.cycles.map(c => {
        const len = c.mode === 'FT8' ? 15 : 120, pos = Math.floor((now / 1000) % len);
        return '<div>' + esc(c.mode) + '<span class="ft8prog"><i style="width:' + Math.round(pos / len * 100) + '%"></i></span>' + pos + '/' + len + ' s' +
          esc(' · ' + (c.busy ? tt('wird dekodiert …') : c.last != null ? (c.last === 1 ? tt('letzter Zyklus 1 Dekodierung') : tt('letzter Zyklus {0} Dekodierungen', c.last)) + (c.secs != null ? ' (' + dec(c.secs.toFixed(1)) + ' s)' : '') : tt('noch kein Zyklus ausgewertet'))) + '</div>';
      }).join('') +
        (d.clock ? '<div' + (d.clockOK ? '' : ' class="warn"') + '>' + esc(d.clock) + '</div>' : '') +
        (d.calibrated ? '' : '<div>' + t('Ohne Quarzabgleich – die Suche ist breiter, Frequenzen können einige 100 Hz daneben liegen.') + '</div>') +
        (d.error ? '<div class="warn">' + esc(d.error) + '</div>' : '') + '</div>';
    }
    function ft8Ensure() {
      if (ft8Map) return;
      $('x-ft8').innerHTML = '<div class="box"><div class="ft8bar">' +
        '<label>' + t('Band') + ' <select id="ft8band" aria-label="' + t('Band') + '"></select></label>' +
        '<span class="ft8seg" id="ft8modes">' + Object.entries(ft8Modes).map(([k, v]) => '<button data-modes="' + k + '">' + v + '</button>').join('') + '</span>' +
        '<label><input type="checkbox" id="ft8cq"> ' + t('nur CQ') + '</label></div><div id="ft8cyc"></div></div>' +
        '<div class="ft8map" id="ft8map"></div><div id="ft8list"></div>';
      $('ft8cq').checked = ft8CQ;
      $('ft8cq').onchange = e => { ft8CQ = e.target.checked; try { localStorage.setItem('ft8cq', ft8CQ ? '1' : '0'); } catch (x) {} loadFT8(); };
      $('ft8band').onchange = e => { e.target.blur(); ft8Fitted = false; loadFT8({ band: e.target.value.replace(' ', '') }); };
      $('ft8modes').querySelectorAll('[data-modes]').forEach(b => b.onclick = () => loadFT8({ modes: b.dataset.modes }));
      ft8Map = L.map('ft8map', { zoomControl: true, worldCopyJump: true }).setView([51, 10], 4);
      L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', { maxZoom: 18, attribution: '© OpenStreetMap' }).addTo(ft8Map);
      ft8Layer = L.layerGroup().addTo(ft8Map);
      new ResizeObserver(() => ft8Map.invalidateSize()).observe($('ft8map'));
    }
    function ft8SelectSpot(id, pan) {
      ft8Sel = ft8Sel === id ? null : id;
      renderFT8();
      const s = ft8Sel && ft8Data.spots.find(x => x.id === ft8Sel);
      if (s && pan && s.lat != null) {
        const pts = ft8Data.home ? [ft8Data.home, [s.lat, s.lon]] : [[s.lat, s.lon]];
        ft8Map.fitBounds(pts, { padding: [40, 40], maxZoom: 8 });
      }
    }
    function ft8RenderMap() {
      const d = ft8Data, s = ft8Sel && d.spots.find(x => x.id === ft8Sel);
      const sig = JSON.stringify([d.home, s ? [s.id, s.lat, s.lon] : null, d.stations.map(x => [x.call, x.grid, x.mode])]);
      if (sig === ft8Sig) return;
      ft8Sig = sig; ft8Layer.clearLayers();
      const accent = getComputedStyle(document.documentElement).getPropertyValue('--accent').trim();
      const pts = [];
      for (const st of d.stations) {
        pts.push([st.lat, st.lon]);
        const m = L.circleMarker([st.lat, st.lon], { radius: 5, color: '#fff', weight: 1, fillColor: st.mode === 'WSPR' ? '#a05cd6' : accent, fillOpacity: .9 })
          .bindTooltip(esc(st.call + ' · ' + st.grid + ' · ' + st.snr + ' dB · ' + st.spots + '×')).addTo(ft8Layer);
        // Antippen wählt die jüngste Dekodierung dieser Station.
        m.on('click', () => { const sp = ft8Data.spots.find(x => x.call === st.call); if (sp) ft8SelectSpot(sp.id, false); });
      }
      if (d.home) L.circleMarker(d.home, { radius: 6, color: '#8b5a2b', weight: 2, fillColor: '#8b5a2b', fillOpacity: 1 }).bindTooltip(esc(t('Standort') + ' ' + (d.homeGrid || ''))).addTo(ft8Layer);
      if (s && s.lat != null) {
        if (d.home) L.polyline([d.home, [s.lat, s.lon]], { color: '#ff9f0a', weight: 3, dashArray: '6 6' }).addTo(ft8Layer);
        L.circleMarker([s.lat, s.lon], { radius: 9, color: '#fff', weight: 2, fillColor: '#ff9f0a', fillOpacity: 1 })
          .bindTooltip(esc((s.call || '') + ' · ' + s.grid)).addTo(ft8Layer);
      }
      if (!ft8Fitted && pts.length) {
        ft8Fitted = true;
        ft8Map.fitBounds(d.home ? pts.concat([d.home]) : pts, { padding: [30, 30], maxZoom: 7 });
      }
    }
    function renderFT8() {
      ft8Ensure();
      const list = $('ft8list'), d = ft8Data;
      if (!d) { list.innerHTML = '<div class="empty">' + t('Lade …') + '</div>'; return; }
      // Kopf: Werte nur setzen, wenn gerade nicht bedient.
      const band = $('ft8band');
      if (band.options.length !== d.bands.length) band.innerHTML = d.bands.map(b => '<option>' + esc(b) + '</option>').join('');
      if (document.activeElement !== band) band.value = d.band;
      $('ft8modes').querySelectorAll('[data-modes]').forEach(b => b.classList.toggle('on', b.dataset.modes === d.modes));
      $('ft8cyc').innerHTML = '<div class="ft8cyc">' + esc((d.modes !== 'wspr' ? 'FT8 ' + dec(d.ft8MHz.toFixed(3)) + ' MHz' : '') + (d.modes === 'both' ? ' · ' : '') +
        (d.modes !== 'ft8' ? 'WSPR ' + dec(d.wsprMHz.toFixed(3)) + ' MHz' : '') + ' ' + tt('(USB-Skala)') + (d.homeGrid ? ' · ' + tt('eigener Locator {0}', d.homeGrid) : '')) + '</div>' + ft8Cycles();
      if (ft8Sel && !d.spots.some(s => s.id === ft8Sel)) ft8Sel = null;
      ft8RenderMap();
      let html = '';
      if (!d.spots.length) {
        html += '<div class="empty">' + esc(d.running
          ? (d.cqOnly && d.decodes ? t('Kein CQ-Ruf unter den Dekodierungen.') : t('Noch nichts dekodiert. Auf 2 m und 70 cm ist FT8 oft nur bei Überreichweiten oder Contesten belebt, auf 6 m vor allem bei sporadischer E-Schicht (Mai–August).'))
          : t('Keine Dekodierungen. Tippe oben auf „Start“, dann wertet der Mac jeden Zyklus aus.')) + '</div>';
      }
      html += d.spots.map(s => {
        const where = [s.grid ? s.grid + (s.gridMsg ? '' : '*') : '', s.km != null ? s.km + ' km ' + s.dir + ' ' + s.brg + '°' : ''].filter(Boolean).join(' · ');
        const msg = esc(s.msg).replace(/^CQ\b/, '<span class="cq">CQ</span>');
        return '<div class="item' + (s.id === ft8Sel ? ' on' : '') + '" data-spot="' + esc(s.id) + '"><div class="grow">' +
          '<div class="msg">' + msg + '</div>' +
          '<div class="sub">' + esc(ft8UTC(s.t)) + ' · <span class="' + (s.mode === 'WSPR' ? 'wspr' : '') + '">' + esc(s.mode + (s.osd ? '*' : '')) + '</span> · ' +
          esc('Δt ' + dec(s.dt.toFixed(1)) + ' · ' + s.hz + ' Hz' + (s.drift != null ? ' · Drift ' + s.drift : '') + (s.dbm != null ? ' · ' + s.dbm + ' dBm' : '') + (where ? ' · ' + where : '')) + '</div></div>' +
          '<span class="snr">' + (s.snr > 0 ? '+' : '') + s.snr + ' dB</span></div>';
      }).join('');
      if (d.total > d.spots.length) html += '<div class="hint" style="padding:8px 12px">' + esc(tt('Die neuesten {0} von {1} – alle in der App.', d.spots.length, d.total)) + '</div>';
      html = wxBox('ft8-list', d.cqOnly ? t('CQ-Rufe und WSPR') : t('Dekodierungen'), html, d.total);
      html += '<div class="hint">' + t('Nur Empfang – gesendet oder gemeldet (PSK Reporter, WSPRnet) wird nichts. * am Locator: zuletzt gesehener, nicht aus dieser Nachricht.') +
        (d.home ? '' : ' ' + t('Für Entfernung und Richtung in der App den eigenen Standort setzen.')) + '</div>';
      if (list.dataset.html === html) return;
      list.dataset.html = html; list.innerHTML = html;
      list.querySelectorAll('[data-spot]').forEach(el => el.onclick = () => ft8SelectSpot(el.dataset.spot, true));
    }
    // ---------- Ende FT8/WSPR ----------

    // ---------- Belegungsmonitor ----------
    // Kopf (Band, Zeitraum) wird einmal gebaut und nur befüllt; das Wärmebild kommt
    // als PNG vom Mac (/occupancy.png, dort 20 s zwischengespeichert) und wird hier
    // alle 30 s neu geladen. Start/Stopp laufen über den Kopf oben (wie alle Reiter).
    let occData = null;
    const occ = { hours: 6, imgAt: 0, imgKey: '', band: '', info: '', list: '', presets: false, noticeTimer: null };
    try { const h = +localStorage.getItem('occHours'); if ([1, 6, 24].includes(h)) occ.hours = h; } catch (e) {}
    async function loadOcc(params = {}) {
      try {
        const action = Object.keys(params).length > 0;
        occData = await api('/api/occupancy', Object.assign({ hours: occ.hours }, params));
        if (action && occData.notice) occNotice(occData.notice);
        if (tab === 'occupancy') render();
      } catch (e) { showError(e); }
    }
    function occStatus() {
      const d = occData;
      if (d && d.running) return tt('Belegungsmonitor läuft') + (d.rounds ? ' · ' + tt('Runde {0}', d.rounds) : '');
      if (d && d.paused) return t('Belegungsmonitor pausiert');
      return state.mode === 'occupancy' ? t('Belegungsmonitor läuft') : t('Belegungsmonitor aus');
    }
    const occNum = (v, d = 3) => Number(v).toLocaleString(LOCALE, { minimumFractionDigits: 0, maximumFractionDigits: d });
    // Eingabefelder ohne Tausendertrennung – der Mac liest nur Dezimalkomma/-punkt.
    const occInput = v => Number(v).toLocaleString(LOCALE, { minimumFractionDigits: 0, maximumFractionDigits: 4, useGrouping: false });
    function occWhen(ms) {
      if (ms == null) return '–';
      const dt = new Date(ms), today = new Date();
      return (dt.toDateString() === today.toDateString() ? '' : fmtDay(ms) + ' ') + fmtTime(ms);
    }
    function occDuration(sec) {
      if (sec < 60) return Math.round(sec) + ' s';
      const m = Math.round(sec / 60);
      if (m < 60) return m + ' min';
      const h = Math.floor(m / 60);
      return h < 48 ? h + ' h ' + (m % 60) + ' min' : tt('{0} Tage {1} h', Math.floor(h / 24), h % 24);
    }
    function occNotice(text) {
      const n = $('occ-notice'); if (!n) return;
      n.textContent = text; n.style.display = 'block';
      clearTimeout(occ.noticeTimer); occ.noticeTimer = setTimeout(() => n.style.display = 'none', 6000);
    }
    function occBuild(root) {
      if (!$('occ-style')) document.head.insertAdjacentHTML('beforeend', '<style id="occ-style">' +
        '.occ-row { display:flex; flex-wrap:wrap; gap:8px; align-items:center; padding:8px 12px; }' +
        '.occ-row > * { min-width:0; }' +
        '.occ-row select, .occ-row input { font:inherit; background:var(--bg); color:var(--text); border:1px solid var(--line); border-radius:8px; padding:5px 8px; }' +
        '.occ-row select { flex:1; }' +
        '.occ-row input { width:6em; flex:1 1 5em; }' +
        '.occ-row .btn { margin-left:0; }' +
        '.occ-seg { display:inline-flex; gap:4px; margin-left:auto; }' +
        '.occ-seg button { border:1px solid var(--line); background:transparent; color:var(--text); border-radius:6px; padding:1px 8px; font:inherit; font-size:12px; cursor:pointer; }' +
        '.occ-seg button.on { background:var(--accent); border-color:var(--accent); color:#fff; }' +
        '.occ-lbl { display:flex; gap:6px; align-items:center; flex:1 1 7em; min-width:0; }' +
        '.occ-lbl input { flex:1 1 4em; min-width:0; width:auto; }' +
        '.occ-pic { display:grid; grid-template-columns:auto minmax(0,1fr); gap:2px 6px; padding:8px 12px 10px 6px; }' +
        '.occ-time { display:flex; flex-direction:column; justify-content:space-between; font-size:11px; color:var(--muted); text-align:right; white-space:nowrap; }' +
        '.occ-pic img { width:100%; display:block; background:#0c0c0c; border-radius:4px; }' +
        '.occ-freq { grid-column:2; display:flex; justify-content:space-between; gap:6px; font-size:11px; color:var(--muted); font-variant-numeric:tabular-nums; }' +
        '#occ-list .item { cursor:pointer; }' +
        '.occ-bar { width:54px; height:6px; background:var(--line); border-radius:3px; overflow:hidden; flex:none; }' +
        '.occ-bar i { display:block; height:100%; background:var(--accent); }' +
        '.occ-pct { font-variant-numeric:tabular-nums; min-width:4.2em; text-align:right; }' +
        '#occ-notice { display:none; margin-bottom:12px; }' +
        '.occ-warn { color:var(--warn); }' +
        '</style>');
      // Feste Kästen (einmal gebaut): auf-/zuklappbar wie in den anderen Reitern.
      root.innerHTML =
        wxBox('occ-band', t('Band'),
          '<div class="occ-row"><select id="occ-preset" aria-label="' + t('Vorlage') + '"></select></div>' +
          '<div class="occ-row"><label class="occ-lbl">' + t('Von') + ' <input id="occ-start" inputmode="decimal" placeholder="MHz" aria-label="' + t('Von (MHz)') + '"></label>' +
          '<label class="occ-lbl">' + t('Bis') + ' <input id="occ-end" inputmode="decimal" placeholder="MHz" aria-label="' + t('Bis (MHz)') + '"></label>' +
          '<button class="btn secondary" id="occ-range">' + t('Übernehmen') + '</button></div>' +
          '<div class="occ-row"><button class="btn secondary" id="occ-fresh">' + t('Neu beginnen') + '</button></div>') +
        '<div id="occ-notice" class="hint"></div>' +
        '<div id="occ-info"></div>' +
        wxBox('occ-pic', t('Wärmebild'),
          '<div class="occ-row"><span class="hint">' + t('Zeitraum') + '</span><span class="occ-seg" id="occ-hours">' +
          [1, 6, 24].map(h => '<button data-h="' + h + '">' + h + ' h</button>').join('') + '</span></div>' +
          '<div class="occ-pic"><div class="occ-time"><span id="occ-t1"></span><span id="occ-t0"></span></div>' +
          '<div style="min-width:0"><img id="occ-img" alt="' + t('Wärmebild der Belegung') + '"><div class="empty" id="occ-noimg" style="display:none"></div></div>' +
          '<div class="occ-freq"><span id="occ-f0"></span><span id="occ-fm"></span><span id="occ-f1"></span></div></div>' +
          '<div class="hint" id="occ-legend" style="padding:0 12px 10px"></div>') +
        wxBox('occ-active', t('Aktivste Frequenzen'), '<div id="occ-list"></div>');
      const running = () => !!(occData && occData.running);
      const ask = () => !running() || confirm(t('Der Monitor läuft. Mit dem neuen Band neu starten? Die bisherige Aufzeichnung bleibt gespeichert.'));
      $('occ-preset').onchange = e => {
        const v = e.target.value; e.target.blur();
        if (!v) return;   // „Eigener Bereich“: unten eintragen
        if (ask()) loadOcc({ preset: v }); else { occ.band = ''; render(); }
      };
      $('occ-range').onclick = () => {
        const s = $('occ-start').value.trim(), en = $('occ-end').value.trim();
        if (!s || !en) return;
        $('occ-start').blur(); $('occ-end').blur();
        if (ask()) loadOcc({ start: s, end: en }); else { occ.band = ''; render(); }
      };
      $('occ-fresh').onclick = () => {
        if (confirm(running() ? t('Neu beginnen? Die bisherige Aufzeichnung bleibt gespeichert.')
                              : t('Der nächste Start beginnt eine neue Aufzeichnung. Die bisherige bleibt gespeichert.'))) loadOcc({ fresh: 1 });
      };
      $('occ-hours').onclick = e => {
        const h = +(e.target.dataset && e.target.dataset.h);
        if (!h || h === occ.hours) return;
        occ.hours = h; try { localStorage.setItem('occHours', h); } catch (err) {}
        occ.imgAt = 0; loadOcc();
      };
      const img = $('occ-img');
      img.onload = () => { img.style.display = ''; $('occ-noimg').style.display = 'none'; };
      img.onerror = () => {
        if (!img.getAttribute('src')) return;
        img.style.display = 'none';
        const n = $('occ-noimg'); n.textContent = tt('Keine Messungen in den letzten {0} h.', occ.hours); n.style.display = '';
      };
      $('occ-list').onclick = e => { const it = e.target.closest('[data-mhz]'); if (it) occJump(+it.dataset.mhz); };
    }
    // Frequenz im Reiter Radio öffnen – fehlertolerant, falls der Radio-Reiter f= (noch) nicht kennt.
    async function occJump(mhz) {
      const b = document.querySelector('.tabs button[data-tab="fm"]');
      if (!b || !isFinite(mhz)) return;
      b.click();
      try { await api('/api/fm', { f: mhz.toFixed(4) }); if (typeof loadFM === 'function') await loadFM(); }
      catch (e) { /* Radio stellt die Frequenz (noch) nicht ein – der Reiter ist trotzdem offen */ }
    }
    function renderOcc() {
      const root = $('x-occupancy');
      if (!$('occ-preset')) occBuild(root);
      const d = occData;
      if (!d || !d.presets) { $('occ-info').innerHTML = '<div class="empty">' + t('Lade …') + '</div>'; occ.info = ''; return; }
      // Kopf: Vorlagen einmal füllen, Werte nur setzen, wenn sie sich geändert haben und niemand tippt.
      const sel = $('occ-preset');
      if (!occ.presets) {
        sel.innerHTML = d.presets.map(p => '<option value="' + esc(p.id) + '">' + esc(p.name) + '</option>').join('') + '<option value="">' + t('Eigener Bereich') + '</option>';
        occ.presets = true;
      }
      const band = (d.preset || '') + '|' + d.startMHz + '|' + d.endMHz;
      const focus = document.activeElement;
      if (band !== occ.band && focus !== sel && focus !== $('occ-start') && focus !== $('occ-end')) {
        occ.band = band;
        sel.value = d.presets.some(p => p.id === d.preset) ? d.preset : '';
        $('occ-start').value = occInput(d.startMHz);
        $('occ-end').value = occInput(d.endMHz);
      }
      document.querySelectorAll('#occ-hours button').forEach(b => b.classList.toggle('on', +b.dataset.h === occ.hours));
      // Zustand
      const r = d.recording;
      const rows = [];
      rows.push('<div class="item"><div class="grow">' + occNum(d.startMHz, 4) + ' – ' + occNum(d.endMHz, 4) + ' MHz' +
        '<div class="sub">' + t('Raster {0} kHz · {1} Frequenzen · Zeitscheibe {2} · Schwelle +{3} dB', occNum(d.binKHz, 3), d.bins, occDuration(d.sliceSeconds), occNum(d.thresholdDB, 1)) + '</div></div></div>');
      if (d.running) rows.push('<div class="item"><div class="grow">' + t('Läuft seit {0}', occWhen(d.since)) +
        '<div class="sub">' + (d.windowMHz != null ? t('Fenster {0} MHz', occNum(d.windowMHz, 3)) + ' · ' : '') + t('Runde {0}', d.rounds) + '</div></div></div>');
      else if (d.paused) rows.push('<div class="item"><div class="grow occ-warn">' + t('Pausiert') + '<div class="sub">' + esc(d.paused) + '</div></div></div>');
      else rows.push('<div class="item"><div class="grow">' + t('Gestoppt') +
        (r && r.continues ? '<div class="sub">' + t('Der nächste Start setzt die Aufzeichnung fort.') + '</div>' : '') + '</div></div>');
      if (r) rows.push('<div class="item"><div class="grow">' + t('Aufzeichnung „{0}“', r.name) +
        '<div class="sub">' + (r.first != null ? occWhen(r.first) + ' – ' + occWhen(r.last) + ' · ' + occDuration(r.seconds) + ' · ' : '') + t('{0} Zeitscheiben', r.slices) + '</div></div></div>');
      if (d.hint) rows.push('<div class="item"><div class="grow sub">' + esc(d.hint) + '</div></div>');
      if (d.error) rows.push('<div class="item"><div class="grow occ-warn">' + esc(d.error) + '</div></div>');
      const info = wxBox('occ-state', t('Zustand'), rows.join(''));
      if (info !== occ.info) { occ.info = info; $('occ-info').innerHTML = info; }
      // Wärmebild: Achsen aus dem JSON, das Bild höchstens alle 30 s neu (Cache-Bust).
      const v = d.view, img = $('occ-img');
      $('occ-t1').textContent = v && v.t1 != null ? occWhen(v.t1) : '';
      $('occ-t0').textContent = v && v.t0 != null ? occWhen(v.t0) : '';
      $('occ-f0').textContent = r ? occNum(r.startMHz, 3) : '';
      $('occ-fm').textContent = r ? occNum((r.startMHz + r.endMHz) / 2, 3) + ' MHz' : '';
      $('occ-f1').textContent = r ? occNum(r.endMHz, 3) : '';
      $('occ-legend').textContent = r ? t('Neueste Zeile oben') + ' · ' + d.legend + ' · ' + t('grau = keine Messung') : '';
      if (!r || !r.slices) {
        img.style.display = 'none'; img.removeAttribute('src'); occ.imgKey = '';
        const n = $('occ-noimg'); n.textContent = t('Noch keine Aufzeichnung – starte den Monitor.'); n.style.display = '';
      } else {
        const box = img.parentElement;
        const w = Math.min(1600, Math.max(64, Math.round((box.clientWidth || 360) * Math.min(2, window.devicePixelRatio || 1))));
        const h = Math.min(1600, Math.round(w * 0.6));
        const key = occ.hours + '|' + w + '|' + r.name + '|' + r.first;
        if (key !== occ.imgKey || Date.now() - occ.imgAt > 30000) {
          occ.imgKey = key; occ.imgAt = Date.now();
          img.src = '/occupancy.png?' + new URLSearchParams({ w, h, hours: occ.hours, t: Date.now() });
        }
      }
      // Aktivste Frequenzen – Antippen öffnet sie im Radio.
      const list = d.active.length ? d.active.map(a =>
        '<div class="item" data-mhz="' + Number(a.mhz) + '" title="' + t('Im Radio öffnen') + '"><div class="grow">' + occNum(a.mhz, 4) + ' MHz' +
        '<div class="sub">' + t('zuletzt aktiv {0} · Spitze +{1} dB · {2} Scheiben', occWhen(a.last), occNum(a.peakDB, 1), a.slices) + '</div></div>' +
        '<span class="occ-bar"><i style="width:' + Math.min(100, Math.max(1, Number(a.occ))) + '%"></i></span>' +
        '<span class="occ-pct">' + occNum(a.occ, a.occ < 10 ? 2 : 1) + ' %</span></div>').join('')
        : '<div class="empty">' + (r ? t('Noch keine Frequenz über der Schwelle.') : t('Noch keine Aufzeichnung.')) + '</div>';
      if (list !== occ.list) { occ.list = list; $('occ-list').innerHTML = list; }
    }
    // ---------- Ende Belegungsmonitor ----------

    // ---------- Flugfunk ----------
    // Kanalliste mit Pegeln, letzte Sprüche, Suchlauf. Der Ton kommt über denselben
    // Strom wie DAB+ (/audio.aac) – es spielt, was gerade empfängt.
    let ab = null;
    async function loadAirband(params = {}) {
      try { ab = await api('/api/airband', params); if (tab === 'airband') render(); } catch (e) { showError(e); }
    }
    const abFmt = ms => new Date(ms).toLocaleTimeString(LOCALE, { hour: '2-digit', minute: '2-digit', second: '2-digit' });
    // Ein Spruch; die Abschrift (Funktext, fremder Inhalt) nur über esc(). Geringe
    // Zuversicht blasser, Rohtext im title.
    function abItem(h) {
      const op = h.conf == null || h.conf >= 0.7 ? 1 : h.conf >= 0.45 ? 0.75 : 0.5;
      const text = h.text ? '<div class="abtx" style="opacity:' + op + '" title="' + esc(h.raw || '') + '">' +
        (h.cs ? '<b>' + esc(h.cs) + '</b> ' : '') + esc(h.text) + '</div>' : '';
      return '<div class="item"><div class="grow"><div>' + esc(h.ch + (h.name ? ' · ' + h.name : '')) + '</div>' + text +
        '<div class="sub">' + esc(abFmt(h.t) + ' · ' + h.dur.toFixed(1) + ' s · +' + h.peak.toFixed(0) + ' dB') + '</div></div></div>';
    }
    // Suche in den Abschriften (/api/airband/search) – eigenes Feld außerhalb der
    // Liste, damit das Neuzeichnen den Fokus nicht nimmt.
    async function searchAirband() {
      const q = $('absearch').value.trim(), out = $('abresults');
      if (!q) { out.innerHTML = ''; return; }
      try {
        const r = await api('/api/airband/search', { q });
        out.innerHTML = r.results.length ? r.results.map(h => abItem({ ...h, ch: new Date(h.t).toLocaleDateString(LOCALE) + ' · ' + h.ch })).join('')
          : '<div class="empty">' + t('Keine Abschrift enthält „{0}“.', q) + '</div>';
      } catch (e) { showError(e); }
    }
    $('absearchbtn').onclick = searchAirband;
    $('absearch').onkeydown = e => { if (e.key === 'Enter') searchAirband(); };
    function renderAirband() {
      const head = $('abhead'), list = $('ablist');
      if (!ab) { list.innerHTML = '<div class="empty">' + t('Lade …') + '</div>'; return; }
      const active = state.mode === 'airband';
      const audibleCh = ab.channels.find(c => c.i === ab.audible);
      // Kopf: nur bei Änderung neu bauen (sonst springt der Knopf beim Tippen).
      const headHTML = '<div class="box"><div class="abbar">' +
        '<button class="btn" id="abplay">' + audioLabel() + '</button>' +
        '<span class="hint">' + t('Sperre') + '</span><button class="btn secondary" data-sq="-1">−</button><b>' + ab.squelch.toFixed(0) + ' dB</b><button class="btn secondary" data-sq="1">+</button>' +
        (ab.hold != null ? '<button class="btn secondary" data-hold="0">' + t('Halten lösen') + '</button>' : '') + '</div>' +
        '<div class="hint" style="padding:0 12px 10px">' + esc((active
          ? (audibleCh ? tt('Hörbar: {0}', audibleCh.ch + (audibleCh.name ? ' · ' + audibleCh.name : '')) : tt('Stille – höre {0} Kanäle ab', ab.channels.filter(c => c.inWindow).length)) +
            ' · ' + tt('Ausschnitt um {0} MHz', ab.centerMHz.toFixed(3))
          : t('Flugfunk ist aus – oben „Start“ tippen.')) +
        ' ' + t('Solange hier jemand zuhört, bleibt der Mac stumm.')) + '</div></div>';
      if (head.dataset.html !== headHTML) {
        head.dataset.html = headHTML; head.innerHTML = headHTML;
        $('abplay').onclick = toggleAudio;
        head.querySelectorAll('[data-sq]').forEach(b => b.onclick = () => loadAirband({ squelch: ab.squelch + Number(b.dataset.sq) }));
        head.querySelectorAll('[data-hold]').forEach(b => b.onclick = () => loadAirband({ hold: -1 }));
      }
      const spr = n => n === 1 ? t('1 Spruch') : t('{0} Sprüche', n);
      // Suchlauf zuerst (einklappbar wie im Wetter-Reiter, Zustand gemerkt).
      let find = '<div class="abbar">' + (ab.finding
          ? '<span class="hint" style="flex:1">' + esc(ab.findStatus || t('Suche läuft …')) + ' · ' + Math.round(ab.findProgress * 100) + ' %</span><button class="btn secondary" data-find="stop">' + t('Abbrechen') + '</button>'
          : '<button class="btn" data-find="start" data-min="15" data-dwell="30">15 min</button><button class="btn" data-find="start" data-min="60" data-dwell="30">1 h</button>' +
            '<button class="btn secondary" data-find="start" data-min="120" data-dwell="60">' + t('2 h, je 1 min') + '</button>' +
            '<span class="hint">' + (active ? t('je Fenster 30 s') : t('schaltet den Flugfunk ein')) + '</span>') + '</div>' +
        (ab.findings.length ? ab.findings.map(f =>
          '<div class="item"><div class="grow"><div>' + esc(f.ch) + (f.cont ? ' · ' + t('Dauerträger?') : '') + '</div><div class="sub">' + spr(f.tx) + ' · ' + t('{0} s belegt', f.openSec) + ' · +' + f.peak.toFixed(0) + ' dB</div></div>' +
          (f.inList ? '<span class="hint">' + t('✓ in Liste') + '</span>' : '<button class="btn secondary" data-add="' + f.i + '">' + t('+ Liste') + '</button>') + '</div>').join('') : '');
      let html = wxBox('ab-find', t('Aktive Kanäle finden'), find, ab.findings.length || null);
      let chans = '';
      if (!ab.channels.length) chans += '<div class="empty">' + t('Noch keine Kanäle – oben eintragen oder „Aktive Kanäle finden“.') + '</div>';
      chans += ab.channels.map(c => {
        const lvl = c.excess == null ? 0 : Math.max(0, Math.min(100, c.excess * 2.5));
        const cls = 'item abch' + (c.i === ab.audible ? ' aud' : c.open ? ' open' : '');
        return '<div class="' + cls + '"><span>' + (c.i === ab.audible ? '🔊' : c.open ? '●' : c.locked ? '⦸' : '·') + '</span>' +
          '<div class="grow"><div>' + esc(c.ch) + (c.name ? ' · ' + esc(c.name) : '') + '</div>' +
          '<div class="sub">' + (c.inWindow ? (c.excess == null ? '–' : '+' + c.excess.toFixed(0) + ' dB') : t('außerhalb des Ausschnitts')) + '</div></div>' +
          '<span class="lvl"><i style="width:' + lvl + '%"></i></span>' +
          '<span class="tools"><button data-a="hold" data-i="' + c.i + '"' + (ab.hold === c.i ? ' class="on"' : '') + ' title="' + t('Halten') + '">📌</button>' +
          '<button data-a="prio" data-i="' + c.i + '"' + (c.prio ? ' class="on"' : '') + ' title="' + t('Vorrang') + '">★</button>' +
          '<button data-a="remove" data-i="' + c.i + '" title="' + t('Entfernen') + '">✕</button></span></div>';
      }).join('');
      html += wxBox('ab-ch', t('Kanäle'), chans, ab.channels.length || null);
      html += wxBox('ab-hist', t('Letzte Sprüche'), ab.history.length ? ab.history.map(abItem).join('')
        : '<div class="empty">' + t('Noch kein Spruch auf einem Listenkanal.') + '</div>', ab.history.length || null);
      html += '<div class="hint">' + t('Flugfunk darfst du in Deutschland hören, aber Inhalte nicht aufzeichnen oder weitergeben (§ 5 TDDDG).') + '</div>';
      if (selecting(list)) return;
      const top = list.scrollTop; list.innerHTML = html; list.scrollTop = top;
      list.querySelectorAll('[data-a]').forEach(b => b.onclick = () => {
        const i = Number(b.dataset.i), a = b.dataset.a;
        loadAirband(a === 'hold' ? { hold: ab.hold === i ? -1 : i } : { [a]: i });
      });
      list.querySelectorAll('[data-find]').forEach(b => b.onclick = () => loadAirband(b.dataset.find === 'start' ? { find: 'start', min: b.dataset.min, dwell: b.dataset.dwell || 30 } : { find: 'stop' }));
      list.querySelectorAll('[data-add]').forEach(b => b.onclick = () => loadAirband({ addfound: b.dataset.add }));
      if ('mediaSession' in navigator && !player.paused) {
        navigator.mediaSession.metadata = new MediaMetadata({ title: audibleCh ? audibleCh.ch + (audibleCh.name ? ' · ' + audibleCh.name : '') : t('Flugfunk'), artist: t('Flugfunk'), album: 'PortaPack',
          artwork: [{ src: '/icon-512.png', sizes: '512x512', type: 'image/png' }] });
      }
    }
    $('abaddbtn').onclick = () => {
      const v = $('abnew').value.trim(); if (!v) return;
      loadAirband({ add: v, name: $('abname').value.trim() }).then(() => { $('abnew').value = ''; $('abname').value = ''; });
    };

    // ---------- Kopf: Start/Stopp ----------
    // Jeder Empfänger-Reiter hat oben denselben Kopf (29.10.2026): großer Knopf
    // „Start“ (schaltet den HackRF auf diesen Reiter um, /api/mode wie früher das
    // Banner) bzw. „Stopp“, wenn dieser Reiter gerade empfängt; daneben, was gerade
    // läuft, und eine geplante Aufnahme. Neu gebaut nur bei geändertem Inhalt.
    async function startReception() {
      const b = $('runbar').querySelector('[data-run]');
      if (b) { b.disabled = true; b.textContent = t('Schalte um …'); }
      try { state = await api('/api/mode', { m: tab }); fitted[tab] = false; } catch (e) { showError(e); }
      $('runbar').dataset.html = ''; render();
    }
    async function stopReception() {
      try { state = await api('/api/mode', { m: '' }); if (!player.paused) stopAudio(); } catch (e) { showError(e); }
      $('runbar').dataset.html = ''; render();
    }
    function renderRunbar() {
      const bar = $('runbar');
      if (tab === 'wx') { bar.style.display = 'none'; bar.dataset.html = ''; return; }
      const mine = state.mode === tab;
      const btn = state.switching ? '<button class="runbtn" disabled>' + t('Schalte um …') + '</button>'
        : mine ? '<button class="runbtn stop" data-run="stop">' + t('■ Stopp') + '</button>'
        : '<button class="runbtn" data-run="start">' + t('▶︎ Start') + '</button>';
      let info;
      if (state.plan) info = t('Geplante Aufnahme: {0}. Danach läuft der vorherige Empfang von selbst weiter.', raw('<b>' + esc(state.plan) + '</b>')) +
        '<button class="btn secondary" data-run="skip">' + t('Aufnahme überspringen') + '</button>';
      else if (mine) info = t('Empfang läuft.');
      else if (state.mode) info = t('Gerade läuft: {0}', raw('<b>' + esc(TITLES[state.mode] || state.mode) + '</b>'));
      else info = state.hackrf ? t('Der HackRF empfängt gerade nichts.') : t('Das Gerät ist nicht im HackRF-Modus – „Start“ schaltet um.');
      const html = btn + '<span class="runinfo">' + info + '</span>';
      bar.style.display = 'flex';
      bar.classList.toggle('plan', !!state.plan);
      if (bar.dataset.html === html) return;
      bar.dataset.html = html; bar.innerHTML = html;
    }
    $('runbar').onclick = e => {
      const b = e.target.closest('[data-run]');
      if (!b || b.disabled) return;
      if (b.dataset.run === 'start') startReception();
      else if (b.dataset.run === 'stop') stopReception();
      else if (b.dataset.run === 'skip') { b.disabled = true; b.textContent = t('Beende Aufnahme …'); api('/api/plan', { skip: 1 }).catch(showError); }
    };

    // ---------- Flugplätze (nur Reiter Flugzeuge) ----------
    // Aus der Flugplatzliste des Macs (/api/airports: höchstens 150 im Ausschnitt,
    // nach Wichtigkeit; Hubschrauberlandeplätze erst nah heran). Neu geholt wird nur
    // nach dem Verschieben/Zoomen; vorhandene Marker bleiben stehen (offene Infos auch).
    const AP_COLOR = '#5e5ce6';
    const apLayer = L.layerGroup();
    const ap = { on: stored('airports', '1') === '1', key: '', busy: false, markers: new Map(), hinted: false };
    $('apbtn').classList.toggle('on', ap.on);
    $('apbtn').onclick = () => {
      ap.on = !ap.on; ap.key = '';
      try { localStorage.setItem('airports', ap.on ? '1' : '0'); } catch (e) {}
      $('apbtn').classList.toggle('on', ap.on);
      updateAirports();
    };
    map.on('moveend', () => updateAirports());
    function apKind(k) {
      return { large: t('Großer Flughafen'), medium: t('Flughafen'), small: t('Flugplatz'), seaplane: t('Wasserflugplatz'), heliport: t('Hubschrauberlandeplatz') }[k] || k;
    }
    function apPopup(a) {
      const sub = [apKind(a.kind), a.city, a.elevM != null ? tt('Höhe {0} m', a.elevM) : null, a.sched ? tt('Linienverkehr') : null].filter(Boolean).join(' · ');
      return '<div class="appop"><b>' + esc(a.code) + (a.iata ? ' · ' + esc(a.iata) : '') + '</b><br>' + esc(a.name) + '<br><span class="hint">' + esc(sub) + '</span></div>';
    }
    function apMarker(a, labeled) {
      let m;
      if (a.kind === 'heliport') {
        m = L.marker([a.lat, a.lon], { keyboard: false, icon: L.divIcon({ className: 'aph', iconSize: [12, 12], html: '<div>H</div>' }) });
      } else {
        const big = a.kind === 'large' || a.kind === 'medium';
        m = L.circleMarker([a.lat, a.lon], { radius: a.kind === 'large' ? 6 : a.kind === 'medium' ? 4.5 : 3.5, weight: 1.5, bubblingMouseEvents: false,
          color: big ? '#fff' : a.kind === 'seaplane' ? '#30b0c7' : AP_COLOR, fillColor: big ? AP_COLOR : '#fff', fillOpacity: big ? .85 : .7 });
      }
      m.bindPopup(apPopup(a), { autoPan: false });
      if (labeled) m.bindTooltip(esc(a.code), { permanent: true, direction: 'right', offset: [5, 0], className: 'aplbl', interactive: false });
      return m;
    }
    async function updateAirports() {
      $('apbtn').style.display = tab === 'adsb' ? '' : 'none';
      if (!ap.on || tab !== 'adsb') { if (map.hasLayer(apLayer)) map.removeLayer(apLayer); return; }
      if (!map.hasLayer(apLayer)) apLayer.addTo(map);
      const b = map.getBounds(), z = map.getZoom();
      const bbox = [b.getSouth(), b.getWest(), b.getNorth(), b.getEast()].map(v => v.toFixed(3)).join(',');
      if (bbox === ap.key || ap.busy) return;
      ap.busy = true;
      try {
        const d = await api('/api/airports', { bbox });
        ap.key = bbox;
        if (!d.available && !ap.hinted) { ap.hinted = true; showError(t('Flugplätze: am Mac auf der Seite Flugzeuge unter „Daten & Export“ laden.')); }
        // Kennungen: große Plätze ab Zoom 6, mittlere ab 8, kleine ab 10 – sonst wird es eng.
        const seen = new Set();
        for (const a of d.airports) {
          const labeled = a.kind === 'large' ? z >= 6 : a.kind === 'medium' ? z >= 8 : z >= 10;
          const key = a.code + '|' + a.kind + '|' + (labeled ? 1 : 0);
          seen.add(key);
          if (!ap.markers.has(key)) { const m = apMarker(a, labeled).addTo(apLayer); ap.markers.set(key, m); }
        }
        for (const [key, m] of ap.markers) if (!seen.has(key)) { apLayer.removeLayer(m); ap.markers.delete(key); }
      } catch (e) { ap.key = bbox; }   // erst nach dem nächsten Verschieben erneut
      finally { ap.busy = false; }
      // Während der Abfrage verschoben? Dann gleich nachholen.
      const nb = map.getBounds();
      if (ap.on && tab === 'adsb' && [nb.getSouth(), nb.getWest(), nb.getNorth(), nb.getEast()].map(v => v.toFixed(3)).join(',') !== ap.key) updateAirports();
    }

    // ---------- Gesamt ----------
    function render() {
      if (!state) return;
      document.querySelectorAll('.tabs button').forEach(b => b.classList.toggle('on', b.dataset.tab === tab));
      const cur = document.querySelector('.tabs button[data-tab="' + tab + '"]');
      if (cur) {
        const icon = cur.cloneNode(true); icon.querySelector('small').remove();
        if ($('menuicon').dataset.tab !== tab) { $('menuicon').innerHTML = icon.innerHTML; $('menuicon').dataset.tab = tab; }
        $('menutitle').textContent = cur.querySelector('small').textContent;
      }
      renderRunbar();
      const isMap = tab === 'adsb' || tab === 'ais';
      $('mapwrap').style.display = isMap ? '' : 'none';
      $('side').style.display = isMap ? '' : 'none';
      $('radio').style.display = tab === 'dab' ? 'block' : 'none';
      $('wx').style.display = tab === 'wx' ? 'block' : 'none';
      $('spec').style.display = tab === 'spectrum' ? 'flex' : 'none';
      $('acars').style.display = tab === 'acars' ? 'block' : 'none';
      $('zb').style.display = tab === 'zigbee' ? 'flex' : 'none';
      $('ab').style.display = tab === 'airband' ? 'block' : 'none';
      for (const x of EXTRA_TABS) $('x-' + x).style.display = tab === x ? 'block' : 'none';
      const st = tab === 'zigbee' ? zigbeeStatus()
               : tab === 'fm' ? fmStatus() : tab === 'sensors' ? sensorsStatus() : tab === 'smart868' ? smartStatus()
               : tab === 'dsc' ? dscStatus() : tab === 'ft8' ? ft8Status() : tab === 'occupancy' ? occStatus()
               : tab === 'airband' ? (ab && ab.running ? tt('{0} Kanäle · {1} Sprüche', ab.channels.length, ab.transmissions) + (ab.finding ? ' · ' + tt('Suche läuft') : '') : tt('Flugfunk aus')) : tab === 'adsb' ? tt('{0} Flugzeuge', state.adsb.aircraft.length) + ' · ' + state.adsb.messagesPerSecond.toFixed(1) + '/s'
               : tab === 'ais' ? tt('{0} Schiffe', state.ais.vessels.length) + ' · ' + tt('{0} Meldungen', state.ais.messages)
               : tab === 'acars' ? (acars && acars.running ? tt('{0} Nachrichten · {1} Rahmen · {2} Flugzeuge', acars.messages, acars.frames, acars.aircraft) : tt('Flugzeug-Datenfunk aus'))
               : tab === 'spectrum' ? (state.mode === 'spectrum' && spec ? spec.centerMHz.toFixed(3) + ' MHz · ' + spec.rateMHz + ' MHz' : t('Spektrum aus'))
               : tab === 'wx' ? (plan && plan.status ? plan.status : plan ? wxNext() : tt('Wetter'))
               : state.mode === 'dab' ? tt('Kanal {0}', state.dab.channel) + ' · ' + (state.dab.listeners ? tt('{0} Hörer', state.dab.listeners) : tt('niemand hört zu'))
               : t('Digitalradio aus');
      const live = tab === 'wx' ? !!(plan && plan.status) : state.mode === tab;
      const gainable = live && tab !== 'wx' && tab !== 'spectrum' && state.gain && state.gain.tunable;
      // Verstärkung als kleiner Knopf in der Statuszeile; die Leiste klappt erst auf Tipp
      // auf (bzw. von selbst, solange optimiert wird) – sonst kostet sie eine ganze Zeile.
      $('status').innerHTML = '<span class="dot' + (live ? ' on' : '') + '"></span>' + esc(st) + levelHTML() +
        (gainable ? '<button class="iconbtn' + (gainOpen ? ' on' : '') + '" data-gain title="' + t('Signal optimieren und Verstärkungsautomatik') + '" aria-label="' + t('Signal optimieren') + '"><svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" aria-hidden="true"><path d="M12 12v10"/><circle cx="12" cy="10" r="1.6" fill="currentColor"/><path d="M8.5 6.5a5 5 0 0 0 0 7M15.5 6.5a5 5 0 0 1 0 7M5.5 3.5a9 9 0 0 0 0 13M18.5 3.5a9 9 0 0 1 0 13"/></svg></button>' : '') +
        (state.mode && tab !== 'wx' ? '<button class="iconbtn" data-stop title="' + t('Empfang beenden (jeder Empfänger)') + '" aria-label="' + t('Empfang beenden') + '"><svg width="14" height="14" viewBox="0 0 14 14" aria-hidden="true"><rect x="1" y="1" width="12" height="12" rx="2" fill="currentColor"/></svg></button>' : '');
      renderGain(gainable && (gainOpen || state.gain.active));
      updateAirports();
      document.querySelectorAll('[data-gain]').forEach(b => b.onclick = () => { gainOpen = !gainOpen; render(); });
      // Quadrat = globales „Empfang beenden“: alles aus, der HackRF ist frei – auch
      // wenn ein anderer Empfänger als der dieses Reiters läuft.
      document.querySelectorAll('[data-stop]').forEach(b => b.onclick = stopReception);
      if (isMap && archive.on) { $('card').style.display = 'none'; if (!archive.data) renderArchive(); setTimeout(() => map.invalidateSize(), 0); }
      else if (isMap) { renderMap(); renderList(); renderCard(); setTimeout(() => map.invalidateSize(), 0); }
      else if (tab === 'dab') renderRadio();
      else if (tab === 'acars') renderACARS();
      else if (tab === 'zigbee') renderZigbee();
      else if (tab === 'airband') renderAirband();
      else if (tab === 'fm') renderFM();
      else if (tab === 'sensors') renderSensors();
      else if (tab === 'smart868') renderSmart();
      else if (tab === 'dsc') renderDSC();
      else if (tab === 'ft8') renderFT8();
      else if (tab === 'occupancy') renderOcc();
    }

    // „Signal optimieren“ und Verstärkungsautomatik für den laufenden Empfänger.
    // Neu gesetzt wird nur bei geändertem Inhalt – sonst springt der Schalter beim Tippen.
    var gainOpen = false;   // var: render() läuft womöglich, bevor diese Zeile erreicht ist
    function renderGain(show) {
      const bar = $('gainbar'), g = state.gain;
      if (!show || !g || !g.tunable) { bar.style.display = 'none'; bar.dataset.html = ''; return; }
      const action = g.active
        ? '<span class="gstat">' + esc(g.status || t('Signal wird optimiert …')) + '</span><button class="btn secondary" id="gcancel">' + t('Abbrechen') + '</button>'
        : '<button class="btn" id="gopt" title="' + t('Pegel und Dekoder für LNA/VGA durchprobieren (etwa eine halbe Minute)') + '">' + t('Signal optimieren') + '</button>';
      const html = '<div class="gline">' + action +
        '<label><input type="checkbox" id="gauto"' + (g.autoGain ? ' checked' : '') + '> ' + t('Verstärkung automatisch nachregeln') + '</label></div>' +
        (g.result ? '<div class="hint">' + esc(tt('Ergebnis: {0}', g.result)) + '</div>' : '') +
        (g.autoNote ? '<div class="hint">' + esc(tt('Automatik: {0}', g.autoNote)) + '</div>' : '');
      bar.style.display = 'block';
      if (bar.dataset.html === html) return;
      bar.dataset.html = html; bar.innerHTML = html;
      const call = (path, params) => api(path, params).then(s => { state = s; render(); }).catch(showError);
      if ($('gopt')) $('gopt').onclick = () => call('/api/optimize');
      if ($('gcancel')) $('gcancel').onclick = () => call('/api/optimize', { cancel: 1 });
      $('gauto').onchange = e => call('/api/gain', { auto: e.target.checked ? 1 : 0 });
    }

    // Pegel am Wandler wie in der App: −50…0 dBFS, grau < −40, grün, orange > −12,
    // rot > −6 oder ab 1 % Anschlag.
    function levelHTML() {
      const l = state.level;
      if (!l) return '';
      const pct = v => Math.max(0, Math.min(100, (v + 50) * 2));
      const color = l.clipped >= 0.01 || l.rms > -6 ? 'var(--warn)' : l.clipped >= 0.001 || l.rms > -12 ? '#ff9f0a' : l.rms < -40 ? 'var(--muted)' : 'var(--ok)';
      const clip = l.clipped >= 0.001 ? ' · ' + (l.clipped * 100).toFixed(1) + ' %' : '';
      return '<span class="level"><span class="meter"><i style="width:' + pct(l.rms) + '%;background:' + color + '"></i><b style="left:' + pct(l.peak) + '%"></b></span>' +
        Math.round(l.rms) + ' dBFS' + clip + '</span>';
    }

    let timer = null;
    async function poll(once) {
      clearTimeout(timer);
      try {
        state = await api('/api/state', sel && sel.startsWith(tab) ? { sel } : {});
        if (tabFromState) { tabFromState = false; if (state.mode) tab = state.mode; }
        render();
        // Plan seltener: alle 10 s, solange der Reiter offen ist.
        if (tab === 'wx' && (!plan || Date.now() - (plan.loaded || 0) > 10000)) { await loadPlan(); if (plan) plan.loaded = Date.now(); }
        if (tab === 'acars') await loadACARS();
        if (tab === 'zigbee') await loadZigbee();
        if (tab === 'airband') await loadAirband();
        if (tab === 'fm') await loadFM();
        if (tab === 'sensors') await loadSensors();
        if (tab === 'smart868') await loadSmart();
        if (tab === 'dsc') await loadDSC();
        if (tab === 'ft8') await loadFT8();
        if (tab === 'occupancy') await loadOcc();
      }
      catch (e) { $('status').textContent = t('Verbindung unterbrochen'); }
      if (!once) timer = setTimeout(poll, 2000); else timer = setTimeout(poll, 2000);
    }
    const menu = $('menu');
    function setMenu(open) { menu.classList.toggle('open', open); $('menubtn').setAttribute('aria-expanded', open ? 'true' : 'false'); }
    $('menubtn').onclick = e => { e.stopPropagation(); setMenu(!menu.classList.contains('open')); };
    document.addEventListener('click', e => { if (menu.classList.contains('open') && !menu.contains(e.target)) setMenu(false); });
    document.addEventListener('keydown', e => { if (e.key === 'Escape') setMenu(false); });
    document.querySelectorAll('.tabs button').forEach(b => b.onclick = () => {
      setMenu(false);
      tab = b.dataset.tab; localStorage.setItem('tab', tab); sel = null;
      if (archive.on) { archive.on = false; archive.data = null; if (archive.line) { map.removeLayer(archive.line); archive.line = null; } $('archbtn').classList.remove('on'); }
      layer.clearLayers(); markers = new Map(); trail = null; if (tab === 'wx') plan = null; render(); if (tab === 'wx') renderWeather(); poll(true);
      if (tab === 'spectrum') { if (!specPresets) loadSpecPresets(); specPoll(); }
    });
    // Konto und Abmelden unten im Menü; „Nur ansehen“ als Hinweis dazu.
    $('whoami').textContent = ROLE === 'view' ? tt('{0} · nur ansehen', USER) : USER;
    $('logoutbtn').value = tt('Abmelden');
    poll();
    if (tab === 'spectrum') { loadSpecPresets(); specPoll(); }
    </script>
    </body>
    </html>
    """#
}
