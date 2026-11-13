-- Meu Cliente v114: Fila da Analise Financeira por etapa financeira real
-- Mantem todos os dados, versoes, aprovacoes e parametros.
-- Financeiro ve Fichas aguardando na etapa Financeiro ou que ja possuem analise.
-- Nao altera a aprovacao operacional da ficha.
BEGIN;
CREATE OR REPLACE FUNCTION public.mc_viabilidade_listar_fichas(p_busca text DEFAULT '',p_limite integer DEFAULT 100)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_busca text:=left(btrim(coalesce(p_busca,'')),100);
 v_limite integer:=least(greatest(coalesce(p_limite,100),1),300);
 v_saida jsonb;
BEGIN
 IF NOT public.mc_viabilidade_autorizado() THEN RAISE EXCEPTION 'Acesso restrito ao Financeiro e Administrador'; END IF;
 SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.created_at DESC),'[]'::jsonb)
 INTO v_saida FROM (
  SELECT f.id,f.created_at,f.razao_social,f.nome_fantasia,f.cnpj_cpf,
   f.preco_kg,f.consumo_previsto,f.faturamento_previsto,
   f.verba_introducao,f.duracao_verba,f.bonificacao_percentual,
   f.bonificacao_periodicidade,f.bonificacao_modalidade,
   f.prazo_pagamento,f.equipamento_condicao,f.precisa_equipamento,
   f.equipamentos_quantidades,f.forno_tipo,f.forno_quantidade,
   f.freezer_tipos,f.armario_tipo,f.camara_climatica,
   f.esteiras_quantidade,f.assadeiras_quantidade,f.tecnico_panificacao,
   f.tecnico_periodicidade,f.senioridade_tecnico,
   f.vendedor_id
  FROM public.fichas_clientes f
  WHERE (
    EXISTS (SELECT 1 FROM public.ficha_aprovacoes fa
      WHERE fa.ficha_id=f.id AND fa.etapa='financeiro' AND fa.status='pendente')
    OR EXISTS (SELECT 1 FROM public.mc_viabilidade_analises ma
      WHERE ma.ficha_id=f.id)
  ) AND (
    v_busca='' OR
    f.razao_social ILIKE '%'||v_busca||'%' OR
    f.nome_fantasia ILIKE '%'||v_busca||'%' OR
    f.cnpj_cpf::text ILIKE '%'||v_busca||'%'
  )
  ORDER BY f.created_at DESC LIMIT v_limite
 ) x;
 RETURN v_saida;
END;
$$;
REVOKE ALL ON FUNCTION public.mc_viabilidade_listar_fichas(text,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.mc_viabilidade_listar_fichas(text,integer) TO authenticated;
COMMIT;
-- Conferência: quantidade atual de Fichas aguardando Financeiro
SELECT count(DISTINCT f.id) AS fichas_pendentes_financeiro
FROM public.fichas_clientes f
JOIN public.ficha_aprovacoes fa ON fa.ficha_id=f.id
WHERE fa.etapa='financeiro' AND fa.status='pendente';
