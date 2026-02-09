import nacl from 'tweetnacl';

export default async function handler(req, res) {
  // CORS headers
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

  if (req.method === 'OPTIONS') {
    return res.status(200).end();
  }

  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Method not allowed' });
  }

  const { box, nonce, from, gatewayPrivateKey, senderPublicKey } = req.body;

  if (!box || !nonce || !gatewayPrivateKey || !senderPublicKey) {
    return res.status(400).json({ error: 'Missing parameters' });
  }

  try {
    const boxBytes = hexToBytes(box);
    const nonceBytes = hexToBytes(nonce);
    const privateKeyBytes = hexToBytes(gatewayPrivateKey);
    const publicKeyBytes = hexToBytes(senderPublicKey);

    const decrypted = nacl.box.open(
      boxBytes,
      nonceBytes,
      publicKeyBytes,
      privateKeyBytes
    );

    if (!decrypted) {
      return res.status(400).json({ error: 'Decryption failed' });
    }

    // Bytes zu String
    const text = String.fromCharCode.apply(null, decrypted);

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

function hexToBytes(hex) {
  const bytes = new Uint8Array(hex.length / 2);
  for (let i = 0; i < hex.length; i += 2) {
    bytes[i / 2] = parseInt(hex.substr(i, 2), 16);
  }
  return bytes;
}
