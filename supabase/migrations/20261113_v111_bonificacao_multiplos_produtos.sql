-- Meu Cliente v111: itens de bonificação sem alterar workflow de aprovações
BEGIN;
CREATE TABLE IF NOT EXISTS public.solicitacao_bonificacao_itens (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 solicitacao_id uuid NOT NULL REFERENCES public.solicitacoes(id) ON DELETE CASCADE,
 produto_id uuid NOT NULL REFERENCES public.produtos(id),
 quantidade numeric(14,3) NOT NULL CHECK (quantidade > 0),
 ordem integer NOT NULL DEFAULT 1,
 criado_em timestamptz NOT NULL DEFAULT now(),
 UNIQUE(solicitacao_id,produto_id)
);
CREATE INDEX IF NOT EXISTS idx_sol_bon_itens_solicitacao ON public.solicitacao_bonificacao_itens(solicitacao_id);
INSERT INTO public.solicitacao_bonificacao_itens(solicitacao_id,produto_id,quantidade,ordem)
SELECT id,produto_id,quantidade,1 FROM public.solicitacoes
WHERE categoria='bonificacao' AND produto_id IS NOT NULL AND quantidade>0
ON CONFLICT(solicitacao_id,produto_id) DO NOTHING;

ALTER TABLE public.solicitacao_bonificacao_itens ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS mc_bon_itens_select ON public.solicitacao_bonificacao_itens;
CREATE POLICY mc_bon_itens_select ON public.solicitacao_bonificacao_itens FOR SELECT TO authenticated
USING (
 EXISTS (SELECT 1 FROM public.solicitacoes s WHERE s.id=solicitacao_id)
 OR EXISTS (SELECT 1 FROM public.usuarios u WHERE u.id=auth.uid()
   AND u.ativo=true AND u.papel::text IN ('adm_vendas','gestao_adm_vendas','admin'))
);
DROP POLICY IF EXISTS mc_bon_itens_insert ON public.solicitacao_bonificacao_itens;
CREATE POLICY mc_bon_itens_insert ON public.solicitacao_bonificacao_itens FOR INSERT TO authenticated
WITH CHECK (EXISTS (
 SELECT 1 FROM public.solicitacoes s
 WHERE s.id=solicitacao_id AND s.solicitante_id=auth.uid()
 AND s.categoria='bonificacao' AND s.status_fluxo='aberta'
));
GRANT SELECT, INSERT ON public.solicitacao_bonificacao_itens TO authenticated;

-- Função INVOKER: preserva as permissões/RLS, triggers, códigos e etapas originais
-- do INSERT em solicitacoes. Se qualquer item falhar, o cabeçalho inteiro é revertido.
CREATE OR REPLACE FUNCTION public.mc_criar_bonificacao_multiplos_itens(
 p_cliente_id uuid,p_solicitante_id uuid,p_descricao text,
 p_modalidade text,p_itens jsonb
) RETURNS uuid LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE v_id uuid; v_primeiro jsonb; v_item jsonb; v_ids uuid[] := ARRAY[]::uuid[];
 v_produto uuid; v_qtd numeric; v_ordem integer := 0;
BEGIN
 IF auth.uid() IS NULL OR p_solicitante_id IS DISTINCT FROM auth.uid() THEN
  RAISE EXCEPTION 'Solicitante não corresponde ao usuário autenticado'; END IF;
 IF p_itens IS NULL OR jsonb_typeof(p_itens)<>'array' OR jsonb_array_length(p_itens)=0
   OR jsonb_array_length(p_itens)>100 THEN RAISE EXCEPTION 'Informe de 1 a 100 produtos.'; END IF;
 IF p_modalidade NOT IN ('acrescimo','desconto') THEN RAISE EXCEPTION 'Modalidade inválida.'; END IF;
 FOR v_item IN SELECT value FROM jsonb_array_elements(p_itens) LOOP
   v_produto := (v_item->>'produto_id')::uuid;
   v_qtd := (v_item->>'quantidade')::numeric;
   IF v_produto IS NULL OR v_qtd IS NULL OR v_qtd<=0 OR v_qtd>1000000
      OR v_produto=ANY(v_ids) THEN RAISE EXCEPTION 'Produtos duplicados ou quantidades inválidas.'; END IF;
   IF NOT EXISTS (SELECT 1 FROM public.produtos WHERE id=v_produto AND ativo=true)
     THEN RAISE EXCEPTION 'Produto indisponível: %',v_produto; END IF;
   v_ids := array_append(v_ids,v_produto);
 END LOOP;
 v_primeiro := p_itens->0;
 INSERT INTO public.solicitacoes
  (cliente_id,solicitante_id,categoria,descricao,equipamento,tipo,produto_id,quantidade,modalidade_bonificacao,status_fluxo)
 VALUES(p_cliente_id,p_solicitante_id,'bonificacao',nullif(trim(p_descricao),''),'BONIFICAÇÃO','bonificacao',
        (v_primeiro->>'produto_id')::uuid,(v_primeiro->>'quantidade')::numeric,p_modalidade,'aberta')
 RETURNING id INTO v_id;
 FOR v_item IN SELECT value FROM jsonb_array_elements(p_itens) LOOP
   v_ordem := v_ordem+1;
   INSERT INTO public.solicitacao_bonificacao_itens(solicitacao_id,produto_id,quantidade,ordem)
   VALUES(v_id,(v_item->>'produto_id')::uuid,(v_item->>'quantidade')::numeric,v_ordem);
 END LOOP;
 RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION public.mc_criar_bonificacao_multiplos_itens(uuid,uuid,text,text,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.mc_criar_bonificacao_multiplos_itens(uuid,uuid,text,text,jsonb) TO authenticated;
COMMIT;
