import nacl from 'tweetnacl';
import { decodeBase64, encodeUTF8 } from 'tweetnacl-util';

export default async function handler(req, res) {
  // Nur POST erlauben
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Method not allowed' });
  }

  const { box, nonce, from, gatewayPrivateKey, senderPublicKey } = req.body;

  // Validierung
  if (!box || !nonce || !gatewayPrivateKey || !senderPublicKey) {
    return res.status(400).json({ error: 'Missing parameters' });
  }

  try {
    // Hex zu Bytes konvertieren
    const boxBytes = hexToBytes(box);
    const nonceBytes = hexToBytes(nonce);
    const privateKeyBytes = hexToBytes(gatewayPrivateKey);
    const publicKeyBytes = hexToBytes(senderPublicKey);

    // Entschlüsseln
    const decrypted = nacl.box.open(
      boxBytes,
      nonceBytes,
      publicKeyBytes,
      privateKeyBytes
    );

    if (!decrypted) {
      return res.status(400).json({ error: 'Decryption failed' });
    }

    // Bytes zu Text
    const text = encodeUTF8(decrypted);

    return res.status(200).json({ 
      text,
      from,
      success: true
    });

  } catch (error) {
    return res.status(500).json({ 
      error: 'Decryption error',
      message: error.message 
    });
  }
}

// Hilfsfunktion: Hex zu Bytes
function hexToBytes(hex) {
  const bytes = new Uint8Array(hex.length / 2);
  for (let i = 0; i < hex.length; i += 2) {
    bytes[i / 2] = parseInt(hex.substr(i, 2), 16);
  }
  return bytes;
}
