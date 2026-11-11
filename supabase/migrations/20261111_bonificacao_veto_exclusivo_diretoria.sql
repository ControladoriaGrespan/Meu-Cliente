-- MEU CLIENTE — 11/11/2026 — Bonificações: apenas Diretoria pode vetar.
-- Supervisor, Coordenador, Gestão Adm. de Vendas e Financeiro registram
-- pareceres aprovado/reprovado, sem encerrar o workflow.
-- Execute após backup. Não muda os pareceres históricos.
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

  -- Bonificação: reprovações de etapas anteriores são PARECERES sem veto.
  -- Somente a Diretoria pode encerrar definitivamente como reprovada.
  IF (v_sol.categoria='bonificacao' AND EXISTS(
       SELECT 1 FROM public.solicitacao_aprovacoes a
       WHERE a.solicitacao_id=p_solicitacao_id
         AND a.etapa='diretoria' AND a.status='reprovado'))
     OR (v_sol.categoria<>'bonificacao' AND EXISTS(
       SELECT 1 FROM public.solicitacao_aprovacoes a
       WHERE a.solicitacao_id=p_solicitacao_id AND a.status='reprovado'))
  THEN
    IF v_sol.status_fluxo IS DISTINCT FROM 'reprovada' THEN
      UPDATE public.solicitacoes SET status_fluxo='reprovada' WHERE id=p_solicitacao_id;
    END IF;
    RETURN jsonb_build_object('acao','reprovada','status_fluxo','reprovada');
  END IF;

  IF v_sol.status_fluxo='reprovada' THEN
    IF v_sol.categoria='bonificacao' THEN
      UPDATE public.solicitacoes SET status_fluxo='aberta'
      WHERE id=p_solicitacao_id;
      v_sol.status_fluxo:='aberta';
    ELSE
      RETURN jsonb_build_object('acao','reprovada','status_fluxo','reprovada');
    END IF;
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
        AND (CASE WHEN v_sol.categoria='bonificacao'
          THEN a.status NOT IN ('aprovado','reprovado','nao_aplica')
          ELSE a.status NOT IN ('aprovado','nao_aplica') END)
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
               AND (CASE WHEN v_sol.categoria='bonificacao'
                 THEN status NOT IN ('aprovado','reprovado','nao_aplica')
                 ELSE status NOT IN ('aprovado','nao_aplica') END)) THEN
    RAISE EXCEPTION 'Existem etapas não concluídas.';
  END IF;
  IF v_sol.categoria='bonificacao' AND (
    NOT EXISTS (SELECT 1 FROM public.solicitacao_aprovacoes
      WHERE solicitacao_id=p_solicitacao_id AND etapa='financeiro'
        AND status IN ('aprovado','reprovado'))
    OR NOT EXISTS (SELECT 1 FROM public.solicitacao_aprovacoes
      WHERE solicitacao_id=p_solicitacao_id AND etapa='diretoria' AND status='aprovado')
  ) THEN
    RAISE EXCEPTION 'Bonificação exige parecer do Financeiro e aprovação final da Diretoria.';
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



-- Atualiza trigger de liberação, preservando a aprovação exclusiva da Diretoria.
CREATE OR REPLACE FUNCTION public.mc_validar_liberacao_bonificacao()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp
AS $guard$
BEGIN
  IF NEW.categoria='bonificacao'
    AND NEW.status_fluxo IN ('aprovada','vinculada','concluida')
    AND (OLD.status_fluxo IS DISTINCT FROM NEW.status_fluxo
      OR OLD.pedido_id IS DISTINCT FROM NEW.pedido_id)
  THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.solicitacao_aprovacoes a
      WHERE a.solicitacao_id=NEW.id AND a.etapa='financeiro'
        AND a.status IN ('aprovado','reprovado')
    ) OR NOT EXISTS (
      SELECT 1 FROM public.solicitacao_aprovacoes a
      WHERE a.solicitacao_id=NEW.id AND a.etapa='diretoria'
        AND a.status='aprovado'
    ) OR EXISTS (
      SELECT 1 FROM public.solicitacao_aprovacoes a
      WHERE a.solicitacao_id=NEW.id
        AND a.status NOT IN ('aprovado','reprovado','nao_aplica')
    ) THEN
      RAISE EXCEPTION 'Bonificação % exige parecer do Financeiro e aprovação final da Diretoria antes da liberação para pedido',NEW.id;
    END IF;
  END IF;
  RETURN NEW;
END;
$guard$;

-- Recupera processos encerrados indevidamente por parecer negativo,
-- sem apagar ou converter qualquer reprovação histórica.
-- Diretoria reprovada permanece vetada.
UPDATE public.solicitacoes s
SET status_fluxo='aberta'
WHERE s.categoria='bonificacao'
  AND s.status_fluxo='reprovada'
  AND EXISTS (
    SELECT 1 FROM public.solicitacao_aprovacoes a
    WHERE a.solicitacao_id=s.id AND a.status='reprovado'
      AND a.etapa<>'diretoria'
  )
  AND NOT EXISTS (
    SELECT 1 FROM public.solicitacao_aprovacoes d
    WHERE d.solicitacao_id=s.id AND d.etapa='diretoria'
      AND d.status='reprovado'
  );

-- Reabre apenas a próxima etapa de processos recuperados sem etapa pendente.
-- Não altera decisões anteriores.
WITH proxima AS (
  SELECT DISTINCT ON (a.solicitacao_id) a.id
  FROM public.solicitacao_aprovacoes a
  JOIN public.solicitacoes s ON s.id=a.solicitacao_id
  WHERE s.categoria='bonificacao' AND s.status_fluxo='aberta'
    AND a.status='aguardando'
    AND EXISTS (
      SELECT 1 FROM public.solicitacao_aprovacoes r
      WHERE r.solicitacao_id=s.id AND r.status='reprovado' AND r.etapa<>'diretoria'
    )
    AND NOT EXISTS (
      SELECT 1 FROM public.solicitacao_aprovacoes p
      WHERE p.solicitacao_id=s.id AND p.status='pendente'
    )
    AND NOT EXISTS (
      SELECT 1 FROM public.solicitacao_aprovacoes d
      WHERE d.solicitacao_id=s.id AND d.etapa='diretoria' AND d.status='reprovado'
    )
  ORDER BY a.solicitacao_id,a.ordem
)
UPDATE public.solicitacao_aprovacoes a
SET status='pendente'
FROM proxima p WHERE p.id=a.id;

COMMIT;

SELECT s.codigo,s.status_fluxo,a.etapa,a.ordem,a.status
FROM public.solicitacoes s
JOIN public.solicitacao_aprovacoes a ON a.solicitacao_id=s.id
WHERE s.codigo IN ('BON-000013','BON-000018')
ORDER BY s.codigo,a.ordem;
