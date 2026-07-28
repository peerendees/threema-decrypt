// Threema-Gateway-Callback fuer den BERENT-Beirat-Bot (*BERENTB, E2E).
// Threema POSTet eingehende Nachrichten (x-www-form-urlencoded) hierher. Wir:
//   1) MAC pruefen (HMAC-SHA256 mit API-Secret ueber from+to+messageId+date+nonce+box)
//   2) Absender-Public-Key ueber die Threema-Lookup-API holen
//   3) Box entschluesseln (NaCl box.open mit unserem Private Key)
//   4) Nachrichtentyp pruefen: Steuernachrichten (>= 0x80) still verwerfen,
//      unlesbaren Inhalt (Sprache/Bild/Datei) mit Hinweis beantworten,
//      Text entpacken (Typ-Byte + Padding weg) -> Klartext
//   5) bekanntes Kommando? -> an den passenden n8n-Webhook weiterreichen ({from, text}):
//        "beirat …" / "/beirat …"       -> Beirat-Orchestrator
//        "idee …" / "ideenparkplatz …"  -> Skill Executor (Skill donna/idee)
//      Text OHNE Kommando -> ebenfalls Skill Executor; der ordnet ueber
//      trigger_keywords zu und antwortet notfalls mit system/skill-hilfe.
// Threema bekommt IMMER schnell 200 (sonst Retries). Fehler werden geloggt, nicht geworfen.
//
// Env (in Vercel setzen, sobald *BERENTB aktiv ist):
//   THREEMA_GATEWAY_ID_BERENTB   = *BERENTB
//   THREEMA_SECRET_BERENTB      = API-Secret der Gateway-ID
//   THREEMA_PRIVATE_KEY_BERENTB  = Private Key (64 hex)
//   N8N_BEIRAT_WEBHOOK          = optional; Default unten
//   N8N_SKILL_WEBHOOK           = optional; Default unten

import nacl from 'tweetnacl';
import crypto from 'node:crypto';
import { sendeE2E } from '../lib/threema-e2e.js';

const GATEWAY_ID = process.env.THREEMA_GATEWAY_ID_BERENTB || '';
const API_SECRET = process.env.THREEMA_SECRET_BERENTB || '';
const PRIVATE_KEY = process.env.THREEMA_PRIVATE_KEY_BERENTB || '';

// Wer an *BERENTB schreiben darf. Die MAC-Pruefung belegt nur, dass die Nachricht
// wirklich von Threema kommt — nicht, WER sie geschrieben hat. Jeder mit der
// Gateway-ID koennte sonst Skills ausloesen. Default: nur Marcus.
const ERLAUBTE_ABSENDER = (process.env.BERENTB_ERLAUBTE_ABSENDER || 'BUMFMZ39')
  .split(',').map((s) => s.trim().toUpperCase()).filter(Boolean);
const N8N_WEBHOOK = process.env.N8N_BEIRAT_WEBHOOK
  || 'https://n8n.srv1098810.hstgr.cloud/webhook/berent-beirat-orchestrator-7f2e9c1a';
const N8N_SKILL_WEBHOOK = process.env.N8N_SKILL_WEBHOOK
  || 'https://n8n.srv1098810.hstgr.cloud/webhook/berent-skill-executor-4e21b7d0';

// Kommando-Router. Reihenfolge = Prioritaet; der erste Treffer gewinnt.
//
// "idee" steht bewusst OHNE Schraegstrich: unterwegs zaehlt jeder Tastendruck, und
// ein Praefix-Zeichen ist auf der Handytastatur teuer. Der Skill Executor erkennt den
// Skill ohnehin ueber seine trigger_keywords — das Kommando hier muss nur entscheiden,
// an WELCHEN Webhook der Text geht.
//
// \b nach "idee" wuerde "ideenparkplatz" NICHT treffen (n ist ein Wortzeichen),
// deshalb beide Formen ausgeschrieben. Danach ist ein Wortende noetig, damit
// "ideensammlung" o. ae. nicht versehentlich hier landet.
//
// Der fuehrende Schraegstrich ist optional: wer "/beirat" gewohnt ist, tippt leicht
// auch "/idee". Das stillschweigend zu verwerfen waere die schlechteste Antwort.
const KOMMANDOS = [
  { muster: /^\/?beirat\b/i, ziel: N8N_WEBHOOK, name: 'beirat' },
  { muster: /^\/?(?:idee|ideenparkplatz)\b/i, ziel: N8N_SKILL_WEBHOOK, name: 'idee' },
];

// Alles ohne erkanntes Kommando geht an den Skill Executor. Dort steht seit jeher ein
// Zuordner, der Skills ueber ihre trigger_keywords erkennt — auch mitten im Satz, mit
// Wortgrenzen und Umlaut-Normalisierung. Der kam bisher nur nie zum Zug, weil hier
// vorher abgewiesen wurde: "Donna, schreibe fuer morgen einen Termin ..." enthaelt das
// Wort "Termin", traf aber nie ein Kommando.
//
// Warum das gefahrlos ist: Der Zuordner wertet die Governance-Ampel aus. ROT wird gar
// nicht ausgefuehrt, GELB laeuft nur als Entwurf mit ausdruecklichem Hinweis. Und trifft
// nichts, antwortet der Skill "system/skill-hilfe" mit der Liste dessen, was es gibt —
// eine bessere Auskunft, als dieser Callback je geben koennte, weil sie aus dem echten
// Skill-Bestand kommt statt aus einer hier gepflegten Aufzaehlung.
//
// Der Beirat behaelt seinen ausdruecklichen Auslöser (Schraegstrich jetzt optional). Er
// startet ein ganzes Gremium, laeuft lange und rechnet ueber einen EIGENEN Anthropic-
// Schluessel ab, der genau zur Kostentrennung getrennt gefuehrt wird. Was so teuer ist,
// soll man absichtlich starten und nicht durch ein Schluesselwort hineinstolpern.
const STANDARD_ZIEL = { ziel: N8N_SKILL_WEBHOOK, name: 'standard' };

export default async function handler(req, res) {
  if (req.method !== 'POST') return res.status(405).send('Method not allowed');

  // Threema sendet x-www-form-urlencoded. Vercel parst das i. d. R. nach req.body (Objekt).
  // Fallback: String selbst parsen.
  let b = req.body;
  if (typeof b === 'string') {
    b = Object.fromEntries(new URLSearchParams(b));
  }
  b = b || {};
  const { from, to, messageId, date, nonce, box, mac } = b;

  // Nicht wohlgeformt -> stillschweigend ack (kein Retry ausloesen).
  if (!from || !to || !messageId || !date || !nonce || !box || !mac) {
    return res.status(200).send('ok');
  }
  if (!API_SECRET || !PRIVATE_KEY) {
    console.error('[beirat-callback] Env fehlt (SECRET/PRIVATE_KEY) — Nachricht ignoriert.');
    return res.status(200).send('ok');
  }

  // 1) MAC pruefen (Authentizitaet der Threema-Zustellung).
  const expected = crypto
    .createHmac('sha256', API_SECRET)
    .update(String(from) + String(to) + String(messageId) + String(date) + String(nonce) + String(box))
    .digest('hex');
  const macOk =
    expected.length === String(mac).length &&
    crypto.timingSafeEqual(Buffer.from(expected), Buffer.from(String(mac)));
  if (!macOk) {
    console.error('[beirat-callback] MAC ungueltig — verworfen.');
    return res.status(200).send('ok');
  }

  // Absender pruefen. Die MAC sagt nur "kommt echt von Threema" — nicht von WEM.
  // Ohne diese Schranke koennte jeder, der die Gateway-ID kennt, Skills ausloesen.
  if (!ERLAUBTE_ABSENDER.includes(String(from).toUpperCase())) {
    console.error('[beirat-callback] Absender nicht zugelassen: ' + from);
    return res.status(200).send('ok');      // 200, damit Threema nicht wiederholt
  }

  // Ab hier verifiziert. Best-effort verarbeiten, Threema immer 200 geben.
  try {
    // 2) Absender-Public-Key holen.
    const pkRes = await fetch(
      `https://msgapi.threema.ch/pubkeys/${encodeURIComponent(from)}?from=${encodeURIComponent(GATEWAY_ID)}&secret=${encodeURIComponent(API_SECRET)}`,
    );
    if (!pkRes.ok) throw new Error('pubkey-Lookup ' + pkRes.status);
    const senderPub = (await pkRes.text()).trim();

    // 3) Entschluesseln.
    const decrypted = nacl.box.open(
      hexToBytes(box),
      hexToBytes(nonce),
      hexToBytes(senderPub),
      hexToBytes(PRIVATE_KEY),
    );
    if (!decrypted) throw new Error('Entschluesselung fehlgeschlagen');

    // 4) Nachrichtentyp auswerten.
    //
    //    NOTBREMSE 27.07.2026: Hier stand kurzzeitig eine Hinweis-Antwort fuer
    //    JEDEN Nicht-Text. Das erzeugte eine Endlosschleife — die Threema-App
    //    quittiert JEDE zugestellte Nachricht mit einer Empfangsbestaetigung
    //    (Typ 0x80), die hier wieder als "Nicht-Text" ankam: Hinweis -> Quittung
    //    -> Hinweis -> ... 1773 Aufrufe in zwei Stunden.
    //
    //    Die Notbremse nannte zwei Bedingungen fuer eine Wiederaufnahme: sauber
    //    nach Nachrichtentyp filtern UND eine Wiederholsperre. Beide sind jetzt
    //    erfuellt — die Sperre steckt seit lib/sende-sperre.js in sendeE2E.
    const typ = decrypted[0];

    //    Steuernachrichten NIE beantworten. Threema legt sie ins obere Band:
    //    0x80 Empfangsbestaetigung, 0x90 Tipp-Anzeige. Die Grenze bei 0x80 statt
    //    zwei Einzelwerten ist Absicht — sie schliesst auch kuenftige
    //    Steuertypen ein, und ein neuer Steuertyp waere genau der Weg zurueck in
    //    die Schleife. Nutzinhalte liegen saemtlich unterhalb.
    if (typ >= 0x80) return res.status(200).send('ok');

    //    Nutzinhalt, den wir nicht lesen koennen — Sprachnachricht, Bild, Datei.
    //    Der bisherige stille Wurf hiess: Marcus diktiert unterwegs eine Idee und
    //    erfaehrt nie, dass sie nirgends ankam.
    if (typ !== 0x01) {
      const hinweis = await sendeE2E(from,
        'Das kann ich noch nicht lesen — bitte als Text schicken. Das Diktat auf der Tastatur reicht.',
        'hinweis-nicht-text');
      if (!hinweis.ok && !hinweis.gesperrt) {
        console.error('[beirat-callback] Hinweis Nicht-Text: ' + hinweis.fehler);
      }
      return res.status(200).send('ok');
    }

    // Typ-Byte vorne, PKCS#7-artiges Padding hinten — beides weg, dann Klartext.
    // Diese zwei Zeilen fielen der Notbremse vom 27.07. versehentlich mit zum Opfer
    // (bf67218 entfernte den Block darueber und nahm sie mit). Folge: `text` war ab
    // da nicht definiert, jede *BERENTB-Nachricht starb in Zeile 5) mit
    // "text is not defined" — quittiert mit 200, also ohne Wiederholung und ohne Spur
    // ausser einer Zeile im Vercel-Protokoll. Wer hier wieder aufraeumt: das Entpacken
    // gehoert zur Zustellung, nicht zur Antwortlogik, und darf mit ihr nicht mitgehen.
    const padLen = decrypted[decrypted.length - 1];
    const text = Buffer.from(decrypted.slice(1, decrypted.length - padLen)).toString('utf8').trim();

    // 5) Weiterreichen. Kommando entscheidet nur noch, an WELCHEN Webhook — ohne
    //    Treffer geht es an den Skill Executor, der selbst zuordnet (siehe oben).
    const kommando = KOMMANDOS.find((k) => k.muster.test(text)) || STANDARD_ZIEL;
    const r = await fetch(kommando.ziel, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      // kanal sagt dem Executor, WOHIN die Antwort gehoert — ohne ihn landet sie
      // im *BERENT1-Chat, also woanders als die Frage. messageId dient spaeter
      // (P6) der Idempotenz, wenn Threema eine Zustellung wiederholt.
      body: JSON.stringify({ from, text, kanal: 'berentb', messageId }),
    });
    if (!r.ok) {
      console.error(`[beirat-callback] n8n-Webhook (${kommando.name}) ` + r.status);
      // Nicht schweigen. Vorher fiel ein Webhook-Fehler nur ins Vercel-Protokoll,
      // und Marcus wartete auf eine Antwort, die nie kam — dasselbe Muster, das den
      // Kanal am 27./28.07. zwei Tage lang unbemerkt tot liegen liess.
      const hinweis = await sendeE2E(from,
        'Ich konnte das gerade nicht weitergeben (' + r.status + '). Versuch es bitte gleich noch einmal.',
        'hinweis-webhook-fehler');
      if (!hinweis.ok && !hinweis.gesperrt) {
        console.error('[beirat-callback] Hinweis Webhook-Fehler: ' + hinweis.fehler);
      }
    }
  } catch (e) {
    console.error('[beirat-callback] Verarbeitung:', e.message);
  }

  return res.status(200).send('ok');
}

function hexToBytes(hex) {
  const bytes = new Uint8Array(hex.length / 2);
  for (let i = 0; i < hex.length; i += 2) bytes[i / 2] = parseInt(hex.substr(i, 2), 16);
  return bytes;
}
