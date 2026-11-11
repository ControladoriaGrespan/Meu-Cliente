-- Meu Cliente — reparar etapa Diretoria ausente na BON-000018
-- 11/11/2026. Preserva integralmente os pareceres já registrados.
-- A Gestão Adm. de Vendas continua pendente; Financeiro permanece reprovado
-- como parecer (sem veto), e Diretoria será a única etapa com poder de veto.
-- Executar após backup. Não libera bonificação nem altera pedido.
BEGIN;

DO $mc$
DECLARE
  v_sol uuid;
  v_status text;
  v_ord int;
BEGIN
  SELECT id,status_fluxo INTO v_sol,v_status
  FROM public.solicitacoes
  WHERE codigo='BON-000018' AND categoria='bonificacao'
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'BON-000018 não localizada como bonificação';
  END IF;

  IF v_status IS DISTINCT FROM 'aberta' THEN
    RAISE EXCEPTION 'BON-000018 está com status %, não aberta: nenhuma alteração',v_status;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.solicitacao_aprovacoes
    WHERE solicitacao_id=v_sol AND etapa='diretoria'
  ) THEN
    RAISE NOTICE 'A etapa Diretoria já existe; nenhuma alteração';
    RETURN;
  END IF;

  SELECT COALESCE(MAX(ordem),0)+1 INTO v_ord
  FROM public.solicitacao_aprovacoes
  WHERE solicitacao_id=v_sol;

  -- Etapa é aguardando enquanto Gestão Adm. ainda estiver pendente.
  -- Não registra aprovação nem altera pareceres reprovados.
  INSERT INTO public.solicitacao_aprovacoes
    (solicitacao_id,etapa,ordem,status)
  VALUES (
    v_sol,'diretoria',GREATEST(v_ord,5),
    CASE WHEN EXISTS (
      SELECT 1 FROM public.solicitacao_aprovacoes
      WHERE solicitacao_id=v_sol AND status IN ('pendente','aguardando')
    ) THEN 'aguardando' ELSE 'pendente' END
  );
  RAISE NOTICE 'Etapa Diretoria incluída na BON-000018';
END;
$mc$;

COMMIT;

-- Verificação após a migração:
SELECT s.codigo,s.status_fluxo,a.etapa,a.ordem,a.status,a.decidido_em
FROM public.solicitacoes s
JOIN public.solicitacao_aprovacoes a ON a.solicitacao_id=s.id
WHERE s.codigo IN ('BON-000013','BON-000018')
ORDER BY s.codigo,a.ordem;

-- Auditoria: outras bonificações abertas sem Diretoria
SELECT s.codigo,s.status_fluxo
FROM public.solicitacoes s
WHERE s.categoria='bonificacao' AND s.status_fluxo='aberta'
AND NOT EXISTS (
 SELECT 1 FROM public.solicitacao_aprovacoes a
 WHERE a.solicitacao_id=s.id AND a.etapa='diretoria'
)
ORDER BY s.created_at DESC;
