-- Meu Cliente - fluxo semanal de aprovação da Visita Técnica (27/10/2026)
-- Pré-requisitos: visita_tecnica.sql e visita_tecnica_inteligente.sql aplicados.
-- Executar no SQL Editor do Supabase de produção APÓS revisão/backup.
BEGIN;
ALTER TABLE public.usuarios DROP CONSTRAINT IF EXISTS usuarios_papel_check;
ALTER TABLE public.usuarios ADD CONSTRAINT usuarios_papel_check CHECK (papel::text IN
 ('vendedor','supervisor','coordenador','analise_credito','financeiro','manutencao',
  'adm_vendas','gestao_adm_vendas','tecnico','supervisor_tec_panificacao',
  'lider_tec_panificacao','tec_panificacao','diretoria','admin'));
-- supervisor_id do líder aponta ao Supervisor Tec Panificação.
-- supervisor_id do técnico aponta ao Líder Tec Panificação (vínculos legados são preservados).
CREATE TABLE IF NOT EXISTS public.agendas_tecnicas_semanais (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 tecnico_id uuid NOT NULL REFERENCES public.usuarios(id),
 lider_id uuid NOT NULL REFERENCES public.usuarios(id),
 supervisor_id uuid NOT NULL REFERENCES public.usuarios(id),
 semana_inicio date NOT NULL,
 status text NOT NULL DEFAULT 'rascunho' CHECK(status IN ('rascunho','pendente','aprovada','devolvida')),
 enviado_em timestamptz,
 aprovado_em timestamptz,
 aprovado_por uuid REFERENCES public.usuarios(id),
 observacao_aprovacao text,
 criado_em timestamptz NOT NULL DEFAULT now(),
 atualizado_em timestamptz NOT NULL DEFAULT now(),
 UNIQUE(tecnico_id,semana_inicio),
 CHECK(EXTRACT(ISODOW FROM semana_inicio)=1)
);
ALTER TABLE public.visitas_tecnicas ADD COLUMN IF NOT EXISTS agenda_semana_id uuid REFERENCES public.agendas_tecnicas_semanais(id);
ALTER TABLE public.visitas_tecnicas ADD COLUMN IF NOT EXISTS lider_acompanha boolean NOT NULL DEFAULT false;
CREATE INDEX IF NOT EXISTS idx_agendas_semanais_supervisor ON public.agendas_tecnicas_semanais(supervisor_id,semana_inicio);
CREATE INDEX IF NOT EXISTS idx_agendas_semanais_lider ON public.agendas_tecnicas_semanais(lider_id,semana_inicio);
CREATE INDEX IF NOT EXISTS idx_visitas_agenda_semana ON public.visitas_tecnicas(agenda_semana_id);
ALTER TABLE public.agendas_tecnicas_semanais ENABLE ROW LEVEL SECURITY;
CREATE OR REPLACE FUNCTION public.vt_papel() RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public AS $$
 SELECT papel::text FROM public.usuarios WHERE id=auth.uid() AND ativo=true LIMIT 1
$$;
CREATE OR REPLACE FUNCTION public.vt_equipe_lider(p_lider uuid) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public AS $$
 SELECT EXISTS(SELECT 1 FROM public.usuarios l WHERE l.id=p_lider AND l.papel::text='lider_tec_panificacao' AND l.supervisor_id=auth.uid() AND l.ativo=true)
$$;
CREATE OR REPLACE FUNCTION public.vt_agenda_visivel(p_agenda uuid) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public AS $$
 SELECT EXISTS(SELECT 1 FROM public.agendas_tecnicas_semanais a WHERE a.id=p_agenda AND
   (public.vt_papel() IN ('admin','coordenador','gestao_adm_vendas')
    OR a.lider_id=auth.uid() OR a.supervisor_id=auth.uid()
    OR (a.tecnico_id=auth.uid() AND a.status='aprovada')))
$$;
CREATE POLICY vt_agendas_select ON public.agendas_tecnicas_semanais FOR SELECT TO authenticated USING (
 public.vt_papel() IN ('admin','coordenador','gestao_adm_vendas')
 OR lider_id=auth.uid() OR supervisor_id=auth.uid()
 OR (tecnico_id=auth.uid() AND status='aprovada')
);
-- Operações de gravação somente pelas RPCs SECURITY DEFINER abaixo.
-- A migração remove políticas antigas das visitas para evitar leitura de rascunhos por técnicos.
DROP POLICY IF EXISTS visitas_tecnicas_select ON public.visitas_tecnicas;
CREATE POLICY visitas_tecnicas_select ON public.visitas_tecnicas FOR SELECT TO authenticated USING (
 (agenda_semana_id IS NULL AND
   (public.vt_papel() IN ('admin','coordenador','gestao_adm_vendas')
    OR tecnico_id=auth.uid()
    OR (public.vt_papel()='supervisor_tec_panificacao' AND public.visita_tecnica_equipe(tecnico_id))))
 OR (agenda_semana_id IS NOT NULL AND public.vt_agenda_visivel(agenda_semana_id))
);
DROP POLICY IF EXISTS visitas_tecnicas_insert ON public.visitas_tecnicas;
-- RPC de criação: só o líder da equipe agenda visitas novas.
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
 INSERT INTO public.agendas_tecnicas_semanais(tecnico_id,lider_id,supervisor_id,semana_inicio)
 VALUES(p_tecnico,v_lider,v_supervisor,v_semana)
 ON CONFLICT(tecnico_id,semana_inicio) DO NOTHING;
 SELECT * INTO v_agenda FROM public.agendas_tecnicas_semanais WHERE tecnico_id=p_tecnico AND semana_inicio=v_semana FOR UPDATE;
 IF v_agenda.lider_id<>auth.uid() THEN RAISE EXCEPTION 'Agenda vinculada a outro líder';END IF;
 IF v_agenda.status IN ('pendente','aprovada') THEN RAISE EXCEPTION 'Agenda enviada/aprovada: devolução necessária antes de editar';END IF;
 INSERT INTO public.visitas_tecnicas(cliente_id,tecnico_id,supervisor_id,data_visita,hora_inicio,duracao_min,objetivo,observacoes,status,agenda_semana_id,lider_acompanha)
 VALUES(p_cliente,p_tecnico,v_supervisor,p_data,p_hora,p_duracao,coalesce(p_objetivo,''),coalesce(p_observacoes,''),'agendada',v_agenda.id,p_acompanha)
 RETURNING id INTO v_id;
 RETURN v_id;
END $$;
CREATE OR REPLACE FUNCTION public.vt_tramitar_agenda(p_agenda uuid,p_acao text,p_justificativa text DEFAULT '')
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE a public.agendas_tecnicas_semanais%ROWTYPE;v_qtd integer;
BEGIN
 SELECT * INTO a FROM public.agendas_tecnicas_semanais WHERE id=p_agenda FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Agenda não encontrada';END IF;
 IF p_acao='enviar' THEN
   IF a.lider_id<>auth.uid() OR public.vt_papel()<>'lider_tec_panificacao' OR a.status NOT IN ('rascunho','devolvida') THEN RAISE EXCEPTION 'Envio não permitido';END IF;
   SELECT count(*) INTO v_qtd FROM public.visitas_tecnicas WHERE agenda_semana_id=a.id;
   IF v_qtd=0 THEN RAISE EXCEPTION 'Agenda vazia';END IF;
   UPDATE public.agendas_tecnicas_semanais SET status='pendente',enviado_em=now(),atualizado_em=now(),observacao_aprovacao=null WHERE id=a.id;
 ELSIF p_acao IN ('aprovar','devolver') THEN
   IF a.supervisor_id<>auth.uid() OR public.vt_papel()<>'supervisor_tec_panificacao' OR a.status<>'pendente' THEN RAISE EXCEPTION 'Aprovação não permitida';END IF;
   IF p_acao='devolver' AND length(trim(p_justificativa))=0 THEN RAISE EXCEPTION 'Informe motivo da devolução';END IF;
   UPDATE public.agendas_tecnicas_semanais SET status=CASE WHEN p_acao='aprovar' THEN 'aprovada' ELSE 'devolvida' END,
     aprovado_em=CASE WHEN p_acao='aprovar' THEN now() ELSE null END,
     aprovado_por=CASE WHEN p_acao='aprovar' THEN auth.uid() ELSE null END,
     observacao_aprovacao=CASE WHEN p_acao='devolver' THEN p_justificativa ELSE null END,atualizado_em=now()
   WHERE id=a.id;
 ELSE RAISE EXCEPTION 'Ação inválida';END IF;
END $$;
-- Proteção adicional do check-in: agenda semanal deve estar aprovada.
-- Mantém assinatura GPS já usada pelo HTML.
CREATE OR REPLACE FUNCTION public.registrar_visita_tecnica(
 p_id uuid,p_acao text,p_relatorio text DEFAULT '',
 p_latitude double precision DEFAULT null,p_longitude double precision DEFAULT null,p_precisao_m double precision DEFAULT null
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v public.visitas_tecnicas%ROWTYPE;
BEGIN
 SELECT * INTO v FROM public.visitas_tecnicas WHERE id=p_id FOR UPDATE;
 IF NOT FOUND OR v.tecnico_id<>auth.uid() OR public.vt_papel()<>'tec_panificacao' THEN RAISE EXCEPTION 'Visita não autorizada';END IF;
 IF v.agenda_semana_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.agendas_tecnicas_semanais WHERE id=v.agenda_semana_id AND status='aprovada') THEN
   RAISE EXCEPTION 'Agenda ainda não aprovada';
 END IF;
 IF p_latitude IS NULL OR p_longitude IS NULL OR p_latitude NOT BETWEEN -90 AND 90 OR p_longitude NOT BETWEEN -180 AND 180 THEN RAISE EXCEPTION 'Localização inválida';END IF;
 IF p_acao='checkin' AND v.status='agendada' THEN
   UPDATE public.visitas_tecnicas SET checkin_em=now(),status='em_andamento',checkin_latitude=p_latitude,checkin_longitude=p_longitude,checkin_precisao_m=p_precisao_m WHERE id=p_id;
 ELSIF p_acao='checkout' AND v.status='em_andamento' AND length(trim(p_relatorio))>0 THEN
   UPDATE public.visitas_tecnicas SET checkout_em=now(),status='concluida',relatorio_qualidade=p_relatorio,checkout_latitude=p_latitude,checkout_longitude=p_longitude,checkout_precisao_m=p_precisao_m WHERE id=p_id;
 ELSE RAISE EXCEPTION 'Transição inválida ou relatório ausente';END IF;
END $$;
REVOKE ALL ON FUNCTION public.vt_criar_visita(uuid,uuid,date,time,integer,text,text,boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.vt_tramitar_agenda(uuid,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.vt_criar_visita(uuid,uuid,date,time,integer,text,text,boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.vt_tramitar_agenda(uuid,text,text) TO authenticated;
COMMIT;
-- Observações: cadastros legados permanecem; visitas antigas sem agenda_semana_id não são apagadas.
-- Para técnicos legados: vincule supervisor_id ao novo Líder na tela Usuários.
-- O bloqueio de conflito de deslocamento continua pré-validado no HTML; para concorrência simultânea,
-- implemente validação transacional de trajetos em serviço próprio.
