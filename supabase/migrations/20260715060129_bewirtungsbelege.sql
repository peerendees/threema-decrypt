-- Bewirtungsbelege (§ 4 Abs. 5 Nr. 2 EStG)

INSERT INTO public.skr04_konten (konto_nr, bezeichnung, konto_klasse, konto_typ, mwst_relevant, vorsteuer_relevant, typische_verwendung)
VALUES ('6640', 'Bewirtungskosten', 6, 'aufwand', true, true,
        'Geschäftliche Bewirtung (§ 4 Abs. 5 Nr. 2 EStG); 70% abziehbar. Split/nicht abziehbaren Anteil bucht die Kanzlei.')
ON CONFLICT (konto_nr) DO NOTHING;

ALTER TABLE public.belege DROP CONSTRAINT IF EXISTS belege_beleg_typ_check;
ALTER TABLE public.belege ADD CONSTRAINT belege_beleg_typ_check
  CHECK (beleg_typ = ANY (ARRAY['eingangsrechnung','ausgangsrechnung','quittung','gutschrift','sonstiges','bewirtung']::text[]));

ALTER TABLE public.belege
  ADD COLUMN IF NOT EXISTS bewirtung_anlass text,
  ADD COLUMN IF NOT EXISTS bewirtung_teilnehmer text;

COMMENT ON COLUMN public.belege.bewirtung_anlass IS 'Geschäftlicher Anlass der Bewirtung (Pflichtangabe § 4 Abs. 5 Nr. 2 EStG)';
COMMENT ON COLUMN public.belege.bewirtung_teilnehmer IS 'Namen der bewirteten Personen (Pflichtangabe § 4 Abs. 5 Nr. 2 EStG)';

GRANT UPDATE (bewirtung_anlass, bewirtung_teilnehmer) ON public.belege TO dashboard_service;
