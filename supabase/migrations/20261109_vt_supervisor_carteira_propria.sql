-- Ajuste para supervisor comercial que atende clientes como vendedor.
-- Executar no Supabase SQL Editor (sem alterar tabelas ou clientes).
-- A busca e a gravacao usam a mesma regra para evitar falso 'fora da carteira'.
BEGIN;

CREATE OR REPLACE FUNCTION public.vt_buscar_clientes(p_busca text, p_limite integer DEFAULT 80)
RETURNS TABLE (
  id uuid,
  codigo_totvs text,
  razao_social text,
  nome_fantasia text,
  cidade text,
  estado text,
  vendedor_id uuid,
  endereco_logradouro text,
  endereco_numero text,
  endereco_bairro text,
  endereco_cep text,
  endereco_complemento text,
  dentro_carteira boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_papel text;
  v_supervisor uuid;
  v_termo text;
  v_partes text[];
BEGIN
  SELECT u.papel::text INTO v_papel
    FROM public.usuarios u
   WHERE u.id = auth.uid() AND u.ativo IS DISTINCT FROM false;
  IF v_papel IS NULL OR v_papel NOT IN (
    'admin','coordenador','gestao_adm_vendas',
    'supervisor_tec_panificacao','lider_tec_panificacao','tec_panificacao'
  ) THEN
    RAISE EXCEPTION 'Perfil sem permissao de consulta de clientes para visitas';
  END IF;

  v_termo := btrim(coalesce(p_busca,''));
  IF length(v_termo) < 2 OR length(v_termo) > 100 THEN
    RAISE EXCEPTION 'Informe de 2 a 100 caracteres para pesquisar';
  END IF;
  IF p_limite IS NULL OR p_limite < 1 OR p_limite > 100 THEN
    RAISE EXCEPTION 'Limite fora do intervalo 1 a 100';
  END IF;

  -- Mesmo supervisor territorial empregado no agendamento de equipe.
  IF v_papel = 'supervisor_tec_panificacao' THEN v_supervisor := auth.uid();
  ELSIF v_papel = 'lider_tec_panificacao' THEN
    SELECT u.supervisor_id INTO v_supervisor FROM public.usuarios u WHERE u.id=auth.uid();
  ELSIF v_papel = 'tec_panificacao' THEN
    SELECT l.supervisor_id INTO v_supervisor
      FROM public.usuarios t JOIN public.usuarios l ON l.id=t.supervisor_id
     WHERE t.id=auth.uid();
  END IF;

  v_partes := regexp_split_to_array(v_termo,'[[:space:]]+');

  RETURN QUERY
  SELECT
    c.id, c.codigo_totvs::text, c.razao_social::text, c.nome_fantasia::text,
    c.cidade::text, c.estado::text, c.vendedor_id,
    CASE WHEN x.autorizado THEN c.endereco_logradouro::text ELSE NULL::text END,
    CASE WHEN x.autorizado THEN c.endereco_numero::text ELSE NULL::text END,
    CASE WHEN x.autorizado THEN c.endereco_bairro::text ELSE NULL::text END,
    CASE WHEN x.autorizado THEN c.endereco_cep::text ELSE NULL::text END,
    CASE WHEN x.autorizado THEN c.endereco_complemento::text ELSE NULL::text END,
    x.autorizado
  FROM public.clientes c
  LEFT JOIN public.usuarios vend ON vend.id=c.vendedor_id
  CROSS JOIN LATERAL (
    SELECT (
      v_papel IN ('admin','coordenador','gestao_adm_vendas')
      OR EXISTS (
        SELECT 1 FROM public.vt_supervisor_comercial_tecnico vinc
        WHERE vinc.supervisor_tecnico_id=v_supervisor
          AND vinc.supervisor_comercial_id=CASE WHEN vend.papel::text='supervisor' THEN vend.id ELSE vend.supervisor_id END
      )
    ) AS autorizado
  ) x
  WHERE NOT EXISTS (
    SELECT 1 FROM unnest(v_partes) t(palavra)
    WHERE NOT (
      coalesce(c.codigo_totvs::text,'') ILIKE '%' || regexp_replace(t.palavra, '[%_]', '', 'g') || '%'
      OR coalesce(c.razao_social::text,'') ILIKE '%' || regexp_replace(t.palavra, '[%_]', '', 'g') || '%'
      OR coalesce(c.nome_fantasia::text,'') ILIKE '%' || regexp_replace(t.palavra, '[%_]', '', 'g') || '%'
    )
  )
  ORDER BY CASE WHEN c.codigo_totvs::text=v_termo THEN 0 ELSE 1 END, c.razao_social
  LIMIT p_limite;
END;
$$;


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
 -- O responsavel comercial pode ser um vendedor comum ou o proprio
 -- supervisor comercial atendendo sua carteira diretamente.
 SELECT CASE WHEN vendedor.papel::text='supervisor' THEN vendedor.id
             ELSE vendedor.supervisor_id END INTO v_cliente_supervisor
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

COMMIT;
