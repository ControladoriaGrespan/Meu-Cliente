-- Gamificacao Comercial V3 — pesos e metas por categoria (admin somente)
-- Executar no Supabase SQL Editor.
BEGIN;
CREATE TABLE IF NOT EXISTS public.gamificacao_regras (
  papel text NOT NULL CHECK(papel IN ('vendedor','supervisor','coordenador')),
  indicador text NOT NULL CHECK(indicador IN ('fichas','faturamento_previsto','faturamento_realizado','volume_previsto_ton','volume_realizado_ton')),
  peso numeric(8,2) NOT NULL DEFAULT 20 CHECK(peso>=0 AND peso<=100),
  meta numeric(18,3) NOT NULL DEFAULT 0 CHECK(meta>=0),
  atualizado_em timestamptz NOT NULL DEFAULT now(),
  atualizado_por uuid,
  PRIMARY KEY (papel,indicador)
);
INSERT INTO public.gamificacao_regras(papel,indicador,peso,meta)
SELECT p.papel,i.indicador,20,0
FROM (VALUES ('vendedor'),('supervisor'),('coordenador')) AS p(papel)
CROSS JOIN (VALUES ('fichas'),('faturamento_previsto'),('faturamento_realizado'),
                   ('volume_previsto_ton'),('volume_realizado_ton')) AS i(indicador)
ON CONFLICT (papel,indicador) DO NOTHING;
ALTER TABLE public.gamificacao_regras ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.gamificacao_regras FROM anon,authenticated;
CREATE OR REPLACE FUNCTION public.gamificacao_admin_autorizado() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
 SELECT EXISTS (SELECT 1 FROM public.usuarios u
   WHERE u.id=auth.uid() AND u.ativo=true AND u.papel::text='admin')
$$;
REVOKE ALL ON FUNCTION public.gamificacao_admin_autorizado() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.gamificacao_admin_autorizado() TO authenticated;
DROP POLICY IF EXISTS gamificacao_regras_admin_select ON public.gamificacao_regras;
CREATE POLICY gamificacao_regras_admin_select ON public.gamificacao_regras
 FOR SELECT TO authenticated USING (public.gamificacao_admin_autorizado());
GRANT SELECT ON public.gamificacao_regras TO authenticated;

CREATE OR REPLACE FUNCTION public.salvar_gamificacao_regras(p_papel text,p_regras jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE item jsonb; v_indicador text; v_peso numeric; v_meta numeric;
BEGIN
 IF NOT public.gamificacao_admin_autorizado() THEN RAISE EXCEPTION 'Acesso restrito ao administrador'; END IF;
 IF p_papel NOT IN ('vendedor','supervisor','coordenador') OR
    jsonb_typeof(p_regras) IS DISTINCT FROM 'array' OR jsonb_array_length(p_regras)<>5 THEN
   RAISE EXCEPTION 'Informe cinco regras validas para o perfil'; END IF;
 IF (SELECT COUNT(DISTINCT el->>'indicador') FROM jsonb_array_elements(p_regras) el)<>5 THEN
   RAISE EXCEPTION 'Indicadores duplicados'; END IF;
 IF (SELECT COUNT(*) FROM jsonb_array_elements(p_regras) el
     WHERE el->>'indicador' IN ('fichas','faturamento_previsto','faturamento_realizado','volume_previsto_ton','volume_realizado_ton'))<>5 THEN
   RAISE EXCEPTION 'Indicadores invalidos'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_regras) el
   WHERE jsonb_typeof(el->'peso')<>'number' OR jsonb_typeof(el->'meta')<>'number') THEN
   RAISE EXCEPTION 'Pesos e metas devem ser numeros'; END IF;
 IF abs((SELECT sum((el->>'peso')::numeric) FROM jsonb_array_elements(p_regras) el)-100)>0.001 THEN
   RAISE EXCEPTION 'A soma dos pesos deve ser 100'; END IF;
 FOR item IN SELECT * FROM jsonb_array_elements(p_regras) LOOP
   v_indicador:=item->>'indicador';v_peso:=(item->>'peso')::numeric;v_meta:=(item->>'meta')::numeric;
   IF v_peso<0 OR v_peso>100 OR v_meta<0 OR v_meta>100000000000000 OR
     round(v_peso,2)<>v_peso OR round(v_meta,3)<>v_meta THEN
     RAISE EXCEPTION 'Peso ou meta fora do intervalo permitido'; END IF;
   UPDATE public.gamificacao_regras SET peso=v_peso,
     meta=v_meta, atualizado_em=now(),atualizado_por=auth.uid()
   WHERE papel=p_papel AND indicador=v_indicador;
   IF NOT FOUND THEN RAISE EXCEPTION 'Regra nao encontrada'; END IF;
 END LOOP;
END;
$$;
REVOKE ALL ON FUNCTION public.salvar_gamificacao_regras(text,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.salvar_gamificacao_regras(text,jsonb) TO authenticated;
COMMIT;