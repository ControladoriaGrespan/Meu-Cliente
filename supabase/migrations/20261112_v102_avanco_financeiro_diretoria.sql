-- Meu Cliente v102 - conserta avanço financeiro -> diretoria.
-- Diagnóstico: a v100 procura somente etapas aguardando após registrar a
-- decisão; se trigger existente já promoveu diretoria a pendente, lança
-- indevidamente "Há etapas não concluídas" e reverte a decisão.
-- Esta função aceita a próxima etapa aguardando OU já pendente.
-- Execute após backup. Não altera registros existentes. Não execute v99/v100
-- novamente após este arquivo, pois sobrescreveriam a função.
BEGIN;
CREATE OR REPLACE FUNCTION public.mc_decidir_solicitacao_workflow(
 p_aprovacao_id uuid,p_status text,p_observacao text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE
 v_uid uuid:=auth.uid(); v_papel text; v_ativo boolean;
 v_ap public.solicitacao_aprovacoes%ROWTYPE;
 v_sol public.solicitacoes%ROWTYPE;
 v_id_sol uuid; v_min integer; v_prox integer; v_proxima text; v_responsavel uuid;
 v_parecer_fin boolean;
BEGIN
 IF p_status NOT IN ('aprovado','reprovado') THEN RAISE EXCEPTION 'Decisão inválida'; END IF;
 IF v_uid IS NULL THEN RAISE EXCEPTION 'Usuário não autenticado'; END IF;
 SELECT u.papel::text,u.ativo INTO v_papel,v_ativo
 FROM public.usuarios u WHERE u.id=v_uid;
 IF v_ativo IS DISTINCT FROM true THEN RAISE EXCEPTION 'Usuário inativo'; END IF;

 SELECT solicitacao_id INTO v_id_sol
 FROM public.solicitacao_aprovacoes WHERE id=p_aprovacao_id;
 IF v_id_sol IS NULL THEN RAISE EXCEPTION 'Aprovação inexistente'; END IF;

 -- Bloqueia a solicitação ANTES de ler a aprovação, serializando decisões simultâneas.
 SELECT * INTO v_sol FROM public.solicitacoes WHERE id=v_id_sol FOR UPDATE;
 IF v_sol.status_fluxo <> 'aberta' THEN
   RAISE EXCEPTION 'Solicitação não está aberta: %',v_sol.status_fluxo;
 END IF;
 SELECT * INTO v_ap FROM public.solicitacao_aprovacoes
 WHERE id=p_aprovacao_id FOR UPDATE;
 IF v_ap.status <> 'pendente' THEN
   RAISE EXCEPTION 'Etapa não disponível para aprovação';
 END IF;

 SELECT min(ordem) INTO v_min FROM public.solicitacao_aprovacoes
 WHERE solicitacao_id=v_sol.id AND status IN ('pendente','aguardando');
 IF v_ap.ordem IS DISTINCT FROM v_min THEN
   RAISE EXCEPTION 'Existe etapa anterior não finalizada';
 END IF;
 IF EXISTS(
   SELECT 1 FROM public.solicitacao_aprovacoes a
   WHERE a.solicitacao_id=v_sol.id AND a.ordem<v_ap.ordem
     AND NOT (
       a.status IN ('aprovado','nao_aplica')
       OR (v_sol.categoria='bonificacao' AND a.etapa='financeiro' AND a.status='reprovado')
     )
 ) THEN
   RAISE EXCEPTION 'Existem etapas anteriores ainda não finalizadas';
 END IF;
 IF v_ap.responsavel_id IS NOT NULL AND v_ap.responsavel_id<>v_uid THEN
   RAISE EXCEPTION 'Usuário não é o responsável designado';
 END IF;
 IF v_ap.responsavel_id IS NULL AND v_ap.etapa<>v_papel THEN
   RAISE EXCEPTION 'Perfil % não autorizado para %',v_papel,v_ap.etapa;
 END IF;

 v_parecer_fin:=v_sol.categoria='bonificacao' AND v_ap.etapa='financeiro'
                 AND p_status='reprovado';

 UPDATE public.solicitacao_aprovacoes SET status=p_status,
   observacao=NULLIF(btrim(p_observacao),''),aprovador_id=v_uid,
   decidido_em=now()
 WHERE id=v_ap.id;

 -- Coordenador e Gestão Adm. compartilham a MESMA ordem.
 IF v_sol.categoria='bonificacao'
   AND v_ap.etapa IN ('coordenador','gestao_adm_vendas') THEN
   UPDATE public.solicitacao_aprovacoes SET status='nao_aplica'
   WHERE solicitacao_id=v_sol.id AND ordem=v_ap.ordem AND id<>v_ap.id
     AND status='pendente';
 END IF;

 IF p_status='reprovado' AND NOT v_parecer_fin THEN
   UPDATE public.solicitacoes SET status_fluxo='reprovada' WHERE id=v_sol.id;
   RETURN jsonb_build_object('acao','reprovada','etapa',v_ap.etapa);
 END IF;

 -- Um gatilho legado pode ter promovido a etapa seguinte durante o UPDATE
 -- da decisão atual. Respeitar esse avanço sem marcar aprovação duplicada.
 SELECT min(ordem) INTO v_prox FROM public.solicitacao_aprovacoes
 WHERE solicitacao_id=v_sol.id AND ordem>v_ap.ordem
   AND status IN ('pendente','aguardando');

 IF v_prox IS NOT NULL THEN
   -- Avança somente a primeira ordem restante, nunca uma etapa posterior.
   UPDATE public.solicitacao_aprovacoes SET status='pendente'
   WHERE solicitacao_id=v_sol.id AND ordem=v_prox AND status='aguardando';
   -- A etapa compartilhada pode ter duas linhas da mesma ordem; escolher
   -- a que estiver efetivamente pendente.
   SELECT etapa,responsavel_id INTO v_proxima,v_responsavel
   FROM public.solicitacao_aprovacoes
   WHERE solicitacao_id=v_sol.id AND ordem=v_prox AND status='pendente'
   ORDER BY id LIMIT 1;
   IF v_proxima IS NULL THEN
     RAISE EXCEPTION 'A próxima etapa não ficou pendente; verificar gatilhos';
   END IF;
   RETURN jsonb_build_object('acao',
     CASE WHEN v_parecer_fin THEN 'parecer_financeiro_desfavoravel' ELSE 'proxima_etapa' END,
     'proxima_etapa',v_proxima,'responsavel_id',v_responsavel,'status_fluxo','aberta');
 END IF;

 IF EXISTS(
   SELECT 1 FROM public.solicitacao_aprovacoes a
   WHERE a.solicitacao_id=v_sol.id AND NOT (
     a.status IN ('aprovado','nao_aplica')
     OR (v_sol.categoria='bonificacao' AND a.etapa='financeiro' AND a.status='reprovado')
   )
 ) THEN
   RAISE EXCEPTION 'Há etapas não concluídas';
 END IF;

 -- Diretoria sempre decide a bonificação por último.
 IF v_sol.categoria='bonificacao'
   AND NOT EXISTS(
     SELECT 1 FROM public.solicitacao_aprovacoes a
     WHERE a.solicitacao_id=v_sol.id AND a.etapa='diretoria'
       AND a.status='aprovado'
   ) THEN
   RAISE EXCEPTION 'Falta aprovação final da Diretoria';
 END IF;

 UPDATE public.solicitacoes SET status_fluxo='aprovada' WHERE id=v_sol.id;
 RETURN jsonb_build_object('acao','aprovada','status_fluxo','aprovada');
END;
$$;

REVOKE ALL ON FUNCTION public.mc_decidir_solicitacao_workflow(uuid,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.mc_decidir_solicitacao_workflow(uuid,text,text) TO authenticated;
COMMIT;

-- Somente leitura: confirme a fila antes/depois com o usuário Financeiro.
SELECT s.codigo,s.status_fluxo,a.ordem,a.etapa,a.status,a.aprovador_id,a.decidido_em
FROM public.solicitacoes s
JOIN public.solicitacao_aprovacoes a ON a.solicitacao_id=s.id
WHERE s.codigo='BON-000019'
ORDER BY a.ordem,a.etapa;

-- Inspecione os triggers que podem promover a próxima etapa:
SELECT t.tgname,pg_get_triggerdef(t.oid) AS definicao
FROM pg_trigger t
WHERE t.tgrelid='public.solicitacao_aprovacoes'::regclass
  AND NOT t.tgisinternal
ORDER BY t.tgname;
