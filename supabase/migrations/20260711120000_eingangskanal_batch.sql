-- BER-90 · Phase 2 PDF-Batch-Import
-- Neuer Eingangskanal 'batch' (CLI/Hot-Folder via n8n-Webhook belegchat-import-pdf)

ALTER TABLE public.belege
  DROP CONSTRAINT IF EXISTS belege_eingangskanal_check;
ALTER TABLE public.belege
  ADD CONSTRAINT belege_eingangskanal_check
  CHECK (eingangskanal IN ('threema', 'frontend_upload', 'batch'));
