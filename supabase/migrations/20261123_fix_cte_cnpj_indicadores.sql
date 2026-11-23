-- Corrige o erro column c.cnpj_cpf does not exist: o alias c é o CTE clientes_alvo,
-- que antes selecionava somente id. Agora inclui também cnpj_cpf.
-- Não modifica nenhuma tabela nem os dados de NF existentes.
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
    coalesce(a.bonificacao,0),f.preco_kg,coalesce(a.sem_peso,0)
  FROM clientes_alvo c CROSS JOIN cobertura cb
  LEFT JOIN agregados a ON a.cliente_id=c.id
  LEFT JOIN LATERAL (
    SELECT fc.preco_kg FROM public.fichas_clientes fc
    WHERE fc.preco_kg IS NOT NULL
      AND regexp_replace(coalesce(c.cnpj_cpf::text,''),'[^0-9]','','g') <> ''
      AND regexp_replace(coalesce(fc.cnpj_cpf::text,''),'[^0-9]','','g')
          = regexp_replace(coalesce(c.cnpj_cpf::text,''),'[^0-9]','','g')
    ORDER BY fc.created_at DESC,fc.id DESC LIMIT 1
  ) f ON true;
END $$;


NOTIFY pgrst, 'reload schema';
COMMIT;
