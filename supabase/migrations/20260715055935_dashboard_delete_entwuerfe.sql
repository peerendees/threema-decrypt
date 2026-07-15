-- Dashboard darf Entwürfe (nicht festgeschriebene Belege) löschen.
-- Der Festschreibungs-Trigger schützt geprueft/exportiert weiterhin doppelt.

GRANT DELETE ON public.belege TO dashboard_service;
GRANT DELETE ON public.beleg_seiten TO dashboard_service;

DROP POLICY IF EXISTS dash_belege_delete ON public.belege;
CREATE POLICY dash_belege_delete ON public.belege
  FOR DELETE TO dashboard_service
  USING (
    mandant_id = NULLIF(current_setting('app.mandant_id', true), '')::uuid
    AND status IN ('neu', 'vorschlag', 'klaerungsbedarf')
  );

DROP POLICY IF EXISTS dash_seiten_delete ON public.beleg_seiten;
CREATE POLICY dash_seiten_delete ON public.beleg_seiten
  FOR DELETE TO dashboard_service
  USING (EXISTS (
    SELECT 1 FROM public.belege b
     WHERE b.id = beleg_id
       AND b.mandant_id = NULLIF(current_setting('app.mandant_id', true), '')::uuid
  ));
