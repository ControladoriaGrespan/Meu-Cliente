-- Meu Cliente / v97 - Solicitação de aumento aprovada -> fila de rotas da Manutenção.
-- Execute no SQL Editor do Supabase depois de backup.
-- Não altera status de aprovação, não conclui entregas e não duplica demandas existentes.
BEGIN;

CREATE OR REPLACE FUNCTION public.mc_criar_demanda_aumento_equipamento(p_solicitacao_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_s public.solicitacoes%ROWTYPE;
  v_cli jsonb;
  v_resumo text;
BEGIN
  SELECT * INTO v_s FROM public.solicitacoes
  WHERE id = p_solicitacao_id;
  IF NOT FOUND OR v_s.categoria IS DISTINCT FROM 'equipamento'
    OR v_s.tipo IS DISTINCT FROM 'aumento'
    OR v_s.status_fluxo IS DISTINCT FROM 'aprovada' THEN
    RETURN;
  END IF;

  -- Uma demanda operacional por solicitação. Preserva a demanda caso já exista.
  IF EXISTS (SELECT 1 FROM public.entregas_equipamentos e
             WHERE e.solicitacao_id = v_s.id) THEN RETURN; END IF;

  SELECT to_jsonb(c) INTO v_cli FROM public.clientes c WHERE c.id = v_s.cliente_id;
  SELECT string_agg(
    coalesce(nullif(trim(e.equipamento),''),'Equipamento') || ' x' ||
      coalesce(e.quantidade,1)::text,
    '; ' ORDER BY e.equipamento
  ) INTO v_resumo
  FROM public.solicitacao_equipamentos e
  WHERE e.solicitacao_id=v_s.id AND e.movimento IN ('equipamento','entregar');

  IF NULLIF(btrim(v_cli->>'endereco_logradouro'),'') IS NULL AND
     NULLIF(btrim(v_cli->>'rua'),'') IS NULL AND
     NULLIF(btrim(v_cli->>'logradouro'),'') IS NULL AND
     NULLIF(btrim(v_cli->>'endereco_rua'),'') IS NULL THEN
    RAISE NOTICE 'Demanda não criada para solicitação %: cliente sem rua cadastrada',v_s.id;
    RETURN;
  END IF;

  INSERT INTO public.entregas_equipamentos (
    solicitacao_id,cliente_id,origem_tipo,tipo_demanda,status,
    equipamento_resumo,equipamento_entrega,criado_por,
    endereco_rua,endereco_numero,endereco_bairro,
    endereco_cidade,endereco_estado,endereco_cep
  ) VALUES (
    v_s.id,v_s.cliente_id,'solicitacao_aumento','envio','ag_rota',
    COALESCE(v_resumo,v_s.equipamento,'Aumento de equipamentos'),
    COALESCE(v_resumo,v_s.equipamento,'Aumento de equipamentos'),
    v_s.solicitante_id,
    COALESCE(NULLIF(btrim(v_cli->>'endereco_logradouro'),''),NULLIF(btrim(v_cli->>'rua'),''),NULLIF(btrim(v_cli->>'logradouro'),''),NULLIF(btrim(v_cli->>'endereco_rua'),'')),
    COALESCE(NULLIF(btrim(v_cli->>'endereco_numero'),''),NULLIF(btrim(v_cli->>'numero'),'')),
    COALESCE(NULLIF(btrim(v_cli->>'endereco_bairro'),''),NULLIF(btrim(v_cli->>'bairro'),'')),
    COALESCE(v_cli->>'cidade',v_cli->>'endereco_cidade'),
    COALESCE(v_cli->>'estado',v_cli->>'uf',v_cli->>'endereco_estado'),
    COALESCE(NULLIF(btrim(v_cli->>'endereco_cep'),''),NULLIF(btrim(v_cli->>'cep'),''))
  );
END;
$fn$;

-- Não conceder execução direta à aplicação: somente o gatilho roda no banco.
REVOKE ALL ON FUNCTION public.mc_criar_demanda_aumento_equipamento(uuid)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.mc_trigger_demanda_aumento_equipamento()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
BEGIN
  IF NEW.categoria='equipamento' AND NEW.tipo='aumento'
     AND NEW.status_fluxo='aprovada' THEN
    PERFORM public.mc_criar_demanda_aumento_equipamento(NEW.id);
  END IF;
  RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS trg_mc_demanda_aumento_equipamento ON public.solicitacoes;
CREATE TRIGGER trg_mc_demanda_aumento_equipamento
AFTER INSERT OR UPDATE OF status_fluxo ON public.solicitacoes
FOR EACH ROW EXECUTE FUNCTION public.mc_trigger_demanda_aumento_equipamento();

-- Recupera aumentos já aprovados (inclusive AUM-000012), sem alterar existentes.
DO $repair$
DECLARE v_id uuid;
BEGIN
  FOR v_id IN
    SELECT s.id FROM public.solicitacoes s
    WHERE s.categoria='equipamento' AND s.tipo='aumento'
      AND s.status_fluxo='aprovada'
      AND NOT EXISTS (SELECT 1 FROM public.entregas_equipamentos e
                      WHERE e.solicitacao_id=s.id)
  LOOP
    PERFORM public.mc_criar_demanda_aumento_equipamento(v_id);
  END LOOP;
END;
$repair$;
COMMIT;

-- Conferência após a execução: AUM-000012 deve ter demanda status ag_rota.
SELECT s.codigo,s.tipo,s.status_fluxo,
       e.id AS demanda_id,e.tipo_demanda,e.status,
       e.equipamento_resumo,e.endereco_cidade
FROM public.solicitacoes s
LEFT JOIN public.entregas_equipamentos e ON e.solicitacao_id=s.id
WHERE s.codigo='AUM-000012';
