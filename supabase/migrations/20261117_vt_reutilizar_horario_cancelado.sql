BEGIN;

ALTER TABLE public.visitas_tecnicas
  ADD COLUMN IF NOT EXISTS substitui_visita_id uuid,
  ADD COLUMN IF NOT EXISTS substituicao_aprovada_em timestamptz;

CREATE OR REPLACE FUNCTION public.vt_substituir_visita_cancelada(
  p_cancelada uuid,p_cliente uuid,p_hora_inicio time,p_hora_fim time,
  p_tipo_atendimento text,p_objetivo text,p_observacoes text
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
DECLARE
  v public.visitas_tecnicas%ROWTYPE;
  a public.agendas_tecnicas_semanais%ROWTYPE;
  v_duracao integer;
  v_nova uuid;
BEGIN
  IF public.vt_papel() IS DISTINCT FROM 'lider_tec_panificacao' THEN
    RAISE EXCEPTION 'Somente o Líder Técnico pode substituir um atendimento da sua agenda.';
  END IF;
  SELECT * INTO v FROM public.visitas_tecnicas WHERE id=p_cancelada;
  IF NOT FOUND OR v.status IS DISTINCT FROM 'cancelada' THEN
    RAISE EXCEPTION 'O atendimento original precisa estar cancelado.';
  END IF;
  SELECT * INTO a FROM public.agendas_tecnicas_semanais WHERE id=v.agenda_semana_id FOR UPDATE;
  IF NOT FOUND OR a.lider_id IS DISTINCT FROM auth.uid() OR a.origem_papel IS DISTINCT FROM 'lider_tec_panificacao'
    OR a.status IS DISTINCT FROM 'aprovada' THEN
    RAISE EXCEPTION 'Use uma visita cancelada na sua agenda aprovada.';
  END IF;
  IF v.data_visita<(now() AT TIME ZONE 'America/Sao_Paulo')::date THEN
    RAISE EXCEPTION 'Não é permitido agendar em data anterior a hoje.';
  END IF;
  v_duracao:=extract(epoch FROM (p_hora_fim-p_hora_inicio))/60;
  IF v_duracao IS NULL OR v_duracao NOT BETWEEN 15 AND 600 OR p_hora_inicio<v.hora_inicio OR
    p_hora_fim>v.hora_inicio+make_interval(mins=>coalesce(v.duracao_min,120)) THEN
    RAISE EXCEPTION 'Informe um intervalo de 15 minutos a 10 horas dentro do horário cancelado.';
  END IF;
  IF p_tipo_atendimento IS NULL OR p_tipo_atendimento NOT IN ('producao','treinamento') THEN
    RAISE EXCEPTION 'Tipo de atendimento inválido.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.usuarios t JOIN public.usuarios l ON l.id=auth.uid()
    WHERE l.ativo AND l.supervisor_id=a.supervisor_id AND t.id=v.tecnico_id AND t.ativo
      AND ((t.id=l.id AND t.papel::text='lider_tec_panificacao') OR (t.papel::text='tec_panificacao'
        AND (t.supervisor_id=l.id OR EXISTS (SELECT 1 FROM public.vt_lider_tecnicos d
          WHERE d.lider_id=l.id AND d.tecnico_id=t.id AND d.ativo))))) THEN
    RAISE EXCEPTION 'Participante fora da equipe autorizada.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.clientes c JOIN public.usuarios vendedor ON vendedor.id=c.vendedor_id
    JOIN public.vt_supervisor_comercial_tecnico m ON m.supervisor_tecnico_id=a.supervisor_id
      AND m.supervisor_comercial_id=CASE WHEN vendedor.papel::text='supervisor' THEN vendedor.id ELSE vendedor.supervisor_id END
    WHERE c.id=p_cliente) THEN RAISE EXCEPTION 'Cliente fora das carteiras comerciais vinculadas.'; END IF;
  IF EXISTS (SELECT 1 FROM public.visitas_tecnicas x WHERE x.tecnico_id=v.tecnico_id AND x.data_visita=v.data_visita
    AND x.status IS DISTINCT FROM 'cancelada'
    AND (p_hora_inicio,p_hora_fim) OVERLAPS (x.hora_inicio,x.hora_inicio+make_interval(mins=>coalesce(x.duracao_min,120)))) THEN
    RAISE EXCEPTION 'Há outro atendimento ocupando esse horário.';
  END IF;
  INSERT INTO public.visitas_tecnicas(cliente_id,tecnico_id,supervisor_id,data_visita,hora_inicio,duracao_min,
    objetivo,observacoes,status,agenda_semana_id,atendimento_id,tipo_agendamento,tipo_atendimento,criador_papel,substitui_visita_id)
  VALUES(p_cliente,v.tecnico_id,a.supervisor_id,v.data_visita,p_hora_inicio,v_duracao,
    coalesce(p_objetivo,''),coalesce(p_observacoes,''),'agendada',a.id,gen_random_uuid(),'normal',p_tipo_atendimento,'lider_tec_panificacao',v.id)
  RETURNING id INTO v_nova;
  RETURN v_nova;
END $fn$;

CREATE OR REPLACE FUNCTION public.vt_decidir_substituicao(p_visita uuid,p_aprovar boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
DECLARE v public.visitas_tecnicas%ROWTYPE;
BEGIN
  SELECT * INTO v FROM public.visitas_tecnicas WHERE id=p_visita FOR UPDATE;
  IF NOT FOUND OR p_aprovar IS NULL OR NOT coalesce(public.vt_papel()='admin' OR
    (public.vt_papel()='supervisor_tec_panificacao' AND v.supervisor_id=auth.uid()),false) THEN
    RAISE EXCEPTION 'Atendimento indisponível para sua aprovação.';
  END IF;
  IF v.substitui_visita_id IS NULL OR v.status IS DISTINCT FROM 'agendada' OR v.substituicao_aprovada_em IS NOT NULL THEN
    RAISE EXCEPTION 'O atendimento não aguarda aprovação.';
  END IF;
  IF p_aprovar THEN
    UPDATE public.visitas_tecnicas SET substituicao_aprovada_em=now() WHERE id=v.id;
  ELSE
    UPDATE public.visitas_tecnicas SET status='cancelada',cancelado_em=now(),cancelado_por=auth.uid() WHERE id=v.id;
  END IF;
END $fn$;

CREATE OR REPLACE FUNCTION public.vt_proteger_checkin_substituicao()
RETURNS trigger LANGUAGE plpgsql SET search_path='' AS $fn$
BEGIN
  IF NEW.substitui_visita_id IS NOT NULL AND NEW.substituicao_aprovada_em IS NULL AND
    (NEW.checkin_em IS DISTINCT FROM OLD.checkin_em OR NEW.status='em_andamento') THEN
    RAISE EXCEPTION 'A substituição aguarda aprovação do Supervisor Técnico.';
  END IF;
  RETURN NEW;
END $fn$;

DROP TRIGGER IF EXISTS vt_proteger_checkin_substituicao ON public.visitas_tecnicas;
CREATE TRIGGER vt_proteger_checkin_substituicao BEFORE UPDATE OF status,checkin_em ON public.visitas_tecnicas
FOR EACH ROW EXECUTE FUNCTION public.vt_proteger_checkin_substituicao();

DROP POLICY IF EXISTS vt_substituicoes_visibilidade ON public.visitas_tecnicas;
CREATE POLICY vt_substituicoes_visibilidade ON public.visitas_tecnicas AS RESTRICTIVE FOR SELECT TO authenticated
USING (substitui_visita_id IS NULL OR substituicao_aprovada_em IS NOT NULL
  OR public.vt_papel() IN ('lider_tec_panificacao','supervisor_tec_panificacao','admin'));

REVOKE ALL ON FUNCTION public.vt_substituir_visita_cancelada(uuid,uuid,time,time,text,text,text),
  public.vt_decidir_substituicao(uuid,boolean) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.vt_substituir_visita_cancelada(uuid,uuid,time,time,text,text,text),
  public.vt_decidir_substituicao(uuid,boolean) TO authenticated;

NOTIFY pgrst,'reload schema';
COMMIT;
