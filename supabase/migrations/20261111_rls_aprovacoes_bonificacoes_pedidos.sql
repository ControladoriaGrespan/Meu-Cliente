-- MEU CLIENTE — 11/11/2026
-- RLS: leitura das etapas de bonificações aprovadas na tela de pedidos.
-- Corrige o caso em que a solicitação está visível mas o embed/consulta de
-- solicitacao_aprovacoes retorna zero registros ao usuário operacional.
-- Preserva demais políticas, não libera alteração e não desabilita RLS.
--
-- IMPORTANTE: a consulta a public.solicitacoes neste USING é executada
-- com as permissões e RLS do usuário autenticado (SECURITY INVOKER).
-- Assim, só permite ver as etapas se a solicitação já for visível ao usuário.

BEGIN;

ALTER TABLE public.solicitacao_aprovacoes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS mc_consultar_etapas_bonificacao_aprovada_pedido
  ON public.solicitacao_aprovacoes;

CREATE POLICY mc_consultar_etapas_bonificacao_aprovada_pedido
ON public.solicitacao_aprovacoes
AS PERMISSIVE
FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.solicitacoes s
    WHERE s.id = solicitacao_aprovacoes.solicitacao_id
      AND s.categoria = 'bonificacao'
      AND s.status_fluxo = 'aprovada'
      AND s.pedido_id IS NULL
  )
);

COMMIT;

-- Conferência da política (não simula a RLS do usuário logado).
SELECT policyname,cmd,roles,qual
FROM pg_policies
WHERE schemaname='public'
  AND tablename='solicitacao_aprovacoes'
  AND policyname='mc_consultar_etapas_bonificacao_aprovada_pedido';

-- Teste funcional: entre como o usuário que opera os pedidos,
-- selecione o cliente 003572 e confirme que a BON-000016 aparece.
