-- Meu Cliente v112: inclui nome fantasia na fila administrativa, sem modificar etapas, aprovações, decisões nem RLS.
BEGIN;
CREATE OR REPLACE FUNCTION public.mc_admin_listar_pendencias()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp
AS $admin$
DECLARE v_sol jsonb;v_fichas jsonb;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM public.usuarios u
    WHERE u.id=auth.uid() AND u.papel::text='admin' AND u.ativo=true)
  THEN RAISE EXCEPTION 'Somente Administrador ativo pode consultar a fila completa'; END IF;

  SELECT COALESCE(jsonb_agg(
    to_jsonb(a) || jsonb_build_object('solicitacoes',
      to_jsonb(s) || jsonb_build_object(
        'clientes',jsonb_build_object('codigo_totvs',c.codigo_totvs,
           'razao_social',c.razao_social,'nome_fantasia',c.nome_fantasia,'cnpj_cpf',c.cnpj_cpf),
        'usuarios',jsonb_build_object('nome',u.nome),
        'produtos',CASE WHEN p.id IS NULL THEN NULL ELSE
           jsonb_build_object('codigo',p.codigo,'descricao',p.descricao) END,
        'solicitacao_aprovacoes',
           (SELECT COALESCE(jsonb_agg(to_jsonb(h) ORDER BY h.ordem,h.etapa),'[]'::jsonb)
            FROM public.solicitacao_aprovacoes h WHERE h.solicitacao_id=s.id)
      )
   ) ORDER BY s.created_at DESC),'[]'::jsonb) INTO v_sol
  FROM public.solicitacao_aprovacoes a
  JOIN public.solicitacoes s ON s.id=a.solicitacao_id
  LEFT JOIN public.clientes c ON c.id=s.cliente_id
  LEFT JOIN public.usuarios u ON u.id=s.solicitante_id
  LEFT JOIN public.produtos p ON p.id=s.produto_id
  WHERE a.status='pendente' AND s.status_fluxo='aberta';

  SELECT COALESCE(jsonb_agg(
    to_jsonb(a) || jsonb_build_object('fichas_clientes',
      to_jsonb(f) || jsonb_build_object(
        'usuarios',jsonb_build_object('nome',u.nome),
        'clientes',NULL,
        'ficha_aprovacoes',
          (SELECT COALESCE(jsonb_agg(to_jsonb(h) ORDER BY h.ordem),'[]'::jsonb)
           FROM public.ficha_aprovacoes h WHERE h.ficha_id=f.id)
      )
    ) ORDER BY f.created_at DESC),'[]'::jsonb) INTO v_fichas
  FROM public.ficha_aprovacoes a
  JOIN public.fichas_clientes f ON f.id=a.ficha_id
  LEFT JOIN public.usuarios u ON u.id=f.vendedor_id
  WHERE a.status='pendente';

  RETURN jsonb_build_object('solicitacoes',v_sol,'fichas',v_fichas);
END;
$admin$;
REVOKE ALL ON FUNCTION public.mc_admin_listar_pendencias() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.mc_admin_listar_pendencias() TO authenticated;
COMMIT;
