BEGIN;

CREATE TABLE IF NOT EXISTS public.ficha_correcoes_equipamentos (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  ficha_id uuid NOT NULL REFERENCES public.fichas_clientes(id) ON DELETE CASCADE,
  autor_id uuid NOT NULL,
  realizado_em timestamptz NOT NULL DEFAULT now(),
  anterior jsonb NOT NULL,
  corrigido jsonb NOT NULL
);
ALTER TABLE public.ficha_correcoes_equipamentos ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ficha_correcoes_equipamentos FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.mc_corrigir_quantidades_ficha(
  p_ficha uuid,p_anterior jsonb,p_quantidades jsonb,p_resumo text,p_itens jsonb
) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE
  v_ficha public.fichas_clientes%ROWTYPE;
  v_entrega public.entregas_equipamentos%ROWTYPE;
  v_antes jsonb;
  v_ajuste public.fichas_clientes%ROWTYPE;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.usuarios WHERE id=auth.uid() AND papel='admin' AND ativo IS DISTINCT FROM false) THEN
    RAISE EXCEPTION 'Somente o Administrador pode corrigir quantidades.';
  END IF;
  SELECT * INTO v_ficha FROM public.fichas_clientes WHERE id=p_ficha FOR UPDATE;
  IF NOT FOUND OR v_ficha.precisa_equipamento IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'A ficha não possui equipamentos cadastrados.';
  END IF;
  v_antes := jsonb_build_object('equipamentos_quantidades',v_ficha.equipamentos_quantidades,
    'forno_tipo',v_ficha.forno_tipo,'forno_quantidade',v_ficha.forno_quantidade,'forno_esteiras',v_ficha.forno_esteiras,
    'esteiras_quantidade',v_ficha.esteiras_quantidade,'assadeiras_quantidade',v_ficha.assadeiras_quantidade);
  IF v_antes IS DISTINCT FROM p_anterior THEN
    RAISE EXCEPTION 'A ficha mudou. Atualize a tela e tente novamente.';
  END IF;
  IF jsonb_typeof(p_quantidades) IS DISTINCT FROM 'object'
    OR jsonb_typeof(p_quantidades->'equipamentos_quantidades') IS DISTINCT FROM 'object'
    OR jsonb_typeof(p_itens) IS DISTINCT FROM 'array'
    OR nullif(btrim(p_resumo),'') IS NULL THEN
    RAISE EXCEPTION 'Dados dos equipamentos inválidos.';
  END IF;
  IF jsonb_array_length(p_itens) NOT BETWEEN 1 AND 30 OR EXISTS (
    SELECT 1 FROM jsonb_to_recordset(p_itens) AS i(descricao text,quantidade numeric)
    WHERE nullif(btrim(i.descricao),'') IS NULL OR i.quantidade IS NULL OR i.quantidade NOT BETWEEN 1 AND 9999
      OR i.quantidade<>trunc(i.quantidade)
  ) THEN RAISE EXCEPTION 'Informe ao menos um equipamento e use quantidades inteiras de até 9.999.'; END IF;
  SELECT * INTO v_entrega FROM public.entregas_equipamentos WHERE ficha_id=p_ficha FOR UPDATE;
  IF FOUND THEN
    IF v_entrega.status IS NULL OR v_entrega.status NOT IN ('pendente','ag_rota')
      OR EXISTS (SELECT 1 FROM public.rota_equipamento_itens WHERE entrega_id=v_entrega.id) THEN
      RAISE EXCEPTION 'A entrega já está em rota ou foi concluída. Para corrigir antes da entrega, retire a demanda da rota.';
    END IF;
    PERFORM 1 FROM public.comodato_equipamentos WHERE entrega_id=v_entrega.id FOR UPDATE;
    IF EXISTS (SELECT 1 FROM public.comodato_equipamentos i WHERE i.entrega_id=v_entrega.id
      AND nullif(btrim(i.patrimonio),'') IS NOT NULL) THEN
      RAISE EXCEPTION 'A Manutenção já atribuiu patrimônios. Ajuste os itens do comodato com a equipe antes de alterar as quantidades.';
    END IF;
  END IF;

  v_ajuste := jsonb_populate_record(NULL::public.fichas_clientes,p_quantidades);
  UPDATE public.fichas_clientes SET equipamentos_quantidades=v_ajuste.equipamentos_quantidades,
    forno_tipo=v_ajuste.forno_tipo,forno_quantidade=v_ajuste.forno_quantidade,forno_esteiras=v_ajuste.forno_esteiras,
    esteiras_quantidade=v_ajuste.esteiras_quantidade,assadeiras_quantidade=v_ajuste.assadeiras_quantidade
  WHERE id=p_ficha;
  IF v_entrega.id IS NOT NULL THEN
    UPDATE public.entregas_equipamentos SET equipamento_resumo=p_resumo,equipamento_entrega=p_resumo WHERE id=v_entrega.id;
    DELETE FROM public.comodato_equipamentos WHERE entrega_id=v_entrega.id;
    INSERT INTO public.comodato_equipamentos(entrega_id,quantidade,descricao,condicao,patrimonio,ordem)
    SELECT v_entrega.id,(i.item->>'quantidade')::integer,i.item->>'descricao',
      upper(coalesce(v_entrega.equipamento_condicao,v_ficha.equipamento_condicao_manutencao,v_ficha.equipamento_condicao,'')),
      '',i.ordem::integer
    FROM jsonb_array_elements(p_itens) WITH ORDINALITY i(item,ordem);
  END IF;
  INSERT INTO public.ficha_correcoes_equipamentos(ficha_id,autor_id,anterior,corrigido)
  VALUES(p_ficha,auth.uid(),v_antes,p_quantidades);
  RETURN v_entrega.id IS NOT NULL;
END $$;
REVOKE ALL ON FUNCTION public.mc_corrigir_quantidades_ficha(uuid,jsonb,jsonb,text,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.mc_corrigir_quantidades_ficha(uuid,jsonb,jsonb,text,jsonb) TO authenticated;

NOTIFY pgrst,'reload schema';
COMMIT;
