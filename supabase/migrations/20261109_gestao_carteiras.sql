-- MEU CLIENTE | Gestao de Carteiras | 2026-11-09
-- Execute uma vez no Supabase SQL Editor antes de confirmar atualizacoes.
-- Mantem cadastro, fichas e historico. Somente troca clientes.vendedor_id.

CREATE TABLE IF NOT EXISTS public.carteira_movimentacoes (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  lote_id uuid NOT NULL,
  cliente_id uuid NOT NULL REFERENCES public.clientes(id) ON DELETE RESTRICT,
  vendedor_anterior_id uuid REFERENCES public.usuarios(id) ON DELETE SET NULL,
  vendedor_novo_id uuid NOT NULL REFERENCES public.usuarios(id) ON DELETE RESTRICT,
  codigo_totvs text,
  loja_totvs text,
  origem text NOT NULL CHECK (origem IN ('SA1','MANUAL')),
  motivo text NOT NULL,
  realizado_por uuid NOT NULL REFERENCES public.usuarios(id),
  realizado_em timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS carteira_movimentacoes_lote_idx ON public.carteira_movimentacoes(lote_id);
CREATE INDEX IF NOT EXISTS carteira_movimentacoes_cliente_idx ON public.carteira_movimentacoes(cliente_id, realizado_em DESC);
ALTER TABLE public.carteira_movimentacoes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.carteira_movimentacoes FROM PUBLIC, anon, authenticated;
REVOKE ALL ON SEQUENCE public.carteira_movimentacoes_id_seq FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.carteira_aplicar_lote(
  p_movimentos jsonb, p_motivo text, p_origem text DEFAULT 'SA1'
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE
  v_lote uuid := gen_random_uuid();
  v_reg record;
  v_cliente public.clientes%ROWTYPE;
  v_novo public.usuarios%ROWTYPE;
  v_total integer := 0;
  v_array jsonb;
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.usuarios WHERE id=auth.uid() AND papel='admin' AND ativo IS DISTINCT FROM false
  ) THEN RAISE EXCEPTION 'Apenas o Administrador pode movimentar carteiras'; END IF;
  IF p_origem NOT IN ('SA1','MANUAL') THEN RAISE EXCEPTION 'Origem invalida'; END IF;
  IF length(btrim(coalesce(p_motivo,''))) < 6 THEN RAISE EXCEPTION 'Informe um motivo (minimo 6 caracteres)'; END IF;
  IF jsonb_typeof(p_movimentos)<>'array' OR jsonb_array_length(p_movimentos) NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION 'Informe de 1 a 100 movimentacoes por lote'; END IF;
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(p_movimentos) x
    GROUP BY x->>'cliente_id' HAVING count(*)>1
  ) THEN RAISE EXCEPTION 'Cliente repetido no lote'; END IF;

  FOR v_reg IN SELECT * FROM jsonb_to_recordset(p_movimentos)
    AS x(cliente_id uuid, vendedor_anterior_id uuid, vendedor_novo_id uuid, codigo_totvs text, loja_totvs text)
  LOOP
    IF v_reg.cliente_id IS NULL OR v_reg.vendedor_novo_id IS NULL THEN
      RAISE EXCEPTION 'Cliente ou vendedor nao informado'; END IF;
    SELECT * INTO v_cliente FROM public.clientes WHERE id=v_reg.cliente_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Cliente nao localizado: %',v_reg.cliente_id; END IF;
    IF v_cliente.vendedor_id IS DISTINCT FROM v_reg.vendedor_anterior_id THEN
      RAISE EXCEPTION 'Carteira do cliente % foi alterada desde a previa; atualize a previa',v_cliente.codigo_totvs;
    END IF;
    IF v_cliente.vendedor_id=v_reg.vendedor_novo_id THEN
      RAISE EXCEPTION 'Cliente % ja pertence ao vendedor de destino',v_cliente.codigo_totvs;
    END IF;
    IF trim(coalesce(v_cliente.codigo_totvs,'')) IS DISTINCT FROM trim(coalesce(v_reg.codigo_totvs,'')) OR
       lpad(trim(coalesce(v_cliente.loja_totvs,'01')),2,'0') IS DISTINCT FROM lpad(trim(coalesce(v_reg.loja_totvs,'01')),2,'0')
    THEN RAISE EXCEPTION 'Codigo TOTVS/loja divergente para cliente %',v_reg.cliente_id; END IF;
    SELECT * INTO v_novo FROM public.usuarios WHERE id=v_reg.vendedor_novo_id
      AND papel='vendedor' AND ativo IS DISTINCT FROM false;
    IF NOT FOUND THEN RAISE EXCEPTION 'Vendedor destino inexistente, inativo ou sem papel vendedor'; END IF;
    UPDATE public.clientes SET vendedor_id=v_reg.vendedor_novo_id WHERE id=v_reg.cliente_id;
    INSERT INTO public.carteira_movimentacoes(
      lote_id,cliente_id,vendedor_anterior_id,vendedor_novo_id,codigo_totvs,loja_totvs,origem,motivo,realizado_por
    ) VALUES(
      v_lote,v_cliente.id,v_reg.vendedor_anterior_id,v_reg.vendedor_novo_id,
      v_cliente.codigo_totvs,v_cliente.loja_totvs,p_origem,trim(p_motivo),auth.uid()
    );
    v_total:=v_total+1;
  END LOOP;
  RETURN jsonb_build_object('lote_id',v_lote,'alterados',v_total);
END;
$$;
REVOKE ALL ON FUNCTION public.carteira_aplicar_lote(jsonb,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.carteira_aplicar_lote(jsonb,text,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.carteira_historico()
RETURNS TABLE (
  realizado_em timestamptz, lote_id uuid, cliente text,
  codigo_totvs text, vendedor_anterior text, vendedor_novo text,
  motivo text, origem text, responsavel text
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.usuarios WHERE id=auth.uid() AND papel='admin' AND ativo IS DISTINCT FROM false
  ) THEN RAISE EXCEPTION 'Consulta restrita ao Administrador'; END IF;
  RETURN QUERY SELECT m.realizado_em,m.lote_id,c.razao_social,m.codigo_totvs,
    a.nome,b.nome,m.motivo,m.origem,u.nome
  FROM public.carteira_movimentacoes m
  JOIN public.clientes c ON c.id=m.cliente_id
  LEFT JOIN public.usuarios a ON a.id=m.vendedor_anterior_id
  JOIN public.usuarios b ON b.id=m.vendedor_novo_id
  JOIN public.usuarios u ON u.id=m.realizado_por
  ORDER BY m.realizado_em DESC LIMIT 5000;
END;
$$;
REVOKE ALL ON FUNCTION public.carteira_historico() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.carteira_historico() TO authenticated;
