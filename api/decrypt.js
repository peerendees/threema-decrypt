import nacl from 'tweetnacl';
import crypto from 'node:crypto';

// Erlaubte Origin für CORS. Für reine Server-zu-Server-Aufrufe (n8n) bleibt das leer,
// dann wird kein CORS-Header gesetzt. Nur setzen, wenn ein Browser-Client nötig ist.
const ALLOWED_ORIGIN = process.env.ALLOWED_ORIGIN || '';

// Gemeinsames Geheimnis zwischen Aufrufer (n8n) und dieser Funktion.
const API_TOKEN = process.env.DECRYPT_API_TOKEN || '';

function applyCors(res) {
  if (ALLOWED_ORIGIN) {
    res.setHeader('Access-Control-Allow-Origin', ALLOWED_ORIGIN);
    res.setHeader('Vary', 'Origin');
    res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');
  }
}

// Konstantzeit-Vergleich des Bearer-Tokens.
function isAuthorized(req) {
  if (!API_TOKEN) return false; // Ohne konfiguriertes Token bleibt der Endpunkt geschlossen.
  const header = req.headers['authorization'] || '';
  const prefix = 'Bearer ';
  if (!header.startsWith(prefix)) return false;
  const provided = Buffer.from(header.slice(prefix.length));
  const expected = Buffer.from(API_TOKEN);
  return provided.length === expected.length && crypto.timingSafeEqual(provided, expected);
}

export default async function handler(req, res) {
  applyCors(res);

  if (req.method === 'OPTIONS') return res.status(200).end();
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });

  if (!isAuthorized(req)) {
    return res.status(401).json({ error: 'Unauthorized' });
  }

  const { action } = req.body || {};

  if (action === 'decrypt') {
    return handleDecrypt(req, res);
  } else if (action === 'send') {
    return handleSend(req, res);
  } else if (action === 'decrypt-blob') {
    return handleDecryptBlob(req, res);
  } else if (action === 'vision-ocr') {
    return handleVisionOcr(req, res);
  } else if (action === 'mistral-chat') {
    return handleMistralChat(req, res);
  } else {
    return res.status(400).json({ error: 'Unknown action' });
  }
}

// ENTSCHLÜSSELN
async function handleDecrypt(req, res) {
  const { box, nonce, from, gatewayPrivateKey, senderPublicKey } = req.body;

  if (!box || !nonce || !gatewayPrivateKey || !senderPublicKey) {
    return res.status(400).json({ error: 'Missing parameters' });
  }

  try {
    const decrypted = nacl.box.open(
      hexToBytes(box),
      hexToBytes(nonce),
      hexToBytes(senderPublicKey),
      hexToBytes(gatewayPrivateKey)
    );

    if (!decrypted) return res.status(400).json({ error: 'Decryption failed' });

    // Buffer statt String.fromCharCode.apply: verhindert RangeError bei großen Belegen.
    const text = Buffer.from(decrypted).toString('latin1');
    return res.status(200).json({ text, from, success: true });
  } catch (error) {
    return res.status(500).json({ error: 'Decryption error', message: error.message });
  }
}

// THREEMA-BLOB ENTSCHLÜSSELN (Datei aus Gateway-Blob)
async function handleDecryptBlob(req, res) {
  const { blobBase64, blobKey } = req.body;

  if (!blobBase64 || !blobKey) {
    return res.status(400).json({ error: 'Missing blobBase64 or blobKey' });
  }

  try {
    const encrypted = new Uint8Array(Buffer.from(blobBase64, 'base64'));
    const key = hexToBytes(blobKey);
    const nonce = new Uint8Array(24);
    nonce[23] = 0x01;

    const decrypted = nacl.secretbox.open(encrypted, nonce, key);
    if (!decrypted) {
      return res.status(400).json({ error: 'Blob decryption failed' });
    }

    const imageBase64 = Buffer.from(decrypted).toString('base64');
    return res.status(200).json({
      success: true,
      imageBase64,
      size: decrypted.length,
    });
  } catch (error) {
    return res.status(500).json({ error: 'Blob decryption error', message: error.message });
  }
}

// OCR VIA MISTRAL VISION – läuft über Supabase, nicht über n8n/Hostinger
async function handleVisionOcr(req, res) {
  const { imageBase64, mimeType = 'image/jpeg' } = req.body;
  const apiKey = process.env.MISTRAL_API_KEY || '';

  if (!apiKey) {
    return res.status(500).json({ error: 'MISTRAL_API_KEY not configured' });
  }
  if (!imageBase64) {
    return res.status(400).json({ error: 'Missing imageBase64' });
  }

  try {
    const response = await fetch('https://api.mistral.ai/v1/chat/completions', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${apiKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        model: process.env.MISTRAL_VISION_MODEL || 'pixtral-12b-2409',
        messages: [
          {
            role: 'user',
            content: [
              {
                type: 'text',
                text: 'Extrahiere den vollständigen Text dieses Belegfotos als Markdown. Gib nur den erkannten Text zurück, ohne Kommentare oder Erklärungen.',
              },
              {
                type: 'image_url',
                image_url: `data:${mimeType};base64,${imageBase64}`,
              },
            ],
          },
        ],
      }),
    });

    const responseText = await response.text();
    if (!response.ok) {
      return res.status(response.status).json({
        error: 'Mistral vision OCR failed',
        status: response.status,
        response: responseText.slice(0, 1000),
      });
    }

    const data = JSON.parse(responseText);
    const text = data.choices?.[0]?.message?.content || '';
    return res.status(200).json({ success: true, text, model: data.model });
  } catch (error) {
    return res.status(500).json({ error: 'Vision OCR error', message: error.message });
  }
}

// MISTRAL CHAT PROXY – für KI-Kontierung
async function handleMistralChat(req, res) {
  const { body } = req.body;
  const apiKey = process.env.MISTRAL_API_KEY || '';

  if (!apiKey) {
    return res.status(500).json({ error: 'MISTRAL_API_KEY not configured' });
  }
  if (!body) {
    return res.status(400).json({ error: 'Missing body' });
  }

  try {
    const response = await fetch('https://api.mistral.ai/v1/chat/completions', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${apiKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(body),
    });

    const responseText = await response.text();
    if (!response.ok) {
      return res.status(response.status).json({
        error: 'Mistral chat failed',
        status: response.status,
        response: responseText.slice(0, 1000),
      });
    }

    return res.status(200).json(JSON.parse(responseText));
  } catch (error) {
    return res.status(500).json({ error: 'Mistral chat error', message: error.message });
  }
}

function padThreemaInnerMessage(payload) {
  let padLen = 1 + (nacl.randomBytes(1)[0] % 255);
  while (payload.length + padLen < 32) {
    padLen++;
  }
  const padded = new Uint8Array(payload.length + padLen);
  padded.set(payload);
  padded.fill(padLen, payload.length);
  return padded;
}

// SENDEN
async function handleSend(req, res) {
  const { to, text, gatewayId, gatewaySecret, gatewayPrivateKey, recipientPublicKey } = req.body;

  if (!to || !text || !gatewayId || !gatewaySecret || !gatewayPrivateKey || !recipientPublicKey) {
    return res.status(400).json({ error: 'Missing parameters' });
  }

  try {
    // Typ-Byte + Text (Threema-Format: erstes Byte = Message-Type, 0x01 = Text)
    const textBytes = new TextEncoder().encode(text);
    const messageData = new Uint8Array(1 + textBytes.length);
    messageData[0] = 0x01;
    messageData.set(textBytes, 1);

    // PKCS#7-Padding (Threema-Pflicht: padded_data >= 32 Bytes, 1-255 Padding-Bytes)
    let padLength = Math.floor(Math.random() * 255) + 1;
    if (messageData.length + padLength < 32) {
      padLength = 32 - messageData.length;
    }
    const paddedData = new Uint8Array(messageData.length + padLength);
    paddedData.set(messageData);
    paddedData.fill(padLength, messageData.length);

    // NaCl box verschlüsseln
    const nonce = nacl.randomBytes(24);
    const encrypted = nacl.box(
      paddedData,
      nonce,
      hexToBytes(recipientPublicKey),
      hexToBytes(gatewayPrivateKey)
    );

    const params = new URLSearchParams({
      from: gatewayId,
      to: to,
      secret: gatewaySecret,
      nonce: bytesToHex(nonce),
      box: bytesToHex(encrypted),
    });

    const response = await fetch('https://msgapi.threema.ch/send_e2e', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: params.toString(),
    });

    const responseText = await response.text();

    if (!response.ok) {
      return res.status(response.status).json({
        error: 'Threema API error',
        status: response.status,
        response: responseText,
      });
    }

    return res.status(200).json({
      success: true,
      messageId: responseText.trim(),
    });
  } catch (error) {
    return res.status(500).json({ error: 'Send error', message: error.message });
  }
}

// Hilfsfunktionen
function hexToBytes(hex) {
  const bytes = new Uint8Array(hex.length / 2);
  for (let i = 0; i < hex.length; i += 2) {
    bytes[i / 2] = parseInt(hex.substr(i, 2), 16);
  }
  return bytes;
}

function bytesToHex(bytes) {
  return Array.from(bytes)
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
}
