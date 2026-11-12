-- Meu Cliente | v101 | Regularização pontual de BON-000017, BON-000018, BON-000019
-- Motivo: fluxos antigos anteriores à aprovação compartilhada Coord./Gestão Adm.
-- EXIGÊNCIA: executar após a v99 e a v100 no Supabase SQL Editor, com backup.
-- Preserva decisões, quem decidiu, horários e observações. Não vincula pedidos.
-- Não altera outras solicitações. Se o estado divergir do diagnóstico, aborta a transação.
BEGIN;

DO $repair$
DECLARE
  r record;
  v_id uuid;
  v_status text;
  v_fin text;
  v_coord text;
  v_gestao text;
  v_dir text;
  v_ord_dir integer;
  v_qtd_dir integer;
  v_qtd_fin integer;
  v_qtd_coord integer;
  v_qtd_gestao integer;
  v_qtd_sup integer;
  v_outras integer;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('BON-000017', 'reprovado', 'aprovado', 'aprovado', 'pendente'),
    ('BON-000018', 'reprovado', 'aprovado', 'pendente', NULL::text),
    ('BON-000019', 'pendente',  'aprovado', 'aprovado', NULL::text)
  ) AS t(codigo,financeiro,coordenador,gestao,diretoria)
  LOOP
    SELECT id,status_fluxo INTO v_id,v_status
      FROM public.solicitacoes
     WHERE codigo=r.codigo AND categoria='bonificacao'
     FOR UPDATE;
    IF v_id IS NULL THEN
      RAISE EXCEPTION 'Solicitação % não encontrada',r.codigo;
    END IF;
    IF v_status IS DISTINCT FROM 'aberta' THEN
      RAISE EXCEPTION '%: status atual %, esperado aberta. Sem alterações',r.codigo,v_status;
    END IF;

    SELECT count(*) FILTER (WHERE etapa='supervisor'),
           count(*) FILTER (WHERE etapa='coordenador'),
           count(*) FILTER (WHERE etapa='gestao_adm_vendas'),
           count(*) FILTER (WHERE etapa='financeiro'),
           count(*) FILTER (WHERE etapa='diretoria'),
           count(*) FILTER (WHERE etapa NOT IN
             ('supervisor','coordenador','gestao_adm_vendas','financeiro','diretoria'))
    INTO v_qtd_sup,v_qtd_coord,v_qtd_gestao,v_qtd_fin,v_qtd_dir,v_outras
    FROM public.solicitacao_aprovacoes
    WHERE solicitacao_id=v_id;

    IF v_qtd_sup<>1 OR v_qtd_coord<>1 OR v_qtd_gestao<>1 OR v_qtd_fin<>1
       OR v_qtd_dir>1 OR v_outras<>0 THEN
       RAISE EXCEPTION '%: fila inesperada. Revisar antes de executar',r.codigo;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public.solicitacao_aprovacoes
      WHERE solicitacao_id=v_id AND etapa='supervisor' AND status='aprovado'
        AND aprovador_id IS NOT NULL AND decidido_em IS NOT NULL) THEN
      RAISE EXCEPTION '%: aprovação do Supervisor não confirmada',r.codigo;
    END IF;

    SELECT status INTO v_coord FROM public.solicitacao_aprovacoes
      WHERE solicitacao_id=v_id AND etapa='coordenador';
    SELECT status INTO v_gestao FROM public.solicitacao_aprovacoes
      WHERE solicitacao_id=v_id AND etapa='gestao_adm_vendas';
    SELECT status INTO v_fin FROM public.solicitacao_aprovacoes
      WHERE solicitacao_id=v_id AND etapa='financeiro';
    SELECT status INTO v_dir FROM public.solicitacao_aprovacoes
      WHERE solicitacao_id=v_id AND etapa='diretoria';

    IF v_coord IS DISTINCT FROM r.coordenador
       OR v_gestao IS DISTINCT FROM r.gestao
       OR v_fin IS DISTINCT FROM r.financeiro
       OR v_dir IS DISTINCT FROM r.diretoria THEN
      RAISE EXCEPTION '%: fila mudou desde o diagnóstico (coord %, gestão %, financeiro %, diretoria %)',
        r.codigo,v_coord,v_gestao,v_fin,v_dir;
    END IF;

    -- A BON-000018 já teve decisão do Coordenador e do Financeiro:
    -- somente a pendência redundante de Gestão Adm. é dispensada.
    -- Não inventa aprovação nem registra aprovador/decidido_em.
    IF r.codigo='BON-000018' THEN
      UPDATE public.solicitacao_aprovacoes
         SET status='nao_aplica'
       WHERE solicitacao_id=v_id AND etapa='gestao_adm_vendas'
         AND status='pendente' AND aprovador_id IS NULL AND decidido_em IS NULL;
      IF NOT FOUND THEN
        RAISE EXCEPTION '%: a pendência da Gestão possui decisão/histórico; revisar manualmente',r.codigo;
      END IF;
    END IF;

    -- A BON-000017 já tem Diretoria pendente e não precisa de recriação.
    -- Nas demais, cria Diretoria como última etapa do histórico.
    IF v_qtd_dir=0 THEN
      SELECT coalesce(max(ordem),0)+1 INTO v_ord_dir
        FROM public.solicitacao_aprovacoes WHERE solicitacao_id=v_id;
      INSERT INTO public.solicitacao_aprovacoes
        (solicitacao_id,etapa,ordem,status)
      VALUES
        (v_id,'diretoria',v_ord_dir,
         CASE WHEN r.codigo='BON-000018' THEN 'pendente' ELSE 'aguardando' END);
    END IF;

    RAISE NOTICE '% regularizada: Financeiro %, Diretoria %',r.codigo,v_fin,
      CASE WHEN r.codigo='BON-000019' THEN 'aguardando' ELSE 'pendente' END;
  END LOOP;
END;
$repair$;

COMMIT;

-- Conferência, somente leitura:
SELECT s.codigo,s.status_fluxo,a.ordem,a.etapa,a.status,
       a.aprovador_id,a.decidido_em,a.observacao
FROM public.solicitacoes s
JOIN public.solicitacao_aprovacoes a ON a.solicitacao_id=s.id
WHERE s.codigo IN ('BON-000017','BON-000018','BON-000019')
ORDER BY s.codigo,a.ordem,a.etapa;
