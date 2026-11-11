-- Meu Cliente — normalização de retirada e correção do fluxo v45
-- Baseado nas funções e triggers inspecionados em 11/11/2026.
-- Executar após backup no Supabase SQL Editor. Não reprocessa solicitações históricas.
BEGIN;

-- Normaliza somente dados de equipamentos, antes do CHECK de justificativa.
CREATE OR REPLACE FUNCTION public.mc_normalizar_equipamento_solicitacao()
RETURNS trigger LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $mc$
DECLARE v_tipo text; v_just text;
BEGIN
  IF NEW.categoria IS DISTINCT FROM 'equipamento' THEN RETURN NEW; END IF;
  v_tipo := lower(btrim(coalesce(NEW.tipo, '')));
  IF v_tipo IN ('retirada','troca','aumento','manutencao') THEN
    NEW.tipo := v_tipo;
  END IF;
  IF v_tipo IN ('retirada','troca') AND NEW.justificativa IS NOT NULL THEN
    v_just := btrim(NEW.justificativa);
    -- Normalização conservadora, sem trocar um motivo por outro.
    IF lower(v_just)='baixo consumo' THEN NEW.justificativa:='Baixo consumo';
    ELSIF lower(v_just)='encerramento do contrato' THEN NEW.justificativa:='Encerramento do contrato';
    ELSIF lower(v_just)='relacionamento' THEN NEW.justificativa:='Relacionamento';
    ELSIF lower(v_just)='equipamento antigo' THEN NEW.justificativa:='Equipamento Antigo';
    ELSIF lower(v_just)='equipamento danificado' THEN NEW.justificativa:='Equipamento Danificado';
    ELSE NEW.justificativa:=v_just;
    END IF;
  END IF;
  RETURN NEW;
END;
$mc$;

DROP TRIGGER IF EXISTS aa_mc_normalizar_equipamento_solicitacao ON public.solicitacoes;
CREATE TRIGGER aa_mc_normalizar_equipamento_solicitacao
BEFORE INSERT OR UPDATE OF tipo, justificativa ON public.solicitacoes
FOR EACH ROW EXECUTE FUNCTION public.mc_normalizar_equipamento_solicitacao();

-- Substitui apenas a implementação do construtor v45, que já é chamado
-- pelo trigger existente zzz_v45_fluxo_solicitacao.
CREATE OR REPLACE FUNCTION public.v45_montar_fluxo_solicitacao_core(p_sol uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp
AS $core$
DECLARE
  s public.solicitacoes%ROWTYPE;
  v_vendedor uuid; v_sup uuid; v_coord uuid;
  v_tem_gestao boolean;
  v_ord integer:=0;
BEGIN
  SELECT * INTO s FROM public.solicitacoes WHERE id=p_sol;
  IF NOT FOUND THEN RAISE EXCEPTION 'Solicitação % inexistente',p_sol; END IF;
  SELECT c.vendedor_id INTO v_vendedor FROM public.clientes c WHERE c.id=s.cliente_id;
  SELECT u.supervisor_id,u.coordenador_id INTO v_sup,v_coord FROM public.usuarios u WHERE u.id=v_vendedor;

  IF v_sup IS NOT NULL THEN
    SELECT COALESCE(u.coordenador_id,v_coord) INTO v_coord
    FROM public.usuarios u WHERE u.id=v_sup;
  END IF;
  SELECT EXISTS (
    SELECT 1 FROM public.usuarios u
    WHERE u.papel::text='gestao_adm_vendas' AND COALESCE(u.ativo,true)
  ) INTO v_tem_gestao;

  IF s.tipo <> 'manutencao' THEN
    IF v_sup IS NOT NULL THEN
      v_ord:=v_ord+1;
      INSERT INTO public.solicitacao_aprovacoes(solicitacao_id,etapa,ordem,status,responsavel_id)
      VALUES(p_sol,'supervisor',v_ord,'aguardando',v_sup);
    END IF;
    IF v_coord IS NOT NULL THEN
      v_ord:=v_ord+1;
      INSERT INTO public.solicitacao_aprovacoes(solicitacao_id,etapa,ordem,status,responsavel_id)
      VALUES(p_sol,'coordenador',v_ord,'aguardando',v_coord);
    END IF;
  END IF;

  IF s.categoria='amostra' THEN
    IF v_tem_gestao THEN
      v_ord:=v_ord+1;
      INSERT INTO public.solicitacao_aprovacoes(solicitacao_id,etapa,ordem,status)
      VALUES(p_sol,'gestao_adm_vendas',v_ord,'aguardando');
    END IF;

  ELSIF s.categoria='bonificacao' THEN
    IF v_tem_gestao THEN
      v_ord:=v_ord+1;
      INSERT INTO public.solicitacao_aprovacoes(solicitacao_id,etapa,ordem,status)
      VALUES(p_sol,'gestao_adm_vendas',v_ord,'aguardando');
    END IF;
    v_ord:=v_ord+1;
    INSERT INTO public.solicitacao_aprovacoes(solicitacao_id,etapa,ordem,status)
    VALUES(p_sol,'financeiro',v_ord,'aguardando');
    v_ord:=v_ord+1;
    INSERT INTO public.solicitacao_aprovacoes(solicitacao_id,etapa,ordem,status)
    VALUES(p_sol,'diretoria',v_ord,'aguardando');

  ELSIF s.tipo='manutencao' THEN
    v_ord:=v_ord+1;
    INSERT INTO public.solicitacao_aprovacoes(solicitacao_id,etapa,ordem,status)
    VALUES(p_sol,'manutencao',v_ord,'aguardando');

  ELSIF s.tipo='troca' AND s.justificativa='Relacionamento' THEN
    IF v_tem_gestao THEN
      v_ord:=v_ord+1;
      INSERT INTO public.solicitacao_aprovacoes(solicitacao_id,etapa,ordem,status)
      VALUES(p_sol,'gestao_adm_vendas',v_ord,'aguardando');
    END IF;
    v_ord:=v_ord+1;
    INSERT INTO public.solicitacao_aprovacoes(solicitacao_id,etapa,ordem,status)
    VALUES(p_sol,'diretoria',v_ord,'aguardando');

  ELSIF s.tipo='troca' AND s.justificativa IN ('Equipamento Danificado','Equipamento Antigo') THEN
    IF v_tem_gestao THEN
      v_ord:=v_ord+1;
      INSERT INTO public.solicitacao_aprovacoes(solicitacao_id,etapa,ordem,status)
      VALUES(p_sol,'gestao_adm_vendas',v_ord,'aguardando');
    END IF;
    v_ord:=v_ord+1;
    INSERT INTO public.solicitacao_aprovacoes(solicitacao_id,etapa,ordem,status)
    VALUES(p_sol,'manutencao',v_ord,'aguardando');
    v_ord:=v_ord+1;
    INSERT INTO public.solicitacao_aprovacoes(solicitacao_id,etapa,ordem,status)
    VALUES(p_sol,'diretoria',v_ord,'aguardando');

  ELSIF s.tipo='retirada' THEN
    -- A retirada não é uma troca; leva o motivo informado ao workflow,
    -- com análise comercial, encaminhamento e autorização final.
    IF v_tem_gestao THEN
      v_ord:=v_ord+1;
      INSERT INTO public.solicitacao_aprovacoes(solicitacao_id,etapa,ordem,status)
      VALUES(p_sol,'gestao_adm_vendas',v_ord,'aguardando');
    END IF;
    v_ord:=v_ord+1;
    INSERT INTO public.solicitacao_aprovacoes(solicitacao_id,etapa,ordem,status)
    VALUES(p_sol,'diretoria',v_ord,'aguardando');

  ELSE
    IF v_tem_gestao THEN
      v_ord:=v_ord+1;
      INSERT INTO public.solicitacao_aprovacoes(solicitacao_id,etapa,ordem,status)
      VALUES(p_sol,'gestao_adm_vendas',v_ord,'aguardando');
    END IF;
    v_ord:=v_ord+1;
    INSERT INTO public.solicitacao_aprovacoes(solicitacao_id,etapa,ordem,status)
    VALUES(p_sol,'diretoria',v_ord,'aguardando');
  END IF;

  IF v_ord=0 THEN
    UPDATE public.solicitacoes SET status_fluxo='aprovada' WHERE id=p_sol;
  ELSE
    UPDATE public.solicitacao_aprovacoes SET status='pendente'
    WHERE id=(SELECT id FROM public.solicitacao_aprovacoes
              WHERE solicitacao_id=p_sol ORDER BY ordem LIMIT 1);
  END IF;
END;
$core$;

-- Os gatilhos legados criam a fila e depois a apagam; deixe um único construtor.
-- Apenas remove os gatilhos redundantes; mantém as funções disponíveis.
DROP TRIGGER IF EXISTS trg_criar_fila_solicitacao ON public.solicitacoes;
DROP TRIGGER IF EXISTS zz_mc_bonificacao_diretoria ON public.solicitacoes;
-- Preserva zzz_v45_fluxo_solicitacao e o bloqueio de bonificações.

COMMIT;

-- Conferência somente leitura:
SELECT t.tgname, pg_get_triggerdef(t.oid) AS definicao
FROM pg_trigger t
WHERE t.tgrelid='public.solicitacoes'::regclass AND NOT t.tgisinternal
ORDER BY t.tgname;
