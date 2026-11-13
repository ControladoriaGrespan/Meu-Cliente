-- Meu Cliente v107 | Corrigir erro 23514 ao criar Bonificação e Equipamentos
-- Origem: workflow v99 inclui 'vendedor', mas CHECK anterior não permitia esta etapa.
-- Execute no SQL Editor Supabase após backup. Não altera solicitações nem histórico.
-- Preserva TODAS as condições anteriores do CHECK; adiciona SOMENTE 'vendedor'.
BEGIN;

DO $mc$
DECLARE
  v_check text;
  v_expressao text;
  v_coluna text;
  v_existe boolean;
BEGIN
  SELECT pg_get_constraintdef(c.oid)
    INTO v_check
  FROM pg_constraint c
  WHERE c.conrelid='public.solicitacao_aprovacoes'::regclass
    AND c.conname='solicitacao_aprovacoes_etapa_check'
    AND c.contype='c';

  IF v_check IS NULL THEN
    RAISE EXCEPTION 'Restrição solicitacao_aprovacoes_etapa_check não encontrada. Não alterar sem verificar o schema.';
  END IF;

  -- CHECK gerado pelo PostgreSQL inicia com "CHECK (" e sua expressão
  -- já está entre parênteses. Mantemos a expressão original integralmente.
  IF left(v_check,6) IS DISTINCT FROM 'CHECK ' THEN
    RAISE EXCEPTION 'Definição inesperada da restrição: %',v_check;
  END IF;
  v_expressao := substr(v_check,7);
  IF left(v_expressao,1) <> '(' OR right(v_expressao,1) <> ')' THEN
    RAISE EXCEPTION 'Expressão CHECK inesperada: %',v_expressao;
  END IF;

  EXECUTE 'ALTER TABLE public.solicitacao_aprovacoes
           DROP CONSTRAINT solicitacao_aprovacoes_etapa_check';

  EXECUTE format(
    'ALTER TABLE public.solicitacao_aprovacoes
     ADD CONSTRAINT solicitacao_aprovacoes_etapa_check
     CHECK ((%s) OR etapa = %L)',
    v_expressao,'vendedor'
  );

  RAISE NOTICE 'Restrição atualizada: etapas anteriores preservadas; vendedor acrescentado.';
END;
$mc$;

COMMIT;

-- Conferir a definição:
SELECT c.conname, pg_get_constraintdef(c.oid) AS regra
FROM pg_constraint c
WHERE c.conrelid='public.solicitacao_aprovacoes'::regclass
  AND c.conname='solicitacao_aprovacoes_etapa_check';

-- Conferir pendências existentes: nenhuma alteração de histórico.
SELECT a.etapa,a.status,count(*) AS quantidade
FROM public.solicitacao_aprovacoes a
GROUP BY a.etapa,a.status
ORDER BY a.etapa,a.status;
