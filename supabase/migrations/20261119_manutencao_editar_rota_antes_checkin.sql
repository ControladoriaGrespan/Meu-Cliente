BEGIN;

CREATE TABLE IF NOT EXISTS public.rota_equipamento_edicoes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  rota_id uuid NOT NULL,
  editado_por uuid NOT NULL,
  editado_em timestamptz NOT NULL DEFAULT now(),
  adicionadas uuid[] NOT NULL,
  retiradas uuid[] NOT NULL,
  aprovacoes_retiradas jsonb NOT NULL,
  carregamentos_retirados jsonb NOT NULL
);
ALTER TABLE public.rota_equipamento_edicoes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.rota_equipamento_edicoes FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.mc_editar_paradas_rota_manutencao(
  p_rota_id uuid,p_paradas_atuais uuid[],p_paradas_finais uuid[]
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
DECLARE
  v_rota public.rotas_equipamentos%ROWTYPE;
  v_atuais uuid[];
  v_esperadas uuid[];
  v_adicionadas uuid[];
  v_retiradas uuid[];
  v_inicio_ordem integer;
  v_aprovacoes jsonb;
  v_carregamentos jsonb;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.usuarios u WHERE u.id=auth.uid()
    AND u.ativo IS DISTINCT FROM false AND u.papel::text IN ('manutencao','admin')) THEN
    RAISE EXCEPTION 'Somente a Manutenção ou o Administrador pode editar esta rota.';
  END IF;

  -- A mesma trava de linha é tomada pelo motorista antes do check-in.
  SELECT * INTO v_rota FROM public.rotas_equipamentos WHERE id=p_rota_id FOR UPDATE;
  IF NOT FOUND OR v_rota.setor_responsavel IS DISTINCT FROM 'manutencao' THEN
    RAISE EXCEPTION 'Rota de Manutenção não encontrada.';
  END IF;
  IF v_rota.motorista_inicio_em IS NOT NULL OR v_rota.concluida_em IS NOT NULL THEN
    RAISE EXCEPTION 'A rota já foi iniciada pelo motorista ou encerrada.';
  END IF;
  IF p_paradas_atuais IS NULL OR coalesce(cardinality(p_paradas_finais),0)=0
    OR array_position(p_paradas_finais,NULL) IS NOT NULL
    OR cardinality(p_paradas_finais)<>(SELECT count(DISTINCT id) FROM unnest(p_paradas_finais) AS id) THEN
    RAISE EXCEPTION 'Selecione pelo menos uma parada válida, sem duplicidades.';
  END IF;

  SELECT coalesce(array_agg(i.entrega_id ORDER BY i.entrega_id),'{}'::uuid[])
  INTO v_atuais FROM public.rota_equipamento_itens i WHERE i.rota_id=p_rota_id;
  SELECT coalesce(array_agg(id ORDER BY id),'{}'::uuid[])
  INTO v_esperadas FROM unnest(p_paradas_atuais) AS id;
  IF v_atuais IS DISTINCT FROM v_esperadas THEN
    RAISE EXCEPTION 'As paradas mudaram desde que você abriu a rota. Atualize a tela e tente novamente.';
  END IF;

  SELECT ARRAY(SELECT id FROM unnest(p_paradas_finais) WITH ORDINALITY AS nova(id,ordem)
    WHERE NOT (id=ANY(v_atuais)) ORDER BY ordem) INTO v_adicionadas;
  SELECT ARRAY(SELECT id FROM unnest(v_atuais) AS id WHERE NOT (id=ANY(p_paradas_finais))) INTO v_retiradas;

  PERFORM 1 FROM public.entregas_equipamentos d
  WHERE d.id=ANY(v_atuais||v_adicionadas) ORDER BY d.id FOR UPDATE;
  IF EXISTS (SELECT 1 FROM public.entregas_equipamentos d
    WHERE d.id=ANY(v_atuais) AND d.status IS DISTINCT FROM 'roteirizada') THEN
    RAISE EXCEPTION 'A rota tem uma parada fora do estado Roteirizada. Atualize a tela.';
  END IF;
  IF (SELECT count(*) FROM public.entregas_equipamentos d
      WHERE d.id=ANY(v_adicionadas) AND d.status='ag_rota'
        AND coalesce(d.tipo_demanda::text,'envio') IN ('envio','entrega','troca','retirada')
        AND NOT EXISTS (SELECT 1 FROM public.rota_equipamento_itens i WHERE i.entrega_id=d.id))
    <>cardinality(v_adicionadas) THEN
    RAISE EXCEPTION 'Uma ou mais demandas novas já estão em rota ou não estão mais em Ag. Rota.';
  END IF;

  IF cardinality(v_adicionadas)+cardinality(v_retiradas)>0 THEN
    -- Retiradas conservam o histórico, mas a programação e a conferência
    -- anteriores deixam de valer caso a demanda retorne para a mesma rota.
    WITH registros AS (
      DELETE FROM public.rota_programacao_aprovacoes a
      WHERE a.rota_id=p_rota_id AND a.entrega_id=ANY(v_retiradas) RETURNING a.*
    ) SELECT coalesce(jsonb_agg(to_jsonb(r)),'[]'::jsonb) INTO v_aprovacoes FROM registros r;
    WITH registros AS (
      DELETE FROM public.rota_motorista_paradas m
      WHERE m.rota_id=p_rota_id AND m.entrega_id=ANY(v_retiradas) RETURNING m.*
    ) SELECT coalesce(jsonb_agg(to_jsonb(r)),'[]'::jsonb) INTO v_carregamentos FROM registros r;
    DELETE FROM public.rota_equipamento_itens i
    WHERE i.rota_id=p_rota_id AND i.entrega_id=ANY(v_retiradas);
    UPDATE public.entregas_equipamentos SET status='ag_rota' WHERE id=ANY(v_retiradas);

    SELECT coalesce(max(i.ordem),0) INTO v_inicio_ordem
    FROM public.rota_equipamento_itens i WHERE i.rota_id=p_rota_id;
    INSERT INTO public.rota_equipamento_itens(rota_id,entrega_id,ordem)
    SELECT p_rota_id,id,v_inicio_ordem+ordem::integer
    FROM unnest(v_adicionadas) WITH ORDINALITY AS nova(id,ordem);
    UPDATE public.entregas_equipamentos SET status='roteirizada' WHERE id=ANY(v_adicionadas);

    INSERT INTO public.rota_equipamento_edicoes
      (rota_id,editado_por,adicionadas,retiradas,aprovacoes_retiradas,carregamentos_retirados)
    VALUES (p_rota_id,auth.uid(),v_adicionadas,v_retiradas,v_aprovacoes,v_carregamentos);
  END IF;
  RETURN jsonb_build_object('adicionadas',cardinality(v_adicionadas),'retiradas',cardinality(v_retiradas));
END;
$fn$;

-- Protege também inclusões e mudanças de ordem feitas fora da tela de edição.
CREATE OR REPLACE FUNCTION public.mc_proteger_composicao_rota_manutencao()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
DECLARE v_origem uuid; v_rota public.rotas_equipamentos%ROWTYPE;
BEGIN
  IF TG_OP='UPDATE' THEN
    IF ROW(OLD.rota_id,OLD.entrega_id,OLD.ordem) IS NOT DISTINCT FROM
      ROW(NEW.rota_id,NEW.entrega_id,NEW.ordem) THEN RETURN NEW; END IF;
    v_origem:=OLD.rota_id;
  END IF;
  FOR v_rota IN SELECT r.* FROM public.rotas_equipamentos r
    WHERE r.id=NEW.rota_id OR r.id=v_origem ORDER BY r.id FOR UPDATE
  LOOP
    IF v_rota.setor_responsavel='manutencao' AND
      (v_rota.motorista_inicio_em IS NOT NULL OR v_rota.concluida_em IS NOT NULL) THEN
      RAISE EXCEPTION 'A composição de uma rota iniciada ou encerrada não pode ser alterada.';
    END IF;
  END LOOP;
  RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS trg_mc_proteger_composicao_rota_manutencao ON public.rota_equipamento_itens;
CREATE TRIGGER trg_mc_proteger_composicao_rota_manutencao
BEFORE INSERT OR UPDATE OF rota_id,entrega_id,ordem ON public.rota_equipamento_itens
FOR EACH ROW EXECUTE FUNCTION public.mc_proteger_composicao_rota_manutencao();

REVOKE ALL ON FUNCTION public.mc_proteger_composicao_rota_manutencao() FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.mc_editar_paradas_rota_manutencao(uuid,uuid[],uuid[]) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.mc_editar_paradas_rota_manutencao(uuid,uuid[],uuid[]) TO authenticated;
NOTIFY pgrst,'reload schema';
COMMIT;
