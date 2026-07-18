-- Trinkgeld bei Bewirtung: eigenes Feld (Rechnungsbetrag bleibt betrag_brutto).
-- Abziehbar als Bewirtungskosten; Vermerk auf dem Deckblatt ersetzt die
-- praktische Quittierung, Verbuchung entscheidet die Kanzlei.
ALTER TABLE public.belege
  ADD COLUMN IF NOT EXISTS bewirtung_trinkgeld numeric(10,2);

COMMENT ON COLUMN public.belege.bewirtung_trinkgeld IS
  'Trinkgeld bei Bewirtung (separat vom Rechnungsbetrag; erscheint auf dem Deckblatt und im DATEV-Buchungstext)';

GRANT UPDATE (bewirtung_trinkgeld) ON public.belege TO dashboard_service;
