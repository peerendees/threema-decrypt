-- Audit-Vokabular: Aktion 'korrektur_vorabgabe' zulassen.
-- Angewendet auf Prod am 23.07.2026 im Zuge der Einmal-Korrektur des 2024-
-- Altbestands vor Erstabgabe (6 Fehlkontierungen 6520 -> 6830/6880, Belegnummern
-- 01-2026- -> 01-2024-; vollständiges Abbild: belegchat/specs/migrations/
-- 20260723_korrektur_2024_vorabgabe.sql, Verfahrensdoku Ä-5). Idempotent.

ALTER TABLE public.audit_log DROP CONSTRAINT IF EXISTS audit_log_aktion_check;
ALTER TABLE public.audit_log ADD CONSTRAINT audit_log_aktion_check
  CHECK (aktion = ANY (ARRAY[
    'status_change','konto_geaendert','export','erstellt','abgelehnt','seite_archiviert',
    'beleg_freigegeben','dokumentation_bestaetigt','teilbetrag_gebucht',
    'zahlungsweg_gesetzt','steuerschluessel_gesetzt','dokument_nachgereicht',
    'nacherfassung_zahlungsweg','nacherfassung_steuerschluessel',
    'export_eingefroren','export_ersetzt','korrektur_vorabgabe'
  ]::text[]));
