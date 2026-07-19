-- BER-109: Vermerk für den Steuerberater (Anlagevermögen/AfA-Verdacht u. a.)
--
-- Belege mit Verdacht auf Anlagevermögen (netto > GWG-Grenze 800 € und
-- langlebiges Wirtschaftsgut laut KI) gehen in 'klaerungsbedarf' und tragen
-- einen vorbefüllten Vermerk, der beim DATEV-Import in den
-- Zusatzinformations-Feldern beim Steuerberater ankommt.

ALTER TABLE public.belege
  ADD COLUMN IF NOT EXISTS stb_vermerk text;

COMMENT ON COLUMN public.belege.stb_vermerk IS
  'Freitext-Vermerk für den Steuerberater; wird im DATEV-Export als Zusatzinformation ausgegeben (BER-109)';

GRANT UPDATE (stb_vermerk) ON public.belege TO dashboard_service;

-- Nach der Festschreibung ist der Vermerk Teil des Buchungssatzes und
-- damit unveränderlich (analog betrag_*/gebucht_*).
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
    OR NEW.stb_vermerk              IS DISTINCT FROM OLD.stb_vermerk
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
