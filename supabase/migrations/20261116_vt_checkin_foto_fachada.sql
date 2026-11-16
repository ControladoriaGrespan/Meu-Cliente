BEGIN;

CREATE TABLE IF NOT EXISTS public.vt_fotos_checkin (
  visita_id uuid PRIMARY KEY REFERENCES public.visitas_tecnicas(id) ON DELETE CASCADE,
  foto_jpeg text NOT NULL
);
ALTER TABLE public.vt_fotos_checkin ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.vt_fotos_checkin FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.vt_fotos_checkin TO authenticated;
DROP POLICY IF EXISTS vt_fotos_checkin_leitura ON public.vt_fotos_checkin;
CREATE POLICY vt_fotos_checkin_leitura ON public.vt_fotos_checkin FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.visitas_tecnicas v WHERE v.id=visita_id));

ALTER TABLE public.visitas_tecnicas ADD COLUMN IF NOT EXISTS checkin_com_foto boolean NOT NULL DEFAULT false;

CREATE OR REPLACE FUNCTION public.vt_registrar_checkin_com_foto(p_visita uuid,p_foto text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE
  v public.visitas_tecnicas%ROWTYPE;
  v_jpeg bytea;
BEGIN
  IF auth.uid() IS NULL OR public.vt_papel() IS DISTINCT FROM 'tec_panificacao' THEN
    RAISE EXCEPTION 'Somente o técnico responsável pode usar o check-in com foto.';
  END IF;
  SELECT * INTO v FROM public.visitas_tecnicas WHERE id=p_visita FOR UPDATE;
  IF NOT FOUND OR v.tecnico_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Atendimento não autorizado.';
  END IF;
  IF v.status='em_andamento' AND v.checkin_com_foto THEN RETURN; END IF;
  IF v.status IS DISTINCT FROM 'agendada' OR v.checkin_em IS NOT NULL
    OR v.tipo_atendimento='treinamento'
    OR NOT coalesce(public.vt_visita_aprovada(p_visita),false) THEN
    RAISE EXCEPTION 'Atendimento indisponível para check-in.';
  END IF;
  IF p_foto IS NULL OR length(p_foto) NOT BETWEEN 150 AND 2000000
    OR p_foto !~ '^data:image/jpeg;base64,[A-Za-z0-9+/]+={0,2}$' THEN
    RAISE EXCEPTION 'Envie uma foto JPEG válida da fachada.';
  END IF;
  v_jpeg := decode(substr(p_foto,length('data:image/jpeg;base64,')+1),'base64');
  IF substring(v_jpeg FROM 1 FOR 3) <> decode('ffd8ff','hex')
    OR substring(v_jpeg FROM length(v_jpeg)-1 FOR 2) <> decode('ffd9','hex') THEN
    RAISE EXCEPTION 'A foto da fachada está inválida.';
  END IF;
  INSERT INTO public.vt_fotos_checkin(visita_id,foto_jpeg) VALUES(p_visita,p_foto);
  UPDATE public.visitas_tecnicas
    SET checkin_em=now(),status='em_andamento',checkin_com_foto=true,
        checkin_latitude=NULL,checkin_longitude=NULL,checkin_precisao_m=NULL
    WHERE id=p_visita;
END $$;
REVOKE ALL ON FUNCTION public.vt_registrar_checkin_com_foto(uuid,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.vt_registrar_checkin_com_foto(uuid,text) TO authenticated;

NOTIFY pgrst,'reload schema';
COMMIT;
