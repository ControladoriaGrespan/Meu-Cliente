-- Gamificacao Comercial v1: apenas administradores, calculo em servidor
BEGIN;
CREATE OR REPLACE FUNCTION public.ranking_gamificacao_comercial(p_inicio date,p_fim date)
RETURNS TABLE(usuario_id uuid,nome text,papel text,supervisor_id uuid,coordenador_id uuid,
  fichas bigint,pedidos bigint,clientes_com_pedido bigint,pontos bigint)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp
AS $$
BEGIN
 IF auth.uid() IS NULL OR NOT EXISTS (
   SELECT 1 FROM public.usuarios u WHERE u.id=auth.uid() AND u.ativo=true AND u.papel::text='admin'
 ) THEN RAISE EXCEPTION 'Acesso restrito ao administrador'; END IF;
 IF p_inicio IS NULL OR p_fim IS NULL OR p_fim<p_inicio OR p_fim-p_inicio>366
 THEN RAISE EXCEPTION 'Periodo invalido (maximo 367 dias inclusivos)'; END IF;
 RETURN QUERY
 WITH equipe AS (
   SELECT u.id,u.nome::text AS nome,u.papel::text AS papel,u.supervisor_id,u.coordenador_id
   FROM public.usuarios u
   WHERE u.ativo=true AND u.papel::text IN ('vendedor','supervisor','coordenador')
 ),
 vendedores AS (
   SELECT e.*,
     COALESCE((SELECT count(*) FROM public.fichas_clientes f
       WHERE f.vendedor_id=e.id AND f.created_at >=p_inicio::timestamptz
         AND f.created_at < (p_fim+1)::timestamptz),0)::bigint AS fichas,
     COALESCE((SELECT count(*) FROM public.pedidos p JOIN public.clientes c ON c.id=p.cliente_id
       WHERE c.vendedor_id=e.id AND p.data_pedido BETWEEN p_inicio AND p_fim),0)::bigint AS pedidos,
     COALESCE((SELECT count(DISTINCT p.cliente_id) FROM public.pedidos p JOIN public.clientes c ON c.id=p.cliente_id
       WHERE c.vendedor_id=e.id AND p.data_pedido BETWEEN p_inicio AND p_fim),0)::bigint AS clientes_com_pedido
   FROM equipe e WHERE e.papel='vendedor'
 ),
 agrupado AS (
   SELECT v.id AS usuario_id,v.nome,v.papel,v.supervisor_id,v.coordenador_id,v.fichas,v.pedidos,v.clientes_com_pedido FROM vendedores v
   UNION ALL
   SELECT e.id,e.nome,e.papel,e.supervisor_id,e.coordenador_id,
     COALESCE(sum(v.fichas),0)::bigint,COALESCE(sum(v.pedidos),0)::bigint,COALESCE(sum(v.clientes_com_pedido),0)::bigint
   FROM equipe e LEFT JOIN vendedores v ON v.supervisor_id=e.id
   WHERE e.papel='supervisor'
   GROUP BY e.id,e.nome,e.papel,e.supervisor_id,e.coordenador_id
   UNION ALL
   SELECT e.id,e.nome,e.papel,e.supervisor_id,e.coordenador_id,
     COALESCE(sum(v.fichas),0)::bigint,COALESCE(sum(v.pedidos),0)::bigint,COALESCE(sum(v.clientes_com_pedido),0)::bigint
   FROM equipe e LEFT JOIN equipe sup ON sup.coordenador_id=e.id AND sup.papel='supervisor'
   LEFT JOIN vendedores v ON v.supervisor_id=sup.id
   WHERE e.papel='coordenador'
   GROUP BY e.id,e.nome,e.papel,e.supervisor_id,e.coordenador_id
 )
 SELECT a.usuario_id,a.nome,a.papel,a.supervisor_id,a.coordenador_id,
   a.fichas,a.pedidos,a.clientes_com_pedido,
   (a.fichas*10+a.clientes_com_pedido*5+a.pedidos*2)::bigint AS pontos
 FROM agrupado a ORDER BY pontos DESC,a.nome;
END;
$$;
REVOKE ALL ON FUNCTION public.ranking_gamificacao_comercial(date,date) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.ranking_gamificacao_comercial(date,date) TO authenticated;
COMMIT;
