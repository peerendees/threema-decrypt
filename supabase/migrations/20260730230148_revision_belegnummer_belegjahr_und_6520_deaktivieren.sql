-- Revision vor dem 2025/2026-Import (Betreiber-Weisung 30.07.2026).
-- Angewendet auf Prod (xuqefeewzdvjhuquciut) am 30.07.2026.
--
-- 1) Belegnummer nach BELEGJAHR statt Erfassungsjahr. naechste_beleg_nr bekommt
--    ein optionales p_beleg_datum; ohne den Parameter bleibt der bisherige
--    now()-Fallback (Erfassungsjahr), d. h. bestehende Aufrufer — inkl. der
--    PostgREST-RPC der n8n-Workflows, solange sie nur p_mandant_id senden —
--    laufen unveraendert weiter. Die App (BER-118) und beide n8n-Workflows
--    (Threema MYpHUIHNMuIUR1ic, PDF scLbdf5AbS8ojqJD) uebergeben ab dieser
--    Revision zusaetzlich das Belegdatum, sodass 2025 -> 01-2025-, 2026 ->
--    01-2026- getrennt nummeriert werden (der 2024-Altbestand endet bei 0060).
--
-- 2) Konto 6520 (Gewerbesteuer) deaktivieren. Der Betreiber ist Freiberufler;
--    6520 war 2024 die Quelle der 6 KI-Fehlkontierungen (korrigiert -> 6830/6880,
--    Verfahrensdoku AE-5). Die eigentliche Wirkung liegt in n8n: 6520 wurde dort
--    aus der KI-Prompt-Kontenliste UND dem Validierungs-Set beider Workflows
--    entfernt; ist_aktiv=false blendet es zusaetzlich im Dashboard aus.
--
-- Verfahrensdoku: docs/verfahrensdoku/AENDERUNGEN-v1.1.md Abschnitt AE-6.
-- Auf einer frischen DB idempotent (DROP IF EXISTS + CREATE OR REPLACE, UPDATE no-op).

DROP FUNCTION IF EXISTS public.naechste_beleg_nr(uuid);

CREATE OR REPLACE FUNCTION public.naechste_beleg_nr(
  p_mandant_id  uuid,
  p_beleg_datum date DEFAULT NULL
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_jahr     INTEGER := COALESCE(EXTRACT(YEAR FROM p_beleg_datum)::INTEGER,
                                 EXTRACT(YEAR FROM now())::INTEGER);
  v_firma_nr CHAR(2);
  v_max_nr   INTEGER;
  v_naechste INTEGER;
  v_beleg_nr TEXT;
BEGIN
  SELECT m.firma_nr INTO v_firma_nr FROM public.mandanten m WHERE m.id = p_mandant_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Mandant nicht gefunden: %', p_mandant_id;
  END IF;

  SELECT COALESCE(
    MAX(CAST(SUBSTRING(beleg_nr FROM '^\d{2}-\d{4}-(\d{4})$') AS INTEGER)), 0)
    INTO v_max_nr
    FROM public.belege
   WHERE mandant_id = p_mandant_id
     AND beleg_nr   ~ ('^\d{2}-' || v_jahr || '-\d{4}$');

  v_naechste := v_max_nr + 1;
  v_beleg_nr := v_firma_nr || '-' || v_jahr || '-' || LPAD(v_naechste::TEXT, 4, '0');

  RETURN json_build_object('beleg_nr', v_beleg_nr);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.naechste_beleg_nr(uuid, date) TO dashboard_service;

UPDATE public.skr04_konten SET ist_aktiv = false WHERE konto_nr = '6520';
