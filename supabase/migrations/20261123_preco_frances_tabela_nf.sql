-- Preço do Francês por tabela DA1 do cliente, com fallback nas NF do SKU 10000122.
-- Produto vendido em pacote de 8 kg. Nunca usa bonificações para formar preço.
-- Histórico de NF publicado só permite fallback se houver kg confiável.
BEGIN;
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
    SELECT DISTINCT cli.id, cli.cnpj_cpf
    FROM unnest(p_clientes) x(id)
    JOIN public.clientes cli ON cli.id=x.id
    WHERE public.mc_indicadores_cliente_autorizado(cli.id)
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
    coalesce(a.bonificacao,0),
    coalesce(round(tab.preco_pacote/8.0,2),nf.preco_kg),
    coalesce(a.sem_peso,0)
  FROM clientes_alvo c
  JOIN public.clientes cliente ON cliente.id=c.id
  CROSS JOIN cobertura cb
  LEFT JOIN agregados a ON a.cliente_id=c.id
  LEFT JOIN LATERAL (
    SELECT tpi.preco_unitario AS preco_pacote
    FROM public.tabela_preco_itens tpi
    JOIN public.produtos produto ON produto.id=tpi.produto_id
    WHERE tpi.tabela_id=cliente.tabela_preco_id
      AND produto.codigo::text='10000122'
      AND tpi.preco_unitario>0
    LIMIT 1
  ) tab ON true
  LEFT JOIN LATERAL (
    SELECT CASE WHEN count(*)>0 AND count(*) FILTER (WHERE fat.kg IS NULL)=0
      AND sum(fat.kg)>0
      THEN round(sum(fat.valor_documento)/sum(fat.kg),2) END AS preco_kg
    FROM public.vt_faturamento_mensal fat
    JOIN public.vt_faturamento_publicado pub USING (mes,carga_id)
    JOIN public.produtos produto ON produto.id=fat.produto_id
    WHERE fat.cliente_id=c.id
      AND fat.tipo='venda'
      AND produto.codigo::text='10000122'
  ) nf ON true;
END $$;


NOTIFY pgrst, 'reload schema';
COMMIT;
