BEGIN;

ALTER TABLE public.pedido_itens
  ADD COLUMN IF NOT EXISTS solicitacao_bonificacao_id uuid REFERENCES public.solicitacoes(id),
  ADD COLUMN IF NOT EXISTS bonificacao_apropriada_por uuid REFERENCES public.usuarios(id),
  ADD COLUMN IF NOT EXISTS bonificacao_apropriada_em timestamptz;

CREATE INDEX IF NOT EXISTS pedido_itens_solicitacao_bonificacao_idx
  ON public.pedido_itens(solicitacao_bonificacao_id, produto_id)
  WHERE solicitacao_bonificacao_id IS NOT NULL;

-- As quantidades apropriadas são as próprias linhas de operação 04 do PV.
CREATE OR REPLACE FUNCTION public.mc_saldo_itens_bonificacao(p_solicitacao_id uuid)
RETURNS TABLE (produto_id uuid, aprovada numeric, saldo numeric, ordem integer)
LANGUAGE sql
SET search_path = public, pg_temp
AS $$
  WITH aprovados AS (
    SELECT i.produto_id, i.quantidade, i.ordem
    FROM public.solicitacao_bonificacao_itens i WHERE i.solicitacao_id = p_solicitacao_id
    UNION ALL
    SELECT s.produto_id, s.quantidade, 1
    FROM public.solicitacoes s
    WHERE s.id = p_solicitacao_id AND s.produto_id IS NOT NULL AND s.quantidade > 0
      AND NOT EXISTS (SELECT 1 FROM public.solicitacao_bonificacao_itens i WHERE i.solicitacao_id = s.id)
  ), utilizados AS (
    SELECT i.produto_id, sum(i.quantidade) AS quantidade
    FROM public.pedido_itens i WHERE i.solicitacao_bonificacao_id = p_solicitacao_id
    GROUP BY i.produto_id
  )
  SELECT a.produto_id, a.quantidade, a.quantidade - coalesce(u.quantidade, 0), a.ordem
  FROM aprovados a LEFT JOIN utilizados u USING (produto_id);
$$;

CREATE OR REPLACE FUNCTION public.mc_validar_item_bonificacao_pv()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_s public.solicitacoes%ROWTYPE;
  v_saldo numeric;
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.solicitacao_bonificacao_id IS NOT NULL THEN
      RAISE EXCEPTION 'O item já foi apropriado em uma solicitação de bonificação.';
    END IF;
    RETURN OLD;
  END IF;
  IF TG_OP = 'UPDATE' THEN
    IF (OLD.solicitacao_bonificacao_id IS NOT NULL OR NEW.solicitacao_bonificacao_id IS NOT NULL)
       AND ROW(NEW.solicitacao_bonificacao_id, NEW.pedido_id, NEW.produto_id, NEW.quantidade,
               NEW.valor_unitario, NEW.tipo_item, NEW.codigo_operacao,
               NEW.bonificacao_apropriada_por, NEW.bonificacao_apropriada_em)
           IS DISTINCT FROM
           ROW(OLD.solicitacao_bonificacao_id, OLD.pedido_id, OLD.produto_id, OLD.quantidade,
               OLD.valor_unitario, OLD.tipo_item, OLD.codigo_operacao,
               OLD.bonificacao_apropriada_por, OLD.bonificacao_apropriada_em) THEN
      RAISE EXCEPTION 'O item já apropriado só permite alteração da NF.';
    END IF;
    RETURN NEW;
  END IF;
  IF NEW.solicitacao_bonificacao_id IS NULL THEN RETURN NEW; END IF;

  IF NOT EXISTS (SELECT 1 FROM public.usuarios u WHERE u.id = auth.uid() AND u.ativo
    AND u.papel::text IN ('adm_vendas','gestao_adm_vendas','admin')) THEN
    RAISE EXCEPTION 'Apropriação restrita à Administração de Vendas.';
  END IF;

  SELECT * INTO v_s FROM public.solicitacoes
  WHERE id = NEW.solicitacao_bonificacao_id FOR NO KEY UPDATE;
  IF NOT FOUND OR v_s.categoria IS DISTINCT FROM 'bonificacao'
     OR v_s.status_fluxo IS DISTINCT FROM 'aprovada' OR v_s.pedido_id IS NOT NULL THEN
    RAISE EXCEPTION 'A solicitação de bonificação não tem saldo disponível para este pedido.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.pedidos p
    WHERE p.id = NEW.pedido_id AND p.cliente_id = v_s.cliente_id AND p.codigo_operacao = '01') THEN
    RAISE EXCEPTION 'A bonificação exige um pedido de venda do mesmo cliente.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.solicitacao_aprovacoes a
    WHERE a.solicitacao_id = v_s.id AND a.etapa = 'diretoria' AND a.status = 'aprovado')
    OR NOT EXISTS (SELECT 1 FROM public.solicitacao_aprovacoes a
    WHERE a.solicitacao_id = v_s.id AND a.etapa = 'financeiro' AND a.status IN ('aprovado','reprovado'))
    OR EXISTS (SELECT 1 FROM public.solicitacao_aprovacoes a WHERE a.solicitacao_id = v_s.id
      AND NOT (a.status IN ('aprovado','nao_aplica') OR (a.etapa = 'financeiro' AND a.status = 'reprovado'))) THEN
    RAISE EXCEPTION 'A bonificação exige parecer Financeiro e aprovação final da Diretoria.';
  END IF;
  SELECT saldo INTO v_saldo FROM public.mc_saldo_itens_bonificacao(v_s.id)
    WHERE produto_id = NEW.produto_id;
  IF NEW.tipo_item IS DISTINCT FROM 'bonificacao' OR NEW.codigo_operacao IS DISTINCT FROM '04'
    OR NEW.valor_unitario IS DISTINCT FROM 0 OR NOT coalesce(NEW.quantidade > 0
    AND NEW.quantidade = round(NEW.quantidade, 3) AND NEW.quantidade <= v_saldo, false) THEN
    RAISE EXCEPTION 'Produto ou quantidade acima do saldo aprovado da bonificação %.', v_s.codigo;
  END IF;
  NEW.bonificacao_apropriada_por := auth.uid();
  NEW.bonificacao_apropriada_em := now();
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.mc_finalizar_bonificacao_pv()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.mc_saldo_itens_bonificacao(NEW.solicitacao_bonificacao_id) WHERE saldo > 0) THEN
    RETURN NULL;
  END IF;

  UPDATE public.solicitacoes SET status_fluxo = 'concluida', pedido_id = NEW.pedido_id,
    vinculada_por = auth.uid(), vinculada_em = now()
  WHERE id = NEW.solicitacao_bonificacao_id AND status_fluxo = 'aprovada';

  IF FOUND THEN
    INSERT INTO public.solicitacao_conclusoes_adm (solicitacao_id,pedido_id,concluido_por)
    VALUES (NEW.solicitacao_bonificacao_id,NEW.pedido_id,auth.uid());
  END IF;
  RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public.mc_proteger_saldo_bonificacao()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF (NEW.status_fluxo IS DISTINCT FROM 'aprovada' OR NEW.pedido_id IS NOT NULL)
    AND EXISTS (SELECT 1 FROM public.pedido_itens WHERE solicitacao_bonificacao_id = OLD.id)
    AND EXISTS (SELECT 1 FROM public.mc_saldo_itens_bonificacao(OLD.id) WHERE saldo > 0) THEN
    RAISE EXCEPTION 'A solicitação ainda possui saldo de bonificação.';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS mc_validar_item_bonificacao_pv ON public.pedido_itens;
CREATE TRIGGER mc_validar_item_bonificacao_pv
BEFORE INSERT OR UPDATE OR DELETE ON public.pedido_itens
FOR EACH ROW EXECUTE FUNCTION public.mc_validar_item_bonificacao_pv();

DROP TRIGGER IF EXISTS mc_finalizar_bonificacao_pv ON public.pedido_itens;
CREATE TRIGGER mc_finalizar_bonificacao_pv AFTER INSERT ON public.pedido_itens
FOR EACH ROW WHEN (NEW.solicitacao_bonificacao_id IS NOT NULL)
EXECUTE FUNCTION public.mc_finalizar_bonificacao_pv();

DROP TRIGGER IF EXISTS mc_proteger_saldo_bonificacao ON public.solicitacoes;
CREATE TRIGGER mc_proteger_saldo_bonificacao BEFORE UPDATE OF status_fluxo, pedido_id ON public.solicitacoes
FOR EACH ROW WHEN (OLD.categoria = 'bonificacao')
EXECUTE FUNCTION public.mc_proteger_saldo_bonificacao();

CREATE OR REPLACE FUNCTION public.mc_bonificacoes_cliente_pv(p_cliente_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.usuarios u WHERE u.id = auth.uid() AND u.ativo
    AND u.papel::text IN ('adm_vendas','gestao_adm_vendas','admin')) THEN
    RAISE EXCEPTION 'Consulta restrita à Administração de Vendas.';
  END IF;
  RETURN jsonb_build_object(
    'abertas', coalesce((
      SELECT jsonb_agg(jsonb_build_object('id',s.id,'codigo',s.codigo,'modalidade',s.modalidade_bonificacao,
        'itens', x.itens) ORDER BY s.created_at)
      FROM public.solicitacoes s
      CROSS JOIN LATERAL (
        SELECT jsonb_agg(to_jsonb(a) || jsonb_build_object('codigo',p.codigo,'descricao',p.descricao,
          'unidade',p.unidade) ORDER BY a.ordem) AS itens
        FROM public.mc_saldo_itens_bonificacao(s.id) a JOIN public.produtos p ON p.id = a.produto_id
      ) x
      WHERE s.cliente_id = p_cliente_id AND s.categoria = 'bonificacao'
        AND s.status_fluxo = 'aprovada' AND s.pedido_id IS NULL AND x.itens IS NOT NULL
        AND EXISTS (SELECT 1 FROM public.solicitacao_aprovacoes a
          WHERE a.solicitacao_id = s.id AND a.etapa = 'diretoria' AND a.status = 'aprovado')
        AND EXISTS (SELECT 1 FROM public.solicitacao_aprovacoes a
          WHERE a.solicitacao_id = s.id AND a.etapa = 'financeiro' AND a.status IN ('aprovado','reprovado'))
        AND NOT EXISTS (SELECT 1 FROM public.solicitacao_aprovacoes a WHERE a.solicitacao_id = s.id
          AND NOT (a.status IN ('aprovado','nao_aplica') OR (a.etapa = 'financeiro' AND a.status = 'reprovado')))
    ), '[]'::jsonb),
    'historico', coalesce((
      SELECT jsonb_agg(to_jsonb(h) ORDER BY h.data_pedido DESC,h.pedido_codigo,h.bonificacao,h.produto)
      FROM (
        SELECT p.id AS pedido_id, p.codigo AS pedido_codigo, p.data_pedido, s.id AS solicitacao_id, s.codigo AS bonificacao,
          pr.codigo AS produto, pr.unidade, sum(i.quantidade) AS quantidade
        FROM public.pedidos p
        JOIN public.pedido_itens i ON i.pedido_id = p.id
        JOIN public.solicitacoes s ON s.id = i.solicitacao_bonificacao_id AND s.cliente_id = p.cliente_id
        JOIN public.produtos pr ON pr.id = i.produto_id
        WHERE p.cliente_id = p_cliente_id
        GROUP BY p.id,p.codigo,p.data_pedido,s.id,s.codigo,pr.codigo,pr.unidade
        UNION ALL
        SELECT p.id,p.codigo,p.data_pedido,s.id,s.codigo,pr.codigo,pr.unidade,sum(i.quantidade)
        FROM public.solicitacoes s JOIN public.pedidos p ON p.id = s.pedido_id AND p.cliente_id = s.cliente_id
        CROSS JOIN LATERAL public.mc_saldo_itens_bonificacao(s.id) a
        JOIN public.produtos pr ON pr.id = a.produto_id
        JOIN public.pedido_itens i ON i.pedido_id = p.id AND i.produto_id = a.produto_id
          AND i.tipo_item = 'bonificacao' AND i.valor_unitario = 0 AND i.solicitacao_bonificacao_id IS NULL
        WHERE s.cliente_id = p_cliente_id AND s.categoria = 'bonificacao'
          AND s.status_fluxo IN ('concluida','vinculada')
          AND NOT EXISTS (SELECT 1 FROM public.pedido_itens WHERE solicitacao_bonificacao_id = s.id)
        GROUP BY p.id,p.codigo,p.data_pedido,s.id,s.codigo,pr.codigo,pr.unidade,a.aprovada
        HAVING sum(i.quantidade) = a.aprovada
      ) h
    ), '[]'::jsonb)
  );
END;
$$;

-- SECURITY INVOKER mantém RLS de pedidos e itens. O gatilho valida e baixa cada solicitação.
CREATE OR REPLACE FUNCTION public.mc_salvar_pedido_bonificacao_pv(
  p_pedido_id uuid, p_cliente_id uuid, p_rota_id uuid, p_data date,
  p_observacoes text, p_operacao text, p_total_nfs integer, p_itens jsonb
) RETURNS jsonb LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  v_p public.pedidos%ROWTYPE;
  v_itens jsonb;
  v_remover integer;
  v_excluidos integer;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.usuarios u WHERE u.id = auth.uid() AND u.ativo
    AND u.papel::text IN ('adm_vendas','gestao_adm_vendas','admin')) THEN
    RAISE EXCEPTION 'Salvamento restrito à Administração de Vendas.';
  END IF;
  IF p_total_nfs IS NULL OR p_total_nfs NOT BETWEEN 1 AND 5 OR p_operacao IS NULL
    OR p_operacao NOT IN ('01','02','03') OR p_itens IS NULL OR jsonb_typeof(p_itens) <> 'array' THEN
    RAISE EXCEPTION 'Confira a operação, as NFs e os itens.';
  END IF;
  IF jsonb_array_length(p_itens) = 0 OR EXISTS (
    SELECT 1 FROM jsonb_to_recordset(p_itens) AS i(produto_id uuid,quantidade numeric,
      valor_unitario numeric,tipo_item text,codigo_operacao text,numero_nf integer)
    WHERE i.produto_id IS NULL OR NOT coalesce(i.quantidade > 0 AND i.quantidade < 'Infinity'::numeric
      AND i.numero_nf BETWEEN 1 AND p_total_nfs AND (
        (i.tipo_item = 'bonificacao' AND i.codigo_operacao = '04' AND i.valor_unitario = 0)
        OR (i.tipo_item = 'venda' AND i.codigo_operacao IN ('01','02','03')
          AND i.valor_unitario > 0 AND i.valor_unitario < 'Infinity'::numeric)
      ), false)
  ) OR EXISTS (
    SELECT 1 FROM generate_series(1,p_total_nfs) nf
    WHERE NOT EXISTS (SELECT 1 FROM jsonb_to_recordset(p_itens) AS i(numero_nf integer) WHERE i.numero_nf = nf)
  ) THEN
    RAISE EXCEPTION 'Confira as quantidades, os valores e a distribuição dos itens por NF.';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(p_cliente_id::text || '/' || p_rota_id::text || '/' || p_data::text, 0));

  IF p_pedido_id IS NULL THEN
    IF EXISTS (SELECT 1 FROM public.pedidos WHERE cliente_id = p_cliente_id AND rota_id = p_rota_id AND data_pedido = p_data) THEN
      RAISE EXCEPTION 'Já existe um pedido do cliente nesta data. Reabra o cliente antes de gravar.';
    END IF;
    INSERT INTO public.pedidos (cliente_id,rota_id,data_pedido,criado_por,observacoes,numero_nf,codigo_operacao,total_nfs)
    VALUES (p_cliente_id,p_rota_id,p_data,auth.uid(),p_observacoes,1,p_operacao,p_total_nfs)
    RETURNING * INTO v_p;
  ELSE
    SELECT * INTO v_p FROM public.pedidos WHERE id = p_pedido_id AND cliente_id = p_cliente_id
      AND rota_id = p_rota_id AND data_pedido = p_data FOR NO KEY UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Pedido não encontrado para o cliente, a rota e a data.'; END IF;
    IF EXISTS (SELECT 1 FROM public.bonificacao_apropriacoes
      WHERE pedido_id = v_p.id AND estornado_em IS NULL) THEN
      RAISE EXCEPTION 'Pedido possui apropriação no Conta Corrente.';
    END IF;
    IF p_operacao <> '01' AND EXISTS (SELECT 1 FROM public.pedido_itens
      WHERE pedido_id = v_p.id AND solicitacao_bonificacao_id IS NOT NULL) THEN
      RAISE EXCEPTION 'Mantenha a operação de venda do pedido com bonificação apropriada.';
    END IF;

    IF EXISTS (
      SELECT 1 FROM public.pedido_itens i WHERE i.pedido_id = v_p.id
        AND i.solicitacao_bonificacao_id IS NOT NULL AND NOT EXISTS (
          SELECT 1 FROM jsonb_to_recordset(p_itens) AS j(item_id uuid,produto_id uuid,quantidade numeric,solicitacao_bonificacao_id uuid)
          WHERE j.item_id = i.id AND j.produto_id = i.produto_id AND j.quantidade = i.quantidade
            AND j.solicitacao_bonificacao_id = i.solicitacao_bonificacao_id
        )
    ) THEN RAISE EXCEPTION 'As apropriações deste pedido mudaram. Reabra o cliente.'; END IF;

    UPDATE public.pedidos SET observacoes = p_observacoes,codigo_operacao = p_operacao,total_nfs = p_total_nfs
    WHERE id = v_p.id RETURNING * INTO v_p;
    IF NOT FOUND THEN RAISE EXCEPTION 'Pedido sem permissão para edição.'; END IF;

    SELECT count(*) INTO v_remover FROM public.pedido_itens WHERE pedido_id = v_p.id AND solicitacao_bonificacao_id IS NULL;
    DELETE FROM public.pedido_itens WHERE pedido_id = v_p.id AND solicitacao_bonificacao_id IS NULL;
    GET DIAGNOSTICS v_excluidos = ROW_COUNT;
    IF v_remover <> v_excluidos THEN RAISE EXCEPTION 'Não foi possível substituir todos os itens do pedido.'; END IF;
  END IF;

  IF EXISTS (
    SELECT 1 FROM jsonb_to_recordset(p_itens) AS j(item_id uuid,produto_id uuid,quantidade numeric,solicitacao_bonificacao_id uuid,
      valor_unitario numeric,tipo_item text,codigo_operacao text)
    WHERE j.item_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.pedido_itens i WHERE i.id = j.item_id AND i.pedido_id = v_p.id
        AND i.produto_id = j.produto_id AND i.quantidade = j.quantidade
        AND i.solicitacao_bonificacao_id = j.solicitacao_bonificacao_id
        AND i.valor_unitario = j.valor_unitario AND i.tipo_item::text = j.tipo_item
        AND i.codigo_operacao::text = j.codigo_operacao
    )
  ) THEN RAISE EXCEPTION 'Item apropriado não encontrado neste pedido.'; END IF;

  UPDATE public.pedido_itens i SET numero_nf = j.numero_nf
  FROM jsonb_to_recordset(p_itens) AS j(item_id uuid,numero_nf integer)
  WHERE i.id = j.item_id AND i.pedido_id = v_p.id AND i.numero_nf IS DISTINCT FROM j.numero_nf;

  INSERT INTO public.pedido_itens (pedido_id,produto_id,quantidade,valor_unitario,tipo_item,numero_nf,codigo_operacao,solicitacao_bonificacao_id)
  SELECT v_p.id,i.produto_id,i.quantidade,i.valor_unitario,i.tipo_item,i.numero_nf,i.codigo_operacao,i.solicitacao_bonificacao_id
  FROM jsonb_array_elements(p_itens) WITH ORDINALITY AS j(item,pos)
  CROSS JOIN LATERAL jsonb_populate_record(NULL::public.pedido_itens,j.item) i
  WHERE j.item->>'item_id' IS NULL
  ORDER BY i.solicitacao_bonificacao_id, j.pos;

  SELECT jsonb_agg(to_jsonb(i) || jsonb_build_object('produtos',
    jsonb_build_object('codigo',p.codigo,'descricao',p.descricao,'unidade',p.unidade))
    ORDER BY i.numero_nf, i.id) INTO v_itens
  FROM public.pedido_itens i LEFT JOIN public.produtos p ON p.id = i.produto_id
  WHERE i.pedido_id = v_p.id;

  IF coalesce(jsonb_array_length(v_itens),0) <> jsonb_array_length(p_itens)
    OR EXISTS (
      SELECT 1 FROM jsonb_to_recordset(p_itens) AS j(item_id uuid,numero_nf integer)
      WHERE j.item_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.pedido_itens i
        WHERE i.id = j.item_id AND i.pedido_id = v_p.id AND i.numero_nf = j.numero_nf)
    ) THEN RAISE EXCEPTION 'Os itens gravados não conferem com o pedido.'; END IF;

  RETURN jsonb_build_object('id',v_p.id,'codigo',v_p.codigo,'pedido_itens',v_itens);
END;
$$;

REVOKE ALL ON FUNCTION public.mc_saldo_itens_bonificacao(uuid),
  public.mc_validar_item_bonificacao_pv(), public.mc_finalizar_bonificacao_pv(),
  public.mc_proteger_saldo_bonificacao() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.mc_bonificacoes_cliente_pv(uuid),
  public.mc_salvar_pedido_bonificacao_pv(uuid,uuid,uuid,date,text,text,integer,jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.mc_bonificacoes_cliente_pv(uuid),
  public.mc_salvar_pedido_bonificacao_pv(uuid,uuid,uuid,date,text,text,integer,jsonb) TO authenticated;
NOTIFY pgrst, 'reload schema';
COMMIT;
