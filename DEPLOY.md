# threema-decrypt auf Supabase deployen

Projekt-Ref: `xuqefeewzdvjhuquciut`

Function-URL (nach Deploy):
`https://xuqefeewzdvjhuquciut.supabase.co/functions/v1/threema-decrypt`

---

## Schritt 1 — Secrets in Supabase setzen

1. Öffne: https://supabase.com/dashboard/project/xuqefeewzdvjhuquciut/settings/functions
2. Tab **Secrets** (oder „Edge Function Secrets“)
3. Diese Keys anlegen:

| Name | Wert |
|---|---|
| `DECRYPT_API_TOKEN` | Langes Zufallstoken (z. B. `openssl rand -hex 32`) |
| `MISTRAL_API_KEY` | Dein Mistral-API-Key aus https://console.mistral.ai/api-keys |
| `SUPABASE_SERVICE_ROLE_KEY` | Service-Role-Key aus Project Settings → API (für Storage-Upload/OCR) |

Optional:

| Name | Wert |
|---|---|
| `MISTRAL_VISION_MODEL` | Standard: `pixtral-12b-2409` |
| `ALLOWED_ORIGIN` | Leer lassen für Server-zu-Server |

**Wichtig:** `DECRYPT_API_TOKEN` muss **identisch** in n8n als Umgebungsvariable stehen.

---

## Schritt 2 — Function deployen (CLI)

Voraussetzung: Supabase CLI installiert und eingeloggt.

```bash
cd /Users/Shared/Projekte/Entwicklung/projekte/threema-decrypt
supabase login
supabase link --project-ref xuqefeewzdvjhuquciut
supabase functions deploy threema-decrypt
```

---

## Schritt 3 — n8n Env setzen

In der Hostinger-n8n-Instanz (Container-Env oder `.env`):

```
DECRYPT_API_TOKEN=<dasselbe Token wie in Supabase>
SUPABASE_URL=https://xuqefeewzdvjhuquciut.supabase.co
```

n8n danach neu starten.

---

## Schritt 4 — Workflow importieren

Datei:
`/Users/Shared/Entwicklung/n8n-workflows/n8n/MYpHUIHNMuIUR1ic/BelegChat mit Threema Beleg-Eingang.json`

In n8n: **Import from File** → Replace → Speichern → Testbeleg schicken.

---

## Schnelltest (Terminal)

```bash
curl -s -X POST \
  'https://xuqefeewzdvjhuquciut.supabase.co/functions/v1/threema-decrypt' \
  -H 'Authorization: Bearer DEIN_DECRYPT_API_TOKEN' \
  -H 'Content-Type: application/json' \
  -d '{"action":"vision-ocr","imageBase64":"..."}'
```

Ohne gültiges Token → `401`. Ohne `MISTRAL_API_KEY` → `MISTRAL_API_KEY not configured`.

### Neue Actions (Alpha Mehrseiten + GoBD)

| action | Zweck |
|---|---|
| `archive-beleg-seite` | Originalbytes → Storage `belege-archiv`, SHA-256 `gobd_hash` |
| `ocr-storage-pages` | OCR über gespeicherte Seiten (`storagePaths[]`) |

Beispiel Archiv:

```bash
curl -s -X POST \
  'https://xuqefeewzdvjhuquciut.supabase.co/functions/v1/threema-decrypt' \
  -H 'Authorization: Bearer DEIN_DECRYPT_API_TOKEN' \
  -H 'Content-Type: application/json' \
  -d '{"action":"archive-beleg-seite","mandantId":"UUID","imageBase64":"...","seiteNr":1}'
```
