-- ============================================================================
-- BER-122 Stufe 1: Mehrere MwSt-Saetze pro Beleg — Datenmodell + Trigger
--
-- Additive Erweiterung: ein Beleg kann n Steuerzeilen tragen. Der GESAMTE
-- Bestand und alle kuenftigen Ein-Satz-Belege bleiben unveraendert im
-- Ein-Satz-Modus (belege.mwst_satz / belege.bu_schluessel) — es findet KEINE
-- Rueckmigration statt. Der Mehrsatz-Modus entsteht ausschliesslich fuer neue,
-- noch offene Belege ueber diese Satellitentabelle.
--
-- Semantik:
--   0 Zeilen  = Ein-Satz-Beleg wie heute (belege.mwst_satz/bu_schluessel gelten)
--   1 Zeile   = verboten (dann Ein-Satz-Modus verwenden)
--   >= 2 Zeilen = Mehrsatz-Beleg: die Zeilen sind die Wahrheit,
--               belege.mwst_satz und belege.bu_schluessel sind dann NULL,
--               die Zeilensummen entsprechen den Belegbetraegen auf den Cent.
--
-- Diese Stufe liefert NUR das Datenmodell samt Absicherung. App (Freigabe,
-- Steuerzeilen-Editor), DATEV-Export (belegRow -> belegRows) und n8n folgen als
-- eigene Stories — bis dahin schreibt niemand Zeilen, das Verhalten des Systems
-- ist unveraendert.
--
-- Spec: specs/BER-122.md (belegchat) · Muster: fn_beleg_seiten_unveraenderbar
-- (Festschreibung) und fn_beleg_seiten_insert_guard (SECURITY DEFINER statt
-- rekursiver Policy-Selbstreferenz, 42P17-Befund Baulauf S1 vom 23.07.2026).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1) Tabelle
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.beleg_steuerzeilen (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  beleg_id      uuid NOT NULL REFERENCES public.belege(id) ON DELETE CASCADE,
  pos           smallint NOT NULL CHECK (pos > 0),
  mwst_satz     numeric(5,2) NOT NULL,
  betrag_netto  numeric(12,2) NOT NULL,
  mwst_betrag   numeric(12,2) NOT NULL,
  betrag_brutto numeric(12,2) GENERATED ALWAYS AS (betrag_netto + mwst_betrag) STORED,
  bu_schluessel varchar(4) CHECK (bu_schluessel IS NULL OR bu_schluessel ~ '^[0-9]{1,4}$'),
  created_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (beleg_id, pos)
);

CREATE INDEX IF NOT EXISTS idx_beleg_steuerzeilen_beleg
  ON public.beleg_steuerzeilen (beleg_id);

COMMENT ON TABLE public.beleg_steuerzeilen IS
  'BER-122: Steuerzeilen eines Mehrsatz-Belegs (7 % / 19 % nebeneinander). '
  '0 Zeilen = Ein-Satz-Beleg (Regelfall, gesamter Bestand); >= 2 Zeilen = Mehrsatz. '
  'Genau 1 Zeile ist verboten. Eigener Festschreibungs-Schutz (GoBD).';
COMMENT ON COLUMN public.beleg_steuerzeilen.pos IS
  'Laufende Nummer der Steuerzeile im Beleg (1-basiert), eindeutig je Beleg.';
COMMENT ON COLUMN public.beleg_steuerzeilen.betrag_brutto IS
  'Generiert aus betrag_netto + mwst_betrag — im DATEV-Export der Umsatz dieser Zeile.';
COMMENT ON COLUMN public.beleg_steuerzeilen.bu_schluessel IS
  'BU-/Steuerschluessel dieser Zeile (BER-117-Mapping ueber steuerschluessel.mwst_satz).';

-- ---------------------------------------------------------------------------
-- 2) Konsistenz: Mehrzeilen-Invarianten
--
--    Diese Regeln sind NICHT je Zeile pruefbar — beim Einfuegen von zwei Zeilen
--    existiert nach der ersten Zeile genau 1 Zeile (verboten) und die Summe
--    stimmt noch nicht. Deshalb DEFERRABLE INITIALLY DEFERRED: der Trigger
--    feuert am Transaktionsende gegen den Endzustand.
--
--    SECURITY DEFINER (Eigentuemer postgres, BYPASSRLS) liest den wahren
--    Bestand ohne erneute Policy-Auswertung — dasselbe Muster wie
--    fn_beleg_seiten_insert_guard, das die 42P17-Rekursion aufgeloest hat.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.fn_beleg_steuerzeilen_konsistenz()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_ids        uuid[];
  v_id         uuid;
  v_anzahl     integer;
  v_sum_netto  numeric(12,2);
  v_sum_mwst   numeric(12,2);
  v_sum_brutto numeric(12,2);
  v_beleg_nr   text;
  v_mwst_satz  numeric(5,2);
  v_bu         varchar(4);
  v_netto      numeric(12,2);
  v_mwst       numeric(12,2);
  v_brutto     numeric(12,2);
BEGIN
  -- Betroffene Belege einsammeln: der Trigger haengt an beiden Seiten der
  -- Beziehung, damit die Regel nicht ueber belege umgangen werden kann.
  IF TG_TABLE_NAME = 'belege' THEN
    v_ids := ARRAY[NEW.id];
  ELSIF TG_OP = 'INSERT' THEN
    v_ids := ARRAY[NEW.beleg_id];
  ELSIF TG_OP = 'DELETE' THEN
    v_ids := ARRAY[OLD.beleg_id];
  ELSE
    v_ids := ARRAY[OLD.beleg_id, NEW.beleg_id];
  END IF;

  FOREACH v_id IN ARRAY v_ids LOOP
    SELECT beleg_nr, mwst_satz, bu_schluessel, betrag_netto, mwst_betrag, betrag_brutto
      INTO v_beleg_nr, v_mwst_satz, v_bu, v_netto, v_mwst, v_brutto
      FROM public.belege WHERE id = v_id;

    -- Beleg existiert nicht mehr (Kaskade beim Loeschen eines offenen Belegs):
    -- nichts zu pruefen.
    CONTINUE WHEN NOT FOUND;

    SELECT count(*),
           COALESCE(sum(betrag_netto),  0),
           COALESCE(sum(mwst_betrag),   0),
           COALESCE(sum(betrag_brutto), 0)
      INTO v_anzahl, v_sum_netto, v_sum_mwst, v_sum_brutto
      FROM public.beleg_steuerzeilen WHERE beleg_id = v_id;

    -- 0 Zeilen = Ein-Satz-Beleg: der Regelfall, keine weitere Pruefung.
    CONTINUE WHEN v_anzahl = 0;

    IF v_anzahl = 1 THEN
      RAISE EXCEPTION
        'Beleg %: genau eine Steuerzeile ist nicht zulaessig — 0 Zeilen = Ein-Satz-Beleg, ab 2 Zeilen Mehrsatz-Beleg (BER-122)',
        v_beleg_nr;
    END IF;

    IF v_mwst_satz IS NOT NULL OR v_bu IS NOT NULL THEN
      RAISE EXCEPTION
        'Beleg %: Steuerzeilen und Einzelsatz schliessen sich aus — belege.mwst_satz und belege.bu_schluessel muessen NULL sein (BER-122)',
        v_beleg_nr;
    END IF;

    IF v_sum_netto  IS DISTINCT FROM v_netto
       OR v_sum_mwst   IS DISTINCT FROM v_mwst
       OR v_sum_brutto IS DISTINCT FROM v_brutto THEN
      RAISE EXCEPTION
        'Beleg %: Steuerzeilen summieren nicht auf den Belegbetrag (Zeilen netto/mwst/brutto = %/%/%, Beleg = %/%/%) (BER-122)',
        v_beleg_nr, v_sum_netto, v_sum_mwst, v_sum_brutto, v_netto, v_mwst, v_brutto;
    END IF;
  END LOOP;

  RETURN NULL;
END
$function$;

DROP TRIGGER IF EXISTS trg_beleg_steuerzeilen_konsistenz ON public.beleg_steuerzeilen;
CREATE CONSTRAINT TRIGGER trg_beleg_steuerzeilen_konsistenz
  AFTER INSERT OR UPDATE OR DELETE ON public.beleg_steuerzeilen
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION public.fn_beleg_steuerzeilen_konsistenz();

-- Gegenrichtung: ohne diesen Trigger liesse sich belege.mwst_satz nachtraeglich
-- wieder setzen, waehrend Steuerzeilen existieren — die Ausschlussregel waere
-- umgehbar. (belege.bu_schluessel ist nach BER-119 auch nach der Festschreibung
-- einmalig NULL -> Wert setzbar, faellt also ebenfalls hierunter.)
DROP TRIGGER IF EXISTS trg_belege_steuerzeilen_konsistenz ON public.belege;
CREATE CONSTRAINT TRIGGER trg_belege_steuerzeilen_konsistenz
  AFTER UPDATE ON public.belege
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION public.fn_beleg_steuerzeilen_konsistenz();

-- ---------------------------------------------------------------------------
-- 3) Festschreibung: Zeilen eines festgeschriebenen Belegs sind unveraenderlich
--
--    Strenger als beleg_seiten: dort ist INSERT nach der Festschreibung in
--    einem Fall erlaubt (BER-118, Dokument nachreichen). Steuerzeilen tragen
--    Buchungsbetraege — nach der Festschreibung gibt es keinen zulaessigen
--    Schreibvorgang mehr.
--
--    Die Kaskade beim Loeschen OFFENER Belege bleibt moeglich: dort ist die
--    belege-Zeile beim Feuern bereits fort (NOT FOUND) und der
--    Festschreibungs-Trigger auf belege schuetzt geprueft/exportiert ohnehin.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.fn_beleg_steuerzeilen_unveraenderbar()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_beleg_id uuid;
  v_status   text;
  v_beleg_nr text;
BEGIN
  IF TG_OP = 'DELETE' THEN
    v_beleg_id := OLD.beleg_id;
  ELSE
    v_beleg_id := NEW.beleg_id;
  END IF;

  SELECT status, beleg_nr INTO v_status, v_beleg_nr
    FROM public.belege WHERE id = v_beleg_id;

  IF FOUND AND v_status IN ('geprueft', 'exportiert') THEN
    RAISE EXCEPTION
      'Beleg % ist festgeschrieben (Status %): Steuerzeilen sind unveraenderlich (GoBD, BER-122)',
      v_beleg_nr, v_status;
  END IF;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END
$function$;

DROP TRIGGER IF EXISTS trg_beleg_steuerzeilen_unveraenderbar ON public.beleg_steuerzeilen;
CREATE TRIGGER trg_beleg_steuerzeilen_unveraenderbar
  BEFORE INSERT OR UPDATE OR DELETE ON public.beleg_steuerzeilen
  FOR EACH ROW EXECUTE FUNCTION public.fn_beleg_steuerzeilen_unveraenderbar();

-- ---------------------------------------------------------------------------
-- 4) RLS: Mandantenisolation ueber den Join auf belege
--
--    beleg_steuerzeilen traegt selbst keine mandant_id — die Isolation laeuft
--    ausschliesslich ueber belege.mandant_id = app.mandant_id (ADR-05).
--    KEIN Selbstbezug auf beleg_steuerzeilen in den Policies (42P17).
--    service_role (n8n, Edge) schreibt weiterhin an RLS vorbei.
-- ---------------------------------------------------------------------------

ALTER TABLE public.beleg_steuerzeilen ENABLE ROW LEVEL SECURITY;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.beleg_steuerzeilen TO dashboard_service;

DROP POLICY IF EXISTS dash_steuerzeilen_select ON public.beleg_steuerzeilen;
CREATE POLICY dash_steuerzeilen_select ON public.beleg_steuerzeilen
  FOR SELECT TO dashboard_service
  USING (EXISTS (
    SELECT 1 FROM public.belege b
     WHERE b.id = beleg_steuerzeilen.beleg_id
       AND b.mandant_id = (NULLIF(current_setting('app.mandant_id', true), ''))::uuid
  ));

DROP POLICY IF EXISTS dash_steuerzeilen_insert ON public.beleg_steuerzeilen;
CREATE POLICY dash_steuerzeilen_insert ON public.beleg_steuerzeilen
  FOR INSERT TO dashboard_service
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.belege b
     WHERE b.id = beleg_steuerzeilen.beleg_id
       AND b.mandant_id = (NULLIF(current_setting('app.mandant_id', true), ''))::uuid
  ));

DROP POLICY IF EXISTS dash_steuerzeilen_update ON public.beleg_steuerzeilen;
CREATE POLICY dash_steuerzeilen_update ON public.beleg_steuerzeilen
  FOR UPDATE TO dashboard_service
  USING (EXISTS (
    SELECT 1 FROM public.belege b
     WHERE b.id = beleg_steuerzeilen.beleg_id
       AND b.mandant_id = (NULLIF(current_setting('app.mandant_id', true), ''))::uuid
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.belege b
     WHERE b.id = beleg_steuerzeilen.beleg_id
       AND b.mandant_id = (NULLIF(current_setting('app.mandant_id', true), ''))::uuid
  ));

DROP POLICY IF EXISTS dash_steuerzeilen_delete ON public.beleg_steuerzeilen;
CREATE POLICY dash_steuerzeilen_delete ON public.beleg_steuerzeilen
  FOR DELETE TO dashboard_service
  USING (EXISTS (
    SELECT 1 FROM public.belege b
     WHERE b.id = beleg_steuerzeilen.beleg_id
       AND b.mandant_id = (NULLIF(current_setting('app.mandant_id', true), ''))::uuid
  ));

-- ============================================================================
-- Nach dem Anwenden: specs/migrations/20260808_ber122_trigger_tests.sql laufen
-- lassen (Rollback-Transaktion am Test-Mandanten Firma 99).
-- ============================================================================
