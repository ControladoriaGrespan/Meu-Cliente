-- Uma agenda semanal por participante e origem. Os conflitos de horário cruzam ambas.
BEGIN;

-- Substitui a unicidade anterior sem depender do nome original da restrição.
DO $$
DECLARE v_nome name;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
    WHERE conrelid='public.agendas_tecnicas_semanais'::regclass AND conname='vt_agendas_tecnico_semana_origem_un') THEN
    ALTER TABLE public.agendas_tecnicas_semanais
      ADD CONSTRAINT vt_agendas_tecnico_semana_origem_un UNIQUE (tecnico_id,semana_inicio,origem_papel);
  END IF;
  FOR v_nome IN
    SELECT cx.conname FROM pg_constraint cx
    WHERE cx.conrelid='public.agendas_tecnicas_semanais'::regclass AND cx.contype='u'
      AND cx.conkey @> ARRAY[
        (SELECT attnum FROM pg_attribute WHERE attrelid=cx.conrelid AND attname='tecnico_id'),
        (SELECT attnum FROM pg_attribute WHERE attrelid=cx.conrelid AND attname='semana_inicio')
      ] AND cardinality(cx.conkey)=2
  LOOP
    EXECUTE format('ALTER TABLE public.agendas_tecnicas_semanais DROP CONSTRAINT %I',v_nome);
  END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION public.vt_bloquear_programacao_semanal(p_participantes uuid[],p_semana date)
RETURNS void LANGUAGE plpgsql SET search_path='' AS $$
DECLARE v_part uuid;
BEGIN
  FOR v_part IN SELECT DISTINCT id FROM unnest(p_participantes) AS id ORDER BY id LOOP
    PERFORM pg_advisory_xact_lock(hashtextextended(v_part::text||'/'||(p_semana-date '2000-01-01')::text,0));
    PERFORM 1 FROM public.agendas_tecnicas_semanais ag
    WHERE ag.tecnico_id=v_part AND ag.semana_inicio=p_semana ORDER BY ag.id FOR UPDATE;
  END LOOP;
END;
$$;
REVOKE ALL ON FUNCTION public.vt_bloquear_programacao_semanal(uuid[],date) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.vt_agendar_equipe(
 p_participantes uuid[],p_cliente uuid,p_data date,p_hora time,p_duracao integer,
 p_objetivo text,p_observacoes text,p_excecao boolean DEFAULT false,p_justificativa text DEFAULT ''
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE
 v_papel text:=public.vt_papel(); v_origem text; v_supervisor uuid;v_lider uuid;
 v_part uuid;v_role text;v_parent uuid;v_semana date;
 v_agenda public.agendas_tecnicas_semanais%ROWTYPE;
 v_atendimento uuid:=gen_random_uuid();v_cliente_supervisor uuid;v_count int;
BEGIN
 IF v_papel IS NULL OR v_papel NOT IN ('lider_tec_panificacao','supervisor_tec_panificacao','admin') THEN RAISE EXCEPTION 'Perfil sem permissão para agendar'; END IF;
 IF p_excecao AND v_papel NOT IN ('supervisor_tec_panificacao','admin') THEN RAISE EXCEPTION 'Somente supervisor técnico pode agendar exceções'; END IF;
 -- Planejamentos normais do Líder e Supervisor serão aprovados por alçadas diferentes.
 IF p_excecao AND length(trim(p_justificativa))<5 THEN RAISE EXCEPTION 'Justificativa da exceção obrigatória'; END IF;
 IF p_data IS NULL OR p_hora IS NULL OR p_duracao IS NULL OR p_duracao NOT BETWEEN 15 AND 600 THEN RAISE EXCEPTION 'Duração inválida'; END IF;
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
 v_origem:=CASE WHEN v_papel='admin' THEN 'supervisor_tec_panificacao' ELSE v_papel END;
 PERFORM public.vt_bloquear_programacao_semanal(p_participantes,v_semana);
 FOR v_part IN SELECT id FROM unnest(p_participantes) AS id ORDER BY id LOOP
   SELECT papel::text,supervisor_id INTO v_role,v_parent FROM public.usuarios WHERE id=v_part AND ativo=true;
   IF NOT FOUND THEN RAISE EXCEPTION 'Participante inexistente ou inativo'; END IF;
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
     IF EXISTS (SELECT 1 FROM public.agendas_tecnicas_semanais ag WHERE ag.tecnico_id=v_part
          AND ag.semana_inicio=v_semana AND ag.supervisor_id IS DISTINCT FROM v_supervisor)
       THEN RAISE EXCEPTION 'A agenda pertence a outro Supervisor Técnico'; END IF;
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
       v_origem,
       CASE WHEN v_origem='supervisor_tec_panificacao' THEN
         (SELECT u.coordenador_id FROM public.usuarios u WHERE u.id=v_supervisor)
         ELSE NULL END)
     ON CONFLICT(tecnico_id,semana_inicio,origem_papel) DO NOTHING;
     SELECT * INTO v_agenda FROM public.agendas_tecnicas_semanais
      WHERE tecnico_id=v_part AND semana_inicio=v_semana AND origem_papel=v_origem FOR UPDATE;
     IF v_agenda.supervisor_id IS DISTINCT FROM v_supervisor
       THEN RAISE EXCEPTION 'A agenda pertence a outro Supervisor Técnico'; END IF;
     IF v_papel='lider_tec_panificacao' AND v_agenda.lider_id IS DISTINCT FROM auth.uid()
       THEN RAISE EXCEPTION 'A agenda pertence a outro Líder Técnico'; END IF;
     IF v_papel IN ('supervisor_tec_panificacao','admin') AND v_agenda.coordenador_id IS NULL THEN
       RAISE EXCEPTION 'Supervisor sem Coordenador vinculado no cadastro de usuários'; END IF;
     IF v_agenda.status IN ('pendente','aprovada') THEN RAISE EXCEPTION 'Agenda do participante já enviada/aprovada';END IF;
   END IF;
   IF EXISTS(SELECT 1 FROM public.visitas_tecnicas x
     WHERE x.tecnico_id=v_part AND x.data_visita=p_data AND x.status IS DISTINCT FROM 'cancelada'
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

CREATE OR REPLACE FUNCTION public.vt_incluir_visita_agenda(
 p_participantes uuid[],p_cliente uuid,p_data date,p_hora_inicio time,p_hora_fim time,
 p_tipo_atendimento text,p_objetivo text,p_observacoes text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $vtinclude$
DECLARE v_part uuid; v_ag public.agendas_tecnicas_semanais%ROWTYPE;
 v_semana date; v_hoje date := (now() AT TIME ZONE 'America/Sao_Paulo')::date;
 v_mudados uuid[]:='{}';v_atendimento uuid;v_duracao integer;
BEGIN
 IF public.vt_papel() IS DISTINCT FROM 'lider_tec_panificacao'
 THEN RAISE EXCEPTION 'Somente Líder Técnico pode incluir visita na agenda';END IF;
 IF p_data IS NULL OR p_data<v_hoje THEN RAISE EXCEPTION 'Não é permitido agendar em data anterior a hoje';END IF;
 v_duracao:=(extract(epoch FROM (p_hora_fim-p_hora_inicio))/60)::integer;
 IF v_duracao IS NULL OR v_duracao NOT BETWEEN 15 AND 600 THEN RAISE EXCEPTION 'Duração inválida';END IF;
 IF p_tipo_atendimento IS NULL OR p_tipo_atendimento NOT IN ('producao','treinamento')
 THEN RAISE EXCEPTION 'Tipo de atendimento inválido';END IF;
 IF coalesce(array_length(p_participantes,1),0) NOT BETWEEN 1 AND 20
 THEN RAISE EXCEPTION 'Selecione entre 1 e 20 participantes';END IF;
 v_semana:=p_data-(extract(isodow FROM p_data)::integer-1);
 PERFORM public.vt_bloquear_programacao_semanal(p_participantes,v_semana);
 FOR v_part IN SELECT DISTINCT x FROM unnest(p_participantes) AS x ORDER BY x LOOP
  SELECT * INTO v_ag FROM public.agendas_tecnicas_semanais
   WHERE tecnico_id=v_part AND semana_inicio=v_semana AND origem_papel='lider_tec_panificacao' FOR UPDATE;
  IF FOUND THEN
    IF v_ag.lider_id IS DISTINCT FROM auth.uid()
    THEN RAISE EXCEPTION 'Agenda de participante não pertence ao Líder'; END IF;
    IF v_ag.status IN ('pendente','aprovada','devolvida') THEN
      IF EXISTS(SELECT 1 FROM public.visitas_tecnicas x WHERE x.agenda_semana_id=v_ag.id
       AND (x.checkin_em IS NOT NULL OR x.checkout_em IS NOT NULL OR x.status='em_andamento'))
      THEN RAISE EXCEPTION 'Agenda já possui atendimento iniciado e não pode voltar para aprovação';END IF;
      UPDATE public.agendas_tecnicas_semanais SET status='rascunho',atualizado_em=now() WHERE id=v_ag.id;
      v_mudados:=array_append(v_mudados,v_ag.id);
    END IF;
  END IF;
 END LOOP;
 v_atendimento:=public.vt_agendar_equipe(p_participantes,p_cliente,p_data,p_hora_inicio,
   v_duracao,p_objetivo,p_observacoes,false,'');
 UPDATE public.visitas_tecnicas SET tipo_atendimento=p_tipo_atendimento WHERE atendimento_id=v_atendimento;
 UPDATE public.agendas_tecnicas_semanais
   SET status='pendente',enviado_em=now(),aprovado_em=NULL,aprovado_por=NULL,
       observacao_aprovacao=NULL,atualizado_em=now()
   WHERE id=ANY(v_mudados);
 RETURN jsonb_build_object('atendimento',v_atendimento,'reanalisadas',cardinality(v_mudados));
END;
$vtinclude$;
REVOKE ALL ON FUNCTION public.vt_incluir_visita_agenda(uuid[],uuid,date,time,time,text,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.vt_incluir_visita_agenda(uuid[],uuid,date,time,time,text,text,text) TO authenticated;


CREATE OR REPLACE FUNCTION public.vt_criar_visita(
 p_tecnico uuid,p_cliente uuid,p_data date,p_hora time,p_duracao integer,
 p_objetivo text,p_observacoes text,p_acompanha boolean DEFAULT false
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_lider uuid;v_supervisor uuid;v_semana date;v_agenda public.agendas_tecnicas_semanais%ROWTYPE;v_id uuid;
BEGIN
 IF public.vt_papel()<>'lider_tec_panificacao' THEN RAISE EXCEPTION 'Somente líder técnico pode planejar visitas';END IF;
 SELECT supervisor_id INTO v_lider FROM public.usuarios WHERE id=p_tecnico AND papel::text='tec_panificacao' AND ativo=true;
 IF v_lider IS DISTINCT FROM auth.uid() THEN RAISE EXCEPTION 'Técnico fora da equipe do líder';END IF;
 SELECT supervisor_id INTO v_supervisor FROM public.usuarios WHERE id=v_lider AND papel::text='lider_tec_panificacao' AND ativo=true;
 IF v_supervisor IS NULL THEN RAISE EXCEPTION 'Líder sem supervisor técnico vinculado';END IF;
 IF p_duracao NOT BETWEEN 15 AND 600 THEN RAISE EXCEPTION 'Duração inválida';END IF;
 v_semana:=p_data-(EXTRACT(ISODOW FROM p_data)::integer-1);
 PERFORM public.vt_bloquear_programacao_semanal(ARRAY[p_tecnico],v_semana);
 INSERT INTO public.agendas_tecnicas_semanais(tecnico_id,lider_id,supervisor_id,semana_inicio)
 VALUES(p_tecnico,v_lider,v_supervisor,v_semana)
 ON CONFLICT(tecnico_id,semana_inicio,origem_papel) DO NOTHING;
 SELECT * INTO v_agenda FROM public.agendas_tecnicas_semanais WHERE tecnico_id=p_tecnico AND semana_inicio=v_semana AND origem_papel='lider_tec_panificacao' FOR UPDATE;
 IF v_agenda.lider_id<>auth.uid() THEN RAISE EXCEPTION 'Agenda vinculada a outro líder';END IF;
 IF v_agenda.status IN ('pendente','aprovada') THEN RAISE EXCEPTION 'Agenda enviada/aprovada: devolução necessária antes de editar';END IF;
 IF EXISTS (SELECT 1 FROM public.visitas_tecnicas x WHERE x.tecnico_id=p_tecnico
   AND x.data_visita=p_data AND x.status IS DISTINCT FROM 'cancelada'
   AND (p_hora,p_hora+make_interval(mins=>p_duracao))
     OVERLAPS (x.hora_inicio,x.hora_inicio+make_interval(mins=>coalesce(x.duracao_min,120))))
 THEN RAISE EXCEPTION 'Conflito de horário do participante'; END IF;
 INSERT INTO public.visitas_tecnicas(cliente_id,tecnico_id,supervisor_id,data_visita,hora_inicio,duracao_min,objetivo,observacoes,status,agenda_semana_id,lider_acompanha)
 VALUES(p_cliente,p_tecnico,v_supervisor,p_data,p_hora,p_duracao,coalesce(p_objetivo,''),coalesce(p_observacoes,''),'agendada',v_agenda.id,p_acompanha)
 RETURNING id INTO v_id;
 RETURN v_id;
END $$;
NOTIFY pgrst,'reload schema';
COMMIT;
