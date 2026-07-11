-- BER-95 · Früher Push nach Integritätsprüfung
-- Atomares Anhängen einer Belegseite an den offenen Pending-Vorgang.
-- Ersetzt das Read-Modify-Write aus n8n (Pending Body / Pending speichern):
-- seite_nr wird serverseitig vergeben, damit kein Foto verloren geht, wenn
-- das nächste Bild eintrifft, bevor die Archivierung der Vorseite fertig ist.

CREATE OR REPLACE FUNCTION public.append_pending_seite(
  p_mandant_id uuid,
  p_threema_sender_id text,
  p_seite jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
  v_row public.pending_belege;
BEGIN
  SELECT * INTO v_row
    FROM public.pending_belege
   WHERE mandant_id = p_mandant_id
     AND status IN ('wartet_auf_antwort', 'wartet_auf_seite')
   FOR UPDATE;

  IF NOT FOUND THEN
    BEGIN
      INSERT INTO public.pending_belege (mandant_id, threema_sender_id, seiten, status)
      VALUES (p_mandant_id, p_threema_sender_id,
              jsonb_build_array(p_seite || jsonb_build_object('seite_nr', 1)),
              'wartet_auf_antwort')
      RETURNING * INTO v_row;
      RETURN jsonb_build_object('id', v_row.id, 'status', v_row.status, 'seiten', v_row.seiten);
    EXCEPTION WHEN unique_violation THEN
      -- Paralleler Lauf hat den Vorgang gerade angelegt → unten anhängen
      SELECT * INTO v_row
        FROM public.pending_belege
       WHERE mandant_id = p_mandant_id
         AND status IN ('wartet_auf_antwort', 'wartet_auf_seite')
       FOR UPDATE;
    END;
  END IF;

  UPDATE public.pending_belege
     SET seiten = seiten || jsonb_build_array(
           p_seite || jsonb_build_object('seite_nr', jsonb_array_length(seiten) + 1)),
         status = 'wartet_auf_antwort',
         updated_at = now()
   WHERE id = v_row.id
  RETURNING * INTO v_row;

  RETURN jsonb_build_object('id', v_row.id, 'status', v_row.status, 'seiten', v_row.seiten);
END;
$$;

COMMENT ON FUNCTION public.append_pending_seite(uuid, text, jsonb) IS
  'BER-95: Seite atomar an offenen Pending-Vorgang anhängen (seite_nr serverseitig); nur Service Role';

-- Nur Service Role (n8n) darf die Funktion aufrufen
REVOKE EXECUTE ON FUNCTION public.append_pending_seite(uuid, text, jsonb) FROM PUBLIC, anon, authenticated;
