-- Meu Cliente v108 | Fluxo Visita Técnica: Líder -> Supervisor / Supervisor -> Coordenador
-- Instalar após backup. Preserva agendas já existentes como originadas pelo Líder.
-- Não migra nem aprova agendas automaticamente. Executar no SQL Editor do Supabase.
BEGIN;
ALTER TABLE public.agendas_tecnicas_semanais
 ADD COLUMN IF NOT EXISTS origem_papel text NOT NULL DEFAULT 'lider_tec_panificacao';
ALTER TABLE public.agendas_tecnicas_semanais
 ADD COLUMN IF NOT EXISTS coordenador_id uuid REFERENCES public.usuarios(id);
ALTER TABLE public.agendas_tecnicas_semanais
 DROP CONSTRAINT IF EXISTS vt_agendas_origem_papel_check;
ALTER TABLE public.agendas_tecnicas_semanais
 ADD CONSTRAINT vt_agendas_origem_papel_check
 CHECK (origem_papel IN ('lider_tec_panificacao','supervisor_tec_panificacao'));
CREATE INDEX IF NOT EXISTS idx_vt_agenda_coordenador_pendente
 ON public.agendas_tecnicas_semanais(coordenador_id,status,semana_inicio);
-- Manter SELECT do Técnico condicionado à aprovação semanal.
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
 IF v_papel NOT IN ('lider_tec_panificacao','supervisor_tec_panificacao') THEN RAISE EXCEPTION 'Perfil sem permissão para agendar'; END IF;
 IF p_excecao AND v_papel<>'supervisor_tec_panificacao' THEN RAISE EXCEPTION 'Somente supervisor técnico pode agendar exceções'; END IF;
 -- Planejamentos normais do Líder e Supervisor serão aprovados por alçadas diferentes.
 IF p_excecao AND length(trim(p_justificativa))<5 THEN RAISE EXCEPTION 'Justificativa da exceção obrigatória'; END IF;
 IF p_duracao NOT BETWEEN 15 AND 600 THEN RAISE EXCEPTION 'Duração inválida'; END IF;
 SELECT count(DISTINCT id) INTO v_count FROM unnest(p_participantes) AS id;
 IF v_count=0 OR v_count>20 OR v_count<>coalesce(array_length(p_participantes,1),0) THEN RAISE EXCEPTION 'Selecione entre 1 e 20 participantes, sem repetição';END IF;
 IF v_papel='lider_tec_panificacao' THEN
   SELECT supervisor_id INTO v_supervisor FROM public.usuarios WHERE id=auth.uid() AND ativo=true;
   v_lider:=auth.uid();
 ELSE v_supervisor:=auth.uid(); END IF;
 IF v_supervisor IS NULL THEN RAISE EXCEPTION 'Supervisor técnico não vinculado';END IF;
 SELECT CASE WHEN vendedor.papel::text='supervisor' THEN vendedor.id ELSE vendedor.supervisor_id END INTO v_cliente_supervisor
 FROM public.clientes c JOIN public.usuarios vendedor ON vendedor.id=c.vendedor_id
 WHERE c.id=p_cliente;
 IF NOT FOUND THEN RAISE EXCEPTION 'Cliente não encontrado ou sem vendedor vinculado';END IF;
 IF NOT p_excecao AND NOT EXISTS(
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
     VALUES(v_part,v_lider,v_supervisor,v_semana,v_papel,
       CASE WHEN v_papel='supervisor_tec_panificacao' THEN
         (SELECT u.coordenador_id FROM public.usuarios u WHERE u.id=v_supervisor)
         ELSE NULL END)
     ON CONFLICT(tecnico_id,semana_inicio) DO NOTHING;
     SELECT * INTO v_agenda FROM public.agendas_tecnicas_semanais
      WHERE tecnico_id=v_part AND semana_inicio=v_semana FOR UPDATE;
     IF v_agenda.supervisor_id<>v_supervisor
       THEN RAISE EXCEPTION 'A agenda pertence a outro Supervisor Técnico'; END IF;
     IF v_agenda.origem_papel IS DISTINCT FROM v_papel THEN
       RAISE EXCEPTION 'Agenda semanal já tem outro originador. Solicite devolução ou escolha outra semana'; END IF;
     IF v_papel='supervisor_tec_panificacao' AND v_agenda.coordenador_id IS NULL THEN
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
 IF public.vt_papel() NOT IN ('lider_tec_panificacao','supervisor_tec_panificacao')
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
   ) THEN RAISE EXCEPTION 'Envio não permitido para este originador'; END IF;
   IF a.origem_papel='supervisor_tec_panificacao' AND
     NOT EXISTS(SELECT 1 FROM public.usuarios u WHERE u.id=a.coordenador_id
       AND u.papel::text='coordenador' AND u.ativo=true) THEN
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
   ) THEN RAISE EXCEPTION 'Aprovação não permitida para sua alçada'; END IF;
   IF p_acao='devolver' AND length(trim(p_justificativa))=0 THEN RAISE EXCEPTION 'Informe motivo da devolução';END IF;
   UPDATE public.agendas_tecnicas_semanais SET status=CASE WHEN p_acao='aprovar' THEN 'aprovada' ELSE 'devolvida' END,
     aprovado_em=CASE WHEN p_acao='aprovar' THEN now() ELSE null END,
     aprovado_por=CASE WHEN p_acao='aprovar' THEN auth.uid() ELSE null END,
     observacao_aprovacao=CASE WHEN p_acao='devolver' THEN p_justificativa ELSE null END,atualizado_em=now()
   WHERE id=a.id;
 ELSE RAISE EXCEPTION 'Ação inválida';END IF;
END $$;
-- A visibilidade por RLS permanece definida pela migração original:
-- Lider, Supervisor, Coordenador ou Técnico apenas se status='aprovada'.
REVOKE ALL ON FUNCTION public.vt_agendar_equipe(uuid[],uuid,date,time,integer,text,text,boolean,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.vt_agendar_equipe(uuid[],uuid,date,time,integer,text,text,boolean,text) TO authenticated;
REVOKE ALL ON FUNCTION public.vt_programar_periodo(uuid[],uuid,date,date,integer[],time,time,text,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.vt_programar_periodo(uuid[],uuid,date,date,integer[],time,time,text,text,text) TO authenticated;
REVOKE ALL ON FUNCTION public.vt_tramitar_agenda(uuid,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.vt_tramitar_agenda(uuid,text,text) TO authenticated;
COMMIT;
-- Conferência: agendas por origem/alçada, sem modificações adicionais
SELECT origem_papel,status,count(*) FROM public.agendas_tecnicas_semanais
 GROUP BY origem_papel,status ORDER BY origem_papel,status;
