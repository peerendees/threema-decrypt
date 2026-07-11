-- BER-90 · Bugfix naechste_beleg_nr
-- Die Max-Abfrage filterte auf buchungsjahr (= Jahr des Belegdatums), vergab die
-- Nummer aber mit dem aktuellen Jahr. Ein Beleg mit abweichendem Belegdatum-Jahr
-- (z. B. 2025er-Rechnung, importiert 2026 → 01-2026-0021 mit buchungsjahr 2025)
-- war dadurch für die Sequenz unsichtbar → Endlos-Kollision auf derselben Nummer.
-- Fix: Sequenz rein über das beleg_nr-Muster des Mandanten bestimmen.

CREATE OR REPLACE FUNCTION public.naechste_beleg_nr(p_mandant_id uuid)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_jahr     INTEGER := EXTRACT(YEAR FROM now())::INTEGER;
  v_firma_nr CHAR(2);
  v_max_nr   INTEGER;
  v_naechste INTEGER;
  v_beleg_nr TEXT;
BEGIN
  SELECT m.firma_nr
  INTO v_firma_nr
  FROM public.mandanten m
  WHERE m.id = p_mandant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Mandant nicht gefunden: %', p_mandant_id;
  END IF;

  -- Höchste laufende Nummer rein aus dem beleg_nr-Muster dieses Mandanten/Jahres
  -- (KEIN buchungsjahr-Filter: das Belegdatum darf vom Vergabejahr abweichen)
  SELECT COALESCE(
    MAX(
      CAST(
        SUBSTRING(beleg_nr FROM '^\d{2}-\d{4}-(\d{4})$')
        AS INTEGER
      )
    ), 0)
  INTO v_max_nr
  FROM public.belege
  WHERE mandant_id = p_mandant_id
    AND beleg_nr   ~ ('^\d{2}-' || v_jahr || '-\d{4}$');

  v_naechste := v_max_nr + 1;
  v_beleg_nr := v_firma_nr || '-' || v_jahr || '-' || LPAD(v_naechste::TEXT, 4, '0');

  RETURN json_build_object('beleg_nr', v_beleg_nr);
END;
$function$;
