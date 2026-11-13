-- Meu Cliente v111 | Analise de Viabilidade Financeira
-- Modulo Financeiro: somente Financeiro e Administrador.
-- Implantar apos backup. Nao altera Fichas, workflow nem pedidos existentes.
BEGIN;

CREATE TABLE IF NOT EXISTS public.mc_viabilidade_analises (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 ficha_id uuid NOT NULL UNIQUE REFERENCES public.fichas_clientes(id) ON DELETE RESTRICT,
 parametros jsonb NOT NULL DEFAULT '{}'::jsonb,
 dados_ficha jsonb NOT NULL DEFAULT '{}'::jsonb,
 resultados jsonb NOT NULL DEFAULT '{}'::jsonb,
 situacao text NOT NULL DEFAULT 'rascunho'
   CHECK(situacao IN ('rascunho','em_analise','favoravel','desfavoravel','condicionada')),
 parecer text,
 atualizado_por uuid REFERENCES public.usuarios(id),
 criado_em timestamptz NOT NULL DEFAULT now(),
 atualizado_em timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.mc_viabilidade_historico (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 analise_id uuid NOT NULL REFERENCES public.mc_viabilidade_analises(id) ON DELETE RESTRICT,
 versao integer NOT NULL CHECK(versao>0),
 parametros jsonb NOT NULL,
 dados_ficha jsonb NOT NULL,
 resultados jsonb NOT NULL,
 situacao text NOT NULL,
 parecer text,
 registrado_por uuid NOT NULL REFERENCES public.usuarios(id),
 registrado_em timestamptz NOT NULL DEFAULT now(),
 UNIQUE(analise_id,versao)
);

CREATE INDEX IF NOT EXISTS idx_mc_viabilidade_hist_analise
 ON public.mc_viabilidade_historico(analise_id,registrado_em DESC);

CREATE OR REPLACE FUNCTION public.mc_viabilidade_autorizado()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
 SELECT EXISTS(SELECT 1 FROM public.usuarios
  WHERE id=auth.uid() AND ativo=true AND papel::text IN ('financeiro','admin'))
$$;
REVOKE ALL ON FUNCTION public.mc_viabilidade_autorizado() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.mc_viabilidade_autorizado() TO authenticated;

ALTER TABLE public.mc_viabilidade_analises ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mc_viabilidade_historico ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS mc_viabilidade_analises_select ON public.mc_viabilidade_analises;
CREATE POLICY mc_viabilidade_analises_select ON public.mc_viabilidade_analises
 FOR SELECT TO authenticated USING(public.mc_viabilidade_autorizado());
DROP POLICY IF EXISTS mc_viabilidade_hist_select ON public.mc_viabilidade_historico;
CREATE POLICY mc_viabilidade_hist_select ON public.mc_viabilidade_historico
 FOR SELECT TO authenticated USING(public.mc_viabilidade_autorizado());
-- Escritas somente por RPC validada, nao pelas tabelas.
REVOKE INSERT,UPDATE,DELETE ON public.mc_viabilidade_analises FROM PUBLIC,anon,authenticated;
REVOKE INSERT,UPDATE,DELETE ON public.mc_viabilidade_historico FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.mc_viabilidade_analises TO authenticated;
GRANT SELECT ON public.mc_viabilidade_historico TO authenticated;

-- Fonte completa da Ficha independente das politicas comerciais de carteira.
-- Nao altera nenhuma Ficha e nao inclui dados financeiros de outros modulos.
CREATE OR REPLACE FUNCTION public.mc_viabilidade_listar_fichas(p_busca text DEFAULT '',p_limite integer DEFAULT 100)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_busca text:=left(btrim(coalesce(p_busca,'')),100);
 v_limite integer:=least(greatest(coalesce(p_limite,100),1),300);
 v_saida jsonb;
BEGIN
 IF NOT public.mc_viabilidade_autorizado() THEN RAISE EXCEPTION 'Acesso restrito ao Financeiro e Administrador'; END IF;
 SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.created_at DESC),'[]'::jsonb)
 INTO v_saida FROM (
  SELECT f.id,f.created_at,f.razao_social,f.nome_fantasia,f.cnpj_cpf,
   f.preco_kg,f.consumo_previsto,f.faturamento_previsto,
   f.verba_introducao,f.duracao_verba,f.bonificacao_percentual,
   f.bonificacao_periodicidade,f.bonificacao_modalidade,
   f.prazo_pagamento,f.equipamento_condicao,f.precisa_equipamento,
   f.equipamentos_quantidades,f.forno_tipo,f.forno_quantidade,
   f.freezer_tipos,f.armario_tipo,f.camara_climatica,
   f.esteiras_quantidade,f.assadeiras_quantidade,f.tecnico_panificacao,
   f.tecnico_periodicidade,f.senioridade_tecnico,
   f.vendedor_id
  FROM public.fichas_clientes f
  WHERE v_busca='' OR
    f.razao_social ILIKE '%'||v_busca||'%' OR
    f.nome_fantasia ILIKE '%'||v_busca||'%' OR
    f.cnpj_cpf::text ILIKE '%'||v_busca||'%'
  ORDER BY f.created_at DESC LIMIT v_limite
 ) x;
 RETURN v_saida;
END;
$$;
REVOKE ALL ON FUNCTION public.mc_viabilidade_listar_fichas(text,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.mc_viabilidade_listar_fichas(text,integer) TO authenticated;

-- Grava snapshot imutavel no historico a cada alteracao da analise.
-- O parecer e uma opiniao gerencial, NAO altera a aprovacao da Ficha.
CREATE OR REPLACE FUNCTION public.mc_viabilidade_salvar(
 p_ficha_id uuid,p_parametros jsonb,p_dados_ficha jsonb,
 p_resultados jsonb,p_situacao text DEFAULT 'rascunho',p_parecer text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_reg public.mc_viabilidade_analises%ROWTYPE;
 v_versao integer;v_usuario uuid:=auth.uid();
BEGIN
 IF NOT public.mc_viabilidade_autorizado() THEN RAISE EXCEPTION 'Acesso restrito ao Financeiro e Administrador'; END IF;
 IF p_ficha_id IS NULL OR NOT EXISTS(SELECT 1 FROM public.fichas_clientes WHERE id=p_ficha_id)
 THEN RAISE EXCEPTION 'Ficha inexistente'; END IF;
 IF p_situacao NOT IN ('rascunho','em_analise','favoravel','desfavoravel','condicionada')
 THEN RAISE EXCEPTION 'Situação inválida'; END IF;
 IF jsonb_typeof(p_parametros) IS DISTINCT FROM 'object'
    OR jsonb_typeof(p_dados_ficha) IS DISTINCT FROM 'object'
    OR jsonb_typeof(p_resultados) IS DISTINCT FROM 'object'
 THEN RAISE EXCEPTION 'Dados da analise devem ser objetos JSON'; END IF;
 IF length(coalesce(p_parecer,''))>5000 THEN RAISE EXCEPTION 'Parecer muito extenso'; END IF;

 INSERT INTO public.mc_viabilidade_analises(ficha_id,atualizado_por)
 VALUES(p_ficha_id,v_usuario) ON CONFLICT(ficha_id) DO NOTHING;
 SELECT * INTO v_reg FROM public.mc_viabilidade_analises
 WHERE ficha_id=p_ficha_id FOR UPDATE;
 UPDATE public.mc_viabilidade_analises SET parametros=p_parametros,
   dados_ficha=p_dados_ficha,resultados=p_resultados,situacao=p_situacao,
   parecer=nullif(trim(p_parecer),''),atualizado_por=v_usuario,atualizado_em=now()
 WHERE id=v_reg.id;
 SELECT coalesce(max(versao),0)+1 INTO v_versao
 FROM public.mc_viabilidade_historico WHERE analise_id=v_reg.id;
 INSERT INTO public.mc_viabilidade_historico
 (analise_id,versao,parametros,dados_ficha,resultados,situacao,parecer,registrado_por)
 VALUES(v_reg.id,v_versao,p_parametros,p_dados_ficha,p_resultados,p_situacao,
    nullif(trim(p_parecer),''),v_usuario);
 RETURN jsonb_build_object('analise_id',v_reg.id,'versao',v_versao,'situacao',p_situacao);
END;
$$;
REVOKE ALL ON FUNCTION public.mc_viabilidade_salvar(uuid,jsonb,jsonb,jsonb,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.mc_viabilidade_salvar(uuid,jsonb,jsonb,jsonb,text,text) TO authenticated;
COMMIT;

-- Teste de estrutura, sem modificar registros:
SELECT proname,prosecdef FROM pg_proc
 WHERE proname IN ('mc_viabilidade_listar_fichas','mc_viabilidade_salvar','mc_viabilidade_autorizado')
 ORDER BY proname;
