-- MEU CLIENTE v105 | Vincular bonificação ao pedido e concluir, atomicamente.
-- Executar no Supabase após backup. Não reprocessa dados automaticamente.
-- A função só atua em bonificações aprovadas e itens de pedido realmente gravados.
-- Corrige o UPDATE direto sujeito a RLS que retornava 0 linhas sem erro.
BEGIN;

CREATE OR REPLACE FUNCTION public.mc_vincular_concluir_bonificacao(
  p_solicitacao_id uuid,
  p_pedido_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $mc$
DECLARE
  v_uid uuid := auth.uid();
  v_papel text;
  v_ativo boolean;
  v_s public.solicitacoes%ROWTYPE;
  v_cliente_pedido uuid;
  v_data timestamptz := now();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Usuário não autenticado';
  END IF;
  SELECT u.papel::text, u.ativo INTO v_papel,v_ativo
  FROM public.usuarios u WHERE u.id=v_uid;
  IF v_ativo IS DISTINCT FROM TRUE OR
     v_papel NOT IN ('adm_vendas','gestao_adm_vendas','admin') THEN
    RAISE EXCEPTION 'Somente a Administração de Vendas pode vincular e concluir a bonificação';
  END IF;

  SELECT * INTO v_s FROM public.solicitacoes
  WHERE id=p_solicitacao_id FOR UPDATE;
  IF NOT FOUND OR v_s.categoria IS DISTINCT FROM 'bonificacao' THEN
    RAISE EXCEPTION 'Bonificação não encontrada';
  END IF;

  -- Idempotência para reexecuções de pedidos já confirmados.
  IF v_s.status_fluxo='concluida' THEN
    IF v_s.pedido_id IS DISTINCT FROM p_pedido_id THEN
      RAISE EXCEPTION 'Bonificação já concluída em outro pedido';
    END IF;
    RETURN jsonb_build_object('situacao','concluida','ja_concluida',true,
      'solicitacao_id',v_s.id,'pedido_id',v_s.pedido_id);
  END IF;

  IF v_s.status_fluxo NOT IN ('aprovada','vinculada') THEN
    RAISE EXCEPTION 'Bonificação ainda não liberada para realização: %',v_s.status_fluxo;
  END IF;
  IF v_s.pedido_id IS NOT NULL AND v_s.pedido_id IS DISTINCT FROM p_pedido_id THEN
    RAISE EXCEPTION 'Bonificação já vinculada a outro pedido';
  END IF;
  SELECT p.cliente_id INTO v_cliente_pedido
  FROM public.pedidos p WHERE p.id=p_pedido_id;
  IF v_cliente_pedido IS NULL OR v_cliente_pedido IS DISTINCT FROM v_s.cliente_id THEN
    RAISE EXCEPTION 'Pedido inexistente ou de outro cliente';
  END IF;
  -- Prova de realização: item de bonificação deve estar gravado no pedido
  -- com o produto/quantidade da solicitação aprovada.
  IF NOT EXISTS(
    SELECT 1 FROM public.pedido_itens pi
    WHERE pi.pedido_id=p_pedido_id
      AND pi.produto_id=v_s.produto_id
      AND pi.tipo_item='bonificacao'
      AND pi.quantidade=v_s.quantidade
      AND pi.valor_unitario=0
  ) THEN
    RAISE EXCEPTION 'O pedido não contém o item de bonificação aprovado (produto, quantidade e valor zero)';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.solicitacao_aprovacoes a
    WHERE a.solicitacao_id=v_s.id AND a.etapa='diretoria'
      AND a.status='aprovado'
  ) THEN
    RAISE EXCEPTION 'Aprovação final da Diretoria não localizada';
  END IF;
  IF NOT EXISTS(
    SELECT 1 FROM public.solicitacao_aprovacoes a
    WHERE a.solicitacao_id=v_s.id AND a.etapa='financeiro'
      AND a.status IN ('aprovado','reprovado')
  ) THEN
    RAISE EXCEPTION 'Parecer do Financeiro não finalizado';
  END IF;
  IF EXISTS(
    SELECT 1 FROM public.solicitacao_aprovacoes a
    WHERE a.solicitacao_id=v_s.id AND (
      a.status IN ('pendente','aguardando')
      OR (a.status='reprovado' AND a.etapa='diretoria')
    )
  ) THEN
    RAISE EXCEPTION 'Existem aprovações pendentes ou veto da Diretoria';
  END IF;

  -- Atualização de solicitação + trilha na mesma transação PostgreSQL.
  -- SECURITY DEFINER evita UPDATE silencioso de zero linhas por RLS.
  UPDATE public.solicitacoes SET
    pedido_id=p_pedido_id,
    vinculada_em=COALESCE(v_s.vinculada_em,v_data),
    vinculada_por=COALESCE(v_s.vinculada_por,v_uid),
    status_fluxo='concluida'
  WHERE id=v_s.id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Não foi possível atualizar o status da bonificação';
  END IF;

  INSERT INTO public.solicitacao_conclusoes_adm
    (solicitacao_id,pedido_id,concluido_por,concluido_em)
  VALUES
    (v_s.id,p_pedido_id,v_uid,v_data)
  ON CONFLICT (solicitacao_id) DO NOTHING;

  IF NOT EXISTS (
    SELECT 1 FROM public.solicitacao_conclusoes_adm c
    WHERE c.solicitacao_id=v_s.id AND c.pedido_id=p_pedido_id
  ) THEN
    RAISE EXCEPTION 'Registro de conclusão está associado a pedido diferente';
  END IF;
  RETURN jsonb_build_object('situacao','concluida',
    'solicitacao_id',v_s.id,'pedido_id',p_pedido_id);
END;
$mc$;

REVOKE ALL ON FUNCTION public.mc_vincular_concluir_bonificacao(uuid,uuid)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.mc_vincular_concluir_bonificacao(uuid,uuid)
TO authenticated;
COMMIT;

-- Conferência da função (somente leitura):
SELECT p.proname,p.prosecdef,pg_get_function_arguments(p.oid) AS argumentos
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public' AND p.proname='mc_vincular_concluir_bonificacao';

-- Consulte o status atual da bonificação sem alterá-lo:
SELECT s.codigo,s.status_fluxo,s.pedido_id,c.concluido_em
FROM public.solicitacoes s
LEFT JOIN public.solicitacao_conclusoes_adm c ON c.solicitacao_id=s.id
WHERE s.codigo='BON-000019';
