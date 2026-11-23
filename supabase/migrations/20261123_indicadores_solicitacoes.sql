BEGIN;

-- Indicadores gerenciais das NF publicadas (jan-out/2026).
-- R$ e kg são informados separadamente; não presume peso quando falta na origem.
CREATE OR REPLACE FUNCTION public.mc_indicadores_cliente_autorizado(p_cliente uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.clientes c
    JOIN public.usuarios u ON u.id=auth.uid() AND u.ativo
    LEFT JOIN public.usuarios vendedor ON vendedor.id=c.vendedor_id
    LEFT JOIN public.usuarios supervisor ON supervisor.id=vendedor.supervisor_id
    WHERE c.id=p_cliente AND (
      u.papel::text IN ('admin','diretoria','financeiro','analise_credito','adm_vendas','gestao_adm_vendas','manutencao')
      OR u.id=c.vendedor_id
      OR (u.papel::text='supervisor' AND u.id=vendedor.supervisor_id)
      OR (u.papel::text='coordenador' AND u.id=supervisor.coordenador_id)
      OR (u.papel::text IN ('tec_panificacao','lider_tec_panificacao','supervisor_tec_panificacao')
          AND public.vt_vendedor_na_carteira(c.vendedor_id,public.vt_supervisor_do_atendimento()))
    )
  );
$$;

CREATE OR REPLACE FUNCTION public.mc_resumo_consumo_solicitacoes(p_clientes uuid[])
RETURNS TABLE (
  cliente_id uuid, meses integer, vendas_rs numeric, vendas_kg numeric,
  bonificacoes_rs numeric, bonificacoes_kg numeric, total_bonificado_rs numeric, preco_kg_frances numeric,
  itens_sem_peso bigint
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
  IF p_clientes IS NULL OR cardinality(p_clientes) NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION 'Informe de 1 a 100 clientes';
  END IF;
  RETURN QUERY
  WITH cobertura AS (
    SELECT count(*)::integer AS meses FROM public.vt_faturamento_publicado
  ), clientes_alvo AS (
    SELECT DISTINCT x.id
    FROM unnest(p_clientes) x(id)
    WHERE public.mc_indicadores_cliente_autorizado(x.id)
  ), agregados AS (
    SELECT f.cliente_id,
      coalesce(sum(f.valor_documento) FILTER (WHERE f.tipo='venda'),0) AS venda,
      coalesce(sum(f.valor_documento) FILTER (WHERE f.tipo='bonificacao'),0) AS bonificacao,
      coalesce(sum(f.kg) FILTER (WHERE f.tipo='venda'),0) AS kg_venda,
      coalesce(sum(f.kg) FILTER (WHERE f.tipo='bonificacao'),0) AS kg_bonificacao,
      count(*) FILTER (WHERE f.kg IS NULL) AS sem_peso
    FROM public.vt_faturamento_mensal f
    JOIN public.vt_faturamento_publicado p USING (mes,carga_id)
    WHERE f.cliente_id IN (SELECT id FROM clientes_alvo)
    GROUP BY f.cliente_id
  )
  SELECT c.id,cb.meses,
    CASE WHEN cb.meses>0 THEN round(coalesce(a.venda,0)/cb.meses,2) END,
    CASE WHEN cb.meses>0 AND coalesce(a.sem_peso,0)=0 THEN round((coalesce(a.kg_venda,0))/cb.meses,3) END,
    CASE WHEN cb.meses>0 THEN round(coalesce(a.bonificacao,0)/cb.meses,2) END,
    CASE WHEN cb.meses>0 AND coalesce(a.sem_peso,0)=0 THEN round(coalesce(a.kg_bonificacao,0)/cb.meses,3) END,
    coalesce(a.bonificacao,0),f.preco_kg,coalesce(a.sem_peso,0)
  FROM clientes_alvo c CROSS JOIN cobertura cb
  LEFT JOIN agregados a ON a.cliente_id=c.id
  LEFT JOIN LATERAL (
    SELECT fc.preco_kg FROM public.fichas_clientes fc
    WHERE fc.cliente_id=c.id AND fc.preco_kg IS NOT NULL
    ORDER BY fc.created_at DESC,fc.id DESC LIMIT 1
  ) f ON true;
END $$;

CREATE OR REPLACE FUNCTION public.mc_bonificacoes_sku_mensal(p_cliente uuid)
RETURNS TABLE (
  mes date, codigo text, descricao text, quantidade numeric,
  unidade text, kg numeric, valor_rs numeric
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
  IF NOT public.mc_indicadores_cliente_autorizado(p_cliente) THEN
    RAISE EXCEPTION 'Sem permissão para consultar o histórico do cliente';
  END IF;
  RETURN QUERY
  SELECT f.mes,p.codigo::text,p.descricao::text,f.quantidade,f.unidade,
    f.kg,f.valor_documento
  FROM public.vt_faturamento_mensal f
  JOIN public.vt_faturamento_publicado pub USING(mes,carga_id)
  JOIN public.produtos p ON p.id=f.produto_id
  WHERE f.cliente_id=p_cliente AND f.tipo='bonificacao'
  ORDER BY f.mes,p.codigo;
END $$;

REVOKE ALL ON FUNCTION public.mc_indicadores_cliente_autorizado(uuid),
  public.mc_resumo_consumo_solicitacoes(uuid[]),
  public.mc_bonificacoes_sku_mensal(uuid)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.mc_resumo_consumo_solicitacoes(uuid[]),
  public.mc_bonificacoes_sku_mensal(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.mc_indicadores_cliente_autorizado(uuid) FROM authenticated;

NOTIFY pgrst,'reload schema';
COMMIT;
