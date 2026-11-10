-- Meu Cliente / Bonificações: Diretoria após Financeiro
-- Executar uma vez no Supabase SQL Editor antes de usar o novo fluxo.
-- Preserva solicitações reprovadas e bonificações já concluídas/vinculadas.
BEGIN;

-- Acrescenta a etapa final em solicitações abertas ou reprovadas,
-- sem reiniciar solicitações encerradas nem reabrir reprovações.
INSERT INTO public.solicitacao_aprovacoes
  (solicitacao_id, etapa, ordem, status)
SELECT s.id, 'diretoria',
       GREATEST(5, COALESCE((
         SELECT MAX(a.ordem) FROM public.solicitacao_aprovacoes a
         WHERE a.solicitacao_id = s.id
       ), 0) + 1),
       CASE
         WHEN s.status_fluxo <> 'reprovada'
           AND EXISTS (
             SELECT 1 FROM public.solicitacao_aprovacoes f
             WHERE f.solicitacao_id=s.id AND f.etapa='financeiro' AND f.status='aprovado'
           )
           AND NOT EXISTS (
             SELECT 1 FROM public.solicitacao_aprovacoes a
             WHERE a.solicitacao_id=s.id AND a.status IN ('pendente','aguardando','reprovado')
           )
         THEN 'pendente'
         ELSE 'aguardando'
       END
FROM public.solicitacoes s
WHERE s.categoria='bonificacao'
  AND COALESCE(s.status_fluxo,'aberta') NOT IN ('concluida','vinculada')
  AND NOT EXISTS (
    SELECT 1 FROM public.solicitacao_aprovacoes a
    WHERE a.solicitacao_id=s.id AND a.etapa='diretoria'
  );

-- Evita que uma aprovação antiga, concluída no Financeiro, seja utilizada
-- antes da Diretoria decidir. Não altera reprovadas nem já utilizadas.
UPDATE public.solicitacoes s
SET status_fluxo='aberta'
WHERE s.categoria='bonificacao' AND s.status_fluxo='aprovada'
  AND NOT EXISTS (
    SELECT 1 FROM public.solicitacao_aprovacoes a
    WHERE a.solicitacao_id=s.id AND a.etapa='diretoria' AND a.status='aprovado'
  );

-- Novas bonificações recebem a etapa Diretoria automaticamente.
CREATE OR REPLACE FUNCTION public.mc_incluir_diretoria_bonificacao()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
BEGIN
  IF NEW.categoria='bonificacao' AND NOT EXISTS (
    SELECT 1 FROM public.solicitacao_aprovacoes a
    WHERE a.solicitacao_id=NEW.id AND a.etapa='diretoria'
  ) THEN
    INSERT INTO public.solicitacao_aprovacoes
      (solicitacao_id,etapa,ordem,status)
    SELECT NEW.id,'diretoria',
           GREATEST(5,COALESCE(MAX(a.ordem),0)+1),'aguardando'
    FROM public.solicitacao_aprovacoes a
    WHERE a.solicitacao_id=NEW.id;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS zz_mc_bonificacao_diretoria ON public.solicitacoes;
CREATE TRIGGER zz_mc_bonificacao_diretoria
AFTER INSERT ON public.solicitacoes
FOR EACH ROW EXECUTE FUNCTION public.mc_incluir_diretoria_bonificacao();

-- Defesa no banco: não permite liberar ou vincular solicitação de
-- bonificação sem Financeiro + Diretoria aprovados, e sem outras pendências.
CREATE OR REPLACE FUNCTION public.mc_validar_liberacao_bonificacao()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
BEGIN
  IF NEW.categoria='bonificacao'
     AND NEW.status_fluxo IN ('aprovada','vinculada','concluida')
     AND (OLD.status_fluxo IS DISTINCT FROM NEW.status_fluxo
          OR OLD.pedido_id IS DISTINCT FROM NEW.pedido_id)
  THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.solicitacao_aprovacoes a
      WHERE a.solicitacao_id=NEW.id AND a.etapa='financeiro' AND a.status='aprovado'
    ) OR NOT EXISTS (
      SELECT 1 FROM public.solicitacao_aprovacoes a
      WHERE a.solicitacao_id=NEW.id AND a.etapa='diretoria' AND a.status='aprovado'
    ) OR EXISTS (
      SELECT 1 FROM public.solicitacao_aprovacoes a
      WHERE a.solicitacao_id=NEW.id
        AND a.status NOT IN ('aprovado','nao_aplica')
    ) THEN
      RAISE EXCEPTION 'Bonificação % exige aprovação do Financeiro e Diretoria antes da liberação para pedido',NEW.id;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS zz_mc_validar_liberacao_bonificacao ON public.solicitacoes;
CREATE TRIGGER zz_mc_validar_liberacao_bonificacao
BEFORE UPDATE ON public.solicitacoes
FOR EACH ROW EXECUTE FUNCTION public.mc_validar_liberacao_bonificacao();

COMMIT;

-- Auditoria das solicitações de bonificação não concluídas:
SELECT s.id, s.status_fluxo,
  f.status AS financeiro, d.status AS diretoria
FROM public.solicitacoes s
LEFT JOIN public.solicitacao_aprovacoes f ON f.solicitacao_id=s.id AND f.etapa='financeiro'
LEFT JOIN public.solicitacao_aprovacoes d ON d.solicitacao_id=s.id AND d.etapa='diretoria'
WHERE s.categoria='bonificacao'
ORDER BY s.created_at DESC;
