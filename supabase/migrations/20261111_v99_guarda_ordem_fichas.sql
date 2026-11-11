-- MEU CLIENTE v99 | Guarda de ordem e autorização para ficha_aprovacoes
-- Executar após backup. Preserva filas existentes e a função decidir_ficha_workflow.
-- Não recria etapas; valida as etapas já geradas pelo workflow atual.
BEGIN;
CREATE OR REPLACE FUNCTION public.mc_validar_ordem_decisao_ficha()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
  v_uid uuid:=auth.uid(); v_papel text; v_ativo boolean;
  v_menor integer;
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
  IF OLD.responsavel_id IS NOT NULL AND OLD.responsavel_id<>v_uid THEN
    RAISE EXCEPTION 'A ficha pertence a outro responsável nesta etapa';
  END IF;
  IF OLD.responsavel_id IS NULL AND v_papel<>OLD.etapa THEN
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
DROP TRIGGER IF EXISTS trg_mc_validar_ordem_decisao_ficha ON public.ficha_aprovacoes;
CREATE TRIGGER trg_mc_validar_ordem_decisao_ficha
BEFORE UPDATE OF status ON public.ficha_aprovacoes
FOR EACH ROW EXECUTE FUNCTION public.mc_validar_ordem_decisao_ficha();
COMMIT;
-- Auditoria somente leitura: identificar quaisquer fichas com duas etapas pendentes.
SELECT ficha_id,count(*) AS etapas_pendentes
FROM public.ficha_aprovacoes
WHERE status='pendente'
GROUP BY ficha_id HAVING count(*)>1 LIMIT 30;
