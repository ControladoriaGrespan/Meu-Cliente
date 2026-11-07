-- Gamificação Comercial v2 — métricas por dimensão (exclusivo administrador)
-- Valores previstos: soma das previsões mensais das fichas cadastradas no intervalo.
-- Faturamento/volume realizado: PEDIDOS DE VENDA cadastrados no Meu Cliente;
-- NÃO constituem faturamento efetivo do Protheus.
BEGIN;
CREATE OR REPLACE FUNCTION public.ranking_gamificacao_metricas(p_inicio date,p_fim date)
RETURNS TABLE (
  usuario_id uuid,nome text,papel text,supervisor_id uuid,coordenador_id uuid,
  fichas bigint,faturamento_previsto numeric,faturamento_realizado numeric,
  volume_previsto_ton numeric,volume_realizado_ton numeric
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.usuarios u WHERE u.id=auth.uid() AND u.ativo=true AND u.papel::text='admin'
  ) THEN RAISE EXCEPTION 'Acesso restrito ao administrador'; END IF;
  IF p_inicio IS NULL OR p_fim IS NULL OR p_fim<p_inicio OR p_fim-p_inicio>366
  THEN RAISE EXCEPTION 'Periodo invalido (maximo 367 dias inclusivos)'; END IF;
  RETURN QUERY
  WITH equipe AS (
    SELECT u.id,u.nome::text nome,u.papel::text papel,u.supervisor_id,u.coordenador_id
    FROM public.usuarios u
    WHERE u.ativo=true AND u.papel::text IN ('vendedor','supervisor','coordenador')
  ),
  fichas_vendedor AS (
    SELECT f.vendedor_id,
      count(*)::bigint fichas,
      coalesce(sum(f.faturamento_previsto),0)::numeric fat_prev,
      coalesce(sum(coalesce(f.consumo_previsto,0)::numeric * 0.080 * 26 / 1000),0)::numeric ton_prev
    FROM public.fichas_clientes f
    WHERE f.created_at >= p_inicio::timestamptz AND f.created_at < (p_fim+1)::timestamptz
    GROUP BY f.vendedor_id
  ),
  pedidos_vendedor AS (
    SELECT c.vendedor_id,
      coalesce(sum(CASE WHEN coalesce(i.tipo_item,'venda')<>'bonificacao'
        AND coalesce(i.codigo_operacao,'01')='01'
        THEN coalesce(i.quantidade,0)::numeric*coalesce(i.valor_unitario,0)::numeric ELSE 0 END),0)::numeric fat_real,
      coalesce(sum(CASE WHEN coalesce(i.tipo_item,'venda')<>'bonificacao'
        AND coalesce(i.codigo_operacao,'01')='01'
        THEN coalesce(i.quantidade,0)::numeric*coalesce(pr.peso_kg,0)::numeric/1000 ELSE 0 END),0)::numeric ton_real
    FROM public.pedidos p
    JOIN public.clientes c ON c.id=p.cliente_id
    JOIN public.pedido_itens i ON i.pedido_id=p.id
    LEFT JOIN public.produtos pr ON pr.id=i.produto_id
    WHERE p.data_pedido BETWEEN p_inicio AND p_fim
    GROUP BY c.vendedor_id
  ),
  vendedores AS (
    SELECT e.id,e.nome,e.papel,e.supervisor_id,e.coordenador_id,
      coalesce(f.fichas,0)::bigint fichas,
      coalesce(f.fat_prev,0)::numeric fat_prev,
      coalesce(p.fat_real,0)::numeric fat_real,
      coalesce(f.ton_prev,0)::numeric ton_prev,
      coalesce(p.ton_real,0)::numeric ton_real
    FROM equipe e
    LEFT JOIN fichas_vendedor f ON f.vendedor_id=e.id
    LEFT JOIN pedidos_vendedor p ON p.vendedor_id=e.id
    WHERE e.papel='vendedor'
  ),
  agrupado AS (
    SELECT v.id,v.nome,v.papel,v.supervisor_id,v.coordenador_id,v.fichas,v.fat_prev,v.fat_real,v.ton_prev,v.ton_real
    FROM vendedores v
    UNION ALL
    SELECT e.id,e.nome,e.papel,e.supervisor_id,e.coordenador_id,
      coalesce(sum(v.fichas),0)::bigint,coalesce(sum(v.fat_prev),0)::numeric,
      coalesce(sum(v.fat_real),0)::numeric,coalesce(sum(v.ton_prev),0)::numeric,
      coalesce(sum(v.ton_real),0)::numeric
    FROM equipe e LEFT JOIN vendedores v ON v.supervisor_id=e.id
    WHERE e.papel='supervisor'
    GROUP BY e.id,e.nome,e.papel,e.supervisor_id,e.coordenador_id
    UNION ALL
    SELECT e.id,e.nome,e.papel,e.supervisor_id,e.coordenador_id,
      coalesce(sum(v.fichas),0)::bigint,coalesce(sum(v.fat_prev),0)::numeric,
      coalesce(sum(v.fat_real),0)::numeric,coalesce(sum(v.ton_prev),0)::numeric,
      coalesce(sum(v.ton_real),0)::numeric
    FROM equipe e
    LEFT JOIN equipe s ON s.papel='supervisor' AND s.coordenador_id=e.id
    LEFT JOIN vendedores v ON v.supervisor_id=s.id
    WHERE e.papel='coordenador'
    GROUP BY e.id,e.nome,e.papel,e.supervisor_id,e.coordenador_id
  )
  SELECT a.id,a.nome,a.papel,a.supervisor_id,a.coordenador_id,
    a.fichas,a.fat_prev,a.fat_real,a.ton_prev,a.ton_real
  FROM agrupado a
  ORDER BY a.nome;
END;
$fn$;
REVOKE ALL ON FUNCTION public.ranking_gamificacao_metricas(date,date) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.ranking_gamificacao_metricas(date,date) TO authenticated;
COMMIT;
