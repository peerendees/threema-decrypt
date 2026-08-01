-- BER-124: Threema-Textbefehl „Belegimport" — Freischaltung je Mandant + Auftragstabelle.
-- Angewendet auf Prod (xuqefeewzdvjhuquciut) am 01.08.2026.
--
-- Der Betreiber stoesst den PDF-Import per Threema-Nachricht „Belegimport" an, statt
-- auf den geplanten Lauf (11:50/17:50/21:50) zu warten. Die Belege liegen lokal in
-- iCloud, die Cloud kommt nicht heran — deshalb legt n8n nur einen AUFTRAG ab, den
-- ein Poller auf dem Mac abholt:
--
--   n8n (Befehl erkannt) -> INSERT status 'offen'
--   Poller               -> 'in_arbeit' -> beleg-import.mjs watch --once
--                        -> ergebnis + 'erledigt' -> n8n-Ergebnis-Webhook -> 'gemeldet'
--
-- Wer den Befehl nutzen darf, ist NICHT hartkodiert (Betreiber-Weisung 31.07.2026),
-- sondern haengt am Mandanten-Flag. Fuer alle anderen Absender bleibt es beim
-- bisherigen Verhalten („Bitte sende ein Foto oder Bild des Belegs").
--
-- Idempotent (IF NOT EXISTS / DROP POLICY IF EXISTS); auf einer frischen DB ist das
-- abschliessende UPDATE ein No-op.

-- 1) Freischaltung je Mandant -------------------------------------------------

ALTER TABLE public.mandanten
  ADD COLUMN IF NOT EXISTS import_befehl_aktiv boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.mandanten.import_befehl_aktiv IS
  'Darf diese Threema-ID den Textbefehl „Belegimport" ausloesen? (BER-124)';

-- 2) Auftragstabelle ----------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.import_kommandos (
  id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  mandant_id     uuid        NOT NULL REFERENCES public.mandanten(id),
  angefordert_am timestamptz NOT NULL DEFAULT now(),
  status         text        NOT NULL DEFAULT 'offen'
                             CHECK (status IN ('offen', 'in_arbeit', 'erledigt', 'gemeldet')),
  ergebnis       jsonb,
  erledigt_am    timestamptz
);

COMMENT ON TABLE public.import_kommandos IS
  'Auftraege des Threema-Befehls „Belegimport"; der Mac-Poller arbeitet sie ab (BER-124)';
COMMENT ON COLUMN public.import_kommandos.ergebnis IS
  'Bilanz des Laufs: {importiert, duplikate, fehler, belegnummern[], duplikatdateien[], fehlerdateien[{datei,grund}]}';

-- Der Poller fragt ausschliesslich nach offenen Auftraegen — Teilindex genuegt.
CREATE INDEX IF NOT EXISTS idx_import_kommandos_offen
  ON public.import_kommandos (angefordert_am)
  WHERE status = 'offen';

-- 3) Zugriff ------------------------------------------------------------------
-- n8n schreibt mit dem Service-Key (BYPASSRLS). Poller und Dashboard laufen als
-- dashboard_service und sehen nur ihren Mandanten (app.mandant_id, ADR-05).
-- anon/authenticated haben hier nichts verloren: die Tabelle wird nie ueber die
-- PostgREST-Publikumsschluessel angefasst.

ALTER TABLE public.import_kommandos ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.import_kommandos FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.import_kommandos TO dashboard_service;

DROP POLICY IF EXISTS dash_import_kommandos_select ON public.import_kommandos;
CREATE POLICY dash_import_kommandos_select ON public.import_kommandos
  FOR SELECT TO dashboard_service
  USING (mandant_id = (NULLIF(current_setting('app.mandant_id', true), ''))::uuid);

DROP POLICY IF EXISTS dash_import_kommandos_insert ON public.import_kommandos;
CREATE POLICY dash_import_kommandos_insert ON public.import_kommandos
  FOR INSERT TO dashboard_service
  WITH CHECK (mandant_id = (NULLIF(current_setting('app.mandant_id', true), ''))::uuid);

DROP POLICY IF EXISTS dash_import_kommandos_update ON public.import_kommandos;
CREATE POLICY dash_import_kommandos_update ON public.import_kommandos
  FOR UPDATE TO dashboard_service
  USING      (mandant_id = (NULLIF(current_setting('app.mandant_id', true), ''))::uuid)
  WITH CHECK (mandant_id = (NULLIF(current_setting('app.mandant_id', true), ''))::uuid);

-- 4) Freischaltung Firma 01 ---------------------------------------------------
-- Einziger produktiver Mandant (Betreiber selbst). Weitere Mandanten werden
-- spaeter im Dashboard freigeschaltet (Teil 3, eigene Story).

UPDATE public.mandanten SET import_befehl_aktiv = true WHERE threema_id = 'BUMFMZ39';
