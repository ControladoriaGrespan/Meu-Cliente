-- Meu Cliente: vincular tabela automaticamente ao novo cliente pelo preço/kg do Francês.
-- Execute no Supabase após importar DA0 e DA1. NÃO altera tabelas já vinculadas.
-- Produto referência 10000122: pacote 8kg. Exemplo R$ 7,20/kg = R$ 57,60/pacote.
CREATE OR REPLACE FUNCTION public.definir_tabela_preco_por_ficha()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_preco_kg numeric;
  v_tabela_id public.tabelas_preco.id%TYPE;
  v_quantidade integer;
BEGIN
  IF NEW.ficha_id IS NULL OR NEW.tabela_preco_id IS NOT NULL THEN
    RETURN NEW;
  END IF;
  SELECT f.preco_kg INTO v_preco_kg
  FROM public.fichas_clientes f WHERE f.id = NEW.ficha_id;
  IF v_preco_kg IS NULL OR v_preco_kg <= 0 THEN RETURN NEW; END IF;

  SELECT COUNT(DISTINCT t.id), (ARRAY_AGG(DISTINCT t.id))[1]
  INTO v_quantidade, v_tabela_id
  FROM public.tabelas_preco t
  JOIN public.tabela_preco_itens i ON i.tabela_id = t.id
  JOIN public.produtos p ON p.id = i.produto_id
  WHERE p.codigo = '10000122' AND t.ativo IS TRUE
    AND ROUND(i.preco_unitario::numeric, 2) = ROUND(v_preco_kg * 8, 2);

  IF v_quantidade = 1 THEN NEW.tabela_preco_id := v_tabela_id; END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_cliente_tabela_preco_por_ficha ON public.clientes;
CREATE TRIGGER trg_cliente_tabela_preco_por_ficha
BEFORE INSERT OR UPDATE OF ficha_id, tabela_preco_id ON public.clientes
FOR EACH ROW EXECUTE FUNCTION public.definir_tabela_preco_por_ficha();

-- Backfill seletivo de clientes originados de fichas e ainda SEM tabela de preços.
WITH candidatos AS (
  SELECT c.id AS cliente_id, (ARRAY_AGG(DISTINCT t.id))[1] AS tabela_id
  FROM public.clientes c
  JOIN public.fichas_clientes f ON f.id = c.ficha_id
  JOIN public.produtos p ON p.codigo = '10000122'
  JOIN public.tabela_preco_itens i ON i.produto_id = p.id
  JOIN public.tabelas_preco t ON t.id = i.tabela_id AND t.ativo IS TRUE
  WHERE c.tabela_preco_id IS NULL AND f.preco_kg > 0
    AND ROUND(i.preco_unitario::numeric, 2) = ROUND(f.preco_kg::numeric * 8, 2)
  GROUP BY c.id HAVING COUNT(DISTINCT t.id) = 1
)
UPDATE public.clientes c
SET tabela_preco_id = cand.tabela_id
FROM candidatos cand
WHERE c.id = cand.cliente_id AND c.tabela_preco_id IS NULL;

-- Conferência para o preço de exemplo.
SELECT t.codigo AS tabela_totvs, t.descricao,
       i.preco_unitario AS preco_pacote_8kg,
       ROUND(i.preco_unitario::numeric / 8, 2) AS preco_frances_kg
FROM public.tabelas_preco t
JOIN public.tabela_preco_itens i ON i.tabela_id = t.id
JOIN public.produtos p ON p.id = i.produto_id
WHERE p.codigo = '10000122' AND t.ativo IS TRUE
  AND ROUND(i.preco_unitario::numeric, 2) = 57.60
ORDER BY t.codigo;
