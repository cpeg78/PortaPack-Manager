/*
 * Karte der Mac-App (PortaPack Manager) auf Leaflet – siehe Docs/Erfahrungen/Karten.md.
 *
 * Swift schickt Nachrichten als JSON-Text an PPM.receive(text):
 *   { options?, remove?: [id], upsert?: [feature], append?: [{id, points}], commands?: [command] }
 * Die Seite meldet über window.webkit.messageHandlers.map:
 *   ready · view (Ausschnitt) · follow (Nutzer hat bewegt) · select (Ziel angeklickt) · tap (Hintergrund) · error
 *
 * Texte aus dem Funk (Schiffsnamen, Rufzeichen …) landen nur über textContent im
 * DOM, nie über innerHTML – Leaflet-Tooltips bekommen deshalb DOM-Elemente.
 */
(function () {
  'use strict';

  function post(message) {
    try { window.webkit.messageHandlers.map.postMessage(message); }
    catch (e) { if (window.ppmDebugPost) window.ppmDebugPost(message); }
  }
  window.addEventListener('error', function (e) { post({ type: 'error', message: String(e.message || e) }); });

  // Symbole im 24×24-Raster, gerichtete zeigen nach Norden. Nur feste Zeichenketten –
  // nie Daten aus dem Funk.
  var ARCS = '<g fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round">';
  // Dunkle Kontur wie bei Flugzeug und Schiff: farbige Symbole gingen sonst auf Wald,
  // Wiesen und Wasser unter (Nutzer 30.10.2026: Relais/APRS und Sonden „schlecht zu erkennen“).
  var EDGE = ' stroke="#1d1d1f" stroke-opacity=".7" stroke-width="1.4" stroke-linejoin="round"';
  // Funkbögen: dunkle Unterlage, darüber die Bögen in der Symbolfarbe.
  function arcs(d) {
    return '<path d="' + d + '" fill="none" stroke="#1d1d1f" stroke-opacity=".7" stroke-width="4.4" stroke-linecap="round"/>' +
      '<path d="' + d + '" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round"/>';
  }
  var SYMBOLS = {
    plane: '<path d="M12 1.5c.9 0 1.5.9 1.5 2V9l8 4.6v2.2l-8-2.4v5l2.6 2v1.7L12 21.2l-4.1.9v-1.7l2.6-2v-5l-8 2.4v-2.2l8-4.6V3.5c0-1.1.6-2 1.5-2z" stroke="#1d1d1f" stroke-opacity=".7" stroke-width="1.4" stroke-linejoin="round"/>',
    arrow: '<path d="M12 2l7 19-7-4-7 4z"/>',
    arrowHead: '<path d="M12 4l8 16H4z"/>',
    dot: '<circle cx="12" cy="12" r="7"/>',
    house: '<path d="M12 3l9 8h-2.5v9H14v-6h-4v6H5.5v-9H3z"/>',
    antenna: '<circle cx="12" cy="12" r="3.1"' + EDGE + '/>' + arcs('M8.2 8a5.5 5.5 0 0 0 0 8M15.8 8a5.5 5.5 0 0 1 0 8M5 5a9.8 9.8 0 0 0 0 14M19 5a9.8 9.8 0 0 1 0 14'),
    signal: '<circle cx="6.5" cy="17.5" r="3.1"' + EDGE + '/>' + arcs('M6.5 11a6.5 6.5 0 0 1 6.5 6.5M6.5 5.5a12 12 0 0 1 12 12'),
    beacon: '<path d="M10 9.5h4l1.6 11.5H8.4z"' + EDGE + '/><rect x="9" y="3" width="6" height="5" rx="1"' + EDGE + '/>' + arcs('M5.5 4.5l-2-1M18.5 4.5l2-1M5.5 7.5H3M18.5 7.5H21'),
    balloon: '<path d="M12 18.5v4" fill="none" stroke="#1d1d1f" stroke-opacity=".7" stroke-width="2.6" stroke-linecap="round"/><path d="M12 18.5v4" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/>' +
      '<ellipse cx="12" cy="9" rx="7" ry="8"' + EDGE + '/><path d="M10.6 16.6h2.8L12 18.8z"' + EDGE + '/>',
    descent: '<circle cx="12" cy="12" r="10.5"/><path d="M12 6v10M7.5 11.5L12 16l4.5-4.5" fill="none" stroke="#fff" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"/>',
    ascent: '<circle cx="12" cy="12" r="9.5" fill="#fff" stroke="currentColor" stroke-width="2"/><path d="M12 17V7M7.5 11.5L12 7l4.5 4.5" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/>',
    scope: ARCS + '<circle cx="12" cy="12" r="7"/><path d="M12 1.5v6M12 16.5v6M1.5 12h6M16.5 12h6"/></g>',
    person: '<circle cx="12" cy="7" r="4"/><path d="M4 21.5c0-4.6 3.6-7.6 8-7.6s8 3 8 7.6z"/>',
    planeCircle: '<circle cx="12" cy="12" r="11"/><path transform="translate(4.5 4.5) scale(.625)" fill="#fff" d="M12 1.5c.9 0 1.5.9 1.5 2V9l8 4.6v2.2l-8-2.4v5l2.6 2v1.7L12 21.2l-4.1.9v-1.7l2.6-2v-5l-8 2.4v-2.2l8-4.6V3.5c0-1.1.6-2 1.5-2z"/>',
    hexagon: '<path d="M12 2l8.7 5v10L12 22l-8.7-5V7z"/>',
    sos: '<circle cx="12" cy="12" r="11"/><text x="12" y="15.2" text-anchor="middle" font-size="8.5" font-weight="700" font-family="-apple-system,Helvetica,sans-serif" fill="#fff">SOS</text>',
    ship: '<path d="M2.5 14h19l-2.8 6H5.3z"/><path d="M6 9h12v4H6z"/><path d="M9.5 5h5v3h-5z"/>',
    car: '<path d="M4 11.5L6 6h12l2 5.5h.5V18h-2.5v2h-3v-2H9v2H6v-2H3.5v-6.5z"/>',
    truck: '<path d="M1.5 5.5h12.5v11H1.5z"/><path d="M14 9h4.5l3.5 4v3.5h-8z"/><circle cx="6" cy="18" r="2.2"/><circle cx="17.5" cy="18" r="2.2"/>',
    bus: '<path d="M5 2.5h14a1.5 1.5 0 0 1 1.5 1.5v14h-17V4A1.5 1.5 0 0 1 5 2.5z"/><path d="M5.5 18h3.5v3H5.5zM15 18h3.5v3H15z"/>',
    weather: '<circle cx="8" cy="7.5" r="3.6"/><path d="M8.5 20a4.8 4.8 0 0 1-.4-9.6 6.2 6.2 0 0 1 11.6 1.8A4 4 0 0 1 19 20z"/>',
    walker: '<circle cx="13" cy="4" r="2.4"/>' + ARCS + '<path d="M12.5 8l-2 6 3.5 3 1 5M10.5 14l-3 7.5M11 9l-4 3M12.5 8.5l4 3.5" stroke-width="2.4"/></g>',
    bike: ARCS + '<circle cx="5.5" cy="16" r="4"/><circle cx="18.5" cy="16" r="4"/><path d="M5.5 16l4.5-8h6l2.5 8M10 8l3 8h-7.5M9 5.5h3"/></g>',
    sailboat: '<path d="M11.5 2v14H4z"/><path d="M13 5l7 11h-7z"/><path d="M2 17.5h20l-2.5 4h-15z"/>',
    medical: '<rect x="2" y="5" width="20" height="15" rx="2.5"/><path d="M10.5 8.5h3v3h3v3h-3v3h-3v-3h-3v-3h3z" fill="#fff"/>',
    flame: '<path d="M12 1.5c1 4.5 6.5 6.5 6.5 12.5a6.5 6.5 0 0 1-13 0c0-3.4 2.1-5.6 3.2-7.6.2 2.2 1.2 3.4 2.4 3.6-.4-3.4.4-5.9.9-8.5z"/>',
    hull: '<path d="M12 1.5c2.6 2.4 4.2 5.3 4.2 8.8V21.3a1.2 1.2 0 0 1-1.2 1.2H9a1.2 1.2 0 0 1-1.2-1.2V10.3c0-3.5 1.6-6.4 4.2-8.8z" stroke="#1d1d1f" stroke-opacity=".7" stroke-width="1.6" stroke-linejoin="round"/>',
    pin: '<circle cx="12" cy="12" r="10.5"/><circle cx="12" cy="12" r="3.6" fill="#fff"/>',
    apFilled: '<circle cx="12" cy="12" r="9.5" stroke="#fff" stroke-width="3"/>',
    apRing: '<circle cx="12" cy="12" r="8.5" fill="rgba(255,255,255,.65)" stroke="currentColor" stroke-width="5"/>',
    apHeli: '<circle cx="12" cy="12" r="10.5" fill="rgba(255,255,255,.75)" stroke="currentColor" stroke-width="1.8"/><text x="12" y="16.5" text-anchor="middle" font-size="13" font-weight="700" font-family="-apple-system,Helvetica,sans-serif">H</text>'
  };
  // Symbole ohne weißen Lichthof (Flugplätze bringen ihren Rand selbst mit).
  var PLAIN = { apFilled: true, apRing: true, apHeli: true };

  var map = null;
  var options = { fitMaxZoom: 13, center: [51, 10], zoom: 5 };
  var renderers = {};
  var items = new Map();          // id → { f, layer, sym, label }
  var follow = true;              // Ausschnitt folgt dem Inhalt, bis der Nutzer bewegt
  var fitKey = null;
  var pendingFit = false;
  var declutterQueued = false;
  var viewQueued = false;
  var tileErrors = 0;

  var PANES = { area: ['ppmArea', 380], track: ['ppmTrack', 390], ground: ['ppmGround', 580], marker: ['markerPane', 600], top: ['ppmTop', 650] };

  function rendererFor(layer) {
    var pane = (PANES[layer] || PANES.marker)[0];
    if (pane === 'markerPane') pane = 'ppmTrack';
    if (!renderers[pane]) renderers[pane] = L.canvas({ pane: pane, padding: 0.3 });
    return renderers[pane];
  }

  function init(o) {
    if (map) return;
    for (var k in o) options[k] = o[k];
    map = L.map('map', {
      zoomControl: false, worldCopyJump: true, zoomSnap: 0.25, zoomDelta: 0.5,
      scrollWheelZoom: false, boxZoom: false, minZoom: 2, maxZoom: 19
    }).setView(options.center, options.zoom);
    smoothWheelZoom(map);
    Object.keys(PANES).forEach(function (key) {
      var name = PANES[key][0];
      if (name === 'markerPane') return;
      map.createPane(name).style.zIndex = PANES[key][1];
    });
    L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', {
      maxZoom: 19,
      attribution: '<a href="https://www.openstreetmap.org/copyright">© OpenStreetMap</a>'
    }).on('tileerror', function (e) {
      // Nur die ersten Fehler melden (offline wären es sonst Hunderte).
      if (tileErrors++ < 3) post({ type: 'error', message: 'Kachel nicht geladen: ' + (e.tile && e.tile.src) });
    }).addTo(map);
    map.attributionControl.setPrefix(false);
    L.control.scale({ position: 'bottomright', imperial: false }).addTo(map);
    L.control.zoom({ position: 'bottomright', zoomInTitle: options.zoomInTitle || '+', zoomOutTitle: options.zoomOutTitle || '−' }).addTo(map);

    // Bewegt der Nutzer die Karte, folgt sie nicht mehr dem Inhalt.
    map.on('dragstart', userMoved);
    var box = map.getContainer();
    box.addEventListener('wheel', userMoved, { passive: true });
    box.addEventListener('dblclick', userMoved);
    box.addEventListener('keydown', userMoved);
    box.addEventListener('click', function (e) { if (e.target.closest && e.target.closest('.leaflet-control-zoom')) userMoved(); }, true);

    map.on('move zoom', function () { queueView(); });
    map.on('moveend zoomend', function () { sendView(false); });
    map.on('zoomend', queueDeclutter);
    map.on('zoomend', placeAllArrows);   // Pfeilabstand bleibt in Bildschirmpunkten gleich
    map.on('resize', function () {
      queueView();
      if (pendingFit || follow) fitAll(false);
      queueDeclutter();
    });
    map.on('click', function (e) { post({ type: 'tap', lat: e.latlng.lat, lon: e.latlng.lng }); });
    sendView(false);
  }

  // Stufenloses Zoomen mit Mausrad und Trackpad (Nutzer 30.10.2026: „zoomt etwas
  // hakelig“). Leaflets eigenes Rad-Zoomen sammelt Ereignisse und startet je Paket
  // eine Zoom-Animation – bei einer durchgehenden Trackpad-Geste laufen die
  // Animationen gegeneinander. Hier folgt der Zoom je Bild einem Ziel (30 % der
  // Restdifferenz) um den Punkt unter dem Mauszeiger, ohne Animation; nach 200 ms
  // Ruhe gilt die Bewegung als beendet (Muster: Leaflet.SmoothWheelZoom, MIT).
  // Nutzt interne Leaflet-1.9-Methoden (_move, _moveStart, _moveEnd, _stop) –
  // Leaflet liegt fest im Bundle.
  function smoothWheelZoom(m) {
    var goal = 0, anchor = null, mouse = null, frame = 0, timer = 0, moved = false;
    var lastCenter = null, lastZoom = 0;
    function step() {
      if (!m.getCenter().equals(lastCenter) || m.getZoom() !== lastZoom) return;   // jemand anderes bewegt
      var zoom = m.getZoom() + (goal - m.getZoom()) * 0.3;
      zoom = Math.round(zoom * 1000) / 1000;
      var offset = mouse.subtract(m.getSize().divideBy(2));
      var center = m.unproject(m.project(anchor, zoom).subtract(offset), zoom);
      if (!moved) { m._moveStart(true, false); moved = true; }
      m._move(center, zoom);
      lastCenter = m.getCenter(); lastZoom = m.getZoom();
      frame = requestAnimationFrame(step);
    }
    function end() {
      cancelAnimationFrame(frame); frame = 0;
      if (moved) { moved = false; m._moveEnd(true); }
    }
    m.getContainer().addEventListener('wheel', function (e) {
      e.preventDefault();
      if (!frame) {
        m._stop();
        if (m._panAnim) m._panAnim.stop();
        goal = m.getZoom();
        mouse = m.mouseEventToContainerPoint(e);
        anchor = m.containerPointToLatLng(mouse);
        lastCenter = m.getCenter(); lastZoom = m.getZoom();
        frame = requestAnimationFrame(step);
      }
      var p = m.mouseEventToContainerPoint(e);
      if (!p.equals(mouse)) { mouse = p; anchor = m.containerPointToLatLng(p); }
      // Zusammenziehen auf dem Trackpad (ctrlKey) liefert kleine Werte – stärker gewichten.
      var delta = L.DomEvent.getWheelDelta(e) * (e.ctrlKey ? 0.02 : 0.004);
      goal = Math.max(m.getMinZoom(), Math.min(m.getMaxZoom(), goal + delta));
      clearTimeout(timer);
      timer = setTimeout(end, 200);
    }, { passive: false });
  }

  function userMoved() {
    if (!follow) return;
    follow = false;
    post({ type: 'follow', on: false });
  }

  function hasSize() { var s = map.getSize(); return s.x > 0 && s.y > 0; }

  function queueView() {
    if (viewQueued) return;
    viewQueued = true;
    requestAnimationFrame(function () { viewQueued = false; sendView(true); });
  }

  function sendView(moving) {
    if (!map) return;
    var b = map.getBounds(), s = map.getSize();
    post({ type: 'view', south: b.getSouth(), west: b.getWest(), north: b.getNorth(), east: b.getEast(),
           zoom: map.getZoom(), width: s.x, height: s.y, moving: moving });
  }

  function latLngs(points) { return points.map(function (p) { return [p[0], p[1]]; }); }

  // ---- Marker ----

  function markerHTML(f) {
    var root = document.createElement('div');
    root.className = 'ppm-marker';
    var sym = document.createElement('div');
    sym.className = 'ppm-sym';
    root.appendChild(sym);
    var label = document.createElement('div');
    label.className = 'ppm-label';
    root.appendChild(label);
    return { root: root, sym: sym, label: label };
  }

  function symbolMarkup(f) {
    var body = SYMBOLS[f.symbol] || SYMBOLS.dot;
    if (f.badge) {
      // Wie ein MapKit-Marker: farbiger Kreis, weißes Zeichen – ohne dunkle Kontur.
      body = body.split('stroke="#1d1d1f"').join('stroke="none"');
      return '<svg viewBox="0 0 28 28" width="100%" height="100%"><circle cx="14" cy="14" r="12.5" fill="currentColor" stroke="#fff" stroke-width="2"/>' +
        '<g transform="translate(7 7) scale(.5833)" fill="#fff" style="color:#fff">' + body + '</g></svg>';
    }
    return '<svg viewBox="0 0 24 24" width="100%" height="100%" fill="currentColor">' + body + '</svg>';
  }

  function renderMarker(item, f) {
    var old = item.f || {};
    var size = f.size || 18;
    var sym = item.parts.sym;
    if (old.symbol !== f.symbol || old.badge !== f.badge) {
      sym.innerHTML = symbolMarkup(f);   // nur feste Symbole, siehe SYMBOLS
      sym.classList.toggle('ppm-plain', !!PLAIN[f.symbol]);
    }
    sym.style.width = size + 'px';
    sym.style.height = size + 'px';
    sym.style.left = (-size / 2) + 'px';
    sym.style.top = (-size / 2) + 'px';
    sym.style.color = f.color || '#007aff';
    sym.style.opacity = f.opacity == null ? '' : String(f.opacity);
    sym.style.transform = f.rotation == null ? '' : 'rotate(' + f.rotation + 'deg)';
    sym.style.cursor = f.select ? 'pointer' : '';
    var label = item.parts.label;
    var text = f.label || '';
    if (label.textContent !== text) label.textContent = text;   // Funktext: nur textContent
    label.style.display = text ? '' : 'none';
    // Anklickbare Ziele: auch die Beschriftung wählt aus (Klick steigt zum Marker auf).
    label.style.pointerEvents = f.select ? 'auto' : '';
    label.style.cursor = f.select ? 'pointer' : '';
    label.classList.toggle('ppm-bold', !!f.emphasis);
    label.classList.toggle('ppm-dim', !!f.dimLabel);
    label.classList.toggle('ppm-small', f.labelStyle === 'small');
    if (f.labelPosition === 'right') {
      label.classList.add('ppm-right');
      label.style.left = (size / 2 + 3) + 'px';
      label.style.top = '';
    } else {
      label.classList.remove('ppm-right');
      label.style.left = '';
      label.style.top = (size / 2 + 1) + 'px';
    }
    item.layer.setZIndexOffset(f.z || 0);
    setTooltip(item, f.tooltip);
  }

  function setTooltip(item, text) {
    var old = item.f ? item.f.tooltip : undefined;
    if (old === text && item.layer.getTooltip()) return;
    if (!text) { item.layer.unbindTooltip(); return; }
    var el = document.createElement('span');
    el.textContent = text;                                          // nie innerHTML
    item.layer.unbindTooltip();
    item.layer.bindTooltip(el, { direction: 'top', offset: [0, -((item.f && item.f.size) || 18) / 2] });
  }

  function createMarker(f) {
    var parts = markerHTML(f);
    var icon = L.divIcon({ className: 'ppm-icon', html: parts.root, iconSize: [0, 0], iconAnchor: [0, 0] });
    var pane = (PANES[f.layer] || PANES.marker)[0];
    var layer = L.marker(f.points[0], { icon: icon, pane: pane, keyboard: false, interactive: !!f.select,
                                        bubblingMouseEvents: false, riseOnHover: !!f.select });
    var item = { f: null, layer: layer, parts: parts };
    layer.on('click', function () { if (item.f && item.f.select) post({ type: 'select', key: item.f.select }); });
    layer.addTo(map);
    renderMarker(item, f);
    return item;
  }

  // ---- Linien, Flächen, Kreise ----

  function pathStyle(f) {
    var s = {
      color: f.color || '#007aff', weight: f.width == null ? 2 : f.width,
      opacity: f.opacity == null ? 1 : f.opacity, dashArray: f.dash ? f.dash.join(' ') : null,
      interactive: !!f.select, bubblingMouseEvents: !f.select
    };
    if (f.width === 0) s.stroke = false;
    if (f.kind === 'polygon' || f.kind === 'circle') {
      s.fill = f.fillOpacity != null && f.fillOpacity > 0;
      s.fillColor = f.fill || s.color;
      s.fillOpacity = f.fillOpacity || 0;
    }
    return s;
  }

  function createPath(f) {
    var style = pathStyle(f);
    style.renderer = rendererFor(f.layer);
    var layer;
    if (f.kind === 'line') layer = L.polyline(latLngs(f.points), style);
    else if (f.kind === 'polygon') layer = L.polygon(latLngs(f.points), style);
    else layer = L.circle(f.points[0], Object.assign(style, { radius: f.radius || 1 }));
    var item = { f: null, layer: layer };
    layer.on('click', function () { if (item.f && item.f.select) post({ type: 'select', key: item.f.select }); });
    layer.addTo(map);
    if (f.z) layer.bringToFront();
    return item;
  }

  // ---- Richtungspfeile entlang einer Linie (Abstand in Bildschirmpunkten) ----

  var ARROW_SPACING = 60;   // mindestens so viele Punkte zwischen zwei Pfeilen
  var ARROW_LIMIT = 200;

  /**
   * Reine Funktion: Pfeilorte entlang einer Linie in Pixelkoordinaten. Erster Pfeil
   * nach halbem Abstand, dann alle `spacing` Punkte, je mit Richtung (Grad, 0 = oben,
   * im Uhrzeigersinn). Liefert [{x, y, angle}].
   */
  function arrowMarks(pixels, spacing, limit) {
    var out = [];
    if (!pixels || pixels.length < 2 || !(spacing > 0)) return out;
    var next = spacing / 2, walked = 0;
    for (var i = 1; i < pixels.length && out.length < (limit || ARROW_LIMIT); i++) {
      var a = pixels[i - 1], b = pixels[i];
      var dx = b[0] - a[0], dy = b[1] - a[1];
      var len = Math.sqrt(dx * dx + dy * dy);
      if (len === 0) continue;
      var angle = Math.atan2(dx, -dy) * 180 / Math.PI;
      while (walked + len >= next && out.length < (limit || ARROW_LIMIT)) {
        var t = (next - walked) / len;
        out.push({ x: a[0] + dx * t, y: a[1] + dy * t, angle: angle });
        next += spacing;
      }
      walked += len;
    }
    return out;
  }

  function placeArrows(item) {
    (item.arrows || []).forEach(function (m) { m.remove(); });
    item.arrows = [];
    var f = item.f;
    if (!f || f.kind !== 'line' || !f.arrows || !map) return;
    var zoom = map.getZoom();
    var pixels = f.points.map(function (p) { var q = map.project(p, zoom); return [q.x, q.y]; });
    arrowMarks(pixels, ARROW_SPACING).forEach(function (m) {
      var el = document.createElement('div');
      el.className = 'ppm-sym ppm-arrow';
      el.style.cssText = 'width:12px;height:12px;left:-6px;top:-6px;color:' + (f.color || '#007aff') +
        ';transform:rotate(' + m.angle.toFixed(1) + 'deg)';
      el.innerHTML = ARROW_SVG;   // festes Zeichen
      var icon = L.divIcon({ className: 'ppm-icon', html: el, iconSize: [0, 0], iconAnchor: [0, 0] });
      item.arrows.push(L.marker(map.unproject([m.x, m.y], zoom), { icon: icon, pane: 'ppmTrack', interactive: false, keyboard: false }).addTo(map));
    });
  }
  var ARROW_SVG = '<svg viewBox="0 0 24 24" width="100%" height="100%" fill="currentColor"><path d="M12 4l8 16H4z"/></svg>';

  function placeAllArrows() {
    items.forEach(function (item) { if (item.f.kind === 'line' && item.f.arrows) placeArrows(item); });
  }

  function updatePath(item, f) {
    var old = item.f;
    if (JSON.stringify(old.points) !== JSON.stringify(f.points)) {
      if (f.kind === 'circle') item.layer.setLatLng(f.points[0]);
      else item.layer.setLatLngs(latLngs(f.points));
    }
    if (f.kind === 'circle' && old.radius !== f.radius) item.layer.setRadius(f.radius || 1);
    item.layer.setStyle(pathStyle(f));
    if ((f.z || 0) > (old.z || 0)) item.layer.bringToFront();
    else if ((f.z || 0) < (old.z || 0)) item.layer.bringToBack();
  }

  // ---- Zustand ----

  function upsert(f) {
    var item = items.get(f.id);
    if (item && item.f.kind !== f.kind) { remove(f.id); item = null; }
    if (!item) {
      item = f.kind === 'marker' ? createMarker(f) : createPath(f);
      item.f = f;
      items.set(f.id, item);
      if (f.arrows) placeArrows(item);
      return;
    }
    if (f.kind === 'marker') {
      var p = item.f.points[0];
      if (p[0] !== f.points[0][0] || p[1] !== f.points[0][1]) item.layer.setLatLng(f.points[0]);
      renderMarker(item, f);
      item.f = f;
    } else {
      updatePath(item, f);
      item.f = f;
      if (f.arrows || item.arrows) placeArrows(item);
    }
  }

  function append(a) {
    var item = items.get(a.id);
    if (!item || item.f.kind !== 'line') return;
    item.f = Object.assign({}, item.f, { points: item.f.points.concat(a.points) });
    item.layer.setLatLngs(latLngs(item.f.points));
    if (item.f.arrows) placeArrows(item);
  }

  function remove(id) {
    var item = items.get(id);
    if (!item) return;
    item.layer.remove();
    (item.arrows || []).forEach(function (m) { m.remove(); });
    items.delete(id);
  }

  // ---- Ausschnitt ----

  function fitBounds() {
    var b = L.latLngBounds([]);
    items.forEach(function (item) {
      var f = item.f;
      var fit = f.fit == null ? (f.kind !== 'line') : f.fit;
      if (!fit) return;
      if (f.kind === 'circle') b.extend(L.latLng(f.points[0]).toBounds((f.radius || 1) * 2));
      else f.points.forEach(function (p) { b.extend(p); });
    });
    return b;
  }

  function currentFitKey() {
    var keys = [];
    items.forEach(function (item, id) {
      var f = item.f;
      if (f.fit == null ? (f.kind !== 'line') : f.fit) keys.push(id);
    });
    return keys.sort().join('\n');
  }

  function fitAll(animate) {
    var b = fitBounds();
    if (!b.isValid()) { pendingFit = false; return; }
    if (!hasSize()) { pendingFit = true; return; }
    pendingFit = false;
    fitKey = currentFitKey();
    map.fitBounds(b, { padding: [36, 36], maxZoom: options.fitMaxZoom, animate: !!animate });
  }

  /** Folgt die Karte dem Inhalt: neu einpassen, wenn Ziele dazukommen/wegfallen oder herauslaufen. */
  function followContent() {
    if (!follow) return;
    var key = currentFitKey();
    if (key !== fitKey) { fitAll(fitKey !== null); return; }
    var view = map.getBounds();
    var outside = false;
    items.forEach(function (item) {
      var f = item.f;
      if (outside || f.kind !== 'marker' || f.fit === false) return;
      if (!view.contains(f.points[0])) outside = true;
    });
    if (outside) fitAll(true);
  }

  function command(c) {
    switch (c.cmd) {
      case 'follow':
        follow = true;
        fitKey = null;
        fitAll(c.animate !== false);
        break;
      case 'center':
        follow = false;
        map.setView([c.lat, c.lon], c.zoom == null ? map.getZoom() : c.zoom, { animate: c.animate !== false });
        break;
      case 'fit':
        follow = false;
        if (!hasSize()) { map.setView([(c.south + c.north) / 2, (c.west + c.east) / 2], c.maxZoom || options.fitMaxZoom); break; }
        map.fitBounds([[c.south, c.west], [c.north, c.east]], { padding: [20, 20], maxZoom: c.maxZoom || 18, animate: c.animate !== false });
        break;
    }
  }

  // ---- Beschriftungen ohne Überlappung ----

  function queueDeclutter() {
    if (declutterQueued) return;
    declutterQueued = true;
    requestAnimationFrame(function () { declutterQueued = false; declutter(); });
  }

  /** Blendet Beschriftungen aus, die eine wichtigere überdecken würden (Auswahl immer sichtbar). */
  function declutter() {
    var list = [];
    var order = 0;
    items.forEach(function (item) {
      if (item.f.kind !== 'marker' || !item.f.label) return;
      var rank = item.f.emphasis ? 1e6 : (item.f.layer === 'ground' ? 0 : 1000) + (item.f.labelPriority || 0);
      list.push({ item: item, rank: rank, order: order++ });
    });
    list.sort(function (a, b) { return b.rank - a.rank || a.order - b.order; });
    var placed = [];
    list.forEach(function (entry) {
      var label = entry.item.parts.label;
      label.style.visibility = '';
      var r = label.getBoundingClientRect();
      if (r.width === 0) return;
      var hit = !entry.item.f.emphasis && placed.some(function (p) {
        return r.left < p.right && r.right > p.left && r.top < p.bottom && r.bottom > p.top;
      });
      if (hit) label.style.visibility = 'hidden';
      else placed.push(r);
    });
  }

  function receive(text) {
    var m = JSON.parse(text);
    if (m.options) init(m.options);
    if (!map) return;
    (m.remove || []).forEach(remove);
    (m.upsert || []).forEach(upsert);
    (m.append || []).forEach(append);
    (m.commands || []).forEach(command);
    if (m.remove || m.upsert || m.append) {
      if (!(m.commands && m.commands.length)) followContent();
      queueDeclutter();
    }
    return items.size;
  }

  window.PPM = {
    receive: receive,
    // Für Tests und Sichtprüfung.
    count: function () { return items.size; },
    labelText: function (id) { var i = items.get(id); return i && i.parts ? i.parts.label.textContent : null; },
    following: function () { return follow; },
    arrowMarks: arrowMarks,
    arrowCount: function (id) { var i = items.get(id); return i && i.arrows ? i.arrows.length : 0; },
    map: function () { return map; }
  };
  post({ type: 'ready' });
})();
