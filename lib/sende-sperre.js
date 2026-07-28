// Notbremse gegen Sende-Schleifen.
//
// Anlass (27.07.2026): Eine Hinweis-Antwort auf Nicht-Text-Nachrichten triggerte sich
// selbst — die Threema-App quittiert jede Zustellung mit einer Empfangsbestaetigung
// (Typ 0x80), die am Callback wieder als "Nicht-Text" ankam. 1773 Aufrufe, rund 900
// Sendungen in zwei Stunden, bis es jemandem auffiel.
//
// Diese Sperre macht aus einem solchen Denkfehler ein Aergernis statt eines Schadens:
// nach GRENZE Sendungen an denselben Empfaenger binnen FENSTER wird nur noch protokolliert.
//
// WAS SIE NICHT IST: eine Garantie. Der Zaehler lebt im Arbeitsspeicher der jeweiligen
// Vercel-Instanz und faengt bei einem Kaltstart neu an; bei paralleler Ausfuehrung zaehlt
// jede Instanz fuer sich. Gegen eine schnelle Schleife hilft das trotzdem, weil die
// wiederholten Aufrufe auf derselben warmen Instanz landen. Die eigentliche Absicherung
// bleibt die Regel: NIE ungefragt auf etwas antworten, das selbst eine Antwort ausloesen
// kann. Wer das doch tut, filtert vorher nach Nachrichtentyp.

const FENSTER_MS = 5 * 60 * 1000;   // Beobachtungszeitraum
const GRENZE = 8;                    // Sendungen je Empfaenger in diesem Zeitraum
const verlauf = new Map();           // empfaenger -> Zeitstempel[]
const letzteMeldung = new Map();     // empfaenger -> Zeitstempel der letzten Log-Zeile
const MELDE_ABSTAND_MS = 60 * 1000;  // hoechstens eine Meldung je Minute und Empfaenger

// Eine blockierte Schleife erzeugt sonst genauso viele Log-Zeilen wie zuvor Nachrichten —
// die Sperre wuerde das Problem nur vom Threema-Konto in die Vercel-Logs verschieben.
function meldeGedrosselt(schluessel, text) {
  const jetzt = Date.now();
  if (jetzt - (letzteMeldung.get(schluessel) || 0) < MELDE_ABSTAND_MS) return;
  letzteMeldung.set(schluessel, jetzt);
  console.error(text);
}

// Fragt UND zaehlt. Liefert { erlaubt, anzahl } — bei erlaubt=false nicht senden.
export function darfSenden(empfaenger, anlass = 'unbekannt') {
  const jetzt = Date.now();
  const schluessel = String(empfaenger || '?');
  const bisher = (verlauf.get(schluessel) || []).filter((t) => jetzt - t < FENSTER_MS);

  if (bisher.length >= GRENZE) {
    verlauf.set(schluessel, bisher);   // nicht weiterzaehlen, sonst laeuft die Sperre nie ab
    meldeGedrosselt(schluessel,
      `[sende-sperre] BLOCKIERT: ${bisher.length} Sendungen an ${schluessel} in `
      + `${FENSTER_MS / 60000} Min (Anlass: ${anlass}). Verdacht auf Schleife. `
      + 'Weitere Meldungen fuer diesen Empfaenger fruehestens in 1 Min.');
    return { erlaubt: false, anzahl: bisher.length };
  }

  bisher.push(jetzt);
  verlauf.set(schluessel, bisher);
  // Frueh warnen, solange es noch harmlos ist.
  if (bisher.length === Math.ceil(GRENZE / 2)) {
    console.error(`[sende-sperre] Warnung: ${bisher.length}/${GRENZE} an ${schluessel} (${anlass}).`);
  }
  return { erlaubt: true, anzahl: bisher.length };
}

// Nur fuer Tests: Zaehler zuruecksetzen.
export function _zuruecksetzen() { verlauf.clear(); letzteMeldung.clear(); }
