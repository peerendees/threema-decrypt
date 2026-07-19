-- BER-107: Termin-Kontext für Auswärts-Belege (Taxi, Bahn, ÖPNV) —
-- Verallgemeinerung des Bewirtungs-Musters.
--
-- Idee: Bei Belegen, die einen Auswärtstermin dokumentieren, ist im Nachhinein
-- schwer rekonstruierbar, WO der Termin war, bei welchem KUNDEN und aus welchem
-- GRUND. Diese Angaben werden — wie bei Bewirtung — zeitnah bei der Freigabe
-- erfasst; ohne Grund landet der Beleg in 'klaerungsbedarf'.
--
-- Steuerlich: Bei Reisekosten ist der Anlass nicht formpflichtig wie bei
-- Bewirtung (§ 4 Abs. 5 Nr. 2 EStG), dient aber dem Nachweis der betrieblichen
-- Veranlassung.

-- 1) Reisekosten-Konto sicherstellen (Taxi/Bahn/ÖPNV → 6860).
INSERT INTO public.skr04_konten
  (konto_nr, bezeichnung, konto_klasse, konto_typ, mwst_relevant, vorsteuer_relevant, typische_verwendung)
VALUES ('6860', 'Reisekosten Arbeitnehmer', 6, 'aufwand', true, true,
        'Fahrtkosten für Auswärtstermine (Taxi, Bahn, ÖPNV, Fahrkarten). Termin-Kontext (Grund/Ort/Kunde) belegt die betriebliche Veranlassung.')
ON CONFLICT (konto_nr) DO NOTHING;

-- 2) Neuer Beleg-Typ 'auswaerts' für Reisekosten-Belege.
ALTER TABLE public.belege DROP CONSTRAINT IF EXISTS belege_beleg_typ_check;
ALTER TABLE public.belege ADD CONSTRAINT belege_beleg_typ_check
  CHECK (beleg_typ = ANY (ARRAY['eingangsrechnung','ausgangsrechnung','quittung','gutschrift','sonstiges','bewirtung','auswaerts']::text[]));

-- 3) Trinkgeld verallgemeinern: bewirtung_trinkgeld → trinkgeld.
--    RENAME ist DDL und löst den Festschreibungs-Trigger (fn_belege_festschreibung)
--    nicht aus; bereits festgeschriebene Belege behalten ihren Wert. Spalten-
--    Privilegien (GRANT UPDATE) wandern in Postgres automatisch mit dem Rename mit.
ALTER TABLE public.belege RENAME COLUMN bewirtung_trinkgeld TO trinkgeld;
COMMENT ON COLUMN public.belege.trinkgeld IS
  'Trinkgeld (separat vom Rechnungsbetrag) — bei Bewirtung und bei Auswärts-Belegen (z. B. Taxi); erscheint auf dem Deckblatt und im DATEV-Buchungstext';

-- 4) Generische Termin-Kontext-Felder.
ALTER TABLE public.belege
  ADD COLUMN IF NOT EXISTS termin_grund text,
  ADD COLUMN IF NOT EXISTS termin_ort   text,
  ADD COLUMN IF NOT EXISTS termin_kunde text;

COMMENT ON COLUMN public.belege.termin_grund IS 'Grund/Anlass des Auswärtstermins (Pflicht bei beleg_typ auswaerts; Nachweis der betrieblichen Veranlassung)';
COMMENT ON COLUMN public.belege.termin_ort   IS 'Ort des Termins (empfohlen; oft aus dem Beleg lesbar, z. B. Bahnhof/Taxi-Stadt)';
COMMENT ON COLUMN public.belege.termin_kunde IS 'Kunde/Geschäftspartner des Termins (optional)';

-- 5) Grants für die Dashboard-Rolle (Erfassung bei Freigabe).
GRANT UPDATE (termin_grund, termin_ort, termin_kunde, trinkgeld) ON public.belege TO dashboard_service;
