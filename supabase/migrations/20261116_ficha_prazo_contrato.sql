BEGIN;

ALTER TABLE public.fichas_clientes
  ADD COLUMN IF NOT EXISTS contrato_prazo_meses integer;

ALTER TABLE public.fichas_clientes
  DROP CONSTRAINT IF EXISTS fichas_clientes_contrato_prazo_meses_check;

-- A coluna fica nula em fichas antigas e em fichas sem contrato.
ALTER TABLE public.fichas_clientes
  ADD CONSTRAINT fichas_clientes_contrato_prazo_meses_check
  CHECK (contrato_prazo_meses IS NULL OR (contrato IS TRUE AND contrato_prazo_meses > 0));

CREATE OR REPLACE FUNCTION public.mc_editar_prazo_contrato_ficha(
  p_ficha uuid, p_prazo_meses integer, p_prazo_anterior integer
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.usuarios
    WHERE id=auth.uid() AND papel='admin' AND ativo IS DISTINCT FROM false) THEN
    RAISE EXCEPTION 'Somente o Administrador pode alterar o prazo do contrato.';
  END IF;
  IF p_prazo_meses IS NULL OR p_prazo_meses < 1 THEN
    RAISE EXCEPTION 'Informe o prazo do contrato em meses inteiros positivos.';
  END IF;
  UPDATE public.fichas_clientes SET contrato_prazo_meses=p_prazo_meses
  WHERE id=p_ficha AND contrato IS TRUE
    AND contrato_prazo_meses IS NOT DISTINCT FROM p_prazo_anterior;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'A ficha foi alterada ou está sem contrato. Atualize a tela e tente novamente.';
  END IF;
END $fn$;

REVOKE ALL ON FUNCTION public.mc_editar_prazo_contrato_ficha(uuid,integer,integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.mc_editar_prazo_contrato_ficha(uuid,integer,integer) TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
