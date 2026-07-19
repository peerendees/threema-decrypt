-- BER-108: Teilbeträge bei Rechnungsbelegen.
--
-- Manchmal soll nur ein Teil einer Rechnung gebucht werden (private/nicht
-- abziehbare Positionen). Das Originaldokument bleibt als Ganzes archiviert
-- (GoBD); betrag_brutto/netto/mwst bleiben der OCR-Dokumentbetrag. Der gebuchte
-- Teilbetrag liegt separat in gebucht_*; Buchung/Export lesen COALESCE().

ALTER TABLE public.belege
  ADD COLUMN IF NOT EXISTS gebucht_brutto  numeric(12,2),
  ADD COLUMN IF NOT EXISTS gebucht_netto   numeric(12,2),
  ADD COLUMN IF NOT EXISTS gebucht_mwst    numeric(12,2),
  ADD COLUMN IF NOT EXISTS teilbetrag_basis text,
  ADD COLUMN IF NOT EXISTS teilbetrag_grund text;

ALTER TABLE public.belege DROP CONSTRAINT IF EXISTS belege_teilbetrag_basis_check;
ALTER TABLE public.belege ADD CONSTRAINT belege_teilbetrag_basis_check
  CHECK (teilbetrag_basis IS NULL OR teilbetrag_basis = ANY (ARRAY['brutto','netto']::text[]));

COMMENT ON COLUMN public.belege.gebucht_brutto   IS 'Gebuchter Teilbetrag brutto (NULL = voller Dokumentbetrag betrag_brutto). BER-108';
COMMENT ON COLUMN public.belege.gebucht_netto    IS 'Gebuchter Teilbetrag netto (abgeleitet aus gebucht_brutto + mwst_satz)';
COMMENT ON COLUMN public.belege.gebucht_mwst     IS 'MwSt-Anteil des gebuchten Teilbetrags';
COMMENT ON COLUMN public.belege.teilbetrag_basis IS 'Eingabebasis des Teilbetrags: brutto | netto';
COMMENT ON COLUMN public.belege.teilbetrag_grund IS 'Optionaler Grund für die Teilbuchung (welche Positionen ausgeschlossen)';

GRANT UPDATE (gebucht_brutto, gebucht_netto, gebucht_mwst, teilbetrag_basis, teilbetrag_grund)
  ON public.belege TO dashboard_service;

-- Neue Audit-Aktion für die Teilbuchung (DDL, der append-only-Row-Trigger bleibt unberührt).
ALTER TABLE public.audit_log DROP CONSTRAINT IF EXISTS audit_log_aktion_check;
ALTER TABLE public.audit_log ADD CONSTRAINT audit_log_aktion_check
  CHECK (aktion = ANY (ARRAY['status_change','konto_geaendert','export','erstellt','abgelehnt','seite_archiviert','beleg_freigegeben','dokumentation_bestaetigt','teilbetrag_gebucht']::text[]));

-- Festschreibung: gebuchter Teilbetrag ist nach 'geprueft' GoBD-relevant und
-- damit unveränderlich (analog zu betrag_*). Funktion um die neuen Spalten
-- erweitert.
CREATE OR REPLACE FUNCTION public.fn_belege_festschreibung()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status IN ('geprueft', 'exportiert') THEN
      RAISE EXCEPTION 'Beleg % ist festgeschrieben (Status %) und darf nicht gelöscht werden (GoBD)',
        OLD.beleg_nr, OLD.status;
    END IF;
    RETURN OLD;
  END IF;

  IF OLD.status NOT IN ('geprueft', 'exportiert') THEN
    RETURN NEW;
  END IF;

  IF NEW.id                         IS DISTINCT FROM OLD.id
    OR NEW.beleg_nr                 IS DISTINCT FROM OLD.beleg_nr
    OR NEW.mandant_id               IS DISTINCT FROM OLD.mandant_id
    OR NEW.eingangskanal            IS DISTINCT FROM OLD.eingangskanal
    OR NEW.threema_sender_id        IS DISTINCT FROM OLD.threema_sender_id
    OR NEW.beleg_datum              IS DISTINCT FROM OLD.beleg_datum
    OR NEW.betrag_brutto            IS DISTINCT FROM OLD.betrag_brutto
    OR NEW.betrag_netto             IS DISTINCT FROM OLD.betrag_netto
    OR NEW.mwst_satz                IS DISTINCT FROM OLD.mwst_satz
    OR NEW.mwst_betrag              IS DISTINCT FROM OLD.mwst_betrag
    OR NEW.beleg_typ                IS DISTINCT FROM OLD.beleg_typ
    OR NEW.verwendungszweck         IS DISTINCT FROM OLD.verwendungszweck
    OR NEW.sachkonto                IS DISTINCT FROM OLD.sachkonto
    OR NEW.sachkonto_ki_vorschlag   IS DISTINCT FROM OLD.sachkonto_ki_vorschlag
    OR NEW.sachkonto_manuell_geaendert IS DISTINCT FROM OLD.sachkonto_manuell_geaendert
    OR NEW.vendor_id                IS DISTINCT FROM OLD.vendor_id
    OR NEW.ablehnungsgrund          IS DISTINCT FROM OLD.ablehnungsgrund
    OR NEW.ocr_konfidenz            IS DISTINCT FROM OLD.ocr_konfidenz
    OR NEW.gobd_hash                IS DISTINCT FROM OLD.gobd_hash
    OR NEW.bild_storage_path        IS DISTINCT FROM OLD.bild_storage_path
    OR NEW.geprueft_am              IS DISTINCT FROM OLD.geprueft_am
    OR NEW.geprueft_von             IS DISTINCT FROM OLD.geprueft_von
    OR NEW.created_at               IS DISTINCT FROM OLD.created_at
    OR NEW.gebucht_brutto           IS DISTINCT FROM OLD.gebucht_brutto
    OR NEW.gebucht_netto            IS DISTINCT FROM OLD.gebucht_netto
    OR NEW.gebucht_mwst             IS DISTINCT FROM OLD.gebucht_mwst
    OR NEW.teilbetrag_basis         IS DISTINCT FROM OLD.teilbetrag_basis
    OR NEW.teilbetrag_grund         IS DISTINCT FROM OLD.teilbetrag_grund
  THEN
    RAISE EXCEPTION 'Beleg % ist festgeschrieben (Status %): GoBD-relevante Felder sind unveränderlich',
      OLD.beleg_nr, OLD.status;
  END IF;

  IF NEW.status IS DISTINCT FROM OLD.status
     AND NOT (OLD.status = 'geprueft' AND NEW.status = 'exportiert') THEN
    RAISE EXCEPTION 'Beleg %: Statuswechsel % → % nicht erlaubt (festgeschrieben)',
      OLD.beleg_nr, OLD.status, NEW.status;
  END IF;

  RETURN NEW;
END;
$function$;
