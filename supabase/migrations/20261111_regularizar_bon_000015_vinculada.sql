-- Meu Cliente v98 — regularização pontual de bonificação já vinculada.
-- Requer a migração 20261111_conclusao_solicitacoes_adm_vendas.sql.
-- Não executa para outras solicitações e não conclui se faltarem requisitos.
BEGIN;
DO $mc$
DECLARE v public.solicitacoes%ROWTYPE;
BEGIN
  SELECT * INTO v FROM public.solicitacoes WHERE codigo='BON-000015' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'BON-000015 não encontrada'; END IF;
  IF v.categoria <> 'bonificacao' THEN RAISE EXCEPTION 'Categoria inválida'; END IF;
  IF v.status_fluxo='concluida' THEN RAISE NOTICE 'BON-000015 já concluída';RETURN;END IF;
  IF v.status_fluxo <> 'vinculada' OR v.pedido_id IS NULL OR v.vinculada_por IS NULL THEN
    RAISE EXCEPTION 'BON-000015 não está vinculada a pedido com responsável registrado';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.pedidos p
      WHERE p.id=v.pedido_id AND p.cliente_id=v.cliente_id) THEN
    RAISE EXCEPTION 'Pedido inexistente ou de outro cliente';
  END IF;
  IF EXISTS (SELECT 1 FROM public.solicitacao_aprovacoes a
      WHERE a.solicitacao_id=v.id AND a.status IN ('pendente','aguardando')) THEN
    RAISE EXCEPTION 'Existem aprovações pendentes';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.solicitacao_aprovacoes a
      WHERE a.solicitacao_id=v.id AND a.etapa='diretoria' AND a.status='aprovado') THEN
    RAISE EXCEPTION 'Sem aprovação da Diretoria';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.usuarios u
    WHERE u.id=v.vinculada_por AND u.papel::text IN ('adm_vendas','gestao_adm_vendas','admin')) THEN
    RAISE EXCEPTION 'Vinculação não foi registrada por Administração de Vendas';
  END IF;
  INSERT INTO public.solicitacao_conclusoes_adm
    (solicitacao_id,pedido_id,concluido_por,concluido_em)
  VALUES (v.id,v.pedido_id,v.vinculada_por,coalesce(v.vinculada_em,now()))
  ON CONFLICT (solicitacao_id) DO NOTHING;
  UPDATE public.solicitacoes SET status_fluxo='concluida' WHERE id=v.id;
END;
$mc$;
COMMIT;
SELECT s.codigo,s.status_fluxo,s.pedido_id,c.concluido_por,c.concluido_em
FROM public.solicitacoes s
LEFT JOIN public.solicitacao_conclusoes_adm c ON c.solicitacao_id=s.id
WHERE s.codigo='BON-000015';
