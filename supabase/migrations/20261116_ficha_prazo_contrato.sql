BEGIN;

ALTER TABLE public.fichas_clientes
  ADD COLUMN IF NOT EXISTS contrato_prazo_meses integer;

ALTER TABLE public.fichas_clientes
  DROP CONSTRAINT IF EXISTS fichas_clientes_contrato_prazo_meses_check;

-- A coluna fica nula em fichas antigas e em fichas sem contrato.
ALTER TABLE public.fichas_clientes
  ADD CONSTRAINT fichas_clientes_contrato_prazo_meses_check
  CHECK (contrato_prazo_meses IS NULL OR (contrato IS TRUE AND contrato_prazo_meses > 0));

NOTIFY pgrst, 'reload schema';
COMMIT;
