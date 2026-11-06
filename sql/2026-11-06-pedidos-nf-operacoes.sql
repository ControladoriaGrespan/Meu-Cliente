-- Meu Cliente — Separação de NF e operações de venda (etapa 1)
-- Execute no SQL Editor do Supabase do ambiente correto, ANTES de utilizar a tela atualizada.
BEGIN;
ALTER TABLE public.pedidos
 ADD COLUMN IF NOT EXISTS codigo_operacao text NOT NULL DEFAULT '01',
 ADD COLUMN IF NOT EXISTS total_nfs integer NOT NULL DEFAULT 1;
ALTER TABLE public.pedido_itens
 ADD COLUMN IF NOT EXISTS numero_nf integer NOT NULL DEFAULT 1,
 ADD COLUMN IF NOT EXISTS codigo_operacao text NOT NULL DEFAULT '01',
 ADD COLUMN IF NOT EXISTS codigo_tes text;
ALTER TABLE public.pedidos
 DROP CONSTRAINT IF EXISTS pedidos_codigo_operacao_check,
 ADD CONSTRAINT pedidos_codigo_operacao_check CHECK (codigo_operacao IN ('01','02','03','04')),
 DROP CONSTRAINT IF EXISTS pedidos_total_nfs_check,
 ADD CONSTRAINT pedidos_total_nfs_check CHECK (total_nfs BETWEEN 1 AND 5);
ALTER TABLE public.pedido_itens
 DROP CONSTRAINT IF EXISTS pedido_itens_codigo_operacao_check,
 ADD CONSTRAINT pedido_itens_codigo_operacao_check CHECK (codigo_operacao IN ('01','02','03','04')),
 DROP CONSTRAINT IF EXISTS pedido_itens_numero_nf_check,
 ADD CONSTRAINT pedido_itens_numero_nf_check CHECK (numero_nf BETWEEN 1 AND 5);
-- Não alteramos os pedidos já registrados: eles assumem operação 01 e NF 1
-- até eventual migração histórica assistida; a emissão de CSV fiscal permanecerá
-- bloqueada sem TES validada conforme as regras de TES Inteligente.
COMMIT;