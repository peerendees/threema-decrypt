-- BER-113: Manuelle Belegerfassung + Nachreichen des Originaldokuments.
-- dashboard_service durfte bisher nur lesen/loeschen und einzelne Spalten aendern.
-- Fuer die manuelle Erfassung braucht es INSERT — bewusst spaltenweise, damit
-- GoBD-relevante Felder (geprueft_*, datev_*) nicht frei setzbar sind.

GRANT INSERT (
  beleg_nr, mandant_id, eingangskanal, status,
  beleg_datum, betrag_brutto, betrag_netto, mwst_satz, mwst_betrag,
  beleg_typ, verwendungszweck, sachkonto, sachkonto_manuell_geaendert,
  stb_vermerk, termin_grund, termin_ort, termin_kunde, trinkgeld,
  bewirtung_anlass, bewirtung_teilnehmer
) ON public.belege TO dashboard_service;

GRANT INSERT (beleg_id, seite_nr, storage_path, gobd_hash, mime_type, archived_at)
  ON public.beleg_seiten TO dashboard_service;

-- gobd_hash/bild_storage_path setzen, sobald das Dokument nachgereicht ist.
-- Nach der Festschreibung sperrt fn_belege_festschreibung die Spalten ohnehin.
GRANT UPDATE (gobd_hash, bild_storage_path) ON public.belege TO dashboard_service;

GRANT EXECUTE ON FUNCTION public.naechste_beleg_nr(uuid) TO dashboard_service;
