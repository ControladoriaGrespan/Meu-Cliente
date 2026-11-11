-- MEU CLIENTE v99 | Workflow oficial de solicitações.
-- EXECUTAR MANUALMENTE NO SUPABASE, APÓS BACKUP.
-- Preserva histórico das solicitações existentes: reconstrói apenas filas NOVAS.
-- Requer os gatilhos v45 instalados (zzz_v45_fluxo_solicitacao).
BEGIN;

-- Montagem: considera perfil de quem abriu a solicitação, nunca apenas o vendedor do cliente.
CREATE OR REPLACE FUNCTION public.v45_montar_fluxo_solicitacao_core(p_sol uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE
 s public.solicitacoes%ROWTYPE;
 v_papel text; v_sup uuid; v_coord uuid;
 v_vendedor uuid; v_ini integer; v_ord integer:=0;
 v_etapas text[]; v_et text; v_res uuid;
 v_i integer;
BEGIN
 SELECT * INTO s FROM public.solicitacoes WHERE id=p_sol;
 IF NOT FOUND THEN RAISE EXCEPTION 'Solicitação não encontrada'; END IF;
 -- Não reconstruir a fila existente: histórico e decisões ficam imutáveis.
 IF EXISTS(SELECT 1 FROM public.solicitacao_aprovacoes WHERE solicitacao_id=p_sol) THEN RETURN; END IF;
 SELECT u.papel::text,u.supervisor_id,u.coordenador_id INTO v_papel,v_sup,v_coord
 FROM public.usuarios u WHERE u.id=s.solicitante_id;
 IF v_papel IS NULL THEN RAISE EXCEPTION 'Solicitante sem perfil cadastrado'; END IF;
 SELECT c.vendedor_id INTO v_vendedor FROM public.clientes c WHERE c.id=s.cliente_id;
 IF v_sup IS NULL AND v_vendedor IS NOT NULL THEN
    SELECT u.supervisor_id INTO v_sup FROM public.usuarios u WHERE u.id=v_vendedor;
 END IF;
 IF v_coord IS NULL AND v_sup IS NOT NULL THEN
    SELECT u.coordenador_id INTO v_coord FROM public.usuarios u WHERE u.id=v_sup;
 END IF;
 IF v_coord IS NULL AND v_vendedor IS NOT NULL THEN
    SELECT u.coordenador_id INTO v_coord FROM public.usuarios u WHERE u.id=v_vendedor;
 END IF;
 IF s.categoria='bonificacao' THEN
   v_etapas:=ARRAY['vendedor','supervisor','coordenador','gestao_adm_vendas','financeiro','diretoria'];
 ELSIF s.categoria='equipamento' AND s.tipo='aumento' THEN
   v_etapas:=ARRAY['vendedor','supervisor','coordenador','gestao_adm_vendas','diretoria'];
 ELSIF s.categoria='equipamento' AND s.tipo='troca' THEN
   v_etapas:=ARRAY['vendedor','supervisor','coordenador','manutencao','diretoria'];
 ELSIF s.categoria='equipamento' AND s.tipo='retirada' THEN
   v_etapas:=ARRAY['vendedor','supervisor','coordenador'];
 ELSE
   -- Categorias fora do escopo permanecem com caminho legado.
   IF s.categoria='amostra' THEN
      v_etapas:=ARRAY['supervisor','coordenador','gestao_adm_vendas'];
   ELSIF s.tipo='manutencao' THEN
      v_etapas:=ARRAY['manutencao'];
   ELSE
      RAISE EXCEPTION 'Categoria/tipo não suportado para fluxo %/%',s.categoria,s.tipo;
   END IF;
 END IF;
 IF v_papel='vendedor' THEN v_ini:=1;
 ELSIF v_papel='supervisor' THEN v_ini:=2;
 ELSIF v_papel='coordenador' THEN v_ini:=3;
 ELSIF v_papel='admin' THEN v_ini:=2; -- admin usa fila operacional sem etapa pessoal
 ELSIF s.categoria='amostra' OR s.tipo='manutencao' THEN v_ini:=1;
 ELSE RAISE EXCEPTION 'Perfil % não pode iniciar este workflow',v_papel; END IF;

 FOR v_i IN v_ini..array_length(v_etapas,1) LOOP
   v_et:=v_etapas[v_i];
   v_res:=CASE v_et
      WHEN 'vendedor' THEN s.solicitante_id
      WHEN 'supervisor' THEN CASE WHEN v_papel='supervisor' THEN s.solicitante_id ELSE v_sup END
      WHEN 'coordenador' THEN CASE WHEN v_papel='coordenador' THEN s.solicitante_id ELSE v_coord END
      ELSE NULL END;
   -- Exigir hierarquia válida para não aprovar por ator não designado.
   IF v_et IN ('vendedor','supervisor','coordenador') AND v_res IS NULL THEN
      RAISE EXCEPTION 'Responsável não identificado para etapa % da solicitação %',v_et,p_sol;
   END IF;
   -- Bonificação: coordenador + gestão formam uma etapa compartilhada,
   -- com a mesma ordem; apenas uma das duas decisões será consumada.
   IF s.categoria='bonificacao' AND v_et='gestao_adm_vendas' THEN
      IF v_i>v_ini THEN CONTINUE; END IF;
   END IF;
   v_ord:=v_ord+1;
   INSERT INTO public.solicitacao_aprovacoes
      (solicitacao_id,etapa,ordem,status,responsavel_id)
   VALUES(p_sol,v_et,v_ord,CASE WHEN v_ord=1 THEN 'pendente' ELSE 'aguardando' END,v_res);
   IF s.categoria='bonificacao' AND v_et='coordenador' THEN
     INSERT INTO public.solicitacao_aprovacoes
       (solicitacao_id,etapa,ordem,status,responsavel_id)
     VALUES(p_sol,'gestao_adm_vendas',v_ord,
       CASE WHEN v_ord=1 THEN 'pendente' ELSE 'aguardando' END,NULL);
   END IF;
 END LOOP;
END;
$$;

-- Decisão única transacional. Em disputas, o lock da solicitação serializa a primeira decisão.
CREATE OR REPLACE FUNCTION public.mc_decidir_solicitacao_workflow(
 p_aprovacao_id uuid,p_status text,p_observacao text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE
 v_uid uuid:=auth.uid(); v_papel text; v_ativo boolean;
 v_ap public.solicitacao_aprovacoes%ROWTYPE;
 v_sol public.solicitacoes%ROWTYPE;
 v_min integer; v_prox integer; v_proxima text;
 v_mesma integer;
BEGIN
 IF p_status NOT IN ('aprovado','reprovado') THEN RAISE EXCEPTION 'Decisão inválida'; END IF;
 IF v_uid IS NULL THEN RAISE EXCEPTION 'Usuário não autenticado'; END IF;
 SELECT u.papel::text,u.ativo INTO v_papel,v_ativo FROM public.usuarios u WHERE u.id=v_uid;
 IF v_ativo IS DISTINCT FROM true THEN RAISE EXCEPTION 'Usuário inativo'; END IF;
 SELECT solicitacao_id INTO v_ap.solicitacao_id
 FROM public.solicitacao_aprovacoes WHERE id=p_aprovacao_id;
 IF v_ap.solicitacao_id IS NULL THEN RAISE EXCEPTION 'Aprovação inexistente'; END IF;
 SELECT * INTO v_sol FROM public.solicitacoes WHERE id=v_ap.solicitacao_id FOR UPDATE;
 IF v_sol.status_fluxo NOT IN ('aberta') THEN RAISE EXCEPTION 'Solicitação não está aberta: %',v_sol.status_fluxo; END IF;
 SELECT * INTO v_ap FROM public.solicitacao_aprovacoes WHERE id=p_aprovacao_id FOR UPDATE;
 IF v_ap.status<>'pendente' THEN RAISE EXCEPTION 'Esta etapa já foi decidida ou não está liberada'; END IF;
 SELECT min(ordem) INTO v_min FROM public.solicitacao_aprovacoes
 WHERE solicitacao_id=v_sol.id AND status IN ('pendente','aguardando');
 IF v_ap.ordem<>v_min THEN RAISE EXCEPTION 'Há etapa anterior aguardando aprovação'; END IF;
 IF EXISTS(SELECT 1 FROM public.solicitacao_aprovacoes
   WHERE solicitacao_id=v_sol.id AND ordem<v_ap.ordem AND status NOT IN ('aprovado','nao_aplica'))
 THEN RAISE EXCEPTION 'Etapas anteriores não concluídas'; END IF;
 IF v_ap.responsavel_id IS NOT NULL AND v_ap.responsavel_id<>v_uid THEN
   RAISE EXCEPTION 'Usuário não é o responsável designado'; END IF;
 IF v_ap.responsavel_id IS NULL AND v_ap.etapa<>v_papel THEN
   RAISE EXCEPTION 'Perfil % não autorizado para etapa %',v_papel,v_ap.etapa; END IF;

 UPDATE public.solicitacao_aprovacoes SET status=p_status,observacao=NULLIF(btrim(p_observacao),''),
   aprovador_id=v_uid,decidido_em=now() WHERE id=v_ap.id;
 -- Consumir a alternativa compartilhada sem registrar aprovação fictícia.
 IF v_sol.categoria='bonificacao' AND v_ap.etapa IN ('coordenador','gestao_adm_vendas') THEN
   UPDATE public.solicitacao_aprovacoes SET status='nao_aplica'
   WHERE solicitacao_id=v_sol.id AND ordem=v_ap.ordem AND id<>v_ap.id
     AND status='pendente';
 END IF;
 IF p_status='reprovado' THEN
   UPDATE public.solicitacoes SET status_fluxo='reprovada' WHERE id=v_sol.id;
   RETURN jsonb_build_object('acao','reprovada','etapa',v_ap.etapa);
 END IF;
 SELECT min(ordem) INTO v_prox FROM public.solicitacao_aprovacoes
 WHERE solicitacao_id=v_sol.id AND status='aguardando';
 IF v_prox IS NOT NULL THEN
   UPDATE public.solicitacao_aprovacoes SET status='pendente'
   WHERE solicitacao_id=v_sol.id AND ordem=v_prox AND status='aguardando';
   SELECT etapa INTO v_proxima FROM public.solicitacao_aprovacoes
    WHERE solicitacao_id=v_sol.id AND ordem=v_prox ORDER BY id LIMIT 1;
   RETURN jsonb_build_object('acao','proxima_etapa','proxima_etapa',v_proxima,'status_fluxo','aberta');
 END IF;
 IF EXISTS(SELECT 1 FROM public.solicitacao_aprovacoes
  WHERE solicitacao_id=v_sol.id AND status NOT IN ('aprovado','nao_aplica')) THEN
  RAISE EXCEPTION 'Fluxo não está integralmente decidido';
 END IF;
 UPDATE public.solicitacoes SET status_fluxo='aprovada' WHERE id=v_sol.id;
 RETURN jsonb_build_object('acao','aprovada','status_fluxo','aprovada');
END;
$$;
REVOKE ALL ON FUNCTION public.mc_decidir_solicitacao_workflow(uuid,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.mc_decidir_solicitacao_workflow(uuid,text,text) TO authenticated;

-- Impedir atualização direta do status das aprovações de solicitações por clientes
-- mesmo quando uma política RLS antiga permita UPDATE. A RPC acima é SECURITY DEFINER.
-- Não modifica aprovações históricas.
CREATE OR REPLACE FUNCTION public.mc_bloquear_decisao_solicitacao_direta()
RETURNS trigger LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
BEGIN
 IF (OLD.status IS DISTINCT FROM NEW.status OR OLD.aprovador_id IS DISTINCT FROM NEW.aprovador_id)
   AND current_user <> (SELECT pg_get_userbyid(p.proowner) FROM pg_proc p
          WHERE p.oid='public.mc_decidir_solicitacao_workflow(uuid,text,text)'::regprocedure)
   AND current_user NOT IN ('postgres','service_role')
 THEN
   RAISE EXCEPTION 'Decisões devem usar mc_decidir_solicitacao_workflow';
 END IF;
 RETURN NEW;
END;
$$;
-- Nota: deixar guard transacional efetivo via RPC e RLS.
COMMIT;

-- Diagnóstico não destrutivo:
SELECT s.codigo,s.tipo,s.categoria,s.status_fluxo,a.ordem,a.etapa,a.status
FROM public.solicitacoes s JOIN public.solicitacao_aprovacoes a ON a.solicitacao_id=s.id
ORDER BY s.created_at DESC,a.ordem LIMIT 60;
