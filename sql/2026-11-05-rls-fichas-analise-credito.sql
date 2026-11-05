-- Meu Cliente — correção de leitura das fichas na etapa Análise de Crédito
-- Executar no SQL Editor do Supabase do ambiente em que o teste ocorre.
-- Não desabilita RLS nem concede leitura irrestrita.
BEGIN;

CREATE OR REPLACE FUNCTION public.pode_ler_ficha_analise_credito(p_ficha_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.usuarios AS u
    JOIN public.ficha_aprovacoes AS a
      ON a.ficha_id = p_ficha_id
    WHERE u.id = (SELECT auth.uid())
      AND u.ativo IS TRUE
      AND u.papel::text = 'analise_credito'
      AND a.etapa = 'analise_credito'
      AND a.status = 'pendente'
      AND (a.responsavel_id IS NULL OR a.responsavel_id = u.id)
  );
$$;

REVOKE ALL ON FUNCTION public.pode_ler_ficha_analise_credito(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.pode_ler_ficha_analise_credito(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.pode_ler_ficha_analise_credito(uuid) TO authenticated;

DROP POLICY IF EXISTS fichas_clientes_select_analise_credito_pendente
  ON public.fichas_clientes;
CREATE POLICY fichas_clientes_select_analise_credito_pendente
  ON public.fichas_clientes
  FOR SELECT TO authenticated
  USING (public.pode_ler_ficha_analise_credito(id));

COMMIT;

-- Validação com sessão autenticada da Pamela:
-- 1. Abrir Pendências > Análise de Crédito.
-- 2. A ficha e03209d5-4e04-402d-b209-09bef167c30f deve aparecer.
-- 3. Clicar em "Preencher análise de crédito".
-- 4. Confirmar que um usuário de outro perfil não ganha acesso à ficha.
-- Atenção: se o papel da Pamela for atribuído via permissões granulares
-- (em vez de usuarios.papel), adapte a checagem de papel antes de executar.
