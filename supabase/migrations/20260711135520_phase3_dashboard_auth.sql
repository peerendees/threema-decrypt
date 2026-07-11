-- BER-93 · Phase 3 Dashboard: Passkey-Auth, Mandanten-Isolation, Freigabe-Audit
-- Zugriffsmodell: Next.js-Server verbindet sich als Rolle dashboard_service
-- (kein BYPASSRLS). Beleg-Daten sind per RLS auf den Mandanten der Session
-- beschränkt: die App setzt pro Request set_config('app.mandant_id', …, true).
-- Details: belegchat/docs/AUTH.md + Vault ADR-05.

-- ---------------------------------------------------------------------------
-- 1) Passkey-Credentials pro Mandant
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.mandant_credentials (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  mandant_id uuid NOT NULL REFERENCES public.mandanten(id) ON DELETE CASCADE,
  credential_id text NOT NULL UNIQUE,
  public_key text NOT NULL,
  counter bigint NOT NULL DEFAULT 0,
  transports text[] NOT NULL DEFAULT '{}',
  bezeichnung text,
  created_at timestamptz NOT NULL DEFAULT now(),
  last_used_at timestamptz
);

CREATE INDEX IF NOT EXISTS idx_mandant_credentials_mandant
  ON public.mandant_credentials (mandant_id);

COMMENT ON TABLE public.mandant_credentials IS
  'WebAuthn/Passkey-Credentials pro Mandant (Dashboard-Login, BER-93)';

ALTER TABLE public.mandant_credentials ENABLE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------------------
-- 2) Registrierungscodes (MVP: Admin-Provisioning; später Threema-Versand)
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.registrierungs_codes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  mandant_id uuid NOT NULL REFERENCES public.mandanten(id) ON DELETE CASCADE,
  code_hash text NOT NULL,
  expires_at timestamptz NOT NULL DEFAULT (now() + interval '24 hours'),
  used_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.registrierungs_codes IS
  'Einmal-Codes für Passkey-Registrierung (SHA-256-Hash, 24 h gültig)';

ALTER TABLE public.registrierungs_codes ENABLE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------------------
-- 3) audit_log: Freigabe-Aktionen zulassen
-- ---------------------------------------------------------------------------

ALTER TABLE public.audit_log
  DROP CONSTRAINT IF EXISTS audit_log_aktion_check;
ALTER TABLE public.audit_log
  ADD CONSTRAINT audit_log_aktion_check
  CHECK (aktion IN ('status_change', 'konto_geaendert', 'export', 'erstellt',
                    'abgelehnt', 'seite_archiviert',
                    'beleg_freigegeben', 'dokumentation_bestaetigt'));

-- ---------------------------------------------------------------------------
-- 4) Rolle dashboard_service (Passwort wird separat gesetzt, nie in Migration)
-- ---------------------------------------------------------------------------

DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'dashboard_service') THEN
    CREATE ROLE dashboard_service LOGIN NOINHERIT;
  END IF;
END $$;

GRANT USAGE ON SCHEMA public TO dashboard_service;
GRANT SELECT ON public.mandanten, public.firmen, public.skr04_konten TO dashboard_service;
GRANT SELECT ON public.beleg_seiten TO dashboard_service;
GRANT SELECT ON public.belege TO dashboard_service;
GRANT UPDATE (status, sachkonto, sachkonto_manuell_geaendert, geprueft_am, updated_at)
  ON public.belege TO dashboard_service;
GRANT SELECT, INSERT ON public.audit_log TO dashboard_service;
GRANT USAGE ON SEQUENCE public.audit_log_id_seq TO dashboard_service;
GRANT SELECT, INSERT, UPDATE ON public.mandant_credentials TO dashboard_service;
GRANT SELECT, UPDATE ON public.registrierungs_codes TO dashboard_service;

-- ---------------------------------------------------------------------------
-- 5) RLS-Policies für dashboard_service
--    Beleg-Daten: strikt mandantenisoliert über app.mandant_id
-- ---------------------------------------------------------------------------

DROP POLICY IF EXISTS dash_belege_select ON public.belege;
CREATE POLICY dash_belege_select ON public.belege
  FOR SELECT TO dashboard_service
  USING (mandant_id = NULLIF(current_setting('app.mandant_id', true), '')::uuid);

DROP POLICY IF EXISTS dash_belege_update ON public.belege;
CREATE POLICY dash_belege_update ON public.belege
  FOR UPDATE TO dashboard_service
  USING (mandant_id = NULLIF(current_setting('app.mandant_id', true), '')::uuid)
  WITH CHECK (mandant_id = NULLIF(current_setting('app.mandant_id', true), '')::uuid);

DROP POLICY IF EXISTS dash_seiten_select ON public.beleg_seiten;
CREATE POLICY dash_seiten_select ON public.beleg_seiten
  FOR SELECT TO dashboard_service
  USING (EXISTS (
    SELECT 1 FROM public.belege b
     WHERE b.id = beleg_id
       AND b.mandant_id = NULLIF(current_setting('app.mandant_id', true), '')::uuid
  ));

DROP POLICY IF EXISTS dash_audit_select ON public.audit_log;
CREATE POLICY dash_audit_select ON public.audit_log
  FOR SELECT TO dashboard_service
  USING (mandant_id = NULLIF(current_setting('app.mandant_id', true), '')::uuid);

DROP POLICY IF EXISTS dash_audit_insert ON public.audit_log;
CREATE POLICY dash_audit_insert ON public.audit_log
  FOR INSERT TO dashboard_service
  WITH CHECK (mandant_id = NULLIF(current_setting('app.mandant_id', true), '')::uuid);

-- Auth-Tabellen: rollenweiter Zugriff (Login/Registrierung laufen vor der Session)
DROP POLICY IF EXISTS dash_mandanten_select ON public.mandanten;
CREATE POLICY dash_mandanten_select ON public.mandanten
  FOR SELECT TO dashboard_service USING (true);

DROP POLICY IF EXISTS dash_firmen_select ON public.firmen;
CREATE POLICY dash_firmen_select ON public.firmen
  FOR SELECT TO dashboard_service USING (true);

DROP POLICY IF EXISTS dash_skr04_select ON public.skr04_konten;
CREATE POLICY dash_skr04_select ON public.skr04_konten
  FOR SELECT TO dashboard_service USING (true);

DROP POLICY IF EXISTS dash_credentials_all ON public.mandant_credentials;
CREATE POLICY dash_credentials_all ON public.mandant_credentials
  FOR ALL TO dashboard_service USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS dash_regcodes_all ON public.registrierungs_codes;
CREATE POLICY dash_regcodes_all ON public.registrierungs_codes
  FOR ALL TO dashboard_service USING (true) WITH CHECK (true);

-- ---------------------------------------------------------------------------
-- 6) Alte Catch-all-Policy schließen: „Nur eigene Belege sichtbar"
-- ---------------------------------------------------------------------------

DROP POLICY IF EXISTS belege_authenticated_lesen ON public.belege;
