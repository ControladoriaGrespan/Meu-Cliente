BEGIN;

ALTER TABLE public.visitas_tecnicas
  ADD COLUMN IF NOT EXISTS checkin_administrativo_por uuid,
  ADD COLUMN IF NOT EXISTS checkout_administrativo_por uuid;

CREATE OR REPLACE FUNCTION public.vt_registrar_atendimento_administrativo(p_visita uuid, p_acao text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
DECLARE
  v public.visitas_tecnicas%ROWTYPE;
  v_usuario uuid := auth.uid();
  v_papel text;
BEGIN
  SELECT papel::text INTO v_papel FROM public.usuarios
  WHERE id=v_usuario AND ativo IS TRUE;
  IF v_papel IS NULL OR v_papel NOT IN ('admin','supervisor_tec_panificacao') THEN
    RAISE EXCEPTION 'Ação exclusiva do Supervisor Tec Panificação e do Administrador.';
  END IF;
  IF p_acao IS NULL OR p_acao NOT IN ('checkin','checkout') THEN
    RAISE EXCEPTION 'Ação inválida.';
  END IF;

  SELECT * INTO v FROM public.visitas_tecnicas WHERE id=p_visita FOR UPDATE;
  IF NOT FOUND OR (v_papel='supervisor_tec_panificacao' AND v.supervisor_id IS DISTINCT FROM v_usuario) THEN
    RAISE EXCEPTION 'Atendimento fora da sua equipe ou indisponível.';
  END IF;

  IF p_acao='checkin' THEN
    IF v.status='em_andamento' AND v.checkin_administrativo_por=v_usuario THEN RETURN; END IF;
    IF v.status IS DISTINCT FROM 'agendada' OR v.checkin_em IS NOT NULL OR v.checkout_em IS NOT NULL THEN
      RAISE EXCEPTION 'O atendimento precisa estar agendado para registrar o check-in.';
    END IF;
    IF NOT coalesce(public.vt_visita_aprovada(p_visita),false) THEN
      RAISE EXCEPTION 'A agenda precisa estar aprovada para registrar o check-in.';
    END IF;
    UPDATE public.visitas_tecnicas SET status='em_andamento',checkin_em=clock_timestamp(),
      checkin_administrativo_por=v_usuario WHERE id=p_visita;
  ELSE
    IF v.status='concluida' AND v.checkout_administrativo_por=v_usuario THEN RETURN; END IF;
    IF v.status IS DISTINCT FROM 'em_andamento' OR v.checkin_em IS NULL OR v.checkout_em IS NOT NULL THEN
      RAISE EXCEPTION 'Registre o check-in antes do checkout. Apenas atendimentos em andamento podem ser concluídos.';
    END IF;
    UPDATE public.visitas_tecnicas SET status='concluida',checkout_em=clock_timestamp(),
      checkout_administrativo_por=v_usuario WHERE id=p_visita;
  END IF;
END $fn$;

REVOKE ALL ON FUNCTION public.vt_registrar_atendimento_administrativo(uuid,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.vt_registrar_atendimento_administrativo(uuid,text) TO authenticated;
NOTIFY pgrst,'reload schema';
COMMIT;
