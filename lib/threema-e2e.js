// E2E-Versand ueber die Threema-Gateway-ID *BERENTB.
//
// Liegt bewusst ausserhalb von api/ — dort wird jede Datei zu einem HTTP-Endpunkt.
// Genutzt von api/decrypt.js (action send_beirat) und api/beirat-callback.js
// (Hinweis-Antworten). Eine Implementierung, nicht zwei: der Krypto-Teil darf nicht
// an zwei Stellen gepflegt werden muessen.

import nacl from 'tweetnacl';
import { darfSenden } from './sende-sperre.js';

function hexToBytes(hex) {
  const bytes = new Uint8Array(hex.length / 2);
  for (let i = 0; i < hex.length; i += 2) bytes[i / 2] = parseInt(hex.substr(i, 2), 16);
  return bytes;
}

function bytesToHex(bytes) {
  return Array.from(bytes).map((b) => b.toString(16).padStart(2, '0')).join('');
}

// Sendet `text` E2E-verschluesselt an die Threema-ID `to`.
// Wirft nie — liefert immer { ok, status, messageId?, fehler? }, damit der Aufrufer
// entscheiden kann, ob ein Fehlschlag ihn interessiert.
export async function sendeE2E(to, text, anlass = 'send_beirat') {
  // Schleifen-Notbremse VOR allem anderen — auch vor dem pubkey-Lookup, damit eine
  // Schleife nicht wenigstens noch Threema-Anfragen erzeugt.
  const sperre = darfSenden(to, anlass);
  if (!sperre.erlaubt) {
    return { ok: false, status: 429, gesperrt: true,
             fehler: 'Sendesperre: zu viele Nachrichten an ' + to + ' in kurzer Zeit' };
  }

  const gatewayId = process.env.THREEMA_GATEWAY_ID_BERENTB;
  const gatewaySecret = process.env.THREEMA_SECRET_BERENTB;
  const gatewayPrivateKey = process.env.THREEMA_PRIVATE_KEY_BERENTB;

  if (!to || !text) return { ok: false, status: 400, fehler: 'Missing parameters' };
  if (!gatewayId || !gatewaySecret || !gatewayPrivateKey) {
    return { ok: false, status: 500, fehler: 'Beirat gateway env not configured' };
  }

  try {
    const pkRes = await fetch(
      `https://msgapi.threema.ch/pubkeys/${encodeURIComponent(to)}?from=${encodeURIComponent(gatewayId)}&secret=${encodeURIComponent(gatewaySecret)}`,
    );
    if (!pkRes.ok) return { ok: false, status: 502, fehler: 'pubkey lookup failed (' + pkRes.status + ')' };
    const recipientPublicKey = (await pkRes.text()).trim();

    // Typ-Byte 0x01 (Text) + PKCS#7-artiges Padding auf mind. 32 Byte.
    const textBytes = new TextEncoder().encode(text);
    const messageData = new Uint8Array(1 + textBytes.length);
    messageData[0] = 0x01;
    messageData.set(textBytes, 1);

    let padLength = Math.floor(Math.random() * 255) + 1;
    if (messageData.length + padLength < 32) padLength = 32 - messageData.length;
    const paddedData = new Uint8Array(messageData.length + padLength);
    paddedData.set(messageData);
    paddedData.fill(padLength, messageData.length);

    const nonce = nacl.randomBytes(24);
    const encrypted = nacl.box(paddedData, nonce, hexToBytes(recipientPublicKey), hexToBytes(gatewayPrivateKey));

    const response = await fetch('https://msgapi.threema.ch/send_e2e', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        from: gatewayId, to, secret: gatewaySecret,
        nonce: bytesToHex(nonce), box: bytesToHex(encrypted),
      }).toString(),
    });

    const responseText = await response.text();
    if (!response.ok) {
      return { ok: false, status: response.status, fehler: 'Threema API: ' + responseText.slice(0, 120) };
    }
    return { ok: true, status: 200, messageId: responseText.trim() };
  } catch (error) {
    return { ok: false, status: 500, fehler: 'Send error: ' + error.message };
  }
}
