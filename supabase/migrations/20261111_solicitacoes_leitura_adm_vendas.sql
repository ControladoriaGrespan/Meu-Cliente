-- Meu Cliente — consulta de solicitações pela Administração de Vendas
-- 11/11/2026. Leitura para adm_vendas/gestao_adm_vendas e admin,
-- independente da carteira do vendedor. Sem direito de atualizar ou aprovar.
-- Execute no Supabase SQL Editor após backup.
BEGIN;
CREATE OR REPLACE FUNCTION public.mc_listar_solicitacoes_adm_vendas()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp
AS $fn$
DECLARE
  v_perfil text;
  v_ativo boolean;
  v_resultado jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Usuário não autenticado';
  END IF;
  SELECT u.papel::text,u.ativo INTO v_perfil,v_ativo
  FROM public.usuarios u WHERE u.id=auth.uid();
  IF v_perfil NOT IN ('adm_vendas','gestao_adm_vendas','admin') OR v_ativo IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'Acesso restrito à Administração de Vendas';
  END IF;
  SELECT COALESCE(jsonb_agg(linha ORDER BY linha->>'created_at' DESC),'[]'::jsonb)
  INTO v_resultado
  FROM (
    SELECT to_jsonb(s)
      || jsonb_build_object(
        'clientes',(
          SELECT jsonb_build_object('razao_social',c.razao_social,'cnpj_cpf',c.cnpj_cpf,
            'codigo_totvs',c.codigo_totvs)
          FROM public.clientes c WHERE c.id=s.cliente_id
        ),
        'usuarios',(
          SELECT jsonb_build_object('nome',u.nome)
          FROM public.usuarios u WHERE u.id=s.solicitante_id
        ),
        'produtos',(
          SELECT jsonb_build_object('codigo',p.codigo,'descricao',p.descricao)
          FROM public.produtos p WHERE p.id=s.produto_id
        ),
        'solicitacao_aprovacoes',(
          SELECT COALESCE(jsonb_agg(to_jsonb(a) ORDER BY a.ordem),'[]'::jsonb)
          FROM public.solicitacao_aprovacoes a WHERE a.solicitacao_id=s.id
        )
      ) AS linha
    FROM public.solicitacoes s
    ORDER BY s.created_at DESC
    LIMIT 5000
  ) dados;
  RETURN v_resultado;
END;
$fn$;
REVOKE ALL ON FUNCTION public.mc_listar_solicitacoes_adm_vendas() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.mc_listar_solicitacoes_adm_vendas() FROM anon;
GRANT EXECUTE ON FUNCTION public.mc_listar_solicitacoes_adm_vendas() TO authenticated;
COMMIT;

-- Conferência da função:
SELECT p.proname,p.prosecdef,pg_get_function_result(p.oid) AS retorno
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public' AND p.proname='mc_listar_solicitacoes_adm_vendas';
