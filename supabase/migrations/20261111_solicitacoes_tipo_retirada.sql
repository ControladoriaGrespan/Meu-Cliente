-- MEU CLIENTE — 11/11/2026
-- CORREÇÃO DO ERRO 23514: solicitacoes_tipo_check
-- Permite o tipo 'retirada' e preserva os valores/regras anteriormente aceitos.
-- Não altera solicitações já cadastradas nem modifica fluxos de aprovação.
-- Execute no Supabase SQL Editor após backup.
BEGIN;

DO $mc$
DECLARE
  v_regra text;
  v_expr text;
BEGIN
  SELECT pg_get_constraintdef(oid)
    INTO v_regra
  FROM pg_constraint
  WHERE conrelid='public.solicitacoes'::regclass
    AND conname='solicitacoes_tipo_check'
    AND contype='c';

  IF v_regra IS NULL THEN
    RAISE EXCEPTION 'Constraint solicitacoes_tipo_check não encontrada; não foi feita nenhuma alteração.';
  END IF;

  IF left(v_regra,7) <> 'CHECK (' OR right(v_regra,1) <> ')' THEN
    RAISE EXCEPTION 'Expressão inesperada da constraint: %',v_regra;
  END IF;

  -- Retira somente o invólucro CHECK (...), deixando sua lógica intacta.
  v_expr:=substring(v_regra FROM 8 FOR char_length(v_regra)-8);

  -- Compatível com reexecução: detectar a autorização explícita adicionada.
  IF position('retirada' IN v_expr)>0 THEN
    RAISE NOTICE 'A constraint já menciona retirada. Nenhuma alteração realizada. Regra: %',v_regra;
    RETURN;
  END IF;

  EXECUTE 'ALTER TABLE public.solicitacoes DROP CONSTRAINT solicitacoes_tipo_check';
  EXECUTE format(
    'ALTER TABLE public.solicitacoes ADD CONSTRAINT solicitacoes_tipo_check CHECK ((%s) OR (tipo = ''retirada'' AND categoria = ''equipamento''))',
    v_expr
  );

  RAISE NOTICE 'Tipo retirada autorizado para categoria equipamento; regra anterior preservada.';
END;
$mc$;

COMMIT;

SELECT conname, pg_get_constraintdef(oid) AS regra
FROM pg_constraint
WHERE conrelid='public.solicitacoes'::regclass
  AND conname='solicitacoes_tipo_check';
