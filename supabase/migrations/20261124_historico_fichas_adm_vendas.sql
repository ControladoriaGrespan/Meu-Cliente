-- Meu Cliente — Histórico de fichas para Administração de Vendas
-- Consulta de leitura autorizada, sem alterar a RLS ou permitir edições.
BEGIN;

CREATE OR REPLACE FUNCTION public.mc_listar_fichas_adm_vendas()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp
AS $fn$
DECLARE
  v_papel text;
  v_ativo boolean;
  v_resultado jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Usuário não autenticado';
  END IF;

  SELECT u.papel::text, u.ativo INTO v_papel,v_ativo
  FROM public.usuarios u
  WHERE u.id=auth.uid();

  IF v_ativo IS DISTINCT FROM true
      OR v_papel IS NULL
      OR v_papel NOT IN ('adm_vendas','gestao_adm_vendas','admin') THEN
    RAISE EXCEPTION 'Acesso restrito à Administração de Vendas';
  END IF;

  SELECT coalesce(jsonb_agg(d.linha ORDER BY d.criada_em DESC),'[]'::jsonb)
  INTO v_resultado
  FROM (
    SELECT f.created_at AS criada_em,
      to_jsonb(f)
      || jsonb_build_object(
        'usuarios', (
          SELECT jsonb_build_object('nome',u.nome)
          FROM public.usuarios u WHERE u.id=f.vendedor_id
        ),
        'ficha_aprovacoes', (
          SELECT coalesce(jsonb_agg(
            jsonb_build_object(
              'id',a.id,
              'etapa',a.etapa,
              'status',a.status,
              'decidido_em',a.decidido_em,
              'observacao',a.observacao
            ) ORDER BY a.ordem),'[]'::jsonb)
          FROM public.ficha_aprovacoes a
          WHERE a.ficha_id=f.id
        )
      ) AS linha
    FROM public.fichas_clientes f
    ORDER BY f.created_at DESC, f.id DESC
    LIMIT 10000
  ) d;

  RETURN v_resultado;
END;
$fn$;

REVOKE ALL ON FUNCTION public.mc_listar_fichas_adm_vendas() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.mc_listar_fichas_adm_vendas() TO authenticated;
NOTIFY pgrst,'reload schema';
COMMIT;
