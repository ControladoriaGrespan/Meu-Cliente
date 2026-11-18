BEGIN;

CREATE OR REPLACE FUNCTION public.mc_financeiro_ativo()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.usuarios u
    WHERE u.id=(SELECT auth.uid()) AND u.ativo IS TRUE AND u.papel::text='financeiro'
  );
$$;
REVOKE ALL ON FUNCTION public.mc_financeiro_ativo() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.mc_financeiro_ativo() TO authenticated;

DROP POLICY IF EXISTS ficha_aprovacoes_select_credito_financeiro ON public.ficha_aprovacoes;
CREATE POLICY ficha_aprovacoes_select_credito_financeiro ON public.ficha_aprovacoes
FOR SELECT TO authenticated USING (
  etapa='analise_credito' AND status='pendente' AND (SELECT public.mc_financeiro_ativo())
);

CREATE OR REPLACE FUNCTION public.pode_ler_ficha_analise_credito(p_ficha_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.usuarios AS u
    JOIN public.ficha_aprovacoes AS a
      ON a.ficha_id = p_ficha_id
    WHERE u.id = (SELECT auth.uid())
      AND u.ativo IS TRUE
      AND a.etapa = 'analise_credito'
      AND a.status = 'pendente'
      AND (
        u.papel::text = 'financeiro'
        OR (u.papel::text = 'analise_credito' AND (a.responsavel_id IS NULL OR a.responsavel_id = u.id))
      )
  );
$$;

REVOKE ALL ON FUNCTION public.pode_ler_ficha_analise_credito(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.pode_ler_ficha_analise_credito(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.pode_ler_ficha_analise_credito(uuid) TO authenticated;

DROP POLICY IF EXISTS fichas_clientes_select_analise_credito_pendente
  ON public.fichas_clientes;
CREATE POLICY fichas_clientes_select_analise_credito_pendente
  ON public.fichas_clientes
  FOR SELECT TO authenticated
  USING (public.pode_ler_ficha_analise_credito(id));

CREATE OR REPLACE FUNCTION public.mc_validar_ordem_decisao_ficha()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
  v_uid uuid:=auth.uid(); v_papel text; v_ativo boolean;
  v_menor integer; v_financeiro_credito boolean;
BEGIN
  -- O construtor do workflow pode preparar a fila; esta guarda intervém
  -- exclusivamente quando alguém tenta decidir uma etapa.
  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN RETURN NEW; END IF;
  IF NEW.status NOT IN ('aprovado','reprovado') THEN RETURN NEW; END IF;
  IF OLD.status<>'pendente' THEN
    RAISE EXCEPTION 'Esta etapa da ficha não está liberada para decisão';
  END IF;
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Usuário não autenticado'; END IF;
  SELECT u.papel::text,u.ativo INTO v_papel,v_ativo
  FROM public.usuarios u WHERE u.id=v_uid;
  IF v_ativo IS DISTINCT FROM true THEN RAISE EXCEPTION 'Usuário inativo'; END IF;
  v_financeiro_credito := v_papel='financeiro' AND OLD.etapa='analise_credito'
    AND NEW.status='aprovado' AND NEW.aprovador_id=v_uid
    AND EXISTS (
      SELECT 1 FROM public.fichas_clientes f WHERE f.id=OLD.ficha_id
      AND f.credito_liberado>0 AND nullif(btrim(f.condicao_pagamento_credito),'') IS NOT NULL
      AND f.risco_credito::text IN ('A','B','C','D') AND f.analise_credito_em IS NOT NULL
    );
  IF v_papel<>'admin' AND v_financeiro_credito IS NOT TRUE AND OLD.responsavel_id IS NOT NULL AND OLD.responsavel_id<>v_uid THEN
    RAISE EXCEPTION 'A ficha pertence a outro responsável nesta etapa';
  END IF;
  IF v_papel<>'admin' AND v_financeiro_credito IS NOT TRUE AND OLD.responsavel_id IS NULL AND v_papel<>OLD.etapa THEN
    RAISE EXCEPTION 'O perfil % não pode aprovar a etapa %',v_papel,OLD.etapa;
  END IF;
  SELECT min(a.ordem) INTO v_menor FROM public.ficha_aprovacoes a
  WHERE a.ficha_id=OLD.ficha_id AND a.status IN ('pendente','aguardando');
  IF OLD.ordem IS DISTINCT FROM v_menor THEN
    RAISE EXCEPTION 'Aprovação de ficha fora da sequência obrigatória';
  END IF;
  IF EXISTS(SELECT 1 FROM public.ficha_aprovacoes a
      WHERE a.ficha_id=OLD.ficha_id AND a.ordem<OLD.ordem
        AND a.status NOT IN ('aprovado','nao_aplica')) THEN
    RAISE EXCEPTION 'Há aprovações anteriores da ficha não concluídas';
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.mc_registrar_analise_credito_ficha(
  p_aprovacao uuid,p_credito numeric,p_condicao text,p_risco text,p_observacoes text,
  p_aprovar_financeiro boolean
) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $credit$
DECLARE
  v_uid uuid := auth.uid();
  v_papel text;
  v_ficha uuid;
  v_credito public.ficha_aprovacoes%ROWTYPE;
  v_financeiro public.ficha_aprovacoes%ROWTYPE;
  v_risco public.fichas_clientes.risco_credito%TYPE;
  v_observacao text;
BEGIN
  SELECT u.papel::text INTO v_papel FROM public.usuarios u WHERE u.id=v_uid AND u.ativo IS TRUE;
  IF v_papel IS NULL OR v_papel NOT IN ('analise_credito','financeiro','admin') THEN
    RAISE EXCEPTION 'Perfil sem permissão para registrar a análise de crédito.';
  END IF;
  IF p_aprovar_financeiro IS NULL OR (p_aprovar_financeiro AND v_papel<>'financeiro') THEN
    RAISE EXCEPTION 'Somente o Financeiro pode concluir as duas etapas nesta operação.';
  END IF;
  IF NOT coalesce(p_credito>0 AND p_credito<'Infinity'::numeric,false)
    OR nullif(btrim(p_condicao),'') IS NULL OR p_risco IS NULL OR p_risco NOT IN ('A','B','C','D') THEN
    RAISE EXCEPTION 'Informe o limite, a condição de pagamento e o risco de crédito.';
  END IF;

  SELECT a.ficha_id INTO v_ficha FROM public.ficha_aprovacoes a WHERE a.id=p_aprovacao;
  IF NOT FOUND THEN RAISE EXCEPTION 'Análise de crédito não encontrada.'; END IF;
  PERFORM 1 FROM public.fichas_clientes f WHERE f.id=v_ficha FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Ficha não encontrada.'; END IF;

  SELECT * INTO v_credito FROM public.ficha_aprovacoes a WHERE a.id=p_aprovacao FOR UPDATE;
  IF NOT FOUND OR v_credito.etapa IS DISTINCT FROM 'analise_credito' OR v_credito.status IS DISTINCT FROM 'pendente' THEN
    RAISE EXCEPTION 'A análise de crédito já foi decidida ou ainda não está liberada. Atualize as pendências.';
  END IF;
  IF v_papel='analise_credito' AND v_credito.responsavel_id IS NOT NULL AND v_credito.responsavel_id<>v_uid THEN
    RAISE EXCEPTION 'A análise de crédito está atribuída a outro analista.';
  END IF;

  SELECT * INTO v_financeiro FROM public.ficha_aprovacoes a
  WHERE a.ficha_id=v_ficha AND a.ordem>v_credito.ordem AND a.status<>'nao_aplica'
  ORDER BY a.ordem,a.id LIMIT 1 FOR UPDATE;
  IF NOT FOUND OR v_financeiro.etapa IS DISTINCT FROM 'financeiro'
    OR v_financeiro.status IS DISTINCT FROM 'aguardando' THEN
    RAISE EXCEPTION 'A próxima etapa da ficha precisa ser a aprovação do Financeiro.';
  END IF;
  IF p_aprovar_financeiro AND v_financeiro.responsavel_id IS NOT NULL AND v_financeiro.responsavel_id<>v_uid THEN
    RAISE EXCEPTION 'A aprovação financeira está atribuída a outro usuário. Conclua apenas a análise de crédito.';
  END IF;

  v_risco:=p_risco;
  UPDATE public.fichas_clientes SET
    credito_liberado=p_credito, condicao_pagamento_credito=btrim(p_condicao),
    risco_credito=v_risco, observacoes_credito=nullif(btrim(p_observacoes),''),
    analise_credito_em=now()
  WHERE id=v_ficha;
  v_observacao:='Crédito: R$ '||p_credito::text||' | Risco '||p_risco||' | '||btrim(p_condicao);

  IF v_papel='financeiro' THEN
    UPDATE public.ficha_aprovacoes SET status='aprovado',aprovador_id=v_uid,decidido_em=now(),observacao=v_observacao
    WHERE id=v_credito.id;
    UPDATE public.ficha_aprovacoes SET status='pendente' WHERE id=v_financeiro.id AND status='aguardando';
  ELSE
    PERFORM public.decidir_ficha_workflow(v_credito.id,'aprovado',v_observacao);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.ficha_aprovacoes a WHERE a.id=v_credito.id AND a.status='aprovado')
    OR NOT EXISTS (SELECT 1 FROM public.ficha_aprovacoes a WHERE a.id=v_financeiro.id AND a.status='pendente') THEN
    RAISE EXCEPTION 'Não foi possível concluir a análise e liberar a etapa financeira.';
  END IF;

  IF p_aprovar_financeiro THEN
    PERFORM public.decidir_ficha_workflow(v_financeiro.id,'aprovado','Aprovação financeira registrada junto à análise de crédito.');
    IF NOT EXISTS (SELECT 1 FROM public.ficha_aprovacoes a WHERE a.id=v_financeiro.id AND a.status='aprovado')
      OR NOT EXISTS (SELECT 1 FROM public.ficha_aprovacoes a
        WHERE a.ficha_id=v_ficha AND a.etapa='diretoria' AND a.ordem>v_financeiro.ordem AND a.status='pendente') THEN
      RAISE EXCEPTION 'Não foi possível confirmar a aprovação financeira e liberar a Diretoria.';
    END IF;
    RETURN v_financeiro.ordem;
  END IF;
  RETURN v_credito.ordem;
END;
$credit$;

REVOKE ALL ON FUNCTION public.mc_registrar_analise_credito_ficha(uuid,numeric,text,text,text,boolean) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.mc_registrar_analise_credito_ficha(uuid,numeric,text,text,text,boolean) TO authenticated;

NOTIFY pgrst,'reload schema';
COMMIT;
