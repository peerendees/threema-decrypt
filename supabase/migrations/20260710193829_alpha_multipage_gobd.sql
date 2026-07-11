-- Alpha-Migration (bereits angewendet am 2026-07-10, Version 20260710193829).
-- Nachträglich versioniert im Rahmen von BER-92 — Inhalt 1:1 aus
-- supabase_migrations.schema_migrations übernommen, nicht verändern.

-- pending_belege: Zwischenzustand Mehrseiten-Erfassung
CREATE TABLE IF NOT EXISTS public.pending_belege (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  mandant_id uuid NOT NULL REFERENCES public.mandanten(id) ON DELETE CASCADE,
  threema_sender_id text NOT NULL,
  seiten jsonb NOT NULL DEFAULT '[]'::jsonb,
  status text NOT NULL DEFAULT 'wartet_auf_antwort'
    CHECK (status IN ('wartet_auf_antwort', 'wartet_auf_seite', 'abgeschlossen', 'abgebrochen')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL DEFAULT (now() + interval '24 hours')
);

CREATE INDEX IF NOT EXISTS idx_pending_belege_mandant_status
  ON public.pending_belege (mandant_id, status)
  WHERE status IN ('wartet_auf_antwort', 'wartet_auf_seite');

CREATE UNIQUE INDEX IF NOT EXISTS idx_pending_belege_one_open_per_mandant
  ON public.pending_belege (mandant_id)
  WHERE status IN ('wartet_auf_antwort', 'wartet_auf_seite');

-- beleg_seiten: revisionssichere Originale pro Belegseite
CREATE TABLE IF NOT EXISTS public.beleg_seiten (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  beleg_id uuid NOT NULL REFERENCES public.belege(id) ON DELETE CASCADE,
  seite_nr smallint NOT NULL CHECK (seite_nr > 0),
  storage_path text NOT NULL,
  gobd_hash text NOT NULL,
  mime_type text NOT NULL DEFAULT 'image/jpeg',
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (beleg_id, seite_nr)
);

CREATE INDEX IF NOT EXISTS idx_beleg_seiten_beleg ON public.beleg_seiten (beleg_id);

COMMENT ON TABLE public.pending_belege IS 'Threema Mehrseiten-Zwischenstand bis Ziffer 1/2';
COMMENT ON TABLE public.beleg_seiten IS 'GoBD-Originale pro Belegseite im Storage belege-archiv';
