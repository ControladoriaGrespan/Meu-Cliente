-- MEU CLIENTE / Visita Técnica v2. Nov/2026
-- Executar no SQL Editor Supabase. Back-up recomendado.
-- Mantem IDs, visitas legadas, registros de check-in e relatórios anteriores.
BEGIN;
ALTER TABLE public.visitas_tecnicas ADD COLUMN IF NOT EXISTS tipo_atendimento text NOT NULL DEFAULT 'producao';
ALTER TABLE public.visitas_tecnicas DROP CONSTRAINT IF EXISTS vt_tipo_atendimento_check;
ALTER TABLE public.visitas_tecnicas ADD CONSTRAINT vt_tipo_atendimento_check CHECK(tipo_atendimento IN ('producao','treinamento'));
CREATE TABLE IF NOT EXISTS public.vt_lider_tecnicos(
 lider_id uuid NOT NULL REFERENCES public.usuarios(id),
 tecnico_id uuid NOT NULL REFERENCES public.usuarios(id),
 ativo boolean NOT NULL DEFAULT true,
 criado_em timestamptz NOT NULL DEFAULT now(),
 criado_por uuid REFERENCES public.usuarios(id),
 PRIMARY KEY(lider_id,tecnico_id),
 CHECK(lider_id<>tecnico_id)
);
CREATE INDEX IF NOT EXISTS vt_lider_tecnicos_tecnico_idx ON public.vt_lider_tecnicos(tecnico_id) WHERE ativo=true;
ALTER TABLE public.vt_lider_tecnicos ENABLE ROW LEVEL SECURITY;
-- Supervisao semanal: dois lideres podem consultar o planejamento
-- mas somente o lider responsavel pela agenda pode enviá-la para aprovação.
DROP POLICY IF EXISTS vt_agendas_select ON public.agendas_tecnicas_semanais;
CREATE POLICY vt_agendas_select ON public.agendas_tecnicas_semanais
 FOR SELECT TO authenticated USING (
    public.vt_papel() IN ('admin','coordenador','gestao_adm_vendas')
    OR lider_id=auth.uid() OR supervisor_id=auth.uid()
    OR (tecnico_id=auth.uid() AND status='aprovada')
    OR (public.vt_papel()='lider_tec_panificacao' AND EXISTS (
        SELECT 1 FROM public.vt_lider_tecnicos d
        WHERE d.tecnico_id=agendas_tecnicas_semanais.tecnico_id
          AND d.lider_id=auth.uid() AND d.ativo
    ))
 );
DROP POLICY IF EXISTS vt_lider_tecnicos_select ON public.vt_lider_tecnicos;
CREATE POLICY vt_lider_tecnicos_select ON public.vt_lider_tecnicos
 FOR SELECT TO authenticated USING (
   EXISTS(SELECT 1 FROM public.usuarios u WHERE u.id=auth.uid() AND u.ativo=true
      AND (u.papel='admin' OR lider_id=u.id OR tecnico_id=u.id
           OR (u.papel='supervisor_tec_panificacao' AND EXISTS(
              SELECT 1 FROM public.usuarios l WHERE l.id=lider_id AND l.supervisor_id=u.id))))
 );
DROP POLICY IF EXISTS vt_lider_tecnicos_insert ON public.vt_lider_tecnicos;
CREATE POLICY vt_lider_tecnicos_insert ON public.vt_lider_tecnicos
 FOR INSERT TO authenticated WITH CHECK (
    EXISTS(SELECT 1 FROM public.usuarios u WHERE u.id=auth.uid() AND u.ativo=true AND u.papel='admin')
 );
DROP POLICY IF EXISTS vt_lider_tecnicos_update ON public.vt_lider_tecnicos;
CREATE POLICY vt_lider_tecnicos_update ON public.vt_lider_tecnicos
 FOR UPDATE TO authenticated USING (
    EXISTS(SELECT 1 FROM public.usuarios u WHERE u.id=auth.uid() AND u.ativo=true AND u.papel='admin')
 ) WITH CHECK (
    EXISTS(SELECT 1 FROM public.usuarios u WHERE u.id=auth.uid() AND u.ativo=true AND u.papel='admin')
 );
DROP POLICY IF EXISTS vt_lider_tecnicos_delete ON public.vt_lider_tecnicos;
CREATE POLICY vt_lider_tecnicos_delete ON public.vt_lider_tecnicos
 FOR DELETE TO authenticated USING (
    EXISTS(SELECT 1 FROM public.usuarios u WHERE u.id=auth.uid() AND u.ativo=true AND u.papel='admin')
 );
-- Matriz adicional nao substitui o líder principal (usuarios.supervisor_id).
-- É possível vincular um técnico a dois líderes simultaneamente.

-- Aprimora agendamento existente preservando assinatura da RPC e regras de territorio.
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
 IF NOT p_excecao AND v_papel<>'lider_tec_panificacao' THEN RAISE EXCEPTION 'Planejamento normal deve ser feito pelo Lider e aprovado pelo Supervisor'; END IF;
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
     INSERT INTO public.agendas_tecnicas_semanais(tecnico_id,lider_id,supervisor_id,semana_inicio)
     VALUES(v_part,v_lider,v_supervisor,v_semana) ON CONFLICT(tecnico_id,semana_inicio) DO NOTHING;
     SELECT * INTO v_agenda FROM public.agendas_tecnicas_semanais
      WHERE tecnico_id=v_part AND semana_inicio=v_semana FOR UPDATE;
     IF v_agenda.supervisor_id<>v_supervisor
       THEN RAISE EXCEPTION 'A agenda pertence a outro Supervisor Técnico'; END IF;
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


-- Aprovacao semanal permanece obrigatoria para visitas planejadas.
-- O atendimento imediato nao e um planejamento antecipado; so o proprio
-- Lider ou Supervisor pode inicia-lo, e sua localizacao e registrada imediatamente.
CREATE OR REPLACE FUNCTION public.vt_checkin_imediato(
 p_cliente uuid, p_latitude double precision,p_longitude double precision,
 p_precisao_m double precision DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_papel text:=public.vt_papel();v_supervisor uuid;
 v_supervisor_comercial uuid;v_cliente public.clientes%ROWTYPE;v_id uuid;
 v_agora timestamp:=now() AT TIME ZONE 'America/Sao_Paulo';
BEGIN
 IF v_papel NOT IN ('lider_tec_panificacao','supervisor_tec_panificacao')
   THEN RAISE EXCEPTION 'Check-in imediato exclusivo de Lider e Supervisor Tecnico'; END IF;
 IF p_latitude IS NULL OR p_longitude IS NULL OR p_latitude NOT BETWEEN -90 AND 90
    OR p_longitude NOT BETWEEN -180 AND 180
   THEN RAISE EXCEPTION 'Localizacao GPS obrigatoria e valida'; END IF;
 SELECT * INTO v_cliente FROM public.clientes WHERE id=p_cliente;
 IF NOT FOUND THEN RAISE EXCEPTION 'Cliente nao encontrado'; END IF;
 v_supervisor:=CASE WHEN v_papel='supervisor_tec_panificacao' THEN auth.uid()
   ELSE (SELECT u.supervisor_id FROM public.usuarios u WHERE u.id=auth.uid()) END;
 SELECT CASE WHEN u.papel::text='supervisor' THEN u.id ELSE u.supervisor_id END
   INTO v_supervisor_comercial FROM public.usuarios u WHERE u.id=v_cliente.vendedor_id;
 IF NOT EXISTS(SELECT 1 FROM public.vt_supervisor_comercial_tecnico m
       WHERE m.supervisor_tecnico_id=v_supervisor AND m.supervisor_comercial_id=v_supervisor_comercial)
   THEN RAISE EXCEPTION 'Cliente fora da carteira. Check-in imediato nao permite excecao; use o planejamento do Supervisor'; END IF;
 IF EXISTS(SELECT 1 FROM public.visitas_tecnicas v
       WHERE v.tecnico_id=auth.uid() AND v.status='em_andamento')
   THEN RAISE EXCEPTION 'Ja existe visita em andamento. Finalize o check-out antes de iniciar outra'; END IF;
 INSERT INTO public.visitas_tecnicas(
     cliente_id,tecnico_id,supervisor_id,data_visita,hora_inicio,duracao_min,
     objetivo,observacoes,status,tipo_agendamento,tipo_atendimento,criador_papel,
     checkin_em,checkin_latitude,checkin_longitude,checkin_precisao_m)
 VALUES(p_cliente,auth.uid(),v_supervisor,v_agora::date,v_agora::time,60,
     'Atendimento presencial imediato','Check-in feito em campo',
     'em_andamento','imediato','producao',v_papel,now(),p_latitude,p_longitude,p_precisao_m)
 RETURNING id INTO v_id;
 RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION public.vt_checkin_imediato(uuid,double precision,double precision,double precision) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.vt_checkin_imediato(uuid,double precision,double precision,double precision) TO authenticated;

-- Visitas imediatas são válidas apenas para quem as criou/participa.
-- Os técnicos continuam sem enxergar planejamentos antes da aprovação.
CREATE OR REPLACE FUNCTION public.vt_visita_aprovada(p_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
 SELECT EXISTS(SELECT 1 FROM public.visitas_tecnicas v
 LEFT JOIN public.agendas_tecnicas_semanais a ON a.id=v.agenda_semana_id
 LEFT JOIN public.vt_aprovacoes_excecao e ON e.atendimento_id=v.atendimento_id
 WHERE v.id=p_id AND (
  (v.tipo_agendamento='imediato' AND v.tecnico_id=auth.uid() AND
    public.vt_papel() IN ('lider_tec_panificacao','supervisor_tec_panificacao'))
  OR (v.tipo_agendamento='normal' AND e.atendimento_id IS NULL AND a.status='aprovada')
  OR (e.atendimento_id IS NOT NULL AND e.status='aprovada')))
$$;
CREATE OR REPLACE FUNCTION public.vt_visita_visivel(p_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
 SELECT EXISTS(
 SELECT 1 FROM public.visitas_tecnicas v
 LEFT JOIN public.vt_aprovacoes_excecao e ON e.atendimento_id=v.atendimento_id
 LEFT JOIN public.agendas_tecnicas_semanais a ON a.id=v.agenda_semana_id
 WHERE v.id=p_id AND (
   public.vt_papel() IN ('admin','coordenador','gestao_adm_vendas')
   OR v.supervisor_id=auth.uid()
   OR (public.vt_papel()='lider_tec_panificacao' AND
       (v.tecnico_id=auth.uid() OR EXISTS(
        SELECT 1 FROM public.usuarios t
        WHERE t.id=v.tecnico_id AND t.supervisor_id=auth.uid())
        OR EXISTS(SELECT 1 FROM public.vt_lider_tecnicos d
        WHERE d.tecnico_id=v.tecnico_id AND d.lider_id=auth.uid() AND d.ativo)))
   OR (v.tecnico_id=auth.uid() AND
       (v.tipo_agendamento='imediato'
        OR (e.atendimento_id IS NOT NULL AND e.status='aprovada')
        OR (v.tipo_agendamento='normal' AND a.status='aprovada' AND e.atendimento_id IS NULL)))
 ))
$$;

-- Lote de visitas por intervalo, uma só transação. O líder envia a agenda
-- e o Supervisor aprova depois. Retorno: numero de dias e IDs de atendimentos.
CREATE OR REPLACE FUNCTION public.vt_programar_periodo(
 p_participantes uuid[],p_cliente uuid,p_inicio date,p_fim date,
 p_dias integer[],p_hora_inicio time,p_hora_fim time,
 p_tipo_atendimento text,p_objetivo text,p_observacoes text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_data date;v_contador integer:=0;v_ids uuid[]:='{}';
 v_atendimento uuid;v_duracao integer;
BEGIN
 IF public.vt_papel()<>'lider_tec_panificacao'
   THEN RAISE EXCEPTION 'Somente o Lider Tecnico programa visitas. O Supervisor aprova as agendas'; END IF;
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
REVOKE ALL ON FUNCTION public.vt_programar_periodo(uuid[],uuid,date,date,integer[],time,time,text,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.vt_programar_periodo(uuid[],uuid,date,date,integer[],time,time,text,text,text) TO authenticated;
-- Permissoes de tabela para usuarios autenticados, limitadas por RLS acima.
GRANT SELECT,INSERT,UPDATE,DELETE ON public.vt_lider_tecnicos TO authenticated;

-- Informacoes do cliente apenas para visitas que o usuario pode visualizar.
-- Corrige agenda com nome em branco quando SELECT direto de clientes sofre RLS.
CREATE OR REPLACE FUNCTION public.vt_clientes_visitas(p_visitas uuid[])
RETURNS TABLE(
  visita_id uuid,id uuid,codigo_totvs text,razao_social text,nome_fantasia text,
  cidade text,estado text,endereco_logradouro text,endereco_numero text,
  endereco_bairro text,endereco_cep text,endereco_latitude double precision,
  endereco_longitude double precision
) LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Autenticacao obrigatoria';END IF;
 IF coalesce(array_length(p_visitas,1),0)>100 OR p_visitas IS NULL
   THEN RAISE EXCEPTION 'Informe ate 100 visitas';END IF;
 RETURN QUERY
 SELECT v.id,c.id,c.codigo_totvs::text,c.razao_social::text,c.nome_fantasia::text,
   c.cidade::text,c.estado::text,c.endereco_logradouro::text,c.endereco_numero::text,
   c.endereco_bairro::text,c.endereco_cep::text,
   c.endereco_latitude::double precision,c.endereco_longitude::double precision
 FROM public.visitas_tecnicas v JOIN public.clientes c ON c.id=v.cliente_id
 WHERE v.id=ANY(p_visitas) AND public.vt_visita_visivel(v.id);
END $;
REVOKE ALL ON FUNCTION public.vt_clientes_visitas(uuid[]) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.vt_clientes_visitas(uuid[]) TO authenticated;


-- Exceção territorial: também respeita a classificação Produção/Treinamento.
CREATE OR REPLACE FUNCTION public.vt_agendar_excecao(
 p_participantes uuid[],p_cliente uuid,p_data date,p_hora time,p_duracao integer,
 p_tipo_atendimento text,p_objetivo text,p_observacoes text,p_justificativa text
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $
DECLARE v_atendimento uuid;
BEGIN
 IF public.vt_papel()<>'supervisor_tec_panificacao'
   THEN RAISE EXCEPTION 'Somente Supervisor Técnico pode agendar exceções';END IF;
 IF p_tipo_atendimento NOT IN ('producao','treinamento')
   THEN RAISE EXCEPTION 'Tipo de atendimento inválido';END IF;
 v_atendimento:=public.vt_agendar_equipe(
    p_participantes,p_cliente,p_data,p_hora,p_duracao,
    p_objetivo,p_observacoes,true,p_justificativa);
 UPDATE public.visitas_tecnicas SET tipo_atendimento=p_tipo_atendimento
 WHERE atendimento_id=v_atendimento;
 RETURN v_atendimento;
END $;
REVOKE ALL ON FUNCTION public.vt_agendar_excecao(uuid[],uuid,date,time,integer,text,text,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.vt_agendar_excecao(uuid[],uuid,date,time,integer,text,text,text,text) TO authenticated;

COMMIT;
