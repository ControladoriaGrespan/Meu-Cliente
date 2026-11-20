BEGIN;

CREATE TABLE IF NOT EXISTS public.vt_cargas_faturamento (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  autor uuid NOT NULL,
  arquivo text NOT NULL,
  total_grupos integer NOT NULL CHECK (total_grupos>0),
  criada_em timestamptz NOT NULL DEFAULT now(),
  publicada_em timestamptz
);
CREATE TABLE IF NOT EXISTS public.vt_faturamento_mensal (
  carga_id uuid NOT NULL REFERENCES public.vt_cargas_faturamento(id) ON DELETE CASCADE,
  mes date NOT NULL CHECK (mes BETWEEN DATE '2026-01-01' AND DATE '2026-10-01' AND EXTRACT(day FROM mes)=1),
  cliente_id uuid NOT NULL REFERENCES public.clientes(id),
  produto_id uuid NOT NULL REFERENCES public.produtos(id),
  tipo text NOT NULL CHECK (tipo IN ('venda','bonificacao')),
  unidade text NOT NULL CHECK (length(unidade) BETWEEN 1 AND 12),
  quantidade numeric NOT NULL CHECK (quantidade>0 AND quantidade<'Infinity'::numeric),
  kg numeric CHECK (kg>0 AND kg<'Infinity'::numeric),
  valor_documento numeric NOT NULL CHECK (valor_documento>=0 AND valor_documento<'Infinity'::numeric),
  PRIMARY KEY (carga_id,mes,cliente_id,produto_id,tipo)
);
CREATE TABLE IF NOT EXISTS public.vt_faturamento_publicado (
  mes date PRIMARY KEY,
  carga_id uuid NOT NULL REFERENCES public.vt_cargas_faturamento(id)
);
CREATE INDEX IF NOT EXISTS vt_faturamento_cliente_mes ON public.vt_faturamento_mensal(cliente_id,mes,carga_id);
ALTER TABLE public.vt_cargas_faturamento ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vt_faturamento_mensal ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vt_faturamento_publicado ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.vt_cargas_faturamento,public.vt_faturamento_mensal,public.vt_faturamento_publicado FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.vt_carga_faturamento_iniciar(p_arquivo text,p_total integer)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_id uuid;
BEGIN
  IF public.vt_papel() IS DISTINCT FROM 'admin' THEN RAISE EXCEPTION 'Acesso restrito ao Administrador'; END IF;
  IF p_total IS NULL OR p_total NOT BETWEEN 1 AND 1000000 OR p_arquivo IS NULL OR length(p_arquivo) NOT BETWEEN 1 AND 255
    THEN RAISE EXCEPTION 'Arquivo ou tamanho da carga inválidos'; END IF;
  INSERT INTO public.vt_cargas_faturamento(autor,arquivo,total_grupos)
    VALUES (auth.uid(),p_arquivo,p_total) RETURNING id INTO v_id;
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION public.vt_carga_faturamento_lote(p_carga uuid,p_lote jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
  IF public.vt_papel() IS DISTINCT FROM 'admin' THEN RAISE EXCEPTION 'Acesso restrito ao Administrador'; END IF;
  IF p_lote IS NULL OR jsonb_typeof(p_lote)<>'array' THEN RAISE EXCEPTION 'Lote inválido'; END IF;
  IF jsonb_array_length(p_lote) NOT BETWEEN 1 AND 400 THEN RAISE EXCEPTION 'Lote inválido'; END IF;
  PERFORM 1 FROM public.vt_cargas_faturamento
    WHERE id=p_carga AND autor=auth.uid() AND publicada_em IS NULL FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Carga indisponível para edição'; END IF;
  INSERT INTO public.vt_faturamento_mensal(carga_id,mes,cliente_id,produto_id,tipo,unidade,quantidade,kg,valor_documento)
  SELECT p_carga,r.mes,r.cliente_id,r.produto_id,r.tipo,r.unidade,r.quantidade,r.kg,r.valor_documento
  FROM jsonb_to_recordset(p_lote) AS r(mes date,cliente_id uuid,produto_id uuid,tipo text,unidade text,quantidade numeric,kg numeric,valor_documento numeric)
  ON CONFLICT (carga_id,mes,cliente_id,produto_id,tipo) DO UPDATE SET
    unidade=excluded.unidade,quantidade=excluded.quantidade,kg=excluded.kg,valor_documento=excluded.valor_documento;
END $$;

CREATE OR REPLACE FUNCTION public.vt_carga_faturamento_publicar(p_carga uuid,p_meses date[])
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_carga public.vt_cargas_faturamento%ROWTYPE; v_total integer; v_meses date[];
BEGIN
  IF public.vt_papel() IS DISTINCT FROM 'admin' THEN RAISE EXCEPTION 'Acesso restrito ao Administrador'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('vt_faturamento_publicar',0));
  SELECT * INTO v_carga FROM public.vt_cargas_faturamento
    WHERE id=p_carga AND autor=auth.uid() FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Carga não encontrada'; END IF;
  SELECT count(*),array_agg(DISTINCT mes ORDER BY mes) INTO v_total,v_meses
    FROM public.vt_faturamento_mensal WHERE carga_id=p_carga;
  IF v_total<>v_carga.total_grupos OR v_meses IS DISTINCT FROM p_meses THEN
    RAISE EXCEPTION 'Carga incompleta. Os dados publicados foram preservados';
  END IF;
  IF v_carga.publicada_em IS NOT NULL THEN RETURN v_total; END IF;
  IF EXISTS (
    SELECT 1 FROM public.vt_faturamento_publicado p JOIN public.vt_cargas_faturamento c ON c.id=p.carga_id
    WHERE p.mes=ANY(v_meses) AND c.criada_em>v_carga.criada_em
  ) THEN RAISE EXCEPTION 'Já existe uma carga mais recente para um dos meses'; END IF;
  INSERT INTO public.vt_faturamento_publicado(mes,carga_id)
    SELECT m,p_carga FROM unnest(v_meses) m
    ON CONFLICT (mes) DO UPDATE SET carga_id=excluded.carga_id;
  UPDATE public.vt_cargas_faturamento SET publicada_em=now() WHERE id=p_carga;
  RETURN v_total;
END $$;

CREATE OR REPLACE FUNCTION public.vt_consumo_clientes(p_clientes uuid[])
RETURNS TABLE(cliente_id uuid,media_kg numeric,meses integer)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_papel text:=public.vt_papel(); v_supervisor uuid:=public.vt_supervisor_do_atendimento();
BEGIN
  IF (v_papel IS DISTINCT FROM 'admin' AND v_supervisor IS NULL) THEN RAISE EXCEPTION 'Perfil sem carteira técnica vinculada'; END IF;
  IF p_clientes IS NULL OR cardinality(p_clientes) NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'Informe até 100 clientes'; END IF;
  RETURN QUERY
  WITH cobertura AS (SELECT count(*)::int AS meses FROM public.vt_faturamento_publicado)
  SELECT c.id,CASE WHEN count(f.produto_id)>0 AND bool_and(f.kg IS NOT NULL)
    THEN round(sum(f.kg)/nullif(m.meses,0),3) END,m.meses
  FROM public.clientes c CROSS JOIN cobertura m
  LEFT JOIN (
    public.vt_faturamento_mensal f JOIN public.vt_faturamento_publicado p USING (mes,carga_id)
  ) ON f.cliente_id=c.id AND f.tipo='venda'
  WHERE c.id=ANY(p_clientes) AND
    (v_papel='admin' OR public.vt_vendedor_na_carteira(c.vendedor_id,v_supervisor))
  GROUP BY c.id,m.meses;
END $$;

CREATE OR REPLACE FUNCTION public.vt_consumo_cliente_sku(p_cliente uuid)
RETURNS TABLE(codigo text,descricao text,unidade text,media_venda numeric,media_bonificacao numeric,meses integer)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_papel text:=public.vt_papel(); v_supervisor uuid:=public.vt_supervisor_do_atendimento();
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.clientes c WHERE c.id=p_cliente
    AND (v_papel='admin' OR public.vt_vendedor_na_carteira(c.vendedor_id,v_supervisor))
  ) THEN RAISE EXCEPTION 'Cliente fora da carteira técnica'; END IF;
  RETURN QUERY
  WITH cobertura AS (SELECT count(*)::int AS meses FROM public.vt_faturamento_publicado)
  SELECT p.codigo::text,p.descricao::text,f.unidade,
    round(coalesce(sum(f.quantidade) FILTER (WHERE f.tipo='venda'),0)/nullif(m.meses,0),3),
    round(coalesce(sum(f.quantidade) FILTER (WHERE f.tipo='bonificacao'),0)/nullif(m.meses,0),3),m.meses
  FROM public.vt_faturamento_mensal f
  JOIN public.vt_faturamento_publicado a USING (mes,carga_id)
  JOIN public.produtos p ON p.id=f.produto_id
  CROSS JOIN cobertura m
  WHERE f.cliente_id=p_cliente
  GROUP BY p.codigo,p.descricao,f.unidade,m.meses ORDER BY p.codigo,f.unidade;
END $$;

REVOKE ALL ON FUNCTION public.vt_carga_faturamento_iniciar(text,integer),public.vt_carga_faturamento_lote(uuid,jsonb),
  public.vt_carga_faturamento_publicar(uuid,date[]),public.vt_consumo_clientes(uuid[]),public.vt_consumo_cliente_sku(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.vt_carga_faturamento_iniciar(text,integer),public.vt_carga_faturamento_lote(uuid,jsonb),
  public.vt_carga_faturamento_publicar(uuid,date[]),public.vt_consumo_clientes(uuid[]),public.vt_consumo_cliente_sku(uuid) TO authenticated;

COMMIT;
