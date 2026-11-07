-- MEU CLIENTE • Bonificações v2 • 2026-11-07
-- Execute em SQL Editor do Supabase após backup. Preserva tabelas anteriores.
BEGIN;

-- Novos compromissos, vinculados à ficha, sem alterar a conta corrente legada.
CREATE TABLE IF NOT EXISTS public.bonificacao_compromissos (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 cliente_id uuid NOT NULL REFERENCES public.clientes(id),
 ficha_id uuid REFERENCES public.fichas_clientes(id),
 tipo text NOT NULL CHECK (tipo IN ('introducao','negociacao')),
 valor_acordado numeric(15,2),
 meses integer,
 percentual numeric(7,4),
 periodicidade text,
 modalidade text,
 faturamento_previsto numeric(15,2) NOT NULL DEFAULT 0,
 kg_previsto_mes numeric(15,3) NOT NULL DEFAULT 0,
 data_inicio date NOT NULL DEFAULT date_trunc('month',current_date)::date,
 ativo boolean NOT NULL DEFAULT true,
 criado_em timestamptz NOT NULL DEFAULT now(),
 CONSTRAINT bonif_v2_tipo_dados CHECK (
   (tipo='introducao' AND valor_acordado>0 AND meses BETWEEN 1 AND 120)
   OR (tipo='negociacao' AND percentual>0 AND percentual<=100 AND periodicidade IN ('todos','mensal','unica')
       AND modalidade IN ('Produto','Desconto'))
 )
);
CREATE UNIQUE INDEX IF NOT EXISTS bonif_v2_ficha_tipo ON public.bonificacao_compromissos(ficha_id,tipo) WHERE ficha_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS bonif_v2_cliente ON public.bonificacao_compromissos(cliente_id);

CREATE TABLE IF NOT EXISTS public.bonificacao_apropriacoes (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 compromisso_id uuid NOT NULL REFERENCES public.bonificacao_compromissos(id),
 cliente_id uuid NOT NULL REFERENCES public.clientes(id),
 pedido_id uuid NOT NULL REFERENCES public.pedidos(id),
 tipo text NOT NULL CHECK(tipo IN('introducao','negociacao')),
 modalidade text NOT NULL CHECK(modalidade IN('Produto','Desconto')),
 valor numeric(15,2) NOT NULL CHECK(valor>0),
 data_pedido date NOT NULL,
 competencia date GENERATED ALWAYS AS (date_trunc('month',data_pedido::timestamp without time zone)::date) STORED,
 descricao text,
 criado_por uuid NOT NULL DEFAULT auth.uid(),
 criado_em timestamptz NOT NULL DEFAULT now(),
 estornado_em timestamptz,
 estornado_por uuid,
 motivo_estorno text
);
CREATE UNIQUE INDEX IF NOT EXISTS bonif_v2_pedido_tipo_ativo ON public.bonificacao_apropriacoes(pedido_id,tipo) WHERE estornado_em IS NULL;
CREATE INDEX IF NOT EXISTS bonif_v2_mov_cliente ON public.bonificacao_apropriacoes(cliente_id,competencia);

-- Sincronização idempotente: somente após aprovação da diretoria e cliente vinculado à ficha.
CREATE OR REPLACE FUNCTION public.bonif_v2_sincronizar_ficha(p_ficha_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE f public.fichas_clientes%ROWTYPE; c record;
        v_periodo text; v_modalidade text; v_inicio date;
BEGIN
 SELECT * INTO f FROM public.fichas_clientes WHERE id=p_ficha_id;
 IF NOT FOUND THEN RETURN; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.ficha_aprovacoes WHERE ficha_id=p_ficha_id AND etapa='diretoria' AND status='aprovado') THEN RETURN; END IF;
 -- Não adivinhar o cliente por CNPJ; vínculo exclusivo ficha_id.
 FOR c IN SELECT id FROM public.clientes WHERE ficha_id=p_ficha_id LOOP
   SELECT date_trunc('month',COALESCE(MAX(ap.decidido_em),now()))::date INTO v_inicio
   FROM public.ficha_aprovacoes ap WHERE ap.ficha_id=p_ficha_id AND ap.etapa='diretoria' AND ap.status='aprovado';
   IF COALESCE(f.verba_introducao,0)>0 AND (CASE WHEN f.duracao_verba::text ~ '^[0-9]+
     INSERT INTO public.bonificacao_compromissos(cliente_id,ficha_id,tipo,valor_acordado,meses,data_inicio)
     VALUES(c.id,f.id,'introducao',f.verba_introducao,f.duracao_verba::integer,v_inicio)
     ON CONFLICT (ficha_id,tipo) WHERE ficha_id IS NOT NULL DO NOTHING;
   END IF;
   IF COALESCE(f.bonificacao_percentual,0) BETWEEN 0.01 AND 100 THEN
     v_periodo=CASE f.bonificacao_periodicidade
       WHEN 'Mensal' THEN 'mensal' WHEN '1 Pedido do mês' THEN 'mensal'
       WHEN 'Bonificação única' THEN 'unica' WHEN '1 parcela' THEN 'unica'
       ELSE 'todos' END;
     v_modalidade=CASE WHEN f.bonificacao_modalidade IN ('Desconto','Desconto financeiro') THEN 'Desconto' ELSE 'Produto' END;
     INSERT INTO public.bonificacao_compromissos
       (cliente_id,ficha_id,tipo,percentual,periodicidade,modalidade,faturamento_previsto,kg_previsto_mes,data_inicio)
     VALUES(c.id,f.id,'negociacao',f.bonificacao_percentual,v_periodo,v_modalidade,
       COALESCE(f.faturamento_previsto,0),COALESCE(f.consumo_previsto,0)*0.080*26,v_inicio)
     ON CONFLICT (ficha_id,tipo) WHERE ficha_id IS NOT NULL DO NOTHING;
   END IF;
 END LOOP;
END $$;
REVOKE ALL ON FUNCTION public.bonif_v2_sincronizar_ficha(uuid) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.bonif_v2_apos_cliente()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
 IF NEW.ficha_id IS NOT NULL THEN PERFORM public.bonif_v2_sincronizar_ficha(NEW.ficha_id); END IF;
 RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_bonif_v2_cliente ON public.clientes;
CREATE TRIGGER trg_bonif_v2_cliente AFTER INSERT OR UPDATE OF ficha_id ON public.clientes
 FOR EACH ROW EXECUTE FUNCTION public.bonif_v2_apos_cliente();

CREATE OR REPLACE FUNCTION public.bonif_v2_apos_aprovacao()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
 IF NEW.etapa='diretoria' AND NEW.status='aprovado' THEN PERFORM public.bonif_v2_sincronizar_ficha(NEW.ficha_id); END IF;
 RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_bonif_v2_aprovacao ON public.ficha_aprovacoes;
CREATE TRIGGER trg_bonif_v2_aprovacao AFTER INSERT OR UPDATE OF status ON public.ficha_aprovacoes
 FOR EACH ROW EXECUTE FUNCTION public.bonif_v2_apos_aprovacao();

-- Segurança: leitura exige acesso ao cliente; escrita somente RPC autorizada.
ALTER TABLE public.bonificacao_compromissos ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bonificacao_apropriacoes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS bonif_v2_comp_leitura ON public.bonificacao_compromissos;
CREATE POLICY bonif_v2_comp_leitura ON public.bonificacao_compromissos FOR SELECT TO authenticated
 USING (EXISTS(SELECT 1 FROM public.clientes c WHERE c.id=cliente_id));
DROP POLICY IF EXISTS bonif_v2_aprop_leitura ON public.bonificacao_apropriacoes;
CREATE POLICY bonif_v2_aprop_leitura ON public.bonificacao_apropriacoes FOR SELECT TO authenticated
 USING (EXISTS(SELECT 1 FROM public.clientes c WHERE c.id=cliente_id));
REVOKE ALL ON public.bonificacao_compromissos, public.bonificacao_apropriacoes FROM anon, authenticated;
GRANT SELECT ON public.bonificacao_compromissos, public.bonificacao_apropriacoes TO authenticated;

-- Valor de realização é conferido na transação (inclusive concorrência) e não pode duplicar.
CREATE OR REPLACE FUNCTION public.bonif_v2_apropriar(
 p_pedido_id uuid, p_tipo text, p_valor numeric, p_descricao text DEFAULT NULL
)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE p record; a public.bonificacao_compromissos%ROWTYPE; v_total numeric; v_realizado numeric;
        v_bonificado numeric; v_id uuid; v_papel text;
BEGIN
 SELECT papel::text INTO v_papel FROM public.usuarios WHERE id=auth.uid() AND ativo=true;
 IF v_papel IS NULL OR v_papel NOT IN('admin','financeiro','adm_vendas','gestao_adm_vendas') THEN
   RAISE EXCEPTION 'Usuário sem autorização para apropriar bonificação';
 END IF;
 IF p_tipo NOT IN ('introducao','negociacao') OR p_valor IS NULL OR p_valor<=0 OR ROUND(p_valor,2)<>p_valor THEN
   RAISE EXCEPTION 'Tipo ou valor de bonificação inválido';
 END IF;
 SELECT id,cliente_id,data_pedido INTO p FROM public.pedidos WHERE id=p_pedido_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Pedido inexistente'; END IF;
 SELECT * INTO a FROM public.bonificacao_compromissos WHERE cliente_id=p.cliente_id AND tipo=p_tipo AND ativo=true
 ORDER BY criado_em DESC LIMIT 1 FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Não há compromisso vigente deste tipo para o cliente'; END IF;
 IF p.data_pedido < a.data_inicio THEN RAISE EXCEPTION 'Pedido anterior ao início do acordo'; END IF;
 IF EXISTS(SELECT 1 FROM public.bonificacao_apropriacoes WHERE pedido_id=p_pedido_id AND tipo=p_tipo AND estornado_em IS NULL) THEN
   RAISE EXCEPTION 'Bonificação já apropriada neste pedido'; END IF;
 IF p_tipo='introducao' THEN
   SELECT COALESCE(SUM(valor),0) INTO v_realizado FROM public.bonificacao_apropriacoes
    WHERE compromisso_id=a.id AND estornado_em IS NULL;
   IF p_valor>a.valor_acordado-v_realizado THEN RAISE EXCEPTION 'Saldo insuficiente da Verba de Introdução'; END IF;
 ELSE
   IF a.periodicidade='unica' AND EXISTS(SELECT 1 FROM public.bonificacao_apropriacoes
      WHERE compromisso_id=a.id AND estornado_em IS NULL) THEN
      RAISE EXCEPTION 'A parcela única já foi aplicada'; END IF;
   IF a.periodicidade='mensal' AND EXISTS(SELECT 1 FROM public.bonificacao_apropriacoes
      WHERE compromisso_id=a.id AND competencia=date_trunc('month',p.data_pedido)::date AND estornado_em IS NULL) THEN
      RAISE EXCEPTION 'Já existe bonificação de negociação nesta competência'; END IF;
   SELECT COALESCE(SUM(quantidade*valor_unitario) FILTER
     (WHERE tipo_item IS DISTINCT FROM 'bonificacao' AND codigo_operacao IS DISTINCT FROM '02' AND codigo_operacao IS DISTINCT FROM '03'),0)
     INTO v_total FROM public.pedido_itens WHERE pedido_id=p_pedido_id;
   IF v_total<=0 THEN RAISE EXCEPTION 'Pedido sem compras elegíveis'; END IF;
   IF p_valor>ROUND(v_total*a.percentual/100,2) THEN
      RAISE EXCEPTION 'Valor supera % da negociação: máximo R$ %',ROUND(v_total*a.percentual/100,2); END IF;
 END IF;
 -- Em produto, só apropria quando existe produto bonificado real no pedido,
 -- com valor aferido pela tabela de preços vinculada ao cliente.
 IF (p_tipo='negociacao' AND a.modalidade='Produto') OR (p_tipo='introducao' AND COALESCE(p_descricao,'') LIKE '[PRODUTO]%') THEN
    SELECT COALESCE(SUM(pi.quantidade*tpi.preco_unitario),0) INTO v_bonificado
    FROM public.pedido_itens pi
    JOIN public.clientes c ON c.id=p.cliente_id
    JOIN public.tabela_preco_itens tpi ON tpi.tabela_id=c.tabela_preco_id AND tpi.produto_id=pi.produto_id
    WHERE pi.pedido_id=p_pedido_id AND pi.tipo_item='bonificacao';
    SELECT v_bonificado-COALESCE(SUM(x.valor),0) INTO v_bonificado
   FROM public.bonificacao_apropriacoes x WHERE x.pedido_id=p_pedido_id
      AND x.estornado_em IS NULL AND x.modalidade='Produto';
   IF v_bonificado < p_valor THEN
       RAISE EXCEPTION 'Itens bonificados insuficientes após outras apropriações no pedido (disponível R$ %)',v_bonificado; END IF;
 END IF;
 INSERT INTO public.bonificacao_apropriacoes(compromisso_id,cliente_id,pedido_id,tipo,modalidade,valor,data_pedido,descricao,criado_por)
 VALUES(a.id,p.cliente_id,p_pedido_id,p_tipo,CASE WHEN p_tipo='negociacao' THEN a.modalidade ELSE
   CASE WHEN COALESCE(p_descricao,'') LIKE '[PRODUTO]%' THEN 'Produto' ELSE 'Desconto' END END,
   p_valor,p.data_pedido,p_descricao,auth.uid()) RETURNING id INTO v_id;
 RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION public.bonif_v2_apropriar(uuid,text,numeric,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.bonif_v2_apropriar(uuid,text,numeric,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.bonif_v2_estornar(p_apropriacao_id uuid,p_motivo text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE a record; v_papel text;
BEGIN
 SELECT papel::text INTO v_papel FROM public.usuarios WHERE id=auth.uid() AND ativo=true;
 IF v_papel IS NULL OR v_papel NOT IN('admin','financeiro','gestao_adm_vendas') THEN RAISE EXCEPTION 'Somente gestores podem estornar'; END IF;
 IF length(trim(COALESCE(p_motivo,'')))<5 THEN RAISE EXCEPTION 'Informe motivo do estorno (mínimo 5 caracteres)'; END IF;
 SELECT id INTO a FROM public.bonificacao_apropriacoes WHERE id=p_apropriacao_id AND estornado_em IS NULL FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Apropriação não encontrada ou já estornada'; END IF;
 UPDATE public.bonificacao_apropriacoes SET estornado_em=now(),estornado_por=auth.uid(),motivo_estorno=p_motivo WHERE id=p_apropriacao_id;
END $$;
REVOKE ALL ON FUNCTION public.bonif_v2_estornar(uuid,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.bonif_v2_estornar(uuid,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.bonif_v2_encerrar(p_compromisso_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_papel text;
BEGIN
 SELECT papel::text INTO v_papel FROM public.usuarios WHERE id=auth.uid() AND ativo=true;
 IF v_papel IS NULL OR v_papel NOT IN('admin','adm_vendas','gestao_adm_vendas','financeiro') THEN RAISE EXCEPTION 'Sem permissão para encerrar'; END IF;
 UPDATE public.bonificacao_compromissos SET ativo=false WHERE id=p_compromisso_id AND tipo='negociacao';
 IF NOT FOUND THEN RAISE EXCEPTION 'Negociação não encontrada'; END IF;
END $$;
REVOKE ALL ON FUNCTION public.bonif_v2_encerrar(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.bonif_v2_encerrar(uuid) TO authenticated;

-- Fichas antigas: somente após aprovação e vínculo inequívoco.
SELECT public.bonif_v2_sincronizar_ficha(f.id)
FROM public.fichas_clientes f
WHERE EXISTS (SELECT 1 FROM public.clientes c WHERE c.ficha_id=f.id)
 AND EXISTS (SELECT 1 FROM public.ficha_aprovacoes ap WHERE ap.ficha_id=f.id AND ap.etapa='diretoria' AND ap.status='aprovado');

COMMIT;

-- Consulta de validação após aplicar:
-- SELECT tipo, COUNT(*), SUM(valor_acordado) FROM public.bonificacao_compromissos GROUP BY tipo;
 THEN f.duracao_verba::integer BETWEEN 1 AND 120 ELSE false END) THEN
     INSERT INTO public.bonificacao_compromissos(cliente_id,ficha_id,tipo,valor_acordado,meses,data_inicio)
     VALUES(c.id,f.id,'introducao',f.verba_introducao,f.duracao_verba::integer,v_inicio)
     ON CONFLICT (ficha_id,tipo) WHERE ficha_id IS NOT NULL DO NOTHING;
   END IF;
   IF COALESCE(f.bonificacao_percentual,0)>0 THEN
     v_periodo=CASE f.bonificacao_periodicidade
       WHEN 'Mensal' THEN 'mensal' WHEN '1 Pedido do mês' THEN 'mensal'
       WHEN 'Bonificação única' THEN 'unica' WHEN '1 parcela' THEN 'unica'
       ELSE 'todos' END;
     v_modalidade=CASE WHEN f.bonificacao_modalidade IN ('Desconto','Desconto financeiro') THEN 'Desconto' ELSE 'Produto' END;
     INSERT INTO public.bonificacao_compromissos
       (cliente_id,ficha_id,tipo,percentual,periodicidade,modalidade,faturamento_previsto,kg_previsto_mes,data_inicio)
     VALUES(c.id,f.id,'negociacao',f.bonificacao_percentual,v_periodo,v_modalidade,
       COALESCE(f.faturamento_previsto,0),COALESCE(f.consumo_previsto,0)*0.080*26,v_inicio)
     ON CONFLICT (ficha_id,tipo) WHERE ficha_id IS NOT NULL DO NOTHING;
   END IF;
 END LOOP;
END $$;
REVOKE ALL ON FUNCTION public.bonif_v2_sincronizar_ficha(uuid) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.bonif_v2_apos_cliente()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
 IF NEW.ficha_id IS NOT NULL THEN PERFORM public.bonif_v2_sincronizar_ficha(NEW.ficha_id); END IF;
 RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_bonif_v2_cliente ON public.clientes;
CREATE TRIGGER trg_bonif_v2_cliente AFTER INSERT OR UPDATE OF ficha_id ON public.clientes
 FOR EACH ROW EXECUTE FUNCTION public.bonif_v2_apos_cliente();

CREATE OR REPLACE FUNCTION public.bonif_v2_apos_aprovacao()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
 IF NEW.etapa='diretoria' AND NEW.status='aprovado' THEN PERFORM public.bonif_v2_sincronizar_ficha(NEW.ficha_id); END IF;
 RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_bonif_v2_aprovacao ON public.ficha_aprovacoes;
CREATE TRIGGER trg_bonif_v2_aprovacao AFTER INSERT OR UPDATE OF status ON public.ficha_aprovacoes
 FOR EACH ROW EXECUTE FUNCTION public.bonif_v2_apos_aprovacao();

-- Segurança: leitura exige acesso ao cliente; escrita somente RPC autorizada.
ALTER TABLE public.bonificacao_compromissos ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bonificacao_apropriacoes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS bonif_v2_comp_leitura ON public.bonificacao_compromissos;
CREATE POLICY bonif_v2_comp_leitura ON public.bonificacao_compromissos FOR SELECT TO authenticated
 USING (EXISTS(SELECT 1 FROM public.clientes c WHERE c.id=cliente_id));
DROP POLICY IF EXISTS bonif_v2_aprop_leitura ON public.bonificacao_apropriacoes;
CREATE POLICY bonif_v2_aprop_leitura ON public.bonificacao_apropriacoes FOR SELECT TO authenticated
 USING (EXISTS(SELECT 1 FROM public.clientes c WHERE c.id=cliente_id));
REVOKE ALL ON public.bonificacao_compromissos, public.bonificacao_apropriacoes FROM anon, authenticated;
GRANT SELECT ON public.bonificacao_compromissos, public.bonificacao_apropriacoes TO authenticated;

-- Valor de realização é conferido na transação (inclusive concorrência) e não pode duplicar.
CREATE OR REPLACE FUNCTION public.bonif_v2_apropriar(
 p_pedido_id uuid, p_tipo text, p_valor numeric, p_descricao text DEFAULT NULL
)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE p record; a public.bonificacao_compromissos%ROWTYPE; v_total numeric; v_realizado numeric;
        v_bonificado numeric; v_id uuid; v_papel text;
BEGIN
 SELECT papel::text INTO v_papel FROM public.usuarios WHERE id=auth.uid() AND ativo=true;
 IF v_papel IS NULL OR v_papel NOT IN('admin','financeiro','adm_vendas','gestao_adm_vendas') THEN
   RAISE EXCEPTION 'Usuário sem autorização para apropriar bonificação';
 END IF;
 IF p_tipo NOT IN ('introducao','negociacao') OR p_valor IS NULL OR p_valor<=0 OR ROUND(p_valor,2)<>p_valor THEN
   RAISE EXCEPTION 'Tipo ou valor de bonificação inválido';
 END IF;
 SELECT id,cliente_id,data_pedido INTO p FROM public.pedidos WHERE id=p_pedido_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Pedido inexistente'; END IF;
 SELECT * INTO a FROM public.bonificacao_compromissos WHERE cliente_id=p.cliente_id AND tipo=p_tipo AND ativo=true
 ORDER BY criado_em DESC LIMIT 1 FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Não há compromisso vigente deste tipo para o cliente'; END IF;
 IF p.data_pedido < a.data_inicio THEN RAISE EXCEPTION 'Pedido anterior ao início do acordo'; END IF;
 IF EXISTS(SELECT 1 FROM public.bonificacao_apropriacoes WHERE pedido_id=p_pedido_id AND tipo=p_tipo AND estornado_em IS NULL) THEN
   RAISE EXCEPTION 'Bonificação já apropriada neste pedido'; END IF;
 IF p_tipo='introducao' THEN
   SELECT COALESCE(SUM(valor),0) INTO v_realizado FROM public.bonificacao_apropriacoes
    WHERE compromisso_id=a.id AND estornado_em IS NULL;
   IF p_valor>a.valor_acordado-v_realizado THEN RAISE EXCEPTION 'Saldo insuficiente da Verba de Introdução'; END IF;
 ELSE
   IF a.periodicidade='unica' AND EXISTS(SELECT 1 FROM public.bonificacao_apropriacoes
      WHERE compromisso_id=a.id AND estornado_em IS NULL) THEN
      RAISE EXCEPTION 'A parcela única já foi aplicada'; END IF;
   IF a.periodicidade='mensal' AND EXISTS(SELECT 1 FROM public.bonificacao_apropriacoes
      WHERE compromisso_id=a.id AND competencia=date_trunc('month',p.data_pedido)::date AND estornado_em IS NULL) THEN
      RAISE EXCEPTION 'Já existe bonificação de negociação nesta competência'; END IF;
   SELECT COALESCE(SUM(quantidade*valor_unitario) FILTER
     (WHERE tipo_item IS DISTINCT FROM 'bonificacao' AND codigo_operacao IS DISTINCT FROM '02' AND codigo_operacao IS DISTINCT FROM '03'),0)
     INTO v_total FROM public.pedido_itens WHERE pedido_id=p_pedido_id;
   IF v_total<=0 THEN RAISE EXCEPTION 'Pedido sem compras elegíveis'; END IF;
   IF p_valor>ROUND(v_total*a.percentual/100,2) THEN
      RAISE EXCEPTION 'Valor supera % da negociação: máximo R$ %',ROUND(v_total*a.percentual/100,2); END IF;
 END IF;
 -- Em produto, só apropria quando existe produto bonificado real no pedido,
 -- com valor aferido pela tabela de preços vinculada ao cliente.
 IF (p_tipo='negociacao' AND a.modalidade='Produto') OR (p_tipo='introducao' AND COALESCE(p_descricao,'') LIKE '[PRODUTO]%') THEN
    SELECT COALESCE(SUM(pi.quantidade*tpi.preco_unitario),0) INTO v_bonificado
    FROM public.pedido_itens pi
    JOIN public.clientes c ON c.id=p.cliente_id
    JOIN public.tabela_preco_itens tpi ON tpi.tabela_id=c.tabela_preco_id AND tpi.produto_id=pi.produto_id
    WHERE pi.pedido_id=p_pedido_id AND pi.tipo_item='bonificacao';
    SELECT v_bonificado-COALESCE(SUM(x.valor),0) INTO v_bonificado
   FROM public.bonificacao_apropriacoes x WHERE x.pedido_id=p_pedido_id
      AND x.estornado_em IS NULL AND x.modalidade='Produto';
   IF v_bonificado < p_valor THEN
       RAISE EXCEPTION 'Itens bonificados insuficientes após outras apropriações no pedido (disponível R$ %)',v_bonificado; END IF;
 END IF;
 INSERT INTO public.bonificacao_apropriacoes(compromisso_id,cliente_id,pedido_id,tipo,modalidade,valor,data_pedido,descricao,criado_por)
 VALUES(a.id,p.cliente_id,p_pedido_id,p_tipo,CASE WHEN p_tipo='negociacao' THEN a.modalidade ELSE
   CASE WHEN COALESCE(p_descricao,'') LIKE '[PRODUTO]%' THEN 'Produto' ELSE 'Desconto' END END,
   p_valor,p.data_pedido,p_descricao,auth.uid()) RETURNING id INTO v_id;
 RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION public.bonif_v2_apropriar(uuid,text,numeric,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.bonif_v2_apropriar(uuid,text,numeric,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.bonif_v2_estornar(p_apropriacao_id uuid,p_motivo text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE a record; v_papel text;
BEGIN
 SELECT papel::text INTO v_papel FROM public.usuarios WHERE id=auth.uid() AND ativo=true;
 IF v_papel NOT IN('admin','financeiro','gestao_adm_vendas') THEN RAISE EXCEPTION 'Somente gestores podem estornar'; END IF;
 IF length(trim(COALESCE(p_motivo,'')))<5 THEN RAISE EXCEPTION 'Informe motivo do estorno (mínimo 5 caracteres)'; END IF;
 SELECT id INTO a FROM public.bonificacao_apropriacoes WHERE id=p_apropriacao_id AND estornado_em IS NULL FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Apropriação não encontrada ou já estornada'; END IF;
 UPDATE public.bonificacao_apropriacoes SET estornado_em=now(),estornado_por=auth.uid(),motivo_estorno=p_motivo WHERE id=p_apropriacao_id;
END $$;
REVOKE ALL ON FUNCTION public.bonif_v2_estornar(uuid,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.bonif_v2_estornar(uuid,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.bonif_v2_encerrar(p_compromisso_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_papel text;
BEGIN
 SELECT papel::text INTO v_papel FROM public.usuarios WHERE id=auth.uid() AND ativo=true;
 IF v_papel NOT IN('admin','gestao_adm_vendas','financeiro') THEN RAISE EXCEPTION 'Sem permissão para encerrar'; END IF;
 UPDATE public.bonificacao_compromissos SET ativo=false WHERE id=p_compromisso_id AND tipo='negociacao';
 IF NOT FOUND THEN RAISE EXCEPTION 'Negociação não encontrada'; END IF;
END $$;
REVOKE ALL ON FUNCTION public.bonif_v2_encerrar(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.bonif_v2_encerrar(uuid) TO authenticated;

-- Fichas antigas: somente após aprovação e vínculo inequívoco.
SELECT public.bonif_v2_sincronizar_ficha(f.id)
FROM public.fichas_clientes f
WHERE EXISTS (SELECT 1 FROM public.clientes c WHERE c.ficha_id=f.id)
 AND EXISTS (SELECT 1 FROM public.ficha_aprovacoes ap WHERE ap.ficha_id=f.id AND ap.etapa='diretoria' AND ap.status='aprovado');

COMMIT;

-- Consulta de validação após aplicar:
-- SELECT tipo, COUNT(*), SUM(valor_acordado) FROM public.bonificacao_compromissos GROUP BY tipo;
