BEGIN;

DO $migration$
DECLARE
  v_coluna smallint;
  v_tipo record;
  v_check record;
  v_ajuste record;
  v_definicao text;
  v_funcao regprocedure;
BEGIN
  SELECT a.attnum INTO STRICT v_coluna FROM pg_attribute a
  WHERE a.attrelid='public.fichas_clientes'::regclass AND a.attname='risco_credito' AND NOT a.attisdropped;

  SELECT n.nspname,t.typname,t.typtype INTO STRICT v_tipo
  FROM pg_attribute a JOIN pg_type t ON t.oid=a.atttypid JOIN pg_namespace n ON n.oid=t.typnamespace
  WHERE a.attrelid='public.fichas_clientes'::regclass AND a.attnum=v_coluna;
  IF v_tipo.typtype='e' THEN
    EXECUTE format('ALTER TYPE %I.%I ADD VALUE IF NOT EXISTS %L',v_tipo.nspname,v_tipo.typname,'E');
  END IF;

  -- Em instalações que usam texto, mantém a regra anterior e inclui E.
  FOR v_check IN
    SELECT c.conname,c.convalidated,pg_get_expr(c.conbin,c.conrelid) AS regra
    FROM pg_constraint c WHERE c.conrelid='public.fichas_clientes'::regclass
      AND c.contype='c' AND c.conkey=ARRAY[v_coluna]
  LOOP
    IF strpos(v_check.regra,'''A''')>0 AND strpos(v_check.regra,'''B''')>0
      AND strpos(v_check.regra,'''C''')>0 AND strpos(v_check.regra,'''D''')>0
      AND strpos(v_check.regra,'''E''')=0 THEN
      EXECUTE format('ALTER TABLE public.fichas_clientes DROP CONSTRAINT %I',v_check.conname);
      EXECUTE format(
        'ALTER TABLE public.fichas_clientes ADD CONSTRAINT %I CHECK ((%s) OR risco_credito::text = %L)%s',
        v_check.conname,v_check.regra,'E',CASE WHEN v_check.convalidated THEN '' ELSE ' NOT VALID' END);
    END IF;
  END LOOP;

  -- Altera só os trechos pertinentes das rotinas instaladas. Preserva o
  -- encaminhamento de crédito e os dados operacionais da fila administrativa.
  FOR v_ajuste IN SELECT * FROM (VALUES
    ('public.mc_registrar_analise_credito_ficha(uuid,numeric,text,text,text,boolean)',
      $old$p_risco NOT IN ('A','B','C','D')$old$,$new$p_risco NOT IN ('A','B','C','D','E')$new$),
    ('public.mc_validar_ordem_decisao_ficha()',
      $old$f.risco_credito::text IN ('A','B','C','D')$old$,$new$f.risco_credito::text IN ('A','B','C','D','E')$new$),
    ('public.mc_listar_solicitacoes_adm_vendas()',
      $old$'razao_social',c.razao_social,'cnpj_cpf',c.cnpj_cpf$old$,
      $new$'razao_social',c.razao_social,'nome_fantasia',c.nome_fantasia,'cnpj_cpf',c.cnpj_cpf$new$)
  ) AS ajustes(assinatura,anterior,novo)
  LOOP
    v_funcao:=to_regprocedure(v_ajuste.assinatura);
    IF v_funcao IS NULL THEN
      RAISE EXCEPTION 'Rotina necessária não encontrada: %',v_ajuste.assinatura;
    END IF;
    v_definicao:=pg_get_functiondef(v_funcao);
    IF strpos(v_definicao,v_ajuste.novo)>0 THEN CONTINUE; END IF;
    IF strpos(v_definicao,v_ajuste.anterior)=0 THEN
      RAISE EXCEPTION 'Versão da rotina não reconhecida para ajuste: %',v_ajuste.assinatura;
    END IF;
    EXECUTE replace(v_definicao,v_ajuste.anterior,v_ajuste.novo);
  END LOOP;
END;
$migration$;

NOTIFY pgrst,'reload schema';
COMMIT;
