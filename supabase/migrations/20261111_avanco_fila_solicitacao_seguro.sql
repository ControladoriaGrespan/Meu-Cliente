-- Meu Cliente — correção do avanço das aprovações sob RLS (11/11/2026)
-- Motivo: depois do Coordenador, SELECT do cliente não enxergava etapas futuras
-- e interpretava erradamente que a bonificação estava totalmente aprovada.
-- A função abaixo verifica TODAS as etapas no banco e decide atomicamente
-- se promove a próxima, reprova o fluxo ou libera a solicitação.
-- Não modifica aprovações já aprovadas/reprovadas.
BEGIN;

CREATE OR REPLACE FUNCTION public.mc_avancar_fila_solicitacao(p_solicitacao_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $mc$
DECLARE
  v_uid uuid := auth.uid();
  v_sol public.solicitacoes%ROWTYPE;
  v_ap public.solicitacao_aprovacoes%ROWTYPE;
  v_pend public.solicitacao_aprovacoes%ROWTYPE;
  v_prox public.solicitacao_aprovacoes%ROWTYPE;
  v_incompleto boolean;
  v_aprovacao_propria boolean;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Usuário não autenticado.'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.usuarios u WHERE u.id=v_uid AND u.ativo IS TRUE) THEN
    RAISE EXCEPTION 'Usuário inativo ou não cadastrado.';
  END IF;

  -- Só pode avançar uma solicitação em que ESTE usuário registrou uma decisão.
  -- Não concede o direito de aprovar etapas alheias.
  SELECT EXISTS (
    SELECT 1 FROM public.solicitacao_aprovacoes a
    WHERE a.solicitacao_id=p_solicitacao_id
      AND a.aprovador_id=v_uid
      AND a.status IN ('aprovado','reprovado')
      AND a.decidido_em IS NOT NULL
  ) INTO v_aprovacao_propria;
  IF NOT v_aprovacao_propria THEN
    RAISE EXCEPTION 'Usuário não possui decisão registrada nesta solicitação.';
  END IF;

  SELECT * INTO v_sol FROM public.solicitacoes
  WHERE id=p_solicitacao_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Solicitação não encontrada.'; END IF;

  IF v_sol.status_fluxo IN ('concluida','vinculada') THEN
    RETURN jsonb_build_object('acao','ja_encerrada','status_fluxo',v_sol.status_fluxo);
  END IF;

  IF EXISTS(SELECT 1 FROM public.solicitacao_aprovacoes a
            WHERE a.solicitacao_id=p_solicitacao_id AND a.status='reprovado')
  THEN
    IF v_sol.status_fluxo <> 'reprovada' THEN
      UPDATE public.solicitacoes SET status_fluxo='reprovada'
      WHERE id=p_solicitacao_id;
    END IF;
    RETURN jsonb_build_object('acao','reprovada','status_fluxo','reprovada');
  END IF;

  IF v_sol.status_fluxo='reprovada' THEN
    RETURN jsonb_build_object('acao','reprovada','status_fluxo','reprovada');
  END IF;

  -- Se já existe pendente, nunca promover outra etapa ou liberar a solicitação.
  SELECT * INTO v_pend
  FROM public.solicitacao_aprovacoes
  WHERE solicitacao_id=p_solicitacao_id AND status='pendente'
  ORDER BY ordem,id LIMIT 1;
  IF FOUND THEN
    RETURN jsonb_build_object('acao','pendente','proxima_etapa',v_pend.etapa,
      'responsavel_id',v_pend.responsavel_id,'status_fluxo',v_sol.status_fluxo);
  END IF;

  SELECT * INTO v_prox
  FROM public.solicitacao_aprovacoes
  WHERE solicitacao_id=p_solicitacao_id AND status='aguardando'
  ORDER BY ordem,id LIMIT 1;

  IF FOUND THEN
    SELECT EXISTS (
      SELECT 1 FROM public.solicitacao_aprovacoes a
      WHERE a.solicitacao_id=p_solicitacao_id
        AND a.ordem<v_prox.ordem
        AND a.status NOT IN ('aprovado','nao_aplica')
    ) INTO v_incompleto;
    IF v_incompleto THEN
      RAISE EXCEPTION 'Etapas anteriores não foram concluídas; não é possível avançar.';
    END IF;
    UPDATE public.solicitacao_aprovacoes
      SET status='pendente'
      WHERE id=v_prox.id AND status='aguardando';
    RETURN jsonb_build_object('acao','proxima_etapa','proxima_etapa',v_prox.etapa,
      'responsavel_id',v_prox.responsavel_id,'status_fluxo',v_sol.status_fluxo);
  END IF;

  -- Não há etapas pendentes/aguardando: somente concluir se TODAS aprovaram.
  IF NOT EXISTS (SELECT 1 FROM public.solicitacao_aprovacoes
                 WHERE solicitacao_id=p_solicitacao_id) THEN
    RAISE EXCEPTION 'Solicitação não possui etapas de aprovação.';
  END IF;
  IF EXISTS (SELECT 1 FROM public.solicitacao_aprovacoes
             WHERE solicitacao_id=p_solicitacao_id
               AND status NOT IN ('aprovado','nao_aplica')) THEN
    RAISE EXCEPTION 'Existem etapas não concluídas.';
  END IF;
  IF v_sol.categoria='bonificacao' AND (
    NOT EXISTS (SELECT 1 FROM public.solicitacao_aprovacoes
      WHERE solicitacao_id=p_solicitacao_id AND etapa='financeiro' AND status='aprovado')
    OR NOT EXISTS (SELECT 1 FROM public.solicitacao_aprovacoes
      WHERE solicitacao_id=p_solicitacao_id AND etapa='diretoria' AND status='aprovado')
  ) THEN
    RAISE EXCEPTION 'Financeiro e Diretoria precisam aprovar antes da liberação.';
  END IF;

  IF v_sol.status_fluxo <> 'aprovada' THEN
    UPDATE public.solicitacoes SET status_fluxo='aprovada'
    WHERE id=p_solicitacao_id;
  END IF;
  RETURN jsonb_build_object('acao','aprovada','status_fluxo','aprovada');
END;
$mc$;

REVOKE ALL ON FUNCTION public.mc_avancar_fila_solicitacao(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.mc_avancar_fila_solicitacao(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.mc_avancar_fila_solicitacao(uuid) TO authenticated;

COMMIT;

-- Conferir se a função está instalada:
SELECT p.proname,pg_get_function_arguments(p.oid) AS argumentos,
       p.prosecdef AS security_definer
FROM pg_proc p
JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public' AND p.proname='mc_avancar_fila_solicitacao';

-- Diagnóstico da bonificação do Coordenador (somente leitura):
SELECT s.id,s.codigo,s.status_fluxo,
       a.etapa,a.ordem,a.status,a.aprovador_id,a.decidido_em
FROM public.solicitacoes s
JOIN public.solicitacao_aprovacoes a ON a.solicitacao_id=s.id
WHERE s.id='0e5f373f-b7ba-4672-baa6-e9bebb02b978'::uuid
ORDER BY a.ordem;
