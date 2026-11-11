-- RECUPERAÇÃO PONTUAL — bonificação 0e5f373f-b7ba-4672-baa6-e9bebb02b978
-- Executar apenas se o diagnóstico mostrar Coordenador APROVADO e próxima etapa AGUARDANDO.
-- NÃO aprova nenhuma etapa, não libera pedido e não mexe em outras solicitações.
BEGIN;

DO $mc$
DECLARE
  v_id uuid := '0e5f373f-b7ba-4672-baa6-e9bebb02b978'::uuid;
  v_proxima uuid;
  v_etapa text;
  v_status text;
  v_ord integer;
  v_count int;
BEGIN
  SELECT status_fluxo INTO v_status FROM public.solicitacoes
  WHERE id=v_id AND categoria='bonificacao' FOR UPDATE;
  IF v_status IS NULL THEN RAISE EXCEPTION 'Bonificação não encontrada.'; END IF;
  IF v_status <> 'aberta' THEN
    RAISE EXCEPTION 'Status da solicitação é %, esperado aberta. Não alterado.',v_status;
  END IF;
  IF EXISTS(SELECT 1 FROM public.solicitacao_aprovacoes
            WHERE solicitacao_id=v_id AND status='reprovado') THEN
    RAISE EXCEPTION 'Há reprovação; recuperação bloqueada.';
  END IF;
  IF EXISTS(SELECT 1 FROM public.solicitacao_aprovacoes
            WHERE solicitacao_id=v_id AND status='pendente') THEN
    RAISE NOTICE 'Já existe etapa pendente. Nenhuma alteração necessária.';
    RETURN;
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.solicitacao_aprovacoes
                WHERE solicitacao_id=v_id AND etapa='coordenador' AND status='aprovado') THEN
    RAISE EXCEPTION 'Coordenador ainda não está aprovado. Não foi alterado.';
  END IF;
  SELECT id,etapa,ordem INTO v_proxima,v_etapa,v_ord
  FROM public.solicitacao_aprovacoes
  WHERE solicitacao_id=v_id AND status='aguardando'
  ORDER BY ordem,id LIMIT 1;
  IF v_proxima IS NULL THEN
    RAISE EXCEPTION 'Nenhuma etapa aguardando; verifique diagnóstico antes de prosseguir.';
  END IF;
  IF EXISTS(SELECT 1 FROM public.solicitacao_aprovacoes
            WHERE solicitacao_id=v_id AND ordem<v_ord AND status NOT IN ('aprovado','nao_aplica')) THEN
    RAISE EXCEPTION 'Existem etapas anteriores não concluídas.';
  END IF;
  UPDATE public.solicitacao_aprovacoes
  SET status='pendente' WHERE id=v_proxima AND status='aguardando';
  GET DIAGNOSTICS v_count=ROW_COUNT;
  IF v_count<>1 THEN RAISE EXCEPTION 'Não foi possível promover a próxima etapa.'; END IF;
  RAISE NOTICE 'Recuperação concluída: % passou a pendente.',v_etapa;
END;
$mc$;

COMMIT;

SELECT s.codigo,s.status_fluxo,a.etapa,a.ordem,a.status
FROM public.solicitacoes s
JOIN public.solicitacao_aprovacoes a ON a.solicitacao_id=s.id
WHERE s.id='0e5f373f-b7ba-4672-baa6-e9bebb02b978'::uuid
ORDER BY a.ordem;
