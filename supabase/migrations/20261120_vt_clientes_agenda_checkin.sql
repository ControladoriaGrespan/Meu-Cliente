BEGIN;

-- A carteira do técnico segue o supervisor técnico do seu líder principal.
CREATE OR REPLACE FUNCTION public.vt_supervisor_do_atendimento()
RETURNS uuid LANGUAGE sql STABLE SET search_path=public,pg_temp AS $$
  SELECT CASE public.vt_papel()
    WHEN 'supervisor_tec_panificacao' THEN u.id
    WHEN 'lider_tec_panificacao' THEN u.supervisor_id
    WHEN 'tec_panificacao' THEN l.supervisor_id
  END
  FROM public.usuarios u
  LEFT JOIN public.usuarios l ON l.id=u.supervisor_id
  WHERE u.id=auth.uid()
$$;

CREATE OR REPLACE FUNCTION public.vt_vendedor_na_carteira(p_vendedor uuid,p_supervisor uuid)
RETURNS boolean LANGUAGE sql STABLE SET search_path=public,pg_temp AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.usuarios vend
    JOIN public.vt_supervisor_comercial_tecnico vinc ON vinc.supervisor_comercial_id=
      CASE WHEN vend.papel::text='supervisor' THEN vend.id ELSE vend.supervisor_id END
    WHERE vend.id=p_vendedor AND vinc.supervisor_tecnico_id=p_supervisor
  )
$$;

CREATE OR REPLACE FUNCTION public.vt_clientes_por_cidade(p_cidade text,p_uf text,p_pagina integer DEFAULT 0)
RETURNS TABLE (
  id uuid,codigo_totvs text,razao_social text,nome_fantasia text,cidade text,estado text,
  endereco_logradouro text,endereco_numero text,endereco_bairro text,endereco_cep text,
  endereco_latitude double precision,endereco_longitude double precision
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE
  v_supervisor uuid:=public.vt_supervisor_do_atendimento();
  v_acentos constant text:='áàâãäéèêëíìîïóòôõöúùûüç';
  v_sem_acentos constant text:='aaaaaeeeeiiiiooooouuuuc';
BEGIN
  IF v_supervisor IS NULL THEN RAISE EXCEPTION 'Perfil sem carteira técnica vinculada'; END IF;
  IF length(btrim(coalesce(p_cidade,''))) NOT BETWEEN 2 AND 120
      OR upper(btrim(coalesce(p_uf,''))) !~ '^[A-Z]{2}$'
      OR p_pagina IS NULL OR p_pagina NOT BETWEEN 0 AND 10000 THEN
    RAISE EXCEPTION 'Informe município, UF e página válidos';
  END IF;
  RETURN QUERY SELECT c.id,c.codigo_totvs::text,c.razao_social::text,c.nome_fantasia::text,
    c.cidade::text,c.estado::text,c.endereco_logradouro::text,c.endereco_numero::text,
    c.endereco_bairro::text,c.endereco_cep::text,c.endereco_latitude::double precision,c.endereco_longitude::double precision
  FROM public.clientes c
  WHERE upper(btrim(c.estado))=upper(btrim(p_uf))
    AND translate(lower(btrim(c.cidade)),v_acentos,v_sem_acentos)=
        translate(lower(btrim(p_cidade)),v_acentos,v_sem_acentos)
    AND public.vt_vendedor_na_carteira(c.vendedor_id,v_supervisor)
  ORDER BY lower(coalesce(nullif(btrim(c.nome_fantasia),''),c.razao_social)),c.codigo_totvs,c.id
  LIMIT 51 OFFSET p_pagina * 50;
END $$;

CREATE OR REPLACE FUNCTION public.vt_historico_visitas_cliente(p_cliente uuid,p_pagina integer DEFAULT 0)
RETURNS TABLE (
  id uuid,data_visita date,hora_inicio time,duracao_min integer,checkin_em timestamptz,
  checkout_em timestamptz,status text,tipo_atendimento text,tecnico_nome text,
  objetivo text,relato_execucao text
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_supervisor uuid:=public.vt_supervisor_do_atendimento();
BEGIN
  IF v_supervisor IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.clientes c WHERE c.id=p_cliente
    AND public.vt_vendedor_na_carteira(c.vendedor_id,v_supervisor)
  ) THEN RAISE EXCEPTION 'Cliente fora da carteira técnica'; END IF;
  IF p_pagina IS NULL OR p_pagina NOT BETWEEN 0 AND 10000 THEN
    RAISE EXCEPTION 'Informe página válida';
  END IF;
  RETURN QUERY SELECT v.id,v.data_visita,v.hora_inicio,v.duracao_min::integer,v.checkin_em,
    v.checkout_em,v.status::text,v.tipo_atendimento::text,u.nome::text,v.objetivo::text,v.relatorio_qualidade::text
  FROM public.visitas_tecnicas v
  LEFT JOIN public.usuarios u ON u.id=v.tecnico_id
  WHERE v.cliente_id=p_cliente AND v.status<>'cancelada'
    AND (v.checkout_em IS NOT NULL OR v.status='concluida'
      OR (v.checkin_em IS NOT NULL AND (v.checkin_em AT TIME ZONE 'America/Sao_Paulo')::date <
        (now() AT TIME ZONE 'America/Sao_Paulo')::date))
  ORDER BY v.data_visita DESC,v.hora_inicio DESC,v.id DESC
  LIMIT 51 OFFSET p_pagina * 50;
END $$;

CREATE OR REPLACE FUNCTION public.vt_checkin_imediato(
  p_cliente uuid,p_latitude double precision,p_longitude double precision,
  p_precisao_m double precision DEFAULT NULL
)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE
  v_papel text:=public.vt_papel();
  v_supervisor uuid:=public.vt_supervisor_do_atendimento();
  v_id uuid;
  v_registro timestamptz;
  v_agora timestamp;
BEGIN
  IF v_papel IS NULL OR v_papel NOT IN ('tec_panificacao','lider_tec_panificacao','supervisor_tec_panificacao')
    THEN RAISE EXCEPTION 'Perfil sem permissão de check-in imediato'; END IF;
  IF p_latitude IS NULL OR p_longitude IS NULL OR p_latitude NOT BETWEEN -90 AND 90
    OR p_longitude NOT BETWEEN -180 AND 180
    THEN RAISE EXCEPTION 'Localização GPS obrigatória e válida'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.clientes c WHERE c.id=p_cliente
      AND public.vt_vendedor_na_carteira(c.vendedor_id,v_supervisor)
  ) THEN RAISE EXCEPTION 'Cliente fora da carteira. Consulte o supervisor técnico'; END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('vt_checkin_imediato:'||auth.uid()::text,0));
  IF EXISTS (SELECT 1 FROM public.visitas_tecnicas v
      WHERE v.tecnico_id=auth.uid() AND v.status='em_andamento') THEN
    RAISE EXCEPTION 'Já existe visita em andamento. Finalize o checkout antes de iniciar outra';
  END IF;

  v_registro:=clock_timestamp();
  v_agora:=v_registro AT TIME ZONE 'America/Sao_Paulo';
  INSERT INTO public.visitas_tecnicas (
    cliente_id,tecnico_id,supervisor_id,data_visita,hora_inicio,duracao_min,
    objetivo,observacoes,status,tipo_agendamento,tipo_atendimento,criador_papel,
    checkin_em,checkin_latitude,checkin_longitude,checkin_precisao_m
  ) VALUES (
    p_cliente,auth.uid(),v_supervisor,v_agora::date,v_agora::time,60,
    'Atendimento presencial imediato','Check-in feito em campo','em_andamento','imediato','producao',v_papel,
    v_registro,p_latitude,p_longitude,p_precisao_m
  ) RETURNING id INTO v_id;
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION public.vt_visita_aprovada(p_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
 SELECT EXISTS(SELECT 1 FROM public.visitas_tecnicas v
 LEFT JOIN public.agendas_tecnicas_semanais a ON a.id=v.agenda_semana_id
 LEFT JOIN public.vt_aprovacoes_excecao e ON e.atendimento_id=v.atendimento_id
 WHERE v.id=p_id AND (
  (v.tipo_agendamento='imediato' AND v.tecnico_id=auth.uid() AND
    public.vt_papel() IN ('tec_panificacao','lider_tec_panificacao','supervisor_tec_panificacao'))
  OR (v.tipo_agendamento='normal' AND e.atendimento_id IS NULL AND a.status='aprovada')
  OR (e.atendimento_id IS NOT NULL AND e.status='aprovada')))
$$;

REVOKE ALL ON FUNCTION public.vt_supervisor_do_atendimento(),public.vt_vendedor_na_carteira(uuid,uuid) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.vt_clientes_por_cidade(text,text,integer),public.vt_historico_visitas_cliente(uuid,integer),
  public.vt_checkin_imediato(uuid,double precision,double precision,double precision) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.vt_clientes_por_cidade(text,text,integer),public.vt_historico_visitas_cliente(uuid,integer),
  public.vt_checkin_imediato(uuid,double precision,double precision,double precision) TO authenticated;

COMMIT;
