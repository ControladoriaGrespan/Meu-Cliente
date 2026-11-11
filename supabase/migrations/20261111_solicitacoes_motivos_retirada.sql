-- MEU CLIENTE — 11/11/2026
-- Compatibiliza a validação de justificativa das solicitações de retirada.
-- Mantém todas as condições anteriormente permitidas pela constraint.
-- Execute no Supabase SQL Editor (produção), após backup.
BEGIN;

DO $mig$
DECLARE
  v_def text;
  v_expr text;
BEGIN
  SELECT pg_get_constraintdef(c.oid)
    INTO v_def
  FROM pg_constraint c
  WHERE c.conrelid = 'public.solicitacoes'::regclass
    AND c.conname = 'solicitacoes_justificativa_check'
    AND c.contype = 'c';

  IF v_def IS NULL THEN
    RAISE EXCEPTION 'Constraint solicitacoes_justificativa_check não encontrada. Verifique o schema antes de alterar.';
  END IF;

  -- pg_get_constraintdef retorna: CHECK (<expressão existente>).
  -- Retira apenas o invólucro CHECK (...), preservando a expressão.
  IF left(v_def, 7) <> 'CHECK (' OR right(v_def,1) <> ')' THEN
    RAISE EXCEPTION 'Formato inesperado da constraint: %', v_def;
  END IF;
  v_expr := substring(v_def FROM 8 FOR char_length(v_def)-8);

  -- Idempotência: não empilha a mesma exceção numa segunda execução.
  IF position('Baixo consumo' IN v_expr) > 0 AND position('Encerramento do contrato' IN v_expr) > 0 THEN
    RAISE NOTICE 'Motivos de retirada já habilitados. Nenhuma alteração necessária.';
    RETURN;
  END IF;

  EXECUTE 'ALTER TABLE public.solicitacoes DROP CONSTRAINT solicitacoes_justificativa_check';
  EXECUTE format(
    'ALTER TABLE public.solicitacoes ADD CONSTRAINT solicitacoes_justificativa_check CHECK ((%s) OR (tipo = ''retirada'' AND justificativa IN (''Baixo consumo'', ''Encerramento do contrato'')))',
    v_expr
  );
  RAISE NOTICE 'Motivos Baixo consumo e Encerramento do contrato habilitados para retirada.';
END;
$mig$;

COMMIT;

-- Conferência: imprime a regra atual da tabela.
SELECT conname, pg_get_constraintdef(oid) AS regra
FROM pg_constraint
WHERE conrelid='public.solicitacoes'::regclass
  AND conname='solicitacoes_justificativa_check';
