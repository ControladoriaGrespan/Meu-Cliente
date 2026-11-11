-- DIAGNÓSTICO (somente leitura) — Solicitações de retirada
-- Execute no Supabase SQL Editor e envie o resultado.
-- Nenhuma tabela, função, trigger ou solicitação será alterada.

-- 1) Confira qual regra está efetivamente ativa no banco.
SELECT c.conname AS nome, pg_get_constraintdef(c.oid) AS regra
FROM pg_constraint c
WHERE c.conrelid='public.solicitacoes'::regclass
  AND c.conname='solicitacoes_justificativa_check';

-- 2) Identifique triggers que podem modificar tipo/justificativa antes do INSERT.
SELECT t.tgname AS trigger_nome,
       pg_get_triggerdef(t.oid,true) AS definicao,
       p.proname AS funcao,
       p.oid::regprocedure::text AS assinatura
FROM pg_trigger t
JOIN pg_proc p ON p.oid=t.tgfoid
WHERE t.tgrelid='public.solicitacoes'::regclass
  AND NOT t.tgisinternal
ORDER BY t.tgname;

-- 3) Execute esta consulta para ler o código das funções encontradas na etapa 2.
SELECT t.tgname AS trigger_nome,
       pg_get_functiondef(t.tgfoid) AS codigo_funcao
FROM pg_trigger t
WHERE t.tgrelid='public.solicitacoes'::regclass
  AND NOT t.tgisinternal
  AND (t.tgtype & 2) = 2 -- BEFORE
ORDER BY t.tgname;

-- 4) Cheque quais combinações a expressão permite, sem inserir registros.
SELECT
  'retirada + Baixo consumo' AS cenario,
  (('Baixo consumo'=ANY(ARRAY['Relacionamento','Equipamento Antigo','Equipamento Danificado']))
   OR ('retirada'='retirada' AND 'Baixo consumo'=ANY(ARRAY['Baixo consumo','Encerramento do contrato']))) AS deveria_permitir
UNION ALL
SELECT 'retirada + Encerramento do contrato',
  (('Encerramento do contrato'=ANY(ARRAY['Relacionamento','Equipamento Antigo','Equipamento Danificado']))
   OR ('retirada'='retirada' AND 'Encerramento do contrato'=ANY(ARRAY['Baixo consumo','Encerramento do contrato'])));
