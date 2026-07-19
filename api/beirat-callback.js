// Threema-Gateway-Callback fuer den BERENT-Beirat-Bot (*BERENTB, E2E).
// Threema POSTet eingehende Nachrichten (x-www-form-urlencoded) hierher. Wir:
//   1) MAC pruefen (HMAC-SHA256 mit API-Secret ueber from+to+messageId+date+nonce+box)
//   2) Absender-Public-Key ueber die Threema-Lookup-API holen
//   3) Box entschluesseln (NaCl box.open mit unserem Private Key)
//   4) Typ-Byte (0x01=Text) + Padding entfernen -> Klartext
//   5) beginnt der Text mit "/beirat": an den n8n-Beirat-Webhook weiterreichen ({from, text})
// Threema bekommt IMMER schnell 200 (sonst Retries). Fehler werden geloggt, nicht geworfen.
//
// Env (in Vercel setzen, sobald *BERENTB aktiv ist):
//   THREEMA_GATEWAY_ID_BEIRAT   = *BERENTB
//   THREEMA_SECRET_BERENTB      = API-Secret der Gateway-ID
//   THREEMA_PRIVATE_KEY_BEIRAT  = Private Key (64 hex)
//   N8N_BEIRAT_WEBHOOK          = optional; Default unten

import nacl from 'tweetnacl';
import crypto from 'node:crypto';

const GATEWAY_ID = process.env.THREEMA_GATEWAY_ID_BEIRAT || '';
const API_SECRET = process.env.THREEMA_SECRET_BERENTB || '';
const PRIVATE_KEY = process.env.THREEMA_PRIVATE_KEY_BEIRAT || '';
const N8N_WEBHOOK = process.env.N8N_BEIRAT_WEBHOOK
  || 'https://n8n.srv1098810.hstgr.cloud/webhook/berent-beirat-orchestrator-7f2e9c1a';

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

    // 4) Nur Textnachrichten (Typ 0x01); Typ-Byte + Padding entfernen.
    if (decrypted[0] !== 0x01) return res.status(200).send('ok');
    const padLen = decrypted[decrypted.length - 1];
    const text = Buffer.from(decrypted.slice(1, decrypted.length - padLen)).toString('utf8').trim();

    // 5) Nur /beirat-Kommandos weiterreichen; alles andere ignorieren.
    if (/^\/beirat\b/i.test(text)) {
      const r = await fetch(N8N_WEBHOOK, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ from, text }),
      });
      if (!r.ok) console.error('[beirat-callback] n8n-Webhook ' + r.status);
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
