-- MEU CLIENTE v110 | Administração operacional mantendo os workflows oficiais.
-- Somente administradores ativos autenticados podem usar a alçada administrativa.
-- Não altera aprovações anteriores, responsáveis, etapas nem status.
-- Aplicar APÓS v108 e v109, com backup do Supabase.
BEGIN;

-- Solicitações: administrador aprova SOMENTE etapa ativa, mantendo ordenação,
-- parecer Financeiro (não veto) e Diretoria final.
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
 IF v_papel<>'admin' AND v_ap.responsavel_id IS NOT NULL AND v_ap.responsavel_id<>v_uid THEN
   RAISE EXCEPTION 'Usuário não é o responsável designado';
 END IF;
 IF v_papel<>'admin' AND v_ap.responsavel_id IS NULL AND v_ap.etapa<>v_papel THEN
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

-- Fichas: guarda mantém sequência e libera administrador ativo a decidir
-- a etapa atual, sem reatribuir o responsável operacional.
CREATE OR REPLACE FUNCTION public.mc_validar_ordem_decisao_ficha()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
  v_uid uuid:=auth.uid(); v_papel text; v_ativo boolean;
  v_menor integer;
BEGIN
  -- O construtor do workflow pode preparar a fila; esta guarda intervém
  -- exclusivamente quando alguém tenta decidir uma etapa.
  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN RETURN NEW; END IF;
  IF NEW.status NOT IN ('aprovado','reprovado') THEN RETURN NEW; END IF;
  IF OLD.status<>'pendente' THEN
    RAISE EXCEPTION 'Esta etapa da ficha não está liberada para decisão';
  END IF;
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Usuário não autenticado'; END IF;
  SELECT u.papel::text,u.ativo INTO v_papel,v_ativo
  FROM public.usuarios u WHERE u.id=v_uid;
  IF v_ativo IS DISTINCT FROM true THEN RAISE EXCEPTION 'Usuário inativo'; END IF;
  IF v_papel<>'admin' AND OLD.responsavel_id IS NOT NULL AND OLD.responsavel_id<>v_uid THEN
    RAISE EXCEPTION 'A ficha pertence a outro responsável nesta etapa';
  END IF;
  IF v_papel<>'admin' AND OLD.responsavel_id IS NULL AND v_papel<>OLD.etapa THEN
    RAISE EXCEPTION 'O perfil % não pode aprovar a etapa %',v_papel,OLD.etapa;
  END IF;
  SELECT min(a.ordem) INTO v_menor FROM public.ficha_aprovacoes a
  WHERE a.ficha_id=OLD.ficha_id AND a.status IN ('pendente','aguardando');
  IF OLD.ordem IS DISTINCT FROM v_menor THEN
    RAISE EXCEPTION 'Aprovação de ficha fora da sequência obrigatória';
  END IF;
  IF EXISTS(SELECT 1 FROM public.ficha_aprovacoes a
      WHERE a.ficha_id=OLD.ficha_id AND a.ordem<OLD.ordem
        AND a.status NOT IN ('aprovado','nao_aplica')) THEN
    RAISE EXCEPTION 'Há aprovações anteriores da ficha não concluídas';
  END IF;
  RETURN NEW;
END;
$$;

-- Agenda técnica: admin agenda profissionais de uma mesma equipe e
-- respeita aprovação semanal; novas agendas criadas pelo admin seguem
-- a alçada Supervisor -> Coordenador, com permissão administrativa para tramitar.
CREATE OR REPLACE FUNCTION public.vt_agendar_equipe(
 p_participantes uuid[],p_cliente uuid,p_data date,p_hora time,p_duracao integer,
 p_objetivo text,p_observacoes text,p_excecao boolean DEFAULT false,p_justificativa text DEFAULT ''
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE
 v_papel text:=public.vt_papel(); v_supervisor uuid;v_lider uuid;
 v_part uuid;v_role text;v_parent uuid;v_semana date;
 v_agenda public.agendas_tecnicas_semanais%ROWTYPE;
 v_atendimento uuid:=gen_random_uuid();v_cliente_supervisor uuid;v_count int;
BEGIN
 IF v_papel NOT IN ('lider_tec_panificacao','supervisor_tec_panificacao','admin') THEN RAISE EXCEPTION 'Perfil sem permissão para agendar'; END IF;
 IF p_excecao AND v_papel NOT IN ('supervisor_tec_panificacao','admin') THEN RAISE EXCEPTION 'Somente supervisor técnico pode agendar exceções'; END IF;
 -- Planejamentos normais do Líder e Supervisor serão aprovados por alçadas diferentes.
 IF p_excecao AND length(trim(p_justificativa))<5 THEN RAISE EXCEPTION 'Justificativa da exceção obrigatória'; END IF;
 IF p_duracao NOT BETWEEN 15 AND 600 THEN RAISE EXCEPTION 'Duração inválida'; END IF;
 SELECT count(DISTINCT id) INTO v_count FROM unnest(p_participantes) AS id;
 IF v_count=0 OR v_count>20 OR v_count<>coalesce(array_length(p_participantes,1),0) THEN RAISE EXCEPTION 'Selecione entre 1 e 20 participantes, sem repetição';END IF;
 IF v_papel='lider_tec_panificacao' THEN
   SELECT supervisor_id INTO v_supervisor FROM public.usuarios WHERE id=auth.uid() AND ativo=true;
   v_lider:=auth.uid();
 ELSEIF v_papel='admin' THEN
   SELECT CASE WHEN p.papel::text='supervisor_tec_panificacao' THEN p.id
     WHEN p.papel::text='lider_tec_panificacao' THEN p.supervisor_id
     WHEN p.papel::text='tec_panificacao' THEN
       (SELECT l.supervisor_id FROM public.usuarios l WHERE l.id=p.supervisor_id)
     ELSE NULL END INTO v_supervisor
   FROM public.usuarios p WHERE p.id=p_participantes[1] AND p.ativo=true;
 ELSE v_supervisor:=auth.uid(); END IF;
 IF v_supervisor IS NULL THEN RAISE EXCEPTION 'Supervisor técnico não vinculado';END IF;
 SELECT CASE WHEN vendedor.papel::text='supervisor' THEN vendedor.id ELSE vendedor.supervisor_id END INTO v_cliente_supervisor
 FROM public.clientes c JOIN public.usuarios vendedor ON vendedor.id=c.vendedor_id
 WHERE c.id=p_cliente;
 IF NOT FOUND THEN RAISE EXCEPTION 'Cliente não encontrado ou sem vendedor vinculado';END IF;
 IF NOT p_excecao AND v_papel<>'admin' AND NOT EXISTS(
 SELECT 1 FROM public.vt_supervisor_comercial_tecnico m
 WHERE m.supervisor_tecnico_id=v_supervisor AND m.supervisor_comercial_id=v_cliente_supervisor)
 THEN RAISE EXCEPTION 'Cliente fora das carteiras comerciais vinculadas. Solicite agendamento de exceção ao Supervisor Tec';END IF;
 v_semana:=p_data-(extract(isodow from p_data)::integer-1);
 FOREACH v_part IN ARRAY p_participantes LOOP
   SELECT papel::text,supervisor_id INTO v_role,v_parent FROM public.usuarios WHERE id=v_part AND ativo=true;
   IF v_papel='lider_tec_panificacao' THEN
     IF NOT ((v_role='lider_tec_panificacao' AND v_part=auth.uid()) OR
             (v_role='tec_panificacao' AND (v_parent=auth.uid() OR EXISTS (
                SELECT 1 FROM public.vt_lider_tecnicos d
                WHERE d.tecnico_id=v_part AND d.lider_id=auth.uid() AND d.ativo
             )))) THEN
       RAISE EXCEPTION 'Líder só pode agendar a si mesmo e técnicos da própria equipe';END IF;
   ELSIF v_papel='admin' THEN
     IF NOT ((v_role='supervisor_tec_panificacao' AND v_part=v_supervisor) OR
       (v_role='lider_tec_panificacao' AND v_parent=v_supervisor) OR
       (v_role='tec_panificacao' AND (
         EXISTS(SELECT 1 FROM public.usuarios l WHERE l.id=v_parent
           AND l.supervisor_id=v_supervisor AND l.papel::text='lider_tec_panificacao')
         OR EXISTS(SELECT 1 FROM public.vt_lider_tecnicos d
           JOIN public.usuarios l ON l.id=d.lider_id
           WHERE d.tecnico_id=v_part AND d.ativo AND l.supervisor_id=v_supervisor)
       ))) THEN RAISE EXCEPTION 'Administrador: participantes precisam pertencer à mesma equipe técnica'; END IF;
   ELSE
     IF NOT ((v_role='supervisor_tec_panificacao' AND v_part=auth.uid()) OR
             (v_role='lider_tec_panificacao' AND v_parent=auth.uid()) OR
             (v_role='tec_panificacao' AND (
                EXISTS(SELECT 1 FROM public.usuarios l WHERE l.id=v_parent AND l.supervisor_id=auth.uid() AND l.papel::text='lider_tec_panificacao')
                OR EXISTS(SELECT 1 FROM public.vt_lider_tecnicos d JOIN public.usuarios l ON l.id=d.lider_id
                          WHERE d.tecnico_id=v_part AND d.ativo AND l.supervisor_id=auth.uid())
             ))) THEN
       RAISE EXCEPTION 'Supervisor só pode agendar a si mesmo, seus líderes e seus técnicos';END IF;
   END IF;
   IF NOT p_excecao THEN
     v_lider:=CASE WHEN v_role='tec_panificacao' THEN
                       CASE WHEN v_papel='lider_tec_panificacao' THEN auth.uid()
                       ELSE COALESCE(
                         (SELECT l.id FROM public.vt_lider_tecnicos d
                          JOIN public.usuarios l ON l.id=d.lider_id
                          WHERE d.tecnico_id=v_part AND d.ativo AND l.supervisor_id=v_supervisor
                          ORDER BY d.criado_em LIMIT 1),v_parent) END
                   WHEN v_role='lider_tec_panificacao' THEN v_part
                   ELSE v_supervisor END;
     INSERT INTO public.agendas_tecnicas_semanais
       (tecnico_id,lider_id,supervisor_id,semana_inicio,origem_papel,coordenador_id)
     VALUES(v_part,v_lider,v_supervisor,v_semana,
       CASE WHEN v_papel='admin' THEN 'supervisor_tec_panificacao' ELSE v_papel END,
       CASE WHEN v_papel='supervisor_tec_panificacao' THEN
         (SELECT u.coordenador_id FROM public.usuarios u WHERE u.id=v_supervisor)
         ELSE NULL END)
     ON CONFLICT(tecnico_id,semana_inicio) DO NOTHING;
     SELECT * INTO v_agenda FROM public.agendas_tecnicas_semanais
      WHERE tecnico_id=v_part AND semana_inicio=v_semana FOR UPDATE;
     IF v_agenda.supervisor_id<>v_supervisor
       THEN RAISE EXCEPTION 'A agenda pertence a outro Supervisor Técnico'; END IF;
     IF v_agenda.origem_papel IS DISTINCT FROM
       (CASE WHEN v_papel='admin' THEN 'supervisor_tec_panificacao' ELSE v_papel END) THEN
       RAISE EXCEPTION 'Agenda semanal já tem outro originador. Solicite devolução ou escolha outra semana'; END IF;
     IF v_papel IN ('supervisor_tec_panificacao','admin') AND v_agenda.coordenador_id IS NULL THEN
       RAISE EXCEPTION 'Supervisor sem Coordenador vinculado no cadastro de usuários'; END IF;
     IF v_agenda.status IN ('pendente','aprovada') THEN RAISE EXCEPTION 'Agenda do participante já enviada/aprovada';END IF;
   END IF;
   IF EXISTS(SELECT 1 FROM public.visitas_tecnicas x
     WHERE x.tecnico_id=v_part AND x.data_visita=p_data AND x.status<>'cancelada'
       AND (p_hora,p_hora+(p_duracao||' minutes')::interval)
           OVERLAPS (x.hora_inicio,x.hora_inicio+(coalesce(x.duracao_min,120)||' minutes')::interval))
   THEN RAISE EXCEPTION 'Conflito de horário de participante %',v_part;END IF;
   INSERT INTO public.visitas_tecnicas
    (cliente_id,tecnico_id,supervisor_id,data_visita,hora_inicio,duracao_min,
     objetivo,observacoes,status,agenda_semana_id,atendimento_id,tipo_agendamento,justificativa_excecao,criador_papel)
   VALUES(p_cliente,v_part,v_supervisor,p_data,p_hora,p_duracao,
    coalesce(p_objetivo,''),coalesce(p_observacoes,''),'agendada',
    CASE WHEN p_excecao THEN NULL ELSE v_agenda.id END,v_atendimento,
    CASE WHEN p_excecao THEN 'excecao' ELSE 'normal' END,
    CASE WHEN p_excecao THEN p_justificativa ELSE NULL END,v_papel);
 END LOOP;
 IF p_excecao THEN
   INSERT INTO public.vt_aprovacoes_excecao(atendimento_id,supervisor_tecnico_id,justificativa)
   VALUES(v_atendimento,v_supervisor,p_justificativa);
 END IF;
 RETURN v_atendimento;
END $$;

CREATE OR REPLACE FUNCTION public.vt_programar_periodo(
 p_participantes uuid[],p_cliente uuid,p_inicio date,p_fim date,
 p_dias integer[],p_hora_inicio time,p_hora_fim time,
 p_tipo_atendimento text,p_objetivo text,p_observacoes text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_data date;v_contador integer:=0;v_ids uuid[]:='{}';
 v_atendimento uuid;v_duracao integer;
BEGIN
 IF public.vt_papel() NOT IN ('lider_tec_panificacao','supervisor_tec_panificacao','admin')
   THEN RAISE EXCEPTION 'Somente Líder e Supervisor Técnico podem programar visitas'; END IF;
 IF p_inicio IS NULL OR p_fim IS NULL OR p_fim<p_inicio OR p_fim>p_inicio+60
   THEN RAISE EXCEPTION 'Periodo invalido: maximo de 61 dias'; END IF;
 IF p_dias IS NULL OR array_length(p_dias,1) IS NULL OR
    EXISTS(SELECT 1 FROM unnest(p_dias) d WHERE d NOT BETWEEN 1 AND 7)
   THEN RAISE EXCEPTION 'Selecione pelo menos um dia da semana'; END IF;
 IF p_tipo_atendimento NOT IN ('producao','treinamento') THEN
   RAISE EXCEPTION 'Tipo de atendimento invalido';END IF;
 v_duracao:=(extract(epoch from (p_hora_fim-p_hora_inicio))/60)::integer;
 IF v_duracao NOT BETWEEN 15 AND 600 THEN RAISE EXCEPTION 'Horario final deve ser posterior ao inicio (15 a 600 minutos)';END IF;
 FOR v_data IN SELECT generate_series(p_inicio,p_fim,'1 day'::interval)::date LOOP
   IF extract(isodow from v_data)::integer=ANY(p_dias) THEN
     v_atendimento:=public.vt_agendar_equipe(p_participantes,p_cliente,v_data,p_hora_inicio,
       v_duracao,p_objetivo,p_observacoes,false,'');
     UPDATE public.visitas_tecnicas SET tipo_atendimento=p_tipo_atendimento
       WHERE atendimento_id=v_atendimento;
     v_ids:=array_append(v_ids,v_atendimento);
     v_contador:=v_contador+1;
   END IF;
 END LOOP;
 IF v_contador=0 THEN RAISE EXCEPTION 'Nenhuma data selecionada no periodo';END IF;
 RETURN jsonb_build_object('visitas',v_contador,'atendimentos',v_ids);
END $$;

CREATE OR REPLACE FUNCTION public.vt_tramitar_agenda(p_agenda uuid,p_acao text,p_justificativa text DEFAULT '')
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE a public.agendas_tecnicas_semanais%ROWTYPE;v_qtd integer;
BEGIN
 SELECT * INTO a FROM public.agendas_tecnicas_semanais WHERE id=p_agenda FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Agenda não encontrada';END IF;
 IF p_acao='enviar' THEN
   IF a.status NOT IN ('rascunho','devolvida') OR NOT (
     (a.origem_papel='lider_tec_panificacao' AND a.lider_id=auth.uid()
      AND public.vt_papel()='lider_tec_panificacao')
     OR (a.origem_papel='supervisor_tec_panificacao' AND a.supervisor_id=auth.uid()
      AND public.vt_papel()='supervisor_tec_panificacao')
     OR public.vt_papel()='admin'
   ) THEN RAISE EXCEPTION 'Envio não permitido para este originador'; END IF;
   IF a.origem_papel='supervisor_tec_panificacao' AND
     NOT EXISTS(SELECT 1 FROM public.usuarios u WHERE u.id=a.coordenador_id
       AND u.papel::text='coordenador' AND u.ativo=true) AND public.vt_papel()<>'admin' THEN
       RAISE EXCEPTION 'Coordenador de aprovação não está ativo ou vinculado'; END IF;
   SELECT count(*) INTO v_qtd FROM public.visitas_tecnicas WHERE agenda_semana_id=a.id;
   IF v_qtd=0 THEN RAISE EXCEPTION 'Agenda vazia';END IF;
   UPDATE public.agendas_tecnicas_semanais SET status='pendente',enviado_em=now(),atualizado_em=now(),observacao_aprovacao=null WHERE id=a.id;
 ELSIF p_acao IN ('aprovar','devolver') THEN
   IF a.status<>'pendente' OR NOT (
     (a.origem_papel='lider_tec_panificacao' AND a.supervisor_id=auth.uid()
      AND public.vt_papel()='supervisor_tec_panificacao')
     OR (a.origem_papel='supervisor_tec_panificacao' AND a.coordenador_id=auth.uid()
      AND public.vt_papel()='coordenador')
     OR public.vt_papel()='admin'
   ) THEN RAISE EXCEPTION 'Aprovação não permitida para sua alçada'; END IF;
   IF p_acao='devolver' AND length(trim(p_justificativa))=0 THEN RAISE EXCEPTION 'Informe motivo da devolução';END IF;
   UPDATE public.agendas_tecnicas_semanais SET status=CASE WHEN p_acao='aprovar' THEN 'aprovada' ELSE 'devolvida' END,
     aprovado_em=CASE WHEN p_acao='aprovar' THEN now() ELSE null END,
     aprovado_por=CASE WHEN p_acao='aprovar' THEN auth.uid() ELSE null END,
     observacao_aprovacao=CASE WHEN p_acao='devolver' THEN p_justificativa ELSE null END,atualizado_em=now()
   WHERE id=a.id;
 ELSE RAISE EXCEPTION 'Ação inválida';END IF;
END $$;

REVOKE ALL ON FUNCTION public.mc_decidir_solicitacao_workflow(uuid,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.mc_decidir_solicitacao_workflow(uuid,text,text) TO authenticated;
REVOKE ALL ON FUNCTION public.vt_agendar_equipe(uuid[],uuid,date,time,integer,text,text,boolean,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.vt_agendar_equipe(uuid[],uuid,date,time,integer,text,text,boolean,text) TO authenticated;
REVOKE ALL ON FUNCTION public.vt_programar_periodo(uuid[],uuid,date,date,integer[],time,time,text,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.vt_programar_periodo(uuid[],uuid,date,date,integer[],time,time,text,text,text) TO authenticated;
REVOKE ALL ON FUNCTION public.vt_tramitar_agenda(uuid,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.vt_tramitar_agenda(uuid,text,text) TO authenticated;

-- Leitura administrativa das pendências, sem depender das RLS das telas
-- operacionais. O perfil admin ativo é conferido no banco a cada chamada.
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
           'razao_social',c.razao_social,'cnpj_cpf',c.cnpj_cpf),
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

-- Exceções territoriais: Admin ativo pode criar e decidir sem assumir
-- o papel do Coordenador. aprovado_por guarda o ID real do Administrador.
CREATE OR REPLACE FUNCTION public.vt_agendar_excecao(
 p_participantes uuid[],p_cliente uuid,p_data date,p_hora time,p_duracao integer,
 p_tipo_atendimento text,p_objetivo text,p_observacoes text,p_justificativa text
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $mc$
DECLARE v_atendimento uuid;
BEGIN
 IF public.vt_papel() NOT IN ('supervisor_tec_panificacao','admin')
   THEN RAISE EXCEPTION 'Somente Supervisor Técnico pode agendar exceções';END IF;
 IF p_tipo_atendimento NOT IN ('producao','treinamento')
   THEN RAISE EXCEPTION 'Tipo de atendimento inválido';END IF;
 v_atendimento:=public.vt_agendar_equipe(
    p_participantes,p_cliente,p_data,p_hora,p_duracao,
    p_objetivo,p_observacoes,true,p_justificativa);
 UPDATE public.visitas_tecnicas SET tipo_atendimento=p_tipo_atendimento
 WHERE atendimento_id=v_atendimento;
 RETURN v_atendimento;
END;
$mc$;
CREATE OR REPLACE FUNCTION public.vt_decidir_excecao(p_atendimento uuid,p_aprovar boolean,p_motivo text DEFAULT '')
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $admin_excecao$
DECLARE v public.vt_aprovacoes_excecao%ROWTYPE;
BEGIN
 IF public.vt_papel() NOT IN ('coordenador','admin') THEN RAISE EXCEPTION 'Somente Coordenador Comercial pode aprovar exceções';END IF;
 SELECT * INTO v FROM public.vt_aprovacoes_excecao WHERE atendimento_id=p_atendimento FOR UPDATE;
 IF NOT FOUND OR v.status<>'pendente' THEN RAISE EXCEPTION 'Exceção não está pendente';END IF;
 IF NOT p_aprovar AND length(trim(p_motivo))=0 THEN RAISE EXCEPTION 'Informe motivo da devolução';END IF;
 UPDATE public.vt_aprovacoes_excecao SET status=CASE WHEN p_aprovar THEN 'aprovada' ELSE 'devolvida' END,
 aprovado_por=auth.uid(),aprovado_em=now(),coordenador_id=CASE WHEN public.vt_papel()='admin' THEN v.coordenador_id ELSE auth.uid() END,motivo_devolucao=CASE WHEN p_aprovar THEN null ELSE p_motivo END
 WHERE atendimento_id=p_atendimento;
END;
$admin_excecao$;
REVOKE ALL ON FUNCTION public.vt_agendar_excecao(uuid[],uuid,date,time,integer,text,text,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.vt_agendar_excecao(uuid[],uuid,date,time,integer,text,text,text,text) TO authenticated;
REVOKE ALL ON FUNCTION public.vt_decidir_excecao(uuid,boolean,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.vt_decidir_excecao(uuid,boolean,text) TO authenticated;

COMMIT;

-- Auditoria somente leitura: aprovações pendentes de todas as etapas.
SELECT a.etapa,a.status,count(*) FROM public.solicitacao_aprovacoes a
 WHERE a.status='pendente' GROUP BY a.etapa,a.status ORDER BY a.etapa;
