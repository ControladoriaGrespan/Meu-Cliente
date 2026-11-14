-- Meu Cliente v113 | Edição segura da agenda técnica e reaprovação
-- Não altera vt_tramitar_agenda, nem regras de alçada existentes.
BEGIN;
CREATE OR REPLACE FUNCTION public.vt_editar_visita_planejada(
 p_visita uuid,p_cliente uuid,p_data date,p_hora_inicio time,p_hora_fim time,
 p_tipo_atendimento text,p_objetivo text,p_observacoes text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $vtedit$
DECLARE
 v public.visitas_tecnicas%ROWTYPE;
 a public.agendas_tecnicas_semanais%ROWTYPE;
 v_papel text;
 v_duracao integer;
 v_hoje date := (now() AT TIME ZONE 'America/Sao_Paulo')::date;
 v_supervisor_comercial uuid;
 v_status_anterior text;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Autenticação obrigatória'; END IF;
 v_papel:=public.vt_papel();
 IF v_papel NOT IN ('lider_tec_panificacao','admin') THEN
  RAISE EXCEPTION 'Somente Líder Técnico ou Administrador pode editar a agenda'; END IF;
 SELECT * INTO v FROM public.visitas_tecnicas WHERE id=p_visita FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Visita não encontrada'; END IF;
 IF v.agenda_semana_id IS NULL THEN RAISE EXCEPTION 'Somente visitas de uma agenda semanal podem ser editadas'; END IF;
 SELECT * INTO a FROM public.agendas_tecnicas_semanais WHERE id=v.agenda_semana_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Agenda semanal não encontrada'; END IF;
 IF v_papel='lider_tec_panificacao' AND
  (a.lider_id IS DISTINCT FROM auth.uid() OR a.origem_papel IS DISTINCT FROM 'lider_tec_panificacao')
 THEN RAISE EXCEPTION 'Agenda não pertence a este Líder'; END IF;
 IF v.status<>'agendada' OR v.checkin_em IS NOT NULL OR v.checkout_em IS NOT NULL
 THEN RAISE EXCEPTION 'Visitas iniciadas, concluídas ou canceladas não podem ser editadas'; END IF;
 IF v.data_visita<v_hoje OR p_data<v_hoje
 THEN RAISE EXCEPTION 'Não é permitido alterar visitas de datas anteriores a hoje'; END IF;
 IF p_data-(extract(isodow FROM p_data)::integer-1)<>a.semana_inicio
 THEN RAISE EXCEPTION 'Mudar para outra semana exige criar uma agenda naquela semana'; END IF;
 IF p_hora_inicio IS NULL OR p_hora_fim IS NULL THEN RAISE EXCEPTION 'Horários obrigatórios'; END IF;
 v_duracao := (extract(epoch FROM (p_hora_fim-p_hora_inicio))/60)::integer;
 IF v_duracao NOT BETWEEN 15 AND 600 THEN RAISE EXCEPTION 'Duração deve ser de 15 a 600 minutos'; END IF;
 IF p_tipo_atendimento NOT IN ('producao','treinamento') THEN RAISE EXCEPTION 'Tipo de atendimento inválido'; END IF;
 IF NOT EXISTS (SELECT 1 FROM public.clientes WHERE id=p_cliente)
 THEN RAISE EXCEPTION 'Cliente não localizado'; END IF;
 IF v_papel='lider_tec_panificacao' THEN
   SELECT CASE WHEN u.papel::text='supervisor' THEN u.id ELSE u.supervisor_id END
     INTO v_supervisor_comercial FROM public.clientes c
     JOIN public.usuarios u ON u.id=c.vendedor_id WHERE c.id=p_cliente;
   IF NOT EXISTS(SELECT 1 FROM public.vt_supervisor_comercial_tecnico x
       WHERE x.supervisor_tecnico_id=a.supervisor_id
         AND x.supervisor_comercial_id=v_supervisor_comercial)
   THEN RAISE EXCEPTION 'Cliente fora do território do Líder'; END IF;
 END IF;
 IF EXISTS(SELECT 1 FROM public.visitas_tecnicas x
   WHERE x.id<>v.id AND x.tecnico_id=v.tecnico_id AND x.data_visita=p_data
   AND x.status<>'cancelada'
   AND x.hora_inicio < p_hora_fim
   AND (x.hora_inicio + x.duracao_min * interval '1 minute') > p_hora_inicio)
 THEN RAISE EXCEPTION 'Conflito de horários com outra visita do técnico'; END IF;
 -- Não esconder visitas com check-in nem invalidar atendimento em curso.
 IF a.status IN ('pendente','aprovada','devolvida')
   AND EXISTS(SELECT 1 FROM public.visitas_tecnicas x
      WHERE x.agenda_semana_id=a.id AND (x.checkin_em IS NOT NULL OR x.checkout_em IS NOT NULL OR x.status='em_andamento'))
 THEN RAISE EXCEPTION 'Há atendimento iniciado nesta agenda. Preserve o histórico; planeje nova semana ou contate a supervisão'; END IF;
 v_status_anterior:=a.status;
 UPDATE public.visitas_tecnicas SET
  cliente_id=p_cliente,data_visita=p_data,hora_inicio=p_hora_inicio,
  duracao_min=v_duracao,tipo_atendimento=p_tipo_atendimento,
  objetivo=coalesce(p_objetivo,''),observacoes=coalesce(p_observacoes,'')
 WHERE id=v.id;
 IF a.status IN ('pendente','aprovada','devolvida') THEN
  UPDATE public.agendas_tecnicas_semanais SET
    status='pendente',enviado_em=now(),aprovado_em=NULL,aprovado_por=NULL,
    observacao_aprovacao=NULL,atualizado_em=now()
  WHERE id=a.id;
 ELSE
  UPDATE public.agendas_tecnicas_semanais SET atualizado_em=now() WHERE id=a.id;
 END IF;
 RETURN jsonb_build_object('agenda_id',a.id,'status',CASE WHEN v_status_anterior='rascunho' THEN 'rascunho' ELSE 'pendente' END,
   'reanalisada',v_status_anterior IN ('pendente','aprovada','devolvida'));
END;
$vtedit$;
REVOKE ALL ON FUNCTION public.vt_editar_visita_planejada(uuid,uuid,date,time,time,text,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.vt_editar_visita_planejada(uuid,uuid,date,time,time,text,text,text) TO authenticated;
COMMIT;
