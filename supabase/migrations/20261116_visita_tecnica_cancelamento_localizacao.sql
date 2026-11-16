BEGIN;

ALTER TABLE public.visitas_tecnicas
  ADD COLUMN IF NOT EXISTS cancelado_em timestamptz,
  ADD COLUMN IF NOT EXISTS cancelado_por uuid;

CREATE OR REPLACE FUNCTION public.vt_cancelar_atendimento(p_visita uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v public.visitas_tecnicas%ROWTYPE;
BEGIN
  IF public.vt_papel() IS DISTINCT FROM 'lider_tec_panificacao' THEN
    RAISE EXCEPTION 'Somente o Líder Técnico pode cancelar seu atendimento.';
  END IF;
  SELECT * INTO v FROM public.visitas_tecnicas WHERE id=p_visita;
  IF NOT FOUND OR NOT EXISTS (
    SELECT 1 FROM public.agendas_tecnicas_semanais a
    WHERE a.id=v.agenda_semana_id AND a.lider_id=auth.uid() AND a.origem_papel='lider_tec_panificacao'
  ) THEN RAISE EXCEPTION 'Atendimento não pertence à agenda deste Líder.'; END IF;

  PERFORM 1 FROM public.visitas_tecnicas x
  WHERE x.id=v.id OR (v.atendimento_id IS NOT NULL AND x.atendimento_id=v.atendimento_id)
  ORDER BY x.id FOR UPDATE;

  IF EXISTS (
    SELECT 1 FROM public.visitas_tecnicas x
    LEFT JOIN public.agendas_tecnicas_semanais a ON a.id=x.agenda_semana_id
    WHERE (x.id=v.id OR (v.atendimento_id IS NOT NULL AND x.atendimento_id=v.atendimento_id))
      AND (x.status NOT IN ('agendada','cancelada') OR x.checkin_em IS NOT NULL OR x.checkout_em IS NOT NULL
        OR a.lider_id IS DISTINCT FROM auth.uid() OR a.origem_papel IS DISTINCT FROM 'lider_tec_panificacao')
  ) THEN RAISE EXCEPTION 'O atendimento já começou ou possui participantes fora da agenda deste Líder.'; END IF;
  UPDATE public.visitas_tecnicas x SET status='cancelada',cancelado_em=now(),cancelado_por=auth.uid()
  WHERE (x.id=v.id OR (v.atendimento_id IS NOT NULL AND x.atendimento_id=v.atendimento_id)) AND x.status='agendada';
END $$;

-- A política restritiva vale mesmo que existam outras políticas de leitura legadas.
DROP POLICY IF EXISTS vt_canceladas_visibilidade ON public.visitas_tecnicas;
CREATE POLICY vt_canceladas_visibilidade ON public.visitas_tecnicas AS RESTRICTIVE FOR SELECT TO authenticated
USING (status IS DISTINCT FROM 'cancelada' OR public.vt_papel() IN ('lider_tec_panificacao','supervisor_tec_panificacao','admin'));

CREATE TABLE IF NOT EXISTS public.vt_pedidos_localizacao (
  tecnico_id uuid PRIMARY KEY REFERENCES public.usuarios(id) ON DELETE CASCADE,
  solicitante_id uuid REFERENCES public.usuarios(id) ON DELETE SET NULL,
  solicitado_em timestamptz NOT NULL,
  respondido_em timestamptz,
  latitude double precision,
  longitude double precision
);
ALTER TABLE public.vt_pedidos_localizacao ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.vt_pedidos_localizacao FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.vt_pode_solicitar_localizacao(p_tecnico uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.usuarios u JOIN public.usuarios t ON t.id=p_tecnico
    WHERE u.id=auth.uid() AND u.ativo AND t.ativo AND t.papel::text='tec_panificacao'
      AND (u.papel::text='admin' OR EXISTS (
        SELECT 1 FROM public.usuarios l
        WHERE l.ativo AND l.papel::text='lider_tec_panificacao'
          AND ((u.papel::text='lider_tec_panificacao' AND l.id=u.id)
            OR (u.papel::text='supervisor_tec_panificacao' AND l.supervisor_id=u.id))
          AND (l.id=t.supervisor_id OR EXISTS (
            SELECT 1 FROM public.vt_lider_tecnicos d WHERE d.lider_id=l.id AND d.tecnico_id=t.id AND d.ativo
          ))
      ))
  )
$$;

CREATE OR REPLACE FUNCTION public.vt_solicitar_localizacao(p_tecnico uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
  IF NOT public.vt_pode_solicitar_localizacao(p_tecnico) THEN
    RAISE EXCEPTION 'Você só pode solicitar a localização de um técnico da sua equipe.';
  END IF;
  INSERT INTO public.vt_pedidos_localizacao(tecnico_id,solicitante_id,solicitado_em)
  VALUES (p_tecnico,auth.uid(),clock_timestamp())
  ON CONFLICT (tecnico_id) DO UPDATE SET solicitante_id=EXCLUDED.solicitante_id,solicitado_em=EXCLUDED.solicitado_em;
END $$;

CREATE OR REPLACE FUNCTION public.vt_listar_pedidos_localizacao()
RETURNS TABLE(tecnico_id uuid,solicitado_em timestamptz,respondido_em timestamptz,latitude double precision,longitude double precision)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
  SELECT p.tecnico_id,p.solicitado_em,p.respondido_em,p.latitude,p.longitude
  FROM public.vt_pedidos_localizacao p
  WHERE (p.tecnico_id=auth.uid() AND public.vt_papel()='tec_panificacao')
    OR public.vt_pode_solicitar_localizacao(p.tecnico_id)
$$;

CREATE OR REPLACE FUNCTION public.vt_responder_localizacao(p_solicitado_em timestamptz,p_latitude double precision,p_longitude double precision)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
  IF public.vt_papel() IS DISTINCT FROM 'tec_panificacao' OR p_latitude IS NULL OR p_longitude IS NULL
    OR p_latitude NOT BETWEEN -90 AND 90 OR p_longitude NOT BETWEEN -180 AND 180 THEN
    RAISE EXCEPTION 'Localização ou perfil inválido.';
  END IF;
  UPDATE public.vt_pedidos_localizacao SET respondido_em=clock_timestamp(),latitude=p_latitude,longitude=p_longitude
  WHERE tecnico_id=auth.uid() AND solicitado_em=p_solicitado_em AND (respondido_em IS NULL OR respondido_em<solicitado_em);
  IF NOT FOUND THEN RAISE EXCEPTION 'O pedido mudou ou já foi respondido. Atualize a tela.'; END IF;
END $$;

REVOKE ALL ON FUNCTION public.vt_pode_solicitar_localizacao(uuid) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.vt_cancelar_atendimento(uuid),public.vt_solicitar_localizacao(uuid),
  public.vt_listar_pedidos_localizacao(),public.vt_responder_localizacao(timestamptz,double precision,double precision)
  FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.vt_cancelar_atendimento(uuid),public.vt_solicitar_localizacao(uuid),
  public.vt_listar_pedidos_localizacao(),public.vt_responder_localizacao(timestamptz,double precision,double precision)
  TO authenticated;

NOTIFY pgrst,'reload schema';
COMMIT;
