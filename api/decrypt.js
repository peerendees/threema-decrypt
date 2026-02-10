import nacl from 'tweetnacl';

export default async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

  if (req.method === 'OPTIONS') return res.status(200).end();
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });

  const { action } = req.body;

  if (action === 'decrypt') {
    return handleDecrypt(req, res);
  } else if (action === 'send') {
    return handleSend(req, res);
  } else {
    return res.status(400).json({ error: 'Missing action (decrypt or send)' });
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

    const text = String.fromCharCode.apply(null, decrypted);
    return res.status(200).json({ text, from, success: true });

  } catch (error) {
    return res.status(500).json({ error: 'Decryption error', message: error.message });
  }
}

// SENDEN
async function handleSend(req, res) {
  const { to, text, gatewayId, gatewaySecret, gatewayPrivateKey, recipientPublicKey } = req.body;

  if (!to || !text || !gatewayId || !gatewaySecret || !gatewayPrivateKey || !recipientPublicKey) {
    return res.status(400).json({ error: 'Missing parameters' });
  }

  try {
    // Nachricht verschlüsseln
    const nonce = nacl.randomBytes(24);
    const messageBytes = new TextEncoder().encode('\x01' + text);

    const encrypted = nacl.box(
      messageBytes,
      nonce,
      hexToBytes(recipientPublicKey),
      hexToBytes(gatewayPrivateKey)
    );

    // An Threema API senden
    const params = new URLSearchParams({
      from: gatewayId,
      to: to,
      secret: gatewaySecret,
      nonce: bytesToHex(nonce),
      box: bytesToHex(encrypted)
    });

    const response = await fetch('https://msgapi.threema.ch/send_e2e', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: params.toString()
    });

    const responseText = await response.text();

    if (!response.ok) {
      return res.status(response.status).json({ 
        error: 'Threema API error', 
        status: response.status,
        response: responseText
      });
    }

    return res.status(200).json({ 
      success: true, 
      messageId: responseText.trim()
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
  return Array.from(bytes).map(b => b.toString(16).padStart(2, '0')).join('');
}
