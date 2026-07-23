-- ============================================================================
-- KONSOLIDIERTE MIGRATION — StB-Rückmeldung 22.07.2026 (BER-116/117/118/119/121)
--
-- Ablage: specs/migrations/ im belegchat-Repo (Spec-Anhang, NICHT automatisch
-- angewendet). Baulauf-Schritt S1 kopiert diese Datei UNVERÄNDERT nach
--   threema-decrypt/supabase/migrations/<JJJJMMTThhmmss>_stb_rueckmeldung_konsolidiert.sql
-- und wendet sie per Supabase-MCP `apply_migration` an (eine Transaktion).
--
-- Warum EINE Migration: Alle vier Stories schreiben fn_belege_festschreibung.
-- Bei getrennten Migrationen gewinnt der letzte CREATE OR REPLACE und wirft die
-- Spalten der anderen still von der Sperrliste (Validierungsbericht 22.07.2026).
--
-- Kernentscheidung: fn_belege_festschreibung wechselt von Blacklist auf
-- WHITELIST (Strukturprüfung 23.07.2026, §2.1) — jede nicht ausdrücklich
-- freigegebene Spalte ist nach der Festschreibung eingefroren. Die Blacklist
-- hatte sechs exportrelevante Spalten verloren (bewirtung_anlass/-teilnehmer,
-- trinkgeld, termin_grund/-ort/-kunde).
--
-- Verhalten idempotent formuliert (IF NOT EXISTS / DROP IF EXISTS), Muster wie
-- 20260711075401_post_alpha_gobd_hardening.sql.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1) belege: neue Buchungssatz-Felder (BER-116/117/118)
-- ----------------------------------------------------------------------------

ALTER TABLE public.belege
  ADD COLUMN IF NOT EXISTS zahlungsweg    text,
  ADD COLUMN IF NOT EXISTS gegenkonto     varchar(10),
  ADD COLUMN IF NOT EXISTS bu_schluessel  varchar(4),
  ADD COLUMN IF NOT EXISTS dokument_fehlt boolean NOT NULL DEFAULT false;

ALTER TABLE public.belege DROP CONSTRAINT IF EXISTS belege_zahlungsweg_check;
ALTER TABLE public.belege ADD CONSTRAINT belege_zahlungsweg_check
  CHECK (zahlungsweg IS NULL
         OR zahlungsweg IN ('geschaeftskonto', 'alternativkonto', 'privat'));

ALTER TABLE public.belege DROP CONSTRAINT IF EXISTS belege_gegenkonto_format;
ALTER TABLE public.belege ADD CONSTRAINT belege_gegenkonto_format
  CHECK (gegenkonto IS NULL OR gegenkonto ~ '^[0-9]{4,9}$');

ALTER TABLE public.belege DROP CONSTRAINT IF EXISTS belege_bu_schluessel_format;
ALTER TABLE public.belege ADD CONSTRAINT belege_bu_schluessel_format
  CHECK (bu_schluessel IS NULL OR bu_schluessel ~ '^[0-9]{1,4}$');

-- Zahlungsweg und Gegenkonto nur paarweise (beide NULL oder beide gesetzt)
ALTER TABLE public.belege DROP CONSTRAINT IF EXISTS belege_zahlungsweg_gegenkonto_paar;
ALTER TABLE public.belege ADD CONSTRAINT belege_zahlungsweg_gegenkonto_paar
  CHECK ((zahlungsweg IS NULL) = (gegenkonto IS NULL));

COMMENT ON COLUMN public.belege.zahlungsweg IS
  'Zahlungsweg des Belegs, Pflichtauswahl bei der Freigabe ohne Vorbelegung: geschaeftskonto | alternativkonto | privat (BER-116)';
COMMENT ON COLUMN public.belege.gegenkonto IS
  'Bei der Freigabe aus zahlungsweg + Firmen-Konfiguration aufgelöstes DATEV-Gegenkonto (Spalte 8 im EXTF); am Beleg festgeschrieben, damit Re-Exports von späteren Konfigurationsänderungen unabhängig sind (BER-116)';
COMMENT ON COLUMN public.belege.bu_schluessel IS
  'DATEV-BU-/Steuerschlüssel (Spalte 9 im EXTF), vorbelegt aus steuerschluessel-Konfiguration, nur bei vorsteuerrelevantem Sachkonto; NULL = ohne Schlüssel (BER-117)';
COMMENT ON COLUMN public.belege.dokument_fehlt IS
  'true = Buchungssatz ohne Originaldokument erfasst (BER-118); wird ausschließlich von der Dokument-Upload-Route auf false gesetzt, gekoppelt an gobd_hash NULL→Wert. Kennzeichnung erscheint im DATEV-Export (Zusatzinformation 2)';

-- ----------------------------------------------------------------------------
-- 2) firmen: Konten für die drei Zahlungswege (BER-116)
--    datev_gegenkonto ('1800') bleibt der Geschäftskonto-Fall.
-- ----------------------------------------------------------------------------

ALTER TABLE public.firmen
  ADD COLUMN IF NOT EXISTS datev_gegenkonto_alternativ varchar(10) NOT NULL DEFAULT '1810',
  ADD COLUMN IF NOT EXISTS datev_gegenkonto_privat     varchar(10) NOT NULL DEFAULT '2100';

COMMENT ON COLUMN public.firmen.datev_gegenkonto_alternativ IS
  'Gegenkonto für zahlungsweg=alternativkonto: 1810 = Geschäftszahlungen über andere Karten/Konten, zur Abgrenzung vom Geschäftskonto 1800 (bestätigt vom Betreiber 23.07.2026) (BER-116)';
COMMENT ON COLUMN public.firmen.datev_gegenkonto_privat IS
  'Gegenkonto für zahlungsweg=privat: 2100 Privatkonto, vom StB vorgegeben (22.07.2026); Hinweis: 2180 Privateinlagen wäre die strengere Buchung — bewusst 2100 (BER-116)';

-- ----------------------------------------------------------------------------
-- 3) steuerschluessel: Zuordnung MwSt-Satz → BU-Schlüssel je Firma (BER-117)
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.steuerschluessel (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  firma_nr      char(2) NOT NULL REFERENCES public.firmen(firma_nr),
  typ           text NOT NULL DEFAULT 'vorsteuer'
                CHECK (typ IN ('vorsteuer', 'umsatzsteuer')),
  mwst_satz     numeric(5,2) NOT NULL,
  bu_schluessel varchar(4) NOT NULL CHECK (bu_schluessel ~ '^[0-9]{1,4}$'),
  bezeichnung   text NOT NULL,
  bestaetigt    boolean NOT NULL DEFAULT false,
  aktiv         boolean NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (firma_nr, typ, mwst_satz)
);

COMMENT ON TABLE public.steuerschluessel IS
  'Konfiguration MwSt-Satz → DATEV-BU-Schlüssel je Firma (BER-117). typ=umsatzsteuer ist für die Erlösseite reserviert. bestaetigt=true nur für kanzleibestätigte Zuordnungen (90/80 bestätigt 23.07.2026). Pflege v1 per SQL durch den Betreiber.';

ALTER TABLE public.steuerschluessel ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS dash_steuerschluessel_select ON public.steuerschluessel;
CREATE POLICY dash_steuerschluessel_select ON public.steuerschluessel
  FOR SELECT TO dashboard_service USING (true);

GRANT SELECT ON public.steuerschluessel TO dashboard_service;

-- Seeds: von der Kanzlei bestätigte Schreibweise 90/80 (Antwort übermittelt vom
-- Betreiber am 23.07.2026, docs/OFFENE-FRAGEN-STB.md Frage 1 → beantwortet).
-- Hinweis für den Testimport: die DATEV-Standardnotation wäre einstellig (9/8);
-- sollte der ASCII-Import 90/80 beanstanden, genügt ein UPDATE dieser Zeilen.
INSERT INTO public.steuerschluessel (firma_nr, typ, mwst_satz, bu_schluessel, bezeichnung, bestaetigt)
VALUES
  ('01', 'vorsteuer', 19.00, '90', 'Vorsteuer 19 %', true),
  ('01', 'vorsteuer',  7.00, '80', 'Vorsteuer 7 %',  true),
  ('99', 'vorsteuer', 19.00, '90', 'Vorsteuer 19 %', true),
  ('99', 'vorsteuer',  7.00, '80', 'Vorsteuer 7 %',  true)
ON CONFLICT (firma_nr, typ, mwst_satz) DO NOTHING;

-- ----------------------------------------------------------------------------
-- 4) datev_exporte: Inhalt, Hash, Fassungen (BER-121)
-- ----------------------------------------------------------------------------

ALTER TABLE public.datev_exporte
  ADD COLUMN IF NOT EXISTS version           smallint NOT NULL DEFAULT 1 CHECK (version >= 1),
  ADD COLUMN IF NOT EXISTS wurzel_export_id  uuid REFERENCES public.datev_exporte(id),
  ADD COLUMN IF NOT EXISTS ersetzt_export_id uuid REFERENCES public.datev_exporte(id),
  ADD COLUMN IF NOT EXISTS korrektur_grund   text,
  ADD COLUMN IF NOT EXISTS inhalts_hash      text,
  ADD COLUMN IF NOT EXISTS datei_inhalt      bytea,
  ADD COLUMN IF NOT EXISTS eingefroren_am    timestamptz;

ALTER TABLE public.datev_exporte DROP CONSTRAINT IF EXISTS datev_exporte_inhalts_hash_format;
ALTER TABLE public.datev_exporte ADD CONSTRAINT datev_exporte_inhalts_hash_format
  CHECK (inhalts_hash IS NULL OR inhalts_hash ~ '^[0-9a-f]{64}$');

-- Korrekturfassung: Referenzpaar + Grund sind Pflicht, Erstfassung hat keines von beiden
ALTER TABLE public.datev_exporte DROP CONSTRAINT IF EXISTS datev_exporte_korrektur_konsistent;
ALTER TABLE public.datev_exporte ADD CONSTRAINT datev_exporte_korrektur_konsistent
  CHECK (
    ((ersetzt_export_id IS NULL) = (wurzel_export_id IS NULL))
    AND (ersetzt_export_id IS NULL OR korrektur_grund IS NOT NULL)
    AND ((version = 1) = (ersetzt_export_id IS NULL))
  );

-- Jede Fassung ist höchstens einmal ersetzbar (keine zwei parallelen Korrekturen)
CREATE UNIQUE INDEX IF NOT EXISTS idx_datev_exporte_ersetzt_einmal
  ON public.datev_exporte (ersetzt_export_id)
  WHERE ersetzt_export_id IS NOT NULL;

-- Status-Lebenszyklus um 'ersetzt' erweitern
ALTER TABLE public.datev_exporte DROP CONSTRAINT IF EXISTS datev_exporte_status_check;
ALTER TABLE public.datev_exporte ADD CONSTRAINT datev_exporte_status_check
  CHECK (status = ANY (ARRAY['erstellt','validiert','uebertragen','fehler','ersetzt']::text[]));

COMMENT ON COLUMN public.datev_exporte.version IS
  'Fassungszähler je Stapel-Wurzel; 1 = Erstfassung (BER-121)';
COMMENT ON COLUMN public.datev_exporte.wurzel_export_id IS
  'NULL = selbst Wurzel; Korrekturfassungen zeigen auf die Version-1-Zeile. Code liest COALESCE(wurzel_export_id, id)';
COMMENT ON COLUMN public.datev_exporte.ersetzt_export_id IS
  'Unmittelbar ersetzte Fassung (Korrektur ist eine NEUE Zeile, keine stille Ersetzung)';
COMMENT ON COLUMN public.datev_exporte.inhalts_hash IS
  'SHA-256 (hex) über die Dateibytes; DB-verifizierbar: encode(sha256(datei_inhalt), ''hex'')';
COMMENT ON COLUMN public.datev_exporte.datei_inhalt IS
  'Die ausgelieferte EXTF-Datei (Latin-1-Bytes). Re-Download liefert exakt diese Bytes';
COMMENT ON COLUMN public.datev_exporte.eingefroren_am IS
  'Ab diesem Zeitpunkt sind Inhalt und Metadaten der Fassung unveränderlich (Trigger fn_datev_exporte_schutz)';

GRANT UPDATE (status, fehler_details, inhalts_hash, datei_inhalt, eingefroren_am, datei_groesse_bytes)
  ON public.datev_exporte TO dashboard_service;

DROP POLICY IF EXISTS dash_datev_update ON public.datev_exporte;
CREATE POLICY dash_datev_update ON public.datev_exporte
  FOR UPDATE TO dashboard_service
  USING (mandant_id = NULLIF(current_setting('app.mandant_id', true), '')::uuid)
  WITH CHECK (mandant_id = NULLIF(current_setting('app.mandant_id', true), '')::uuid);

-- ----------------------------------------------------------------------------
-- 5) audit_log: Export-Ereignisse ohne Einzelbeleg + neue Aktionen
-- ----------------------------------------------------------------------------

ALTER TABLE public.audit_log ALTER COLUMN beleg_id DROP NOT NULL;

ALTER TABLE public.audit_log DROP CONSTRAINT IF EXISTS audit_log_beleg_id_pflicht;
ALTER TABLE public.audit_log ADD CONSTRAINT audit_log_beleg_id_pflicht
  CHECK (beleg_id IS NOT NULL OR aktion IN ('export_eingefroren', 'export_ersetzt'));

ALTER TABLE public.audit_log DROP CONSTRAINT IF EXISTS audit_log_aktion_check;
ALTER TABLE public.audit_log ADD CONSTRAINT audit_log_aktion_check
  CHECK (aktion = ANY (ARRAY[
    'status_change', 'konto_geaendert', 'export', 'erstellt', 'abgelehnt',
    'seite_archiviert', 'beleg_freigegeben', 'dokumentation_bestaetigt',
    'teilbetrag_gebucht',
    'zahlungsweg_gesetzt',            -- BER-116 (Freigabe)
    'steuerschluessel_gesetzt',       -- BER-117 (Freigabe, Setzen und Ändern)
    'dokument_nachgereicht',          -- BER-118
    'nacherfassung_zahlungsweg',      -- BER-119 (Anlass im neuer_wert)
    'nacherfassung_steuerschluessel', -- BER-119 (Anlass im neuer_wert)
    'export_eingefroren',             -- BER-121 (beleg_id NULL erlaubt)
    'export_ersetzt'                  -- BER-121 (beleg_id NULL erlaubt)
  ]::text[]));

-- ----------------------------------------------------------------------------
-- 6) log_beleg_aenderungen: mandant_id mitstempeln (Nebenbefund Strukturprüfung
--    §1.9 — bisher trugen Trigger-Audit-Zeilen mandant_id NULL und waren für
--    die mandantenscopierte RLS-Sicht unsichtbar; 125 Altzeilen bleiben NULL,
--    audit_log ist append-only. Mandantenscopierte Auswertungen joinen über
--    beleg_id → belege.mandant_id).
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.log_beleg_aenderungen()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF OLD.status IS DISTINCT FROM NEW.status THEN
    INSERT INTO public.audit_log (beleg_id, aktion, alter_wert, neuer_wert, user_id, mandant_id)
    VALUES (NEW.id, 'status_change', OLD.status, NEW.status, auth.uid(), NEW.mandant_id);
  END IF;
  IF OLD.sachkonto IS DISTINCT FROM NEW.sachkonto THEN
    INSERT INTO public.audit_log (beleg_id, aktion, alter_wert, neuer_wert, user_id, mandant_id)
    VALUES (NEW.id, 'konto_geaendert', OLD.sachkonto, NEW.sachkonto, auth.uid(), NEW.mandant_id);
  END IF;
  RETURN NEW;
END;
$function$;

-- ----------------------------------------------------------------------------
-- 7) fn_belege_festschreibung — ENDFASSUNG (Whitelist)
--
-- Ersetzt die Blacklist-Fassung aus 20260719221107_stb_vermerk.sql vollständig.
-- Semantik ab Status geprueft/exportiert:
--   * ALLE Spalten eingefroren, außer:
--     - status:           einzig geprueft → exportiert
--     - datev_export_id:  einmalig NULL → Wert (Export-Prozess)
--     - export_datum:     einmalig NULL → Wert (Export-Prozess)
--     - updated_at:       frei (technischer Zeitstempel, Trigger belege_updated_at)
--     - zahlungsweg:      einmalig NULL → Wert, nur gemeinsam mit gegenkonto (BER-119)
--     - gegenkonto:       einmalig NULL → Wert, nur gemeinsam mit zahlungsweg (BER-119)
--     - bu_schluessel:    einmalig NULL → Wert (BER-119)
--     - gobd_hash:        einmalig NULL → Wert, nur gemeinsam mit bild_storage_path (BER-118)
--     - bild_storage_path: einmalig NULL → Wert, nur gemeinsam mit gobd_hash (BER-118)
--     - dokument_fehlt:   einzig true → false, nur im selben UPDATE wie gobd_hash NULL → Wert (BER-118)
--   * DELETE bleibt verboten.
--   * Damit sind auch die sechs bisher fehlenden Spalten (bewirtung_anlass,
--     bewirtung_teilnehmer, trinkgeld, termin_grund, termin_ort, termin_kunde)
--     sowie stb_vermerk und JEDE künftige Spalte automatisch eingefroren.
--   * buchungsjahr/-quartal/-monat (generierte Spalten) sind vom jsonb-Vergleich
--     ausgenommen: ihr Wert hängt allein am (eingefrorenen) beleg_datum, und
--     generierte Spalten sind in NEW eines BEFORE-Triggers nicht verlässlich
--     befüllt.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.fn_belege_festschreibung()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
  erlaubte_spalten CONSTANT text[] := ARRAY[
    'status', 'datev_export_id', 'export_datum', 'updated_at',
    'zahlungsweg', 'gegenkonto', 'bu_schluessel',
    'gobd_hash', 'bild_storage_path', 'dokument_fehlt'
  ];
  vergleich_ausgenommen CONSTANT text[] := ARRAY[
    'status', 'datev_export_id', 'export_datum', 'updated_at',
    'zahlungsweg', 'gegenkonto', 'bu_schluessel',
    'gobd_hash', 'bild_storage_path', 'dokument_fehlt',
    'buchungsjahr', 'buchungsquartal', 'buchungsmonat'
  ];
  gesperrt_alt jsonb;
  gesperrt_neu jsonb;
  geaenderte_spalten text;
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

  -- Whitelist-Prüfung: alles außerhalb der Ausnahmen muss identisch bleiben.
  gesperrt_alt := to_jsonb(OLD) - vergleich_ausgenommen;
  gesperrt_neu := to_jsonb(NEW) - vergleich_ausgenommen;
  IF gesperrt_alt IS DISTINCT FROM gesperrt_neu THEN
    SELECT string_agg(spalte, ', ' ORDER BY spalte) INTO geaenderte_spalten
      FROM (
        SELECT a.key AS spalte
          FROM jsonb_each(gesperrt_alt) AS a
         WHERE gesperrt_neu -> a.key IS DISTINCT FROM a.value
        UNION
        SELECT n.key
          FROM jsonb_each(gesperrt_neu) AS n
         WHERE gesperrt_alt -> n.key IS DISTINCT FROM n.value
      ) AS diff(spalte);
    RAISE EXCEPTION 'Beleg % ist festgeschrieben (Status %): GoBD-relevante Felder sind unveränderlich (%)',
      OLD.beleg_nr, OLD.status, geaenderte_spalten;
  END IF;

  -- Status: einzig erlaubter Wechsel geprueft → exportiert
  IF NEW.status IS DISTINCT FROM OLD.status
     AND NOT (OLD.status = 'geprueft' AND NEW.status = 'exportiert') THEN
    RAISE EXCEPTION 'Beleg %: Statuswechsel % → % nicht erlaubt (festgeschrieben)',
      OLD.beleg_nr, OLD.status, NEW.status;
  END IF;

  -- Export-Metadaten: einmalig setzen, danach unveränderlich
  IF NEW.datev_export_id IS DISTINCT FROM OLD.datev_export_id
     AND OLD.datev_export_id IS NOT NULL THEN
    RAISE EXCEPTION 'Beleg %: datev_export_id ist gesetzt und unveränderlich', OLD.beleg_nr;
  END IF;
  IF NEW.export_datum IS DISTINCT FROM OLD.export_datum
     AND OLD.export_datum IS NOT NULL THEN
    RAISE EXCEPTION 'Beleg %: export_datum ist gesetzt und unveränderlich', OLD.beleg_nr;
  END IF;

  -- Append-only-Spalten: einmalig NULL → Wert, nie Wert → anderer Wert / NULL
  IF NEW.zahlungsweg IS DISTINCT FROM OLD.zahlungsweg
     AND (OLD.zahlungsweg IS NOT NULL OR NEW.zahlungsweg IS NULL) THEN
    RAISE EXCEPTION 'Beleg %: zahlungsweg darf nach der Festschreibung nur einmalig von NULL auf einen Wert gesetzt werden (BER-119)', OLD.beleg_nr;
  END IF;
  IF NEW.gegenkonto IS DISTINCT FROM OLD.gegenkonto
     AND (OLD.gegenkonto IS NOT NULL OR NEW.gegenkonto IS NULL) THEN
    RAISE EXCEPTION 'Beleg %: gegenkonto darf nach der Festschreibung nur einmalig von NULL auf einen Wert gesetzt werden (BER-119)', OLD.beleg_nr;
  END IF;
  IF NEW.bu_schluessel IS DISTINCT FROM OLD.bu_schluessel
     AND (OLD.bu_schluessel IS NOT NULL OR NEW.bu_schluessel IS NULL) THEN
    RAISE EXCEPTION 'Beleg %: bu_schluessel darf nach der Festschreibung nur einmalig von NULL auf einen Wert gesetzt werden (BER-119)', OLD.beleg_nr;
  END IF;
  IF NEW.gobd_hash IS DISTINCT FROM OLD.gobd_hash
     AND (OLD.gobd_hash IS NOT NULL OR NEW.gobd_hash IS NULL) THEN
    RAISE EXCEPTION 'Beleg %: gobd_hash darf nach der Festschreibung nur einmalig von NULL auf einen Wert gesetzt werden (BER-118)', OLD.beleg_nr;
  END IF;
  IF NEW.bild_storage_path IS DISTINCT FROM OLD.bild_storage_path
     AND (OLD.bild_storage_path IS NOT NULL OR NEW.bild_storage_path IS NULL) THEN
    RAISE EXCEPTION 'Beleg %: bild_storage_path darf nach der Festschreibung nur einmalig von NULL auf einen Wert gesetzt werden (BER-118)', OLD.beleg_nr;
  END IF;

  -- Kopplungen: nur gemeinsam wandern
  IF (NEW.zahlungsweg IS DISTINCT FROM OLD.zahlungsweg)
     <> (NEW.gegenkonto IS DISTINCT FROM OLD.gegenkonto) THEN
    RAISE EXCEPTION 'Beleg %: zahlungsweg und gegenkonto dürfen nur gemeinsam gesetzt werden', OLD.beleg_nr;
  END IF;
  IF (NEW.gobd_hash IS DISTINCT FROM OLD.gobd_hash)
     <> (NEW.bild_storage_path IS DISTINCT FROM OLD.bild_storage_path) THEN
    RAISE EXCEPTION 'Beleg %: gobd_hash und bild_storage_path dürfen nur gemeinsam gesetzt werden', OLD.beleg_nr;
  END IF;

  -- dokument_fehlt: einzig true → false, gekoppelt an das Nachreichen
  IF NEW.dokument_fehlt IS DISTINCT FROM OLD.dokument_fehlt THEN
    IF NOT (OLD.dokument_fehlt = true AND NEW.dokument_fehlt = false
            AND OLD.gobd_hash IS NULL AND NEW.gobd_hash IS NOT NULL) THEN
      RAISE EXCEPTION 'Beleg %: dokument_fehlt wechselt nur beim Nachreichen des Dokuments (gobd_hash NULL → Wert) auf false (BER-118)', OLD.beleg_nr;
    END IF;
  END IF;

  RETURN NEW;
END;
$function$;

-- Trigger selbst bleibt unverändert bestehen (BEFORE UPDATE OR DELETE, FOR EACH ROW);
-- CREATE OR REPLACE der Funktion genügt. Zur Sicherheit idempotent neu binden:
DROP TRIGGER IF EXISTS trg_belege_festschreibung ON public.belege;
CREATE TRIGGER trg_belege_festschreibung
  BEFORE UPDATE OR DELETE ON public.belege
  FOR EACH ROW EXECUTE FUNCTION public.fn_belege_festschreibung();

-- ----------------------------------------------------------------------------
-- 8) fn_datev_exporte_schutz — Fassungen sind unveränderlich (BER-121)
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.fn_datev_exporte_schutz()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
  -- nach dem Einfrieren nur noch Status-Lebenszyklus + Fehlertext
  frei_nach_einfrieren CONSTANT text[] := ARRAY['status', 'fehler_details'];
  -- vor dem Einfrieren zusätzlich das Einfrieren selbst (Altbestands-Fall BER-119)
  frei_vor_einfrieren CONSTANT text[] := ARRAY[
    'status', 'fehler_details',
    'inhalts_hash', 'datei_inhalt', 'eingefroren_am', 'datei_groesse_bytes'
  ];
  erlaubt text[];
  gesperrt_alt jsonb;
  gesperrt_neu jsonb;
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'datev_exporte sind unveränderlich (GoBD): DELETE nicht erlaubt (%)', OLD.datei_pfad;
  END IF;

  IF TG_OP = 'UPDATE' THEN
    erlaubt := CASE WHEN OLD.eingefroren_am IS NULL
                    THEN frei_vor_einfrieren
                    ELSE frei_nach_einfrieren END;
    gesperrt_alt := to_jsonb(OLD) - erlaubt;
    gesperrt_neu := to_jsonb(NEW) - erlaubt;
    IF gesperrt_alt IS DISTINCT FROM gesperrt_neu THEN
      RAISE EXCEPTION 'Export % (v%): Felder sind nach dem Anlegen unveränderlich (BER-121)',
        OLD.datei_pfad, OLD.version;
    END IF;

    IF NEW.status IS DISTINCT FROM OLD.status
       AND NOT (OLD.status = 'erstellt'
                AND NEW.status IN ('validiert', 'uebertragen', 'fehler', 'ersetzt')) THEN
      RAISE EXCEPTION 'Export %: Statuswechsel % → % nicht erlaubt', OLD.datei_pfad, OLD.status, NEW.status;
    END IF;

    -- Hash/Inhalt/Zeitpunkt nur als vollständiges Einfrier-Paket setzen
    IF OLD.eingefroren_am IS NULL AND NEW.eingefroren_am IS NULL
       AND (NEW.inhalts_hash IS DISTINCT FROM OLD.inhalts_hash
            OR NEW.datei_inhalt IS DISTINCT FROM OLD.datei_inhalt) THEN
      RAISE EXCEPTION 'Export %: inhalts_hash/datei_inhalt nur zusammen mit eingefroren_am setzen', OLD.datei_pfad;
    END IF;
  END IF;

  -- gilt für INSERT und UPDATE: Einfrieren nur vollständig und hash-korrekt
  IF NEW.eingefroren_am IS NOT NULL THEN
    IF NEW.inhalts_hash IS NULL OR NEW.datei_inhalt IS NULL THEN
      RAISE EXCEPTION 'Export %: Einfrieren erfordert inhalts_hash UND datei_inhalt', NEW.datei_pfad;
    END IF;
    IF encode(sha256(NEW.datei_inhalt), 'hex') IS DISTINCT FROM NEW.inhalts_hash THEN
      RAISE EXCEPTION 'Export %: inhalts_hash stimmt nicht mit sha256(datei_inhalt) überein', NEW.datei_pfad;
    END IF;
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_datev_exporte_schutz ON public.datev_exporte;
CREATE TRIGGER trg_datev_exporte_schutz
  BEFORE INSERT OR UPDATE OR DELETE ON public.datev_exporte
  FOR EACH ROW EXECUTE FUNCTION public.fn_datev_exporte_schutz();

-- ----------------------------------------------------------------------------
-- 9) RLS: Seiten-INSERT auch nach der Festschreibung, solange keine Seite hängt
--    (BER-118). Neufassung ersetzt die BER-113-Policy; jetzt ausdrücklich
--    TO dashboard_service (n8n schreibt als service_role an RLS vorbei).
-- ----------------------------------------------------------------------------

DROP POLICY IF EXISTS dash_seiten_insert ON public.beleg_seiten;
CREATE POLICY dash_seiten_insert ON public.beleg_seiten
  FOR INSERT TO dashboard_service
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.belege b
       WHERE b.id = beleg_seiten.beleg_id
         AND b.mandant_id = (NULLIF(current_setting('app.mandant_id', true), ''))::uuid
         AND (
           -- offener Beleg: wie bisher
           b.status = ANY (ARRAY['neu', 'vorschlag', 'klaerungsbedarf'])
           -- festgeschriebener Beleg: Nachreichen genau EINER Datei (BER-118)
           OR (
             b.status = ANY (ARRAY['geprueft', 'exportiert'])
             AND NOT EXISTS (
               SELECT 1 FROM public.beleg_seiten s2
                WHERE s2.beleg_id = beleg_seiten.beleg_id
             )
           )
         )
    )
  );

-- ----------------------------------------------------------------------------
-- 10) Grants belege: neue Spalten für die Dashboard-Rolle
--     (INSERT-Grant ist spaltenweise — neue Spalten explizit nachziehen)
-- ----------------------------------------------------------------------------

GRANT UPDATE (zahlungsweg, gegenkonto, bu_schluessel, dokument_fehlt)
  ON public.belege TO dashboard_service;
GRANT INSERT (dokument_fehlt)
  ON public.belege TO dashboard_service;

-- ----------------------------------------------------------------------------
-- 11) Mandanten-Invariante: höchstens EIN produktiver Mandant je Threema-ID
--     (Strukturprüfung §1.1 — verhindert, dass ein Belegfoto still im falschen
--     Echtbestand landet; heute erfüllt: beide Mandanten nutzen getrennte IDs)
-- ----------------------------------------------------------------------------

CREATE UNIQUE INDEX IF NOT EXISTS idx_mandanten_threema_produktiv
  ON public.mandanten (threema_id)
  WHERE modus = 'produktiv' AND aktiv;

-- ----------------------------------------------------------------------------
-- 12) Hilfs-Indexe für die neuen Abfragen
-- ----------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS idx_belege_dokument_fehlt
  ON public.belege (mandant_id)
  WHERE dokument_fehlt;

CREATE INDEX IF NOT EXISTS idx_belege_nacherfassung
  ON public.belege (mandant_id)
  WHERE status = 'exportiert' AND zahlungsweg IS NULL;

-- ============================================================================
-- ENDE der Migration.
--
-- Nach der Anwendung (Baulauf S1) verifizieren — read-only, erwartete Werte:
--   SELECT count(*) FROM steuerschluessel;                              -- = 4
--   SELECT count(*) FROM information_schema.columns
--    WHERE table_name='belege'
--      AND column_name IN ('zahlungsweg','gegenkonto','bu_schluessel',
--                          'dokument_fehlt');                           -- = 4
--   SELECT count(*) FROM information_schema.columns
--    WHERE table_name='datev_exporte'
--      AND column_name IN ('version','wurzel_export_id','ersetzt_export_id',
--                          'korrektur_grund','inhalts_hash','datei_inhalt',
--                          'eingefroren_am');                           -- = 7
--   SELECT count(*) FROM belege WHERE dokument_fehlt;                   -- = 0
--   SELECT count(*) FROM belege WHERE status='exportiert'
--      AND zahlungsweg IS NULL;                                         -- = 60
--   SELECT tgname FROM pg_trigger
--    WHERE tgrelid='public.datev_exporte'::regclass
--      AND NOT tgisinternal;              -- enthält trg_datev_exporte_schutz
--   SELECT pg_get_functiondef('public.fn_belege_festschreibung'::regproc)
--          LIKE '%erlaubte_spalten%';                                   -- true
-- Verhaltens-Tests: specs/migrations/20260723_trigger_tests.sql
-- (eine Transaktion, endet mit ROLLBACK — hinterlässt nichts).
-- ============================================================================
