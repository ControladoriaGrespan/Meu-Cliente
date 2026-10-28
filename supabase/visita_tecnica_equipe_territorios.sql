-- Visitas em equipe: cada participante recebe uma linha individual de visita,
-- vinculada ao mesmo atendimento_id. Mantém GPS, check-in e agenda semanal por pessoa.
BEGIN;
ALTER TABLE public.visitas_tecnicas ADD COLUMN IF NOT EXISTS atendimento_id uuid;
ALTER TABLE public.visitas_tecnicas ADD COLUMN IF NOT EXISTS tipo_agendamento text NOT NULL DEFAULT 'normal';
ALTER TABLE public.visitas_tecnicas ADD COLUMN IF NOT EXISTS justificativa_excecao text;
ALTER TABLE public.visitas_tecnicas ADD COLUMN IF NOT EXISTS criador_papel text;
CREATE INDEX IF NOT EXISTS vt_atendimento_idx ON public.visitas_tecnicas(atendimento_id);
CREATE TABLE IF NOT EXISTS public.vt_supervisor_comercial_tecnico(
 supervisor_tecnico_id uuid NOT NULL REFERENCES public.usuarios(id),
 supervisor_comercial_id uuid NOT NULL REFERENCES public.usuarios(id),
 criado_em timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(supervisor_tecnico_id,supervisor_comercial_id)
);
ALTER TABLE public.vt_supervisor_comercial_tecnico ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS vt_vinculos_select ON public.vt_supervisor_comercial_tecnico;
CREATE POLICY vt_vinculos_select ON public.vt_supervisor_comercial_tecnico FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS vt_vinculos_admin ON public.vt_supervisor_comercial_tecnico;
CREATE POLICY vt_vinculos_admin ON public.vt_supervisor_comercial_tecnico FOR ALL TO authenticated USING(public.vt_papel()='admin') WITH CHECK(public.vt_papel()='admin');
CREATE TABLE IF NOT EXISTS public.vt_aprovacoes_excecao(
 atendimento_id uuid PRIMARY KEY,
 supervisor_tecnico_id uuid NOT NULL REFERENCES public.usuarios(id),
 coordenador_id uuid REFERENCES public.usuarios(id),
 status text NOT NULL DEFAULT 'pendente' CHECK(status IN ('pendente','aprovada','devolvida')),
 justificativa text NOT NULL,
 aprovado_por uuid REFERENCES public.usuarios(id),
 aprovado_em timestamptz,
 motivo_devolucao text,
 criado_em timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.vt_aprovacoes_excecao ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS vt_excecoes_select ON public.vt_aprovacoes_excecao;
CREATE POLICY vt_excecoes_select ON public.vt_aprovacoes_excecao FOR SELECT TO authenticated USING (
 public.vt_papel() IN ('admin','coordenador','gestao_adm_vendas')
 OR supervisor_tecnico_id=auth.uid()
);
-- Bloqueia exposição de exceções não aprovadas e rascunhos aos executores.
CREATE OR REPLACE FUNCTION public.vt_visita_visivel(p_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public AS $$
 SELECT EXISTS(
 SELECT 1 FROM public.visitas_tecnicas v
 LEFT JOIN public.vt_aprovacoes_excecao e ON e.atendimento_id=v.atendimento_id
 LEFT JOIN public.agendas_tecnicas_semanais a ON a.id=v.agenda_semana_id
 WHERE v.id=p_id AND (
   public.vt_papel() IN ('admin','coordenador','gestao_adm_vendas')
   OR v.supervisor_id=auth.uid()
   OR (public.vt_papel()='lider_tec_panificacao' AND
       (v.tecnico_id=auth.uid() OR EXISTS(SELECT 1 FROM public.usuarios t WHERE t.id=v.tecnico_id AND t.supervisor_id=auth.uid())))
   OR (v.tecnico_id=auth.uid() AND
      (e.atendimento_id IS NOT NULL AND e.status='aprovada'
       OR v.tipo_agendamento='normal' AND (a.status='aprovada' OR v.agenda_semana_id IS NULL) AND e.atendimento_id IS NULL))
 ))
$$;
DROP POLICY IF EXISTS visitas_tecnicas_select ON public.visitas_tecnicas;
CREATE POLICY visitas_tecnicas_select ON public.visitas_tecnicas FOR SELECT TO authenticated
 USING(public.vt_visita_visivel(id));
-- Remove políticas de escrita diretas para impedir bypass das aprovações.
DO $$
DECLARE pol record;
BEGIN
 FOR pol IN SELECT policyname FROM pg_policies
 WHERE schemaname='public' AND tablename='visitas_tecnicas' AND cmd IN ('INSERT','UPDATE','DELETE','ALL')
 LOOP EXECUTE format('DROP POLICY IF EXISTS %I ON public.visitas_tecnicas',pol.policyname); END LOOP;
END $$;
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
 IF p_excecao AND length(trim(p_justificativa))<5 THEN RAISE EXCEPTION 'Justificativa da exceção obrigatória'; END IF;
 IF p_duracao NOT BETWEEN 15 AND 600 THEN RAISE EXCEPTION 'Duração inválida'; END IF;
 SELECT count(DISTINCT id) INTO v_count FROM unnest(p_participantes) AS id;
 IF v_count=0 OR v_count>20 OR v_count<>coalesce(array_length(p_participantes,1),0) THEN RAISE EXCEPTION 'Selecione entre 1 e 20 participantes, sem repetição';END IF;
 IF v_papel='lider_tec_panificacao' THEN
   SELECT supervisor_id INTO v_supervisor FROM public.usuarios WHERE id=auth.uid() AND ativo=true;
   v_lider:=auth.uid();
 ELSE v_supervisor:=auth.uid(); END IF;
 IF v_supervisor IS NULL THEN RAISE EXCEPTION 'Supervisor técnico não vinculado';END IF;
 SELECT vendedor.supervisor_id INTO v_cliente_supervisor
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
             (v_role='tec_panificacao' AND v_parent=auth.uid())) THEN
       RAISE EXCEPTION 'Líder só pode agendar a si mesmo e técnicos da própria equipe';END IF;
   ELSE
     IF NOT ((v_role='supervisor_tec_panificacao' AND v_part=auth.uid()) OR
             (v_role='lider_tec_panificacao' AND v_parent=auth.uid()) OR
             (v_role='tec_panificacao' AND EXISTS(SELECT 1 FROM public.usuarios l WHERE l.id=v_parent AND l.supervisor_id=auth.uid() AND l.papel::text='lider_tec_panificacao'))) THEN
       RAISE EXCEPTION 'Supervisor só pode agendar a si mesmo, seus líderes e seus técnicos';END IF;
   END IF;
   IF NOT p_excecao THEN
     v_lider:=CASE WHEN v_role='tec_panificacao' THEN v_parent
                   WHEN v_role='lider_tec_panificacao' THEN v_part
                   ELSE v_supervisor END;
     INSERT INTO public.agendas_tecnicas_semanais(tecnico_id,lider_id,supervisor_id,semana_inicio)
     VALUES(v_part,v_lider,v_supervisor,v_semana) ON CONFLICT(tecnico_id,semana_inicio) DO NOTHING;
     SELECT * INTO v_agenda FROM public.agendas_tecnicas_semanais
      WHERE tecnico_id=v_part AND semana_inicio=v_semana FOR UPDATE;
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
 IF p_excecao OR v_papel='supervisor_tec_panificacao' THEN
   INSERT INTO public.vt_aprovacoes_excecao(atendimento_id,supervisor_tecnico_id,justificativa)
   VALUES(v_atendimento,v_supervisor,CASE WHEN p_excecao THEN p_justificativa ELSE 'Agendamento normal criado pelo Supervisor Tec — requer Coordenador Comercial' END);
 END IF;
 RETURN v_atendimento;
END $$;
CREATE OR REPLACE FUNCTION public.vt_decidir_excecao(p_atendimento uuid,p_aprovar boolean,p_motivo text DEFAULT '')
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v public.vt_aprovacoes_excecao%ROWTYPE;
BEGIN
 IF public.vt_papel()<>'coordenador' THEN RAISE EXCEPTION 'Somente Coordenador Comercial pode aprovar exceções';END IF;
 SELECT * INTO v FROM public.vt_aprovacoes_excecao WHERE atendimento_id=p_atendimento FOR UPDATE;
 IF NOT FOUND OR v.status<>'pendente' THEN RAISE EXCEPTION 'Exceção não está pendente';END IF;
 IF NOT p_aprovar AND length(trim(p_motivo))=0 THEN RAISE EXCEPTION 'Informe motivo da devolução';END IF;
 UPDATE public.vt_aprovacoes_excecao SET status=CASE WHEN p_aprovar THEN 'aprovada' ELSE 'devolvida' END,
 aprovado_por=auth.uid(),aprovado_em=now(),coordenador_id=auth.uid(),motivo_devolucao=CASE WHEN p_aprovar THEN null ELSE p_motivo END
 WHERE atendimento_id=p_atendimento;
END $$;
-- Restringe também o registro de GPS dos novos atendimentos não aprovados.
-- A RPC registrar_visita_tecnica original deve ser atualizada para verificar
-- vt_visita_aprovada(id) antes do check-in e checkout.
CREATE OR REPLACE FUNCTION public.vt_visita_aprovada(p_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public AS $$
 SELECT EXISTS(SELECT 1 FROM public.visitas_tecnicas v
 LEFT JOIN public.agendas_tecnicas_semanais a ON a.id=v.agenda_semana_id
 LEFT JOIN public.vt_aprovacoes_excecao e ON e.atendimento_id=v.atendimento_id
 WHERE v.id=p_id AND (
 (v.tipo_agendamento='normal' AND e.atendimento_id IS NULL AND (a.status='aprovada' OR v.agenda_semana_id IS NULL))
 OR (e.atendimento_id IS NOT NULL AND e.status='aprovada')))
$$;
REVOKE ALL ON FUNCTION public.vt_agendar_equipe(uuid[],uuid,date,time,integer,text,text,boolean,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.vt_decidir_excecao(uuid,boolean,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.vt_agendar_equipe(uuid[],uuid,date,time,integer,text,text,boolean,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.vt_decidir_excecao(uuid,boolean,text) TO authenticated;

-- Atualiza a função GPS para impedir check-in antes da aprovação.
CREATE OR REPLACE FUNCTION public.registrar_visita_tecnica(
 p_id uuid,p_acao text,p_relatorio text DEFAULT '',
 p_latitude double precision DEFAULT null,p_longitude double precision DEFAULT null,p_precisao_m double precision DEFAULT null
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v public.visitas_tecnicas%ROWTYPE;
BEGIN
 SELECT * INTO v FROM public.visitas_tecnicas WHERE id=p_id FOR UPDATE;
 IF NOT FOUND OR v.tecnico_id<>auth.uid() OR public.vt_papel() NOT IN
 ('tec_panificacao','lider_tec_panificacao','supervisor_tec_panificacao')
 THEN RAISE EXCEPTION 'Participante não autorizado';END IF;
 IF NOT public.vt_visita_aprovada(p_id) THEN RAISE EXCEPTION 'Visita não aprovada';END IF;
 IF p_latitude IS NULL OR p_longitude IS NULL OR p_latitude NOT BETWEEN -90 AND 90
 OR p_longitude NOT BETWEEN -180 AND 180 THEN RAISE EXCEPTION 'Localização inválida';END IF;
 IF p_acao='checkin' AND v.status='agendada' THEN
  UPDATE public.visitas_tecnicas SET checkin_em=now(),status='em_andamento',
  checkin_latitude=p_latitude,checkin_longitude=p_longitude,checkin_precisao_m=p_precisao_m WHERE id=p_id;
 ELSIF p_acao='checkout' AND v.status='em_andamento' AND length(trim(p_relatorio))>0 THEN
  UPDATE public.visitas_tecnicas SET checkout_em=now(),status='concluida',
  relatorio_qualidade=p_relatorio,checkout_latitude=p_latitude,
  checkout_longitude=p_longitude,checkout_precisao_m=p_precisao_m WHERE id=p_id;
 ELSE RAISE EXCEPTION 'Transição inválida ou relatório ausente';END IF;
END $$;
-- Desabilita RPC antiga que não conhece participantes/territórios.
REVOKE EXECUTE ON FUNCTION public.vt_criar_visita(uuid,uuid,date,time,integer,text,text,boolean) FROM authenticated;
COMMIT;
