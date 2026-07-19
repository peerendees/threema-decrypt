-- BER-113: RLS-Policies fuer die manuelle Erfassung.
-- Die vorhandene INSERT-Policy auf belege verlangt ein Admin-JWT; der
-- Dashboard-Pfad (Rolle dashboard_service, Mandant via app.mandant_id)
-- hatte bisher gar keine INSERT-Moeglichkeit — beleg_seiten ebenfalls nicht.

DROP POLICY IF EXISTS dash_belege_insert ON public.belege;
CREATE POLICY dash_belege_insert ON public.belege
  FOR INSERT
  WITH CHECK (
    mandant_id = (NULLIF(current_setting('app.mandant_id', true), ''))::uuid
    -- Manuell erfasste Belege starten immer im Entwurf; 'geprueft'/'exportiert'
    -- duerfen nur ueber die Freigabe-/Export-Wege entstehen (GoBD).
    AND status = ANY (ARRAY['neu','vorschlag','klaerungsbedarf'])
  );

DROP POLICY IF EXISTS dash_seiten_insert ON public.beleg_seiten;
CREATE POLICY dash_seiten_insert ON public.beleg_seiten
  FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.belege b
       WHERE b.id = beleg_seiten.beleg_id
         AND b.mandant_id = (NULLIF(current_setting('app.mandant_id', true), ''))::uuid
         -- Nachreichen nur solange der Beleg offen ist: nach der Festschreibung
         -- liesse sich der Beleg-Hash nicht mehr setzen (Trigger), das Dokument
         -- wuerde am Duplikatschutz vorbeilaufen.
         AND b.status = ANY (ARRAY['neu','vorschlag','klaerungsbedarf'])
    )
  );
