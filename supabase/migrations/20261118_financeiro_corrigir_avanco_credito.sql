-- Visão Financeiro v136 | Compatibilidade com filas legadas das fichas.
BEGIN;

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

  -- Financeiro é obrigatório. Um registro legado sem decisão pode estar
  -- aguardando, já pendente ou indevidamente marcado como não aplicável.
  SELECT * INTO v_financeiro FROM public.ficha_aprovacoes a
  WHERE a.ficha_id=v_ficha AND a.ordem>v_credito.ordem
    AND (a.etapa='financeiro' OR a.status IS DISTINCT FROM 'nao_aplica')
  ORDER BY a.ordem,a.id LIMIT 1 FOR UPDATE;
  IF NOT FOUND OR v_financeiro.etapa IS DISTINCT FROM 'financeiro' THEN
    RAISE EXCEPTION 'A ficha não tem a etapa Financeiro na posição esperada. Próxima etapa encontrada: %.',
      coalesce(v_financeiro.etapa,'nenhuma');
  END IF;
  IF v_financeiro.status IS NULL OR v_financeiro.status NOT IN ('aguardando','pendente','nao_aplica')
    OR v_financeiro.aprovador_id IS NOT NULL THEN
    RAISE EXCEPTION 'A etapa Financeiro já possui decisão ou está em situação inválida (%).',
      coalesce(v_financeiro.status,'sem status');
  END IF;
  -- Bloqueia as etapas posteriores antes de conferir e acertar sua fila.
  PERFORM 1 FROM public.ficha_aprovacoes a
  WHERE a.ficha_id=v_ficha AND a.ordem>v_financeiro.ordem
  ORDER BY a.ordem,a.id FOR UPDATE;
  IF EXISTS (
    SELECT 1 FROM public.ficha_aprovacoes a WHERE a.ficha_id=v_ficha
      AND a.id<>v_financeiro.id AND (
        (a.ordem=v_financeiro.ordem AND a.status IS DISTINCT FROM 'nao_aplica')
        OR (a.ordem>v_financeiro.ordem AND
          (a.status IN ('aprovado','reprovado') OR
            (a.status='pendente' AND (a.aprovador_id IS NOT NULL OR a.decidido_em IS NOT NULL))))
      )
  ) THEN
    RAISE EXCEPTION 'A fila tem etapas duplicadas ou decisões posteriores ao Financeiro. Confira o histórico da ficha.';
  END IF;
  IF p_aprovar_financeiro AND v_financeiro.responsavel_id IS NOT NULL AND v_financeiro.responsavel_id<>v_uid THEN
    RAISE EXCEPTION 'A aprovação financeira está atribuída a outro usuário. Conclua apenas a análise de crédito.';
  END IF;

  -- Só devolve à espera etapas posteriores abertas sem decisão.
  UPDATE public.ficha_aprovacoes SET status='aguardando'
  WHERE ficha_id=v_ficha AND ordem>v_financeiro.ordem AND status='pendente'
    AND aprovador_id IS NULL AND decidido_em IS NULL;

  v_risco:=p_risco;
  UPDATE public.fichas_clientes SET
    credito_liberado=p_credito, condicao_pagamento_credito=btrim(p_condicao),
    risco_credito=v_risco, observacoes_credito=nullif(btrim(p_observacoes),''),
    analise_credito_em=now()
  WHERE id=v_ficha;
  v_observacao:='Crédito: R$ '||p_credito::text||' | Risco '||p_risco||' | '||btrim(p_condicao);

  IF v_papel='financeiro' OR v_financeiro.status<>'aguardando' THEN
    UPDATE public.ficha_aprovacoes SET status='aprovado',aprovador_id=v_uid,decidido_em=now(),observacao=v_observacao
    WHERE id=v_credito.id;
    UPDATE public.ficha_aprovacoes SET status='pendente',decidido_em=NULL
    WHERE id=v_financeiro.id AND status IN ('aguardando','nao_aplica');
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
