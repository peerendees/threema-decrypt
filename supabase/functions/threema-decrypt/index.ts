import nacl from "npm:tweetnacl@1.0.3";

const ALLOWED_ORIGIN = Deno.env.get("ALLOWED_ORIGIN") || "";
const API_TOKEN = Deno.env.get("DECRYPT_API_TOKEN") || "";
const MISTRAL_API_KEY = Deno.env.get("MISTRAL_API_KEY") || "";
const MISTRAL_VISION_MODEL =
  Deno.env.get("MISTRAL_VISION_MODEL") || "pixtral-12b-2409";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") || "";
const SUPABASE_SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
// Eng begrenztes Token nur für die Deckblatt-Aktion (Dashboard-Server).
const DECKBLATT_TOKEN = Deno.env.get("DECKBLATT_TOKEN") || "";
const BELEGE_BUCKET = "belege-archiv";

function corsHeaders(): HeadersInit {
  if (!ALLOWED_ORIGIN) return {};
  return {
    "Access-Control-Allow-Origin": ALLOWED_ORIGIN,
    Vary: "Origin",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type, Authorization",
  };
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json",
      ...corsHeaders(),
    },
  });
}

function isAuthorized(req: Request, expectedToken: string = API_TOKEN): boolean {
  if (!expectedToken) return false;
  const header = req.headers.get("authorization") || "";
  const prefix = "Bearer ";
  if (!header.startsWith(prefix)) return false;
  const provided = new TextEncoder().encode(header.slice(prefix.length));
  const expected = new TextEncoder().encode(expectedToken);
  if (provided.length !== expected.length) return false;
  let ok = 0;
  for (let i = 0; i < provided.length; i++) {
    ok |= provided[i] ^ expected[i];
  }
  return ok === 0;
}

function hexToBytes(hex: string): Uint8Array {
  const bytes = new Uint8Array(hex.length / 2);
  for (let i = 0; i < hex.length; i += 2) {
    bytes[i / 2] = parseInt(hex.substring(i, i + 2), 16);
  }
  return bytes;
}

function bytesToHex(bytes: Uint8Array): string {
  return Array.from(bytes)
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

/** Threema E2E: PKCS#7-Padding (mind. 32 Bytes), sonst wird das letzte Textbyte als Pad-Länge gelesen. */
function padThreemaInnerMessage(payload: Uint8Array): Uint8Array {
  let padLen = 1 + (nacl.randomBytes(1)[0] % 255);
  while (payload.length + padLen < 32) {
    padLen++;
  }
  const padded = new Uint8Array(payload.length + padLen);
  padded.set(payload);
  padded.fill(padLen, payload.length);
  return padded;
}

async function handleDecrypt(body: Record<string, string>) {
  const { box, nonce, from, gatewayPrivateKey, senderPublicKey } = body;
  if (!box || !nonce || !gatewayPrivateKey || !senderPublicKey) {
    return jsonResponse({ error: "Missing parameters" }, 400);
  }

  const decrypted = nacl.box.open(
    hexToBytes(box),
    hexToBytes(nonce),
    hexToBytes(senderPublicKey),
    hexToBytes(gatewayPrivateKey),
  );

  if (!decrypted) {
    return jsonResponse({ error: "Decryption failed" }, 400);
  }

  const text = new TextDecoder("latin1").decode(decrypted);
  return jsonResponse({ text, from, success: true });
}

async function handleSend(body: Record<string, string>) {
  const { to, text, gatewayId, gatewaySecret, gatewayPrivateKey, recipientPublicKey } =
    body;

  if (!to || !text || !gatewayId || !gatewaySecret || !gatewayPrivateKey ||
    !recipientPublicKey) {
    return jsonResponse({ error: "Missing parameters" }, 400);
  }

  const nonce = nacl.randomBytes(24);
  const inner = padThreemaInnerMessage(new TextEncoder().encode("\x01" + text));
  const encrypted = nacl.box(
    inner,
    nonce,
    hexToBytes(recipientPublicKey),
    hexToBytes(gatewayPrivateKey),
  );

  const params = new URLSearchParams({
    from: gatewayId,
    to,
    secret: gatewaySecret,
    nonce: bytesToHex(nonce),
    box: bytesToHex(encrypted),
  });

  const response = await fetch("https://msgapi.threema.ch/send_e2e", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: params.toString(),
  });

  const responseText = await response.text();
  if (!response.ok) {
    return jsonResponse({
      error: "Threema API error",
      status: response.status,
      response: responseText,
    }, response.status);
  }

  return jsonResponse({ success: true, messageId: responseText.trim() });
}

function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  const chunkSize = 0x8000;
  for (let i = 0; i < bytes.length; i += chunkSize) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunkSize));
  }
  return btoa(binary);
}

/** Direkt nach dem Upload liefert Mistral sporadisch 404 auf /files/{id}/url — mit Backoff neu versuchen. */
async function mistralSignedUrlWithRetry(
  fileId: string,
): Promise<{ ok: boolean; status: number; text: string }> {
  let status = 0;
  let text = "";
  for (let attempt = 1; attempt <= 4; attempt++) {
    const res = await fetch(`https://api.mistral.ai/v1/files/${fileId}/url`, {
      headers: { Authorization: `Bearer ${MISTRAL_API_KEY}` },
    });
    status = res.status;
    text = await res.text();
    if (res.ok) return { ok: true, status, text };
    if (res.status !== 404) break;
    await new Promise((r) => setTimeout(r, attempt * 1000));
  }
  return { ok: false, status, text };
}

async function mistralOcrFromImageBytes(
  imageBytes: Uint8Array,
  fileName = "beleg.jpg",
) {
  if (!MISTRAL_API_KEY) {
    return jsonResponse({ error: "MISTRAL_API_KEY not configured" }, 500);
  }

  const form = new FormData();
  form.append("purpose", "ocr");
  form.append("file", new Blob([imageBytes], { type: "image/jpeg" }), fileName);

  const uploadRes = await fetch("https://api.mistral.ai/v1/files", {
    method: "POST",
    headers: { Authorization: `Bearer ${MISTRAL_API_KEY}` },
    body: form,
  });
  const uploadText = await uploadRes.text();
  if (!uploadRes.ok) {
    return jsonResponse({
      error: "Mistral file upload failed",
      status: uploadRes.status,
      response: uploadText.slice(0, 1000),
    }, uploadRes.status);
  }

  const uploaded = JSON.parse(uploadText);
  const fileId = uploaded.id as string;

  const urlAttempt = await mistralSignedUrlWithRetry(fileId);
  if (!urlAttempt.ok) {
    return jsonResponse({
      error: "Mistral signed URL failed",
      status: urlAttempt.status,
      response: urlAttempt.text.slice(0, 1000),
    }, urlAttempt.status);
  }

  const { url: signedUrl } = JSON.parse(urlAttempt.text);

  const chatRes = await fetch("https://api.mistral.ai/v1/chat/completions", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${MISTRAL_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: MISTRAL_VISION_MODEL,
      messages: [{
        role: "user",
        content: [
          {
            type: "text",
            text:
              "Extrahiere den vollständigen Text dieses Belegfotos als Markdown. Gib nur den erkannten Text zurück, ohne Kommentare oder Erklärungen.",
          },
          { type: "image_url", image_url: signedUrl },
        ],
      }],
    }),
  });
  const chatText = await chatRes.text();

  fetch(`https://api.mistral.ai/v1/files/${fileId}`, {
    method: "DELETE",
    headers: { Authorization: `Bearer ${MISTRAL_API_KEY}` },
  }).catch(() => {});

  if (!chatRes.ok) {
    return jsonResponse({
      error: "Mistral vision OCR failed",
      status: chatRes.status,
      response: chatText.slice(0, 1000),
    }, chatRes.status);
  }

  const data = JSON.parse(chatText);
  return jsonResponse({
    success: true,
    text: data.choices?.[0]?.message?.content || "",
    model: data.model,
    size: imageBytes.length,
  });
}

/** BER-95: Magic-Byte-Check — nur nachweislich intakte JPEG/PNG gelten als verarbeitbar. */
function detectImageMime(bytes: Uint8Array): string | null {
  if (bytes.length > 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) {
    return "image/jpeg";
  }
  if (
    bytes.length > 7 && bytes[0] === 0x89 && bytes[1] === 0x50 &&
    bytes[2] === 0x4e && bytes[3] === 0x47
  ) {
    return "image/png";
  }
  return null;
}

async function handleDecryptBlob(body: Record<string, string>) {
  const { blobBase64, blobKey } = body;
  if (!blobBase64 || !blobKey) {
    return jsonResponse({ error: "Missing blobBase64 or blobKey" }, 400);
  }

  const encrypted = Uint8Array.from(atob(blobBase64), (c) => c.charCodeAt(0));
  const key = hexToBytes(blobKey);
  const nonce = new Uint8Array(24);
  nonce[23] = 0x01;

  const decrypted = nacl.secretbox.open(encrypted, nonce, key);
  if (!decrypted) {
    return jsonResponse({ error: "Blob decryption failed" }, 400);
  }

  const detectedMime = detectImageMime(decrypted);
  if (!detectedMime) {
    return jsonResponse(
      { error: "Foto ist kein gültiges JPEG/PNG (beschädigt oder nicht unterstütztes Format)" },
      422,
    );
  }

  const imageBase64 = bytesToBase64(decrypted);
  return jsonResponse({
    success: true,
    imageBase64,
    detectedMime,
    size: decrypted.length,
  });
}

async function handleDecryptBlobAndOcr(body: Record<string, string>) {
  const { blobBase64, blobKey } = body;
  if (!blobBase64 || !blobKey) {
    return jsonResponse({ error: "Missing blobBase64 or blobKey" }, 400);
  }

  const encrypted = Uint8Array.from(atob(blobBase64), (c) => c.charCodeAt(0));
  const key = hexToBytes(blobKey);
  const nonce = new Uint8Array(24);
  nonce[23] = 0x01;

  const decrypted = nacl.secretbox.open(encrypted, nonce, key);
  if (!decrypted) {
    return jsonResponse({ error: "Blob decryption failed" }, 400);
  }

  return mistralOcrFromImageBytes(decrypted);
}

async function handleVisionOcr(body: Record<string, string>) {
  if (!MISTRAL_API_KEY) {
    return jsonResponse({ error: "MISTRAL_API_KEY not configured" }, 500);
  }

  const { imageBase64 } = body;
  if (!imageBase64) {
    return jsonResponse({ error: "Missing imageBase64" }, 400);
  }

  const imageBytes = Uint8Array.from(atob(imageBase64), (c) => c.charCodeAt(0));
  return mistralOcrFromImageBytes(imageBytes);
}

async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const hash = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(hash))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

function storageAuthHeaders(contentType?: string): Record<string, string> {
  const headers: Record<string, string> = {
    apikey: SUPABASE_SERVICE_KEY,
  };
  // Legacy JWT service_role keys need Bearer; neue sb_secret_* nur apikey
  if (SUPABASE_SERVICE_KEY.startsWith("eyJ")) {
    headers.Authorization = `Bearer ${SUPABASE_SERVICE_KEY}`;
  }
  if (contentType) headers["Content-Type"] = contentType;
  return headers;
}

async function downloadFromStorage(storagePath: string): Promise<Uint8Array> {
  const res = await fetch(
    `${SUPABASE_URL}/storage/v1/object/${BELEGE_BUCKET}/${storagePath}`,
    { headers: storageAuthHeaders() },
  );
  if (!res.ok) {
    throw new Error(`Storage download failed: ${storagePath} (${res.status})`);
  }
  return new Uint8Array(await res.arrayBuffer());
}

async function handleArchiveBelegSeite(body: Record<string, string>) {
  const { mandantId, imageBase64, seiteNr, mimeType = "image/jpeg" } = body;
  if (!mandantId || !imageBase64) {
    return jsonResponse({ error: "Missing mandantId or imageBase64" }, 400);
  }
  if (!SUPABASE_URL || !SUPABASE_SERVICE_KEY) {
    return jsonResponse({ error: "Supabase service credentials not configured" }, 500);
  }

  const bytes = Uint8Array.from(atob(imageBase64), (c) => c.charCodeAt(0));
  const gobdHash = await sha256Hex(bytes);
  const page = String(seiteNr || "1");
  const ext = mimeType.includes("png") ? "png" : "jpg";
  const storagePath = `${mandantId}/${crypto.randomUUID()}-s${page}.${ext}`;

  const uploadRes = await fetch(
    `${SUPABASE_URL}/storage/v1/object/${BELEGE_BUCKET}/${storagePath}`,
    {
      method: "POST",
      headers: {
        ...storageAuthHeaders(mimeType),
        "x-upsert": "false",
      },
      body: bytes,
    },
  );
  const uploadText = await uploadRes.text();
  if (!uploadRes.ok) {
    return jsonResponse({
      error: "Storage upload failed",
      status: uploadRes.status,
      response: uploadText.slice(0, 500),
    }, uploadRes.status);
  }

  return jsonResponse({
    success: true,
    storagePath,
    gobdHash,
    seiteNr: Number(page),
    mimeType,
    // GoBD-Archivierungszeitstempel: Zeitpunkt des erfolgreichen Uploads
    archivedAt: new Date().toISOString(),
  });
}

/** BER-90: Original-PDF unverändert archivieren (GoBD-Original, Hash über Originaldatei). */
async function handleArchiveBelegPdf(body: Record<string, string>) {
  const { mandantId, pdfBase64, fileName = "import.pdf" } = body;
  if (!mandantId || !pdfBase64) {
    return jsonResponse({ error: "Missing mandantId or pdfBase64" }, 400);
  }
  if (!SUPABASE_URL || !SUPABASE_SERVICE_KEY) {
    return jsonResponse({ error: "Supabase service credentials not configured" }, 500);
  }

  const bytes = Uint8Array.from(atob(pdfBase64), (c) => c.charCodeAt(0));

  // Magic Bytes %PDF-
  if (
    bytes.length < 5 || bytes[0] !== 0x25 || bytes[1] !== 0x50 ||
    bytes[2] !== 0x44 || bytes[3] !== 0x46 || bytes[4] !== 0x2d
  ) {
    return jsonResponse({ error: "Datei ist kein gültiges PDF" }, 422);
  }

  // Strukturvalidierung + Seitenzahl
  let pageCount = 0;
  try {
    const { PDFDocument } = await import("npm:pdf-lib@1.17.1");
    const doc = await PDFDocument.load(bytes, { ignoreEncryption: true });
    pageCount = doc.getPageCount();
  } catch (_e) {
    return jsonResponse({ error: "PDF ist beschädigt oder nicht lesbar" }, 422);
  }

  const gobdHash = await sha256Hex(bytes);

  // Duplikat-Check vor Upload — spart Storage-Objekt und OCR-Kosten
  const dupRes = await fetch(
    `${SUPABASE_URL}/rest/v1/belege?mandant_id=eq.${mandantId}&gobd_hash=eq.${gobdHash}&select=beleg_nr&limit=1`,
    { headers: storageAuthHeaders() },
  );
  if (dupRes.ok) {
    const dup = await dupRes.json();
    if (Array.isArray(dup) && dup.length > 0) {
      return jsonResponse({
        error: `Duplikat: bereits archiviert als ${dup[0].beleg_nr}`,
        duplicate: true,
      }, 409);
    }
  }

  const storagePath = `${mandantId}/${crypto.randomUUID()}-${
    fileName.replace(/[^a-zA-Z0-9._-]/g, "_").slice(-80)
  }`;

  const uploadRes = await fetch(
    `${SUPABASE_URL}/storage/v1/object/${BELEGE_BUCKET}/${storagePath}`,
    {
      method: "POST",
      headers: {
        ...storageAuthHeaders("application/pdf"),
        "x-upsert": "false",
      },
      body: bytes,
    },
  );
  const uploadText = await uploadRes.text();
  if (!uploadRes.ok) {
    return jsonResponse({
      error: "Storage upload failed",
      status: uploadRes.status,
      response: uploadText.slice(0, 500),
    }, uploadRes.status);
  }

  return jsonResponse({
    success: true,
    storagePath,
    gobdHash,
    pageCount,
    mimeType: "application/pdf",
    archivedAt: new Date().toISOString(),
  });
}

/** BER-90: OCR über eine archivierte PDF via Mistral OCR (alle Seiten). */
async function handleOcrStoragePdf(body: Record<string, string>) {
  const { storagePath } = body;
  if (!storagePath) {
    return jsonResponse({ error: "Missing storagePath" }, 400);
  }
  if (!MISTRAL_API_KEY) {
    return jsonResponse({ error: "MISTRAL_API_KEY not configured" }, 500);
  }

  const bytes = await downloadFromStorage(storagePath);

  const form = new FormData();
  form.append("purpose", "ocr");
  form.append(
    "file",
    new Blob([bytes], { type: "application/pdf" }),
    "beleg.pdf",
  );

  const uploadRes = await fetch("https://api.mistral.ai/v1/files", {
    method: "POST",
    headers: { Authorization: `Bearer ${MISTRAL_API_KEY}` },
    body: form,
  });
  const uploadText = await uploadRes.text();
  if (!uploadRes.ok) {
    return jsonResponse({
      error: "Mistral file upload failed",
      status: uploadRes.status,
      response: uploadText.slice(0, 1000),
    }, uploadRes.status);
  }
  const fileId = JSON.parse(uploadText).id as string;

  const urlAttempt = await mistralSignedUrlWithRetry(fileId);
  if (!urlAttempt.ok) {
    return jsonResponse({
      error: "Mistral signed URL failed",
      status: urlAttempt.status,
      response: urlAttempt.text.slice(0, 1000),
    }, urlAttempt.status);
  }
  const { url: signedUrl } = JSON.parse(urlAttempt.text);

  const ocrRes = await fetch("https://api.mistral.ai/v1/ocr", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${MISTRAL_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: "mistral-ocr-latest",
      document: { type: "document_url", document_url: signedUrl },
    }),
  });
  const ocrText = await ocrRes.text();

  fetch(`https://api.mistral.ai/v1/files/${fileId}`, {
    method: "DELETE",
    headers: { Authorization: `Bearer ${MISTRAL_API_KEY}` },
  }).catch(() => {});

  if (!ocrRes.ok) {
    return jsonResponse({
      error: "Mistral OCR failed",
      status: ocrRes.status,
      response: ocrText.slice(0, 1000),
    }, ocrRes.status);
  }

  const data = JSON.parse(ocrText);
  const pages = Array.isArray(data.pages) ? data.pages : [];
  const text = pages
    .map((p: { index?: number; markdown?: string }, i: number) =>
      `--- Seite ${(p.index ?? i) + 1} ---\n${p.markdown || ""}`)
    .join("\n\n");

  return jsonResponse({
    success: true,
    text,
    pageCount: pages.length,
  });
}

async function handleOcrStoragePages(body: Record<string, unknown>) {
  const paths = body.storagePaths;
  if (!Array.isArray(paths) || paths.length === 0) {
    return jsonResponse({ error: "Missing storagePaths array" }, 400);
  }
  if (!SUPABASE_URL || !SUPABASE_SERVICE_KEY) {
    return jsonResponse({ error: "Supabase service credentials not configured" }, 500);
  }

  const parts: string[] = [];
  for (let i = 0; i < paths.length; i++) {
    const storagePath = String(paths[i]);
    const bytes = await downloadFromStorage(storagePath);
    const ocr = await mistralOcrFromImageBytes(
      bytes,
      `beleg-s${i + 1}.jpg`,
    );
    if (ocr.status !== 200) {
      return ocr;
    }
    const data = await ocr.json();
    parts.push(`--- Seite ${i + 1} ---\n${data.text || ""}`);
  }

  return jsonResponse({
    success: true,
    text: parts.join("\n\n"),
    pageCount: paths.length,
  });
}

async function handleMistralChat(body: Record<string, unknown>) {
  if (!MISTRAL_API_KEY) {
    return jsonResponse({ error: "MISTRAL_API_KEY not configured" }, 500);
  }

  const chatBody = body.body;
  if (!chatBody || typeof chatBody !== "object") {
    return jsonResponse({ error: "Missing body" }, 400);
  }

  const response = await fetch("https://api.mistral.ai/v1/chat/completions", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${MISTRAL_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(chatBody),
  });

  const responseText = await response.text();
  if (!response.ok) {
    return jsonResponse({
      error: "Mistral chat failed",
      status: response.status,
      response: responseText.slice(0, 1000),
    }, response.status);
  }

  return new Response(responseText, {
    status: 200,
    headers: {
      "Content-Type": "application/json",
      ...corsHeaders(),
    },
  });
}

/**
 * BER-99: Bewirtungs-Deckblatt. Erzeugt ein selbsttragendes PDF —
 * Kopfseite mit den Pflichtangaben (§ 4 Abs. 5 Nr. 2 EStG) + die Original-
 * Belegseiten (Bilder eingebettet, PDF-Seiten kopiert). Storage-Zugriff läuft
 * hier über den Service Key; die App liefert nur die (RLS-geprüften) Metadaten.
 */
async function handleBewirtungDeckblatt(body: Record<string, unknown>) {
  const angaben = (body.angaben ?? {}) as Record<string, string>;
  const seiten = Array.isArray(body.seiten)
    ? (body.seiten as Array<{ storage_path: string; mime_type?: string }>)
    : [];
  if (!SUPABASE_URL || !SUPABASE_SERVICE_KEY) {
    return jsonResponse({ error: "Supabase service credentials not configured" }, 500);
  }

  const { PDFDocument, StandardFonts, rgb } = await import("npm:pdf-lib@1.17.1");
  const doc = await PDFDocument.create();
  const font = await doc.embedFont(StandardFonts.Helvetica);
  const bold = await doc.embedFont(StandardFonts.HelveticaBold);
  const A4: [number, number] = [595.28, 841.89];
  const gold = rgb(0.71, 0.455, 0.165);
  const dark = rgb(0.1, 0.08, 0.06);

  // ---- Kopfseite ----
  const cover = doc.addPage(A4);
  let y = 800;
  cover.drawText("+", { x: 50, y: y - 4, size: 34, font: bold, color: gold });
  cover.drawText("Bewirtungsbeleg", { x: 82, y, size: 24, font: bold, color: dark });
  y -= 26;
  cover.drawText("Angaben nach § 4 Abs. 5 Nr. 2 EStG", { x: 82, y, size: 10, font, color: rgb(0.48, 0.42, 0.35) });
  y -= 40;

  const zeile = (label: string, wert: string) => {
    cover.drawText(label, { x: 50, y, size: 10, font: bold, color: dark });
    const words = String(wert || "—").split(/\s+/);
    let line = "", ly = y;
    for (const w of words) {
      const test = line ? line + " " + w : w;
      if (font.widthOfTextAtSize(test, 11) > 330) {
        cover.drawText(line, { x: 210, y: ly, size: 11, font, color: dark });
        line = w; ly -= 15;
      } else line = test;
    }
    cover.drawText(line, { x: 210, y: ly, size: 11, font, color: dark });
    y = ly - 22;
  };

  zeile("Beleg-Nr.", angaben.beleg_nr);
  zeile("Datum der Bewirtung", angaben.beleg_datum);
  zeile("Gaststätte / Ort", angaben.lieferant);
  zeile("Rechnungsbetrag (brutto)", angaben.betrag_brutto);
  zeile("davon MwSt", angaben.mwst);
  zeile("Anlass der Bewirtung", angaben.anlass);
  zeile("Bewirtete Personen", angaben.teilnehmer);
  zeile("SKR04-Konto", angaben.sachkonto);

  y -= 10;
  cover.drawLine({ start: { x: 50, y }, end: { x: 545, y }, thickness: 0.5, color: gold });
  y -= 20;
  cover.drawText(
    "Die 70/30-Aufteilung der abziehbaren Bewirtungskosten erfolgt in der Buchhaltung.",
    { x: 50, y, size: 8, font, color: rgb(0.48, 0.42, 0.35) },
  );
  y -= 12;
  cover.drawText(
    `Erstellt: ${angaben.erstellt || ""} · BelegChat · BERENT.AI`,
    { x: 50, y, size: 8, font, color: rgb(0.48, 0.42, 0.35) },
  );

  // ---- Original-Belegseiten anhängen ----
  for (const s of seiten) {
    const bytes = await downloadFromStorage(s.storage_path);
    const mime = (s.mime_type || "").toLowerCase();
    if (mime.includes("pdf")) {
      const src = await PDFDocument.load(bytes, { ignoreEncryption: true });
      const copied = await doc.copyPages(src, src.getPageIndices());
      for (const p of copied) doc.addPage(p);
    } else {
      const img = mime.includes("png")
        ? await doc.embedPng(bytes)
        : await doc.embedJpg(bytes);
      const page = doc.addPage(A4);
      const maxW = A4[0] - 60, maxH = A4[1] - 60;
      const scale = Math.min(maxW / img.width, maxH / img.height, 1);
      const w = img.width * scale, h = img.height * scale;
      page.drawImage(img, { x: (A4[0] - w) / 2, y: (A4[1] - h) / 2, width: w, height: h });
    }
  }

  const pdfBytes = await doc.save();
  return jsonResponse({ success: true, pdfBase64: bytesToBase64(pdfBytes) });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 200, headers: corsHeaders() });
  }

  if (req.method !== "POST") {
    return jsonResponse({ error: "Method not allowed" }, 405);
  }

  let payload: Record<string, unknown>;
  try {
    payload = await req.json();
  } catch {
    return jsonResponse({ error: "Invalid JSON body" }, 400);
  }

  const action = payload.action;
  // Deckblatt darf mit dem eng begrenzten DECKBLATT_TOKEN aufgerufen werden;
  // alle übrigen Aktionen weiterhin nur mit dem vollen DECRYPT_API_TOKEN.
  const authed = isAuthorized(req) ||
    (action === "bewirtung-deckblatt" && !!DECKBLATT_TOKEN && isAuthorized(req, DECKBLATT_TOKEN));
  if (!authed) {
    return jsonResponse({ error: "Unauthorized" }, 401);
  }
  if (action === "decrypt") {
    return handleDecrypt(payload as Record<string, string>);
  }
  if (action === "send") {
    return handleSend(payload as Record<string, string>);
  }
  if (action === "decrypt-blob") {
    return handleDecryptBlob(payload as Record<string, string>);
  }
  if (action === "decrypt-blob-and-ocr") {
    return handleDecryptBlobAndOcr(payload as Record<string, string>);
  }
  if (action === "vision-ocr") {
    return handleVisionOcr(payload as Record<string, string>);
  }
  if (action === "mistral-chat") {
    return handleMistralChat(payload);
  }
  if (action === "archive-beleg-seite") {
    return handleArchiveBelegSeite(payload as Record<string, string>);
  }
  if (action === "ocr-storage-pages") {
    return handleOcrStoragePages(payload);
  }
  if (action === "archive-beleg-pdf") {
    return handleArchiveBelegPdf(payload as Record<string, string>);
  }
  if (action === "ocr-storage-pdf") {
    return handleOcrStoragePdf(payload as Record<string, string>);
  }
  if (action === "bewirtung-deckblatt") {
    return handleBewirtungDeckblatt(payload);
  }

  return jsonResponse({ error: "Unknown action" }, 400);
});
