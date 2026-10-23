-- Migração: novos perfis técnicos da Panificação
-- Execute no SQL Editor do Supabase de PRODUÇÃO.
-- Preserva todos os papéis anteriores e inclui os dois novos.
BEGIN;
ALTER TABLE public.usuarios DROP CONSTRAINT IF EXISTS usuarios_papel_check;
ALTER TABLE public.usuarios ADD CONSTRAINT usuarios_papel_check CHECK (
  papel::text IN (
    'vendedor','supervisor','coordenador','analise_credito','financeiro',
    'manutencao','adm_vendas','gestao_adm_vendas','tecnico',
    'supervisor_tec_panificacao','tec_panificacao','diretoria','admin'
  )
);
COMMIT;
-- IMPORTANTE: se public.usuarios.papel for ENUM (em vez de text/varchar),
-- será necessário adicionar os valores ao tipo ENUM antes desta migração.
-- O usuário cujo login já foi criado deve ser recuperado, não cadastrado novamente.
