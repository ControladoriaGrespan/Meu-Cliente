-- MEU CLIENTE — 11/11/2026
-- Gestão do cumprimento das solicitações: Administração de Vendas
-- Aprovação é diferente de vinculação ao pedido e da confirmação da realização.
-- Bonificações e Amostras são concluídas por Adm. de Vendas/Gestão Adm. de Vendas.
-- Requer pedido vinculado, impedindo conclusão sem execução documentada.
BEGIN;

CREATE OR REPLACE FUNCTION public.mc_concluir_solicitacao_adm_vendas(p_solicitacao_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp
AS $mc$
DECLARE
 v_papel text;
 v_ativo boolean;
 v_sol public.solicitacoes%ROWTYPE;
BEGIN
 SELECT u.papel::text,u.ativo INTO v_papel,v_ativo
 FROM public.usuarios u WHERE u.id=auth.uid();
 IF auth.uid() IS NULL OR v_ativo IS DISTINCT FROM true OR
    v_papel NOT IN ('adm_vendas','gestao_adm_vendas','admin') THEN
   RAISE EXCEPTION 'Somente Administração de Vendas pode concluir bonificações e amostras';
 END IF;

 SELECT * INTO v_sol FROM public.solicitacoes
 WHERE id=p_solicitacao_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Solicitação não encontrada'; END IF;
 IF v_sol.categoria NOT IN ('bonificacao','amostra') THEN
   RAISE EXCEPTION 'Categoria não autorizada para conclusão pela Administração de Vendas';
 END IF;
 IF v_sol.status_fluxo='concluida' THEN
   RETURN jsonb_build_object('situacao','concluida','ja_concluida',true);
 END IF;
 IF v_sol.status_fluxo<>'vinculada' OR v_sol.pedido_id IS NULL THEN
   RAISE EXCEPTION 'A solicitação deve estar vinculada a um pedido antes da confirmação';
 END IF;
 IF NOT EXISTS(SELECT 1 FROM public.pedidos p
               WHERE p.id=v_sol.pedido_id AND p.cliente_id=v_sol.cliente_id) THEN
   RAISE EXCEPTION 'Pedido não encontrado ou vinculado a outro cliente';
 END IF;
 IF EXISTS(SELECT 1 FROM public.solicitacao_aprovacoes a
           WHERE a.solicitacao_id=v_sol.id
             AND a.status IN ('pendente','aguardando')) THEN
   RAISE EXCEPTION 'Ainda há etapas de aprovação pendentes';
 END IF;
 IF v_sol.categoria='bonificacao' AND NOT EXISTS(
      SELECT 1 FROM public.solicitacao_aprovacoes a
      WHERE a.solicitacao_id=v_sol.id AND a.etapa='diretoria' AND a.status='aprovado'
   ) THEN RAISE EXCEPTION 'Bonificação sem autorização final da Diretoria'; END IF;

 UPDATE public.solicitacoes
 SET status_fluxo='concluida'
 WHERE id=v_sol.id;

 RETURN jsonb_build_object('situacao','concluida','solicitacao_id',v_sol.id,'pedido_id',v_sol.pedido_id);
END;
$mc$;

REVOKE ALL ON FUNCTION public.mc_concluir_solicitacao_adm_vendas(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.mc_concluir_solicitacao_adm_vendas(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.mc_concluir_solicitacao_adm_vendas(uuid) TO authenticated;

COMMIT;

SELECT proname,prosecdef,pg_get_function_arguments(oid) AS argumentos
FROM pg_proc WHERE proname='mc_concluir_solicitacao_adm_vendas';
