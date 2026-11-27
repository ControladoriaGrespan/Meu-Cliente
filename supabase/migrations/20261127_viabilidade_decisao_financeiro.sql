-- Meu Cliente — Grespan
-- Análise de Viabilidade Financeira: a lista passa a informar a decisão que o Financeiro
-- já tomou na Ficha (campo decisao_financeiro), para a tela tirar da fila "Pendentes"
-- as fichas aprovadas ou reprovadas mesmo sem parecer registrado na análise.
--
--   decisao_financeiro = 'ajuste'     etapa do Financeiro devolveu a ficha para ajuste
--                        'reprovado'  Análise de Crédito ou Financeiro reprovou
--                        'aprovado'   etapa Financeiro aprovada
--                        null         ainda sem decisão
--
-- Só acrescenta um campo à resposta da função; o restante é a definição que já estava
-- no banco. Idempotente. Não altera dados, tabelas nem regras de acesso.

begin;

create or replace function public.mc_viabilidade_listar_fichas(p_busca text default ''::text, p_limite integer default 100)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public', 'pg_temp'
as $function$
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
   f.vendedor_id,
   (SELECT CASE
      WHEN bool_or(fa.status='reprovado' AND fa.ajuste_solicitado_em IS NOT NULL) THEN 'ajuste'
      WHEN bool_or(fa.status='reprovado') THEN 'reprovado'
      WHEN bool_or(fa.etapa='financeiro' AND fa.status='aprovado') THEN 'aprovado'
    END
    FROM public.ficha_aprovacoes fa
    WHERE fa.ficha_id=f.id AND fa.etapa IN ('analise_credito','financeiro')) AS decisao_financeiro
  FROM public.fichas_clientes f
  WHERE (
    EXISTS (SELECT 1 FROM public.ficha_aprovacoes fa
      WHERE fa.ficha_id=f.id AND fa.etapa='financeiro' AND fa.status='pendente')
    OR EXISTS (SELECT 1 FROM public.mc_viabilidade_analises ma
      WHERE ma.ficha_id=f.id)
  ) AND (
    v_busca='' OR
    f.razao_social ILIKE '%'||v_busca||'%' OR
    f.nome_fantasia ILIKE '%'||v_busca||'%' OR
    f.cnpj_cpf::text ILIKE '%'||v_busca||'%'
  )
  ORDER BY f.created_at DESC LIMIT v_limite
 ) x;
 RETURN v_saida;
END;
$function$;

commit;

notify pgrst, 'reload schema';
