-- Meu Cliente v103 — remover avanço duplicado de solicitações
-- Aplicar DEPOIS da v102, com backup, no SQL Editor do Supabase.
-- Falha/ROLLBACK se a RPC v102 não estiver instalada ou os gatilhos diferirem
-- do diagnóstico. NÃO altera aprovações já registradas, filas ou solicitações.
-- As decisões novas continuam a passar exclusivamente pela RPC
-- mc_decidir_solicitacao_workflow, usada pelo index.html v100+.
BEGIN;

DO $validacao$
DECLARE
  v_def text;
  v_legado1 text;
  v_legado2 text;
  v_trg1 text;
  v_trg2 text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public'
    AND p.proname='mc_decidir_solicitacao_workflow'
    AND pg_get_function_identity_arguments(p.oid)
      = 'p_aprovacao_id uuid, p_status text, p_observacao text';
  IF v_def IS NULL THEN
    RAISE EXCEPTION 'Função mc_decidir_solicitacao_workflow(uuid,text,text) inexistente';
  END IF;

  -- A v102 trata a próxima etapa já pendente, mesmo se disparos antigos
  -- a tiverem promovido. Não desativar triggers sem esta versão funcional.
  IF position('ordem>v_ap.ordem' IN regexp_replace(v_def,'[[:space:]]+','','g'))=0
     OR position('statusIN(''pendente'',''aguardando'')' IN regexp_replace(v_def,'[[:space:]]+','','g'))=0 THEN
    RAISE EXCEPTION 'Instale primeiro a migração v102 da decisão transacional';
  END IF;

  SELECT pg_get_functiondef('public.avancar_fila_solicitacao()'::regprocedure)
    INTO v_legado1;
  SELECT pg_get_functiondef('public.v45_avancar_solicitacao()'::regprocedure)
    INTO v_legado2;
  SELECT pg_get_triggerdef(t.oid) INTO v_trg1
  FROM pg_trigger t
  WHERE t.tgrelid='public.solicitacao_aprovacoes'::regclass
    AND t.tgname='trg_avancar_fila_solicitacao' AND NOT t.tgisinternal;
  SELECT pg_get_triggerdef(t.oid) INTO v_trg2
  FROM pg_trigger t
  WHERE t.tgrelid='public.solicitacao_aprovacoes'::regclass
    AND t.tgname='zzz_v45_avancar_solicitacao' AND NOT t.tgisinternal;

  IF v_trg1 IS NULL OR v_trg2 IS NULL THEN
    RAISE EXCEPTION 'Gatilhos legados não correspondem ao diagnóstico. Revisar antes de remover.';
  END IF;
  IF position('avancar_fila_solicitacao()' IN v_trg1)=0
     OR position('v45_avancar_solicitacao()' IN v_trg2)=0
     OR position('ordem > new.ordem' IN lower(v_legado1))=0
     OR position('status_fluxo=''reprovada''' IN replace(lower(v_legado2),' ',''))=0 THEN
    RAISE EXCEPTION 'Definição dos gatilhos/funções legados diverge do diagnóstico';
  END IF;
END;
$validacao$;

-- Elimina apenas os dois disparadores AUTOMÁTICOS e conflitantes.
-- Funções legadas não são apagadas (reversão/auditoria).
DROP TRIGGER trg_avancar_fila_solicitacao ON public.solicitacao_aprovacoes;
DROP TRIGGER zzz_v45_avancar_solicitacao ON public.solicitacao_aprovacoes;

-- Os demais gatilhos permanecem: trava de decisão direta, troca e retirada.
COMMIT;

-- Auditoria após execução:
SELECT t.tgname, pg_get_triggerdef(t.oid) AS definicao
FROM pg_trigger t
WHERE t.tgrelid='public.solicitacao_aprovacoes'::regclass
  AND NOT t.tgisinternal
ORDER BY t.tgname;

-- Inspeção BON-000019: deve continuar aberta e Financeiro pendente
-- até que o próprio Financeiro decida pela interface.
SELECT s.codigo,s.status_fluxo,a.ordem,a.etapa,a.status,a.aprovador_id,a.decidido_em
FROM public.solicitacoes s
JOIN public.solicitacao_aprovacoes a ON a.solicitacao_id=s.id
WHERE s.codigo='BON-000019'
ORDER BY a.ordem,a.etapa;

-- Reversão de emergência, SE necessária, não executar normalmente:
-- CREATE TRIGGER trg_avancar_fila_solicitacao
--   AFTER UPDATE ON public.solicitacao_aprovacoes
--   FOR EACH ROW EXECUTE FUNCTION public.avancar_fila_solicitacao();
-- CREATE TRIGGER zzz_v45_avancar_solicitacao
--   AFTER UPDATE OF status ON public.solicitacao_aprovacoes
--   FOR EACH ROW EXECUTE FUNCTION public.v45_avancar_solicitacao();
