-- BER-96 · Phase 4 DATEV-Export (EXTF-Buchungsstapel aus dem Dashboard)

-- DATEV-Stammdaten je Firma (Beraternummer/Mandantennummer liefert der StB;
-- bis dahin exportiert der Stapel mit 0-Werten)
ALTER TABLE public.firmen
  ADD COLUMN IF NOT EXISTS datev_berater_nr integer,
  ADD COLUMN IF NOT EXISTS datev_mandant_nr integer,
  ADD COLUMN IF NOT EXISTS datev_gegenkonto varchar(10) NOT NULL DEFAULT '1800';

COMMENT ON COLUMN public.firmen.datev_gegenkonto IS
  'Gegenkonto für den Buchungsstapel-Export (Default 1800 Bank, SKR04)';

-- Dashboard-Rolle: Export anlegen/lesen, Belege in exportiert überführen
GRANT SELECT, INSERT ON public.datev_exporte TO dashboard_service;
GRANT UPDATE (datev_export_id, export_datum) ON public.belege TO dashboard_service;

DROP POLICY IF EXISTS dash_datev_select ON public.datev_exporte;
CREATE POLICY dash_datev_select ON public.datev_exporte
  FOR SELECT TO dashboard_service
  USING (mandant_id = NULLIF(current_setting('app.mandant_id', true), '')::uuid);

DROP POLICY IF EXISTS dash_datev_insert ON public.datev_exporte;
CREATE POLICY dash_datev_insert ON public.datev_exporte
  FOR INSERT TO dashboard_service
  WITH CHECK (mandant_id = NULLIF(current_setting('app.mandant_id', true), '')::uuid);
