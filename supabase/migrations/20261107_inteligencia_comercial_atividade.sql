-- Meu Cliente | Inteligencia Comercial: ultima movimentacao de pedidos por cliente
-- Fonte exclusiva: pedidos do Meu Cliente (nao representa faturamento TOTVS).
BEGIN;
CREATE OR REPLACE FUNCTION public.comercial_atividade_pedidos(p_vendedores uuid[])
RETURNS TABLE(cliente_id uuid, ultimo_pedido date, pedidos_30d bigint)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path=public,pg_temp
AS $$
  SELECT c.id AS cliente_id,
         MAX(p.data_pedido)::date AS ultimo_pedido,
         COUNT(p.id) FILTER (WHERE p.data_pedido >= current_date - 29 AND p.data_pedido <= current_date)::bigint AS pedidos_30d
  FROM public.clientes c
  LEFT JOIN public.pedidos p ON p.cliente_id=c.id AND p.data_pedido <= current_date
  WHERE c.vendedor_id=ANY(p_vendedores)
  GROUP BY c.id
$$;
REVOKE ALL ON FUNCTION public.comercial_atividade_pedidos(uuid[]) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.comercial_atividade_pedidos(uuid[]) TO authenticated;
COMMIT;