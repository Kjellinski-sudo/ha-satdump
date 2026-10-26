// Zusatz für den Datei-Manager: Menüpunkt „Wiederherstellen“ im Ordner „Papierkorb“.
// Wird von nginx in jede Seite eingebunden; spricht nur mit /dateien-api/ (gleiche Adresse, eigene Anmeldung).
(function () {
  "use strict";
  var KORB = "/files/Stick/Papierkorb";

  function imKorb() {
    var p = decodeURIComponent(location.pathname).replace(/\/+$/, "");
    return p === KORB;
  }

  function ausgewaehlt() {
    return Array.prototype.slice.call(document.querySelectorAll('.listing-item[aria-selected="true"]'))
      .map(function (e) { return e.dataset.name; })
      .filter(Boolean);
  }

  function meldung(text, fehler) {
    var d = document.createElement("div");
    d.textContent = text;
    d.style.cssText = "position:fixed;left:50%;bottom:24px;transform:translateX(-50%);z-index:99999;" +
      "padding:12px 18px;border-radius:14px;font:500 14px system-ui,sans-serif;color:#fff;max-width:90vw;" +
      "box-shadow:0 10px 30px rgba(0,0,0,.5);background:" +
      (fehler ? "#b91c1c" : "linear-gradient(90deg,#06b6d4,#8b5cf6)");
    document.body.appendChild(d);
    setTimeout(function () { d.remove(); }, 4000);
  }

  function wiederherstellen(namen) {
    fetch("/dateien-api/wiederherstellen", {
      method: "POST",
      credentials: "same-origin",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ namen: namen })
    }).then(function (r) { return r.json().catch(function () { return {}; }); })
      .then(function (e) {
        var ok = (e.wiederhergestellt || []).length, f = (e.fehler || []).length;
        if (ok) meldung(ok === 1 ? "Wiederhergestellt nach „" + e.wiederhergestellt[0].ziel + "“" : ok + " Einträge wiederhergestellt");
        if (f) meldung(f + " Eintrag/Einträge nicht wiederhergestellt: " + e.fehler[0].grund, true);
        if (ok) setTimeout(function () { location.reload(); }, 1200);
      })
      .catch(function () { meldung("Wiederherstellen fehlgeschlagen", true); });
  }

  function ergaenzen() {
    var menu = document.getElementById("context-menu");
    if (!menu) return;
    var vorhanden = menu.querySelector(".dateien-wiederherstellen");
    if (!imKorb()) { if (vorhanden) vorhanden.remove(); return; }
    if (vorhanden) return;
    var vorlage = menu.querySelector("button.action");
    if (!vorlage) return;
    var knopf = vorlage.cloneNode(true);
    knopf.classList.add("dateien-wiederherstellen");
    knopf.setAttribute("aria-label", "Wiederherstellen");
    knopf.setAttribute("title", "An den alten Platz zurücklegen");
    var icon = knopf.querySelector("i");
    if (icon) icon.textContent = "restore_from_trash";
    var span = knopf.querySelector("span");
    if (span) span.textContent = "Wiederherstellen";
    knopf.addEventListener("click", function (ev) {
      ev.preventDefault();
      ev.stopPropagation();
      var namen = ausgewaehlt();
      if (!namen.length) { meldung("Bitte zuerst etwas im Papierkorb auswählen", true); return; }
      wiederherstellen(namen);
    }, true);
    vorlage.parentNode.insertBefore(knopf, vorlage);
  }

  new MutationObserver(ergaenzen).observe(document.documentElement, { childList: true, subtree: true });
})();
