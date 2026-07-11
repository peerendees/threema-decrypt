-- BER-92 · Phase 1 GoBD-Härtung
-- Zeitstempel, Hash-Eindeutigkeit, Unveränderbarkeit, RLS.
-- Idempotent formuliert; Doku: belegchat/docs/GOBD.md, Vault ADR-03.

-- ---------------------------------------------------------------------------
-- 1) archived_at: GoBD-Archivierungszeitstempel pro Belegseite
-- ---------------------------------------------------------------------------

ALTER TABLE public.beleg_seiten
  ADD COLUMN IF NOT EXISTS archived_at timestamptz;

-- Bestandsseiten: Upload-Zeitpunkt ≈ created_at (Insert erfolgte unmittelbar
-- nach dem Storage-Upload durch die Edge Function)
UPDATE public.beleg_seiten
   SET archived_at = created_at
 WHERE archived_at IS NULL;

ALTER TABLE public.beleg_seiten
  ALTER COLUMN archived_at SET DEFAULT now();
ALTER TABLE public.beleg_seiten
  ALTER COLUMN archived_at SET NOT NULL;

COMMENT ON COLUMN public.beleg_seiten.archived_at IS
  'Zeitpunkt des Storage-Uploads (Edge-Action archive-beleg-seite) — GoBD-Archivierungszeitstempel';

-- ---------------------------------------------------------------------------
-- 2) Hash-Format: SHA-256 als 64 Hex-Zeichen (lowercase)
-- ---------------------------------------------------------------------------

ALTER TABLE public.beleg_seiten
  DROP CONSTRAINT IF EXISTS beleg_seiten_gobd_hash_format;
ALTER TABLE public.beleg_seiten
  ADD CONSTRAINT beleg_seiten_gobd_hash_format
  CHECK (gobd_hash ~ '^[0-9a-f]{64}$');

ALTER TABLE public.belege
  DROP CONSTRAINT IF EXISTS belege_gobd_hash_format;
ALTER TABLE public.belege
  ADD CONSTRAINT belege_gobd_hash_format
  CHECK (gobd_hash IS NULL OR gobd_hash ~ '^[0-9a-f]{64}$');

-- ---------------------------------------------------------------------------
-- 3) Hash-Eindeutigkeit: identischer Beleg pro Mandant nur einmal
--    (belege.gobd_hash = Hash der ersten Seite)
-- ---------------------------------------------------------------------------

CREATE UNIQUE INDEX IF NOT EXISTS idx_belege_mandant_gobd_hash
  ON public.belege (mandant_id, gobd_hash)
  WHERE gobd_hash IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 4) audit_log: Aktion 'seite_archiviert' zulassen
-- ---------------------------------------------------------------------------

ALTER TABLE public.audit_log
  DROP CONSTRAINT IF EXISTS audit_log_aktion_check;
ALTER TABLE public.audit_log
  ADD CONSTRAINT audit_log_aktion_check
  CHECK (aktion IN ('status_change', 'konto_geaendert', 'export',
                    'erstellt', 'abgelehnt', 'seite_archiviert'));

-- ---------------------------------------------------------------------------
-- 5) audit_log: append-only (GoBD — Protokoll unveränderlich)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.fn_audit_log_append_only()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'audit_log ist append-only (GoBD): % nicht erlaubt', TG_OP;
END;
$$;

DROP TRIGGER IF EXISTS trg_audit_log_append_only ON public.audit_log;
CREATE TRIGGER trg_audit_log_append_only
  BEFORE UPDATE OR DELETE ON public.audit_log
  FOR EACH ROW EXECUTE FUNCTION public.fn_audit_log_append_only();

-- ---------------------------------------------------------------------------
-- 6) belege: Festschreibung ab Status 'geprueft'
--    Erlaubt bleiben nur: Statuswechsel geprueft → exportiert sowie
--    datev_export_id, export_datum, updated_at (Export-Prozess).
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.fn_belege_festschreibung()
RETURNS trigger
LANGUAGE plpgsql
AS $$
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
$$;

DROP TRIGGER IF EXISTS trg_belege_festschreibung ON public.belege;
CREATE TRIGGER trg_belege_festschreibung
  BEFORE UPDATE OR DELETE ON public.belege
  FOR EACH ROW EXECUTE FUNCTION public.fn_belege_festschreibung();

-- ---------------------------------------------------------------------------
-- 7) beleg_seiten: Originale sind unveränderlich
--    UPDATE generell verboten; DELETE nur solange der zugehörige Beleg
--    nicht festgeschrieben ist (Kaskade beim Löschen offener Belege bleibt
--    möglich, da der Beleg-Trigger festgeschriebene Belege bereits schützt).
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.fn_beleg_seiten_unveraenderbar()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'UPDATE' THEN
    RAISE EXCEPTION 'beleg_seiten sind unveränderlich (GoBD-Original, Seite %)', OLD.seite_nr;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.belege b
     WHERE b.id = OLD.beleg_id
       AND b.status IN ('geprueft', 'exportiert')
  ) THEN
    RAISE EXCEPTION 'Seite % gehört zu festgeschriebenem Beleg und darf nicht gelöscht werden (GoBD)',
      OLD.seite_nr;
  END IF;

  RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS trg_beleg_seiten_unveraenderbar ON public.beleg_seiten;
CREATE TRIGGER trg_beleg_seiten_unveraenderbar
  BEFORE UPDATE OR DELETE ON public.beleg_seiten
  FOR EACH ROW EXECUTE FUNCTION public.fn_beleg_seiten_unveraenderbar();

-- ---------------------------------------------------------------------------
-- 8) RLS: pending_belege + beleg_seiten absichern
--    Keine Policies — Zugriff ausschließlich via Service Role (n8n, Edge).
--    Mandanten-Policies für das Dashboard folgen in Phase 3 (BER-93).
-- ---------------------------------------------------------------------------

ALTER TABLE public.pending_belege ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.beleg_seiten ENABLE ROW LEVEL SECURITY;

-- Offene Public-INSERT-Policy entfernen: audit_log wird nur noch per
-- Service Role beschrieben (n8n); anon/authenticated haben keinen Schreibzugriff.
DROP POLICY IF EXISTS audit_insert ON public.audit_log;
