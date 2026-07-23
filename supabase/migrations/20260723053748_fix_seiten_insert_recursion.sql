-- ============================================================================
-- KORREKTUR zu 20260723_stb_rueckmeldung_konsolidiert.sql (BER-118)
--
-- Befund im Baulauf S1 (Trigger-Test T10a, 23.07.2026): die dort angelegte
-- Policy dash_seiten_insert referenziert beleg_seiten aus einer Policy AUF
-- beleg_seiten heraus (NOT EXISTS-Subquery) → PostgreSQL wirft
--   42P17: infinite recursion detected in policy for relation "beleg_seiten"
-- sobald eine nicht-BYPASSRLS-Rolle (dashboard_service) einfügt. Kein Live-Pfad
-- war betroffen (n8n schreibt als service_role an RLS vorbei; der manuelle
-- Upload-Pfad ist noch nicht gebaut), aber die Policy ist falsch.
--
-- Fix: Die Policy wird auf reinen Mandanten-Scope reduziert (kein Selbstbezug
-- mehr). Die fachliche Regel „bei festgeschriebenem Beleg genau EIN Dokument
-- nachreichen" (BER-118) übernimmt ein BEFORE-INSERT-Trigger auf beleg_seiten;
-- als SECURITY DEFINER (Eigentümer postgres, BYPASSRLS) liest er den wahren
-- Bestand ohne erneute Policy-Auswertung — keine Rekursion, klare Meldung.
-- ============================================================================

-- 1) Nicht-rekursive INSERT-Policy: nur Mandanten-Zugehörigkeit prüfen.
DROP POLICY IF EXISTS dash_seiten_insert ON public.beleg_seiten;
CREATE POLICY dash_seiten_insert ON public.beleg_seiten
  FOR INSERT TO dashboard_service
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.belege b
       WHERE b.id = beleg_seiten.beleg_id
         AND b.mandant_id = (NULLIF(current_setting('app.mandant_id', true), ''))::uuid
    )
  );

-- 2) Einmal-Dokument-Regel für festgeschriebene Belege via Trigger.
--    Offene Belege (neu/vorschlag/klaerungsbedarf) bleiben unbeschränkt
--    (Mehrseiten-Eingang von n8n läuft, solange der Beleg offen ist).
CREATE OR REPLACE FUNCTION public.fn_beleg_seiten_insert_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_status   text;
  v_beleg_nr text;
BEGIN
  SELECT status, beleg_nr INTO v_status, v_beleg_nr
    FROM public.belege WHERE id = NEW.beleg_id;

  IF v_status IN ('geprueft', 'exportiert')
     AND EXISTS (SELECT 1 FROM public.beleg_seiten s WHERE s.beleg_id = NEW.beleg_id) THEN
    RAISE EXCEPTION 'Beleg % ist festgeschrieben und hat bereits ein Dokument — es lässt sich genau eine Datei nachreichen (BER-118)',
      v_beleg_nr;
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_beleg_seiten_insert_guard ON public.beleg_seiten;
CREATE TRIGGER trg_beleg_seiten_insert_guard
  BEFORE INSERT ON public.beleg_seiten
  FOR EACH ROW EXECUTE FUNCTION public.fn_beleg_seiten_insert_guard();

-- Nach der Anwendung erneut Trigger-Test T10 laufen lassen (jetzt grün):
-- T10a Einfügen bei festgeschriebenem Beleg ohne Seite = erlaubt,
-- T10c zweite Seite = vom Trigger blockiert (raise_exception statt 42501).
-- ============================================================================
