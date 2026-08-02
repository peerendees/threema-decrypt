-- BER-130: Audit-Aktion `entwurf_verworfen`.
-- Angewendet auf Prod (xuqefeewzdvjhuquciut) am 02.08.2026.
--
-- Das Loeschen eines Entwurfs (Status neu/vorschlag/klaerungsbedarf) hinterliess
-- bisher KEINEN Eintrag. Was zurueckblieb, waren nur die Spuren der Erfassung -
-- `erstellt` und `seite_archiviert` -, weil audit_log.beleg_id keinen
-- Fremdschluessel auf belege hat und deshalb nicht mitgeloescht wird.
--
-- Damit war eine Luecke in der Belegnummernfolge zwar ERSCHLIESSBAR (Nummer fehlt
-- in belege, `erstellt`-Eintrag existiert), aber nirgends dokumentiert. Die GoBD
-- erwarten eine lueckenlose, erklaerbare Nummernfolge; "erklaerbar" sollte nicht
-- heissen "rekonstruierbar, wenn man weiss, wo man sucht".
--
-- Ab jetzt schreibt die Loesch-Route vor dem Entfernen eine Zeile mit Belegnummer,
-- Status und Seitenzahl. Der Eintrag ueberlebt den Beleg (kein FK) und erklaert
-- die Luecke von sich aus.
--
-- Idempotent: der CHECK wird als Ganzes neu gesetzt.

ALTER TABLE public.audit_log DROP CONSTRAINT IF EXISTS audit_log_aktion_check;
ALTER TABLE public.audit_log ADD CONSTRAINT audit_log_aktion_check
  CHECK (aktion = ANY (ARRAY[
    'status_change','konto_geaendert','export','erstellt','abgelehnt','seite_archiviert',
    'beleg_freigegeben','dokumentation_bestaetigt','teilbetrag_gebucht',
    'zahlungsweg_gesetzt','steuerschluessel_gesetzt','dokument_nachgereicht',
    'nacherfassung_zahlungsweg','nacherfassung_steuerschluessel',
    'export_eingefroren','export_ersetzt','korrektur_vorabgabe',
    'entwurf_verworfen'
  ]::text[]));
