BEGIN;

ALTER TABLE public.rotas_equipamentos
  ADD COLUMN IF NOT EXISTS motorista_inicio_em timestamptz,
  ADD COLUMN IF NOT EXISTS motorista_inicio_por uuid,
  ADD COLUMN IF NOT EXISTS motorista_checkout_por uuid;

ALTER TABLE public.entregas_equipamentos
  ADD COLUMN IF NOT EXISTS ultima_intercorrencia_motorista text;

CREATE TABLE IF NOT EXISTS public.rota_motorista_paradas (
  rota_id uuid NOT NULL REFERENCES public.rotas_equipamentos(id) ON DELETE CASCADE,
  entrega_id uuid NOT NULL REFERENCES public.entregas_equipamentos(id),
  parada jsonb NOT NULL,
  carregado_em timestamptz NOT NULL DEFAULT now(),
  carregado_por uuid NOT NULL,
  entregue_em timestamptz,
  entregue_por uuid,
  recebedor text,
  assinatura text,
  intercorrencia_tipo text CHECK (intercorrencia_tipo = 'nao_consegui_entregar'),
  intercorrencia_motivo text,
  intercorrencia_em timestamptz,
  intercorrencia_por uuid,
  CHECK (entregue_em IS NULL OR intercorrencia_em IS NULL),
  PRIMARY KEY (rota_id, entrega_id)
);
ALTER TABLE public.rota_motorista_paradas ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.rota_motorista_paradas FROM PUBLIC, anon, authenticated;

-- O manifesto descreve cada unidade a conferir. As retiradas são identificadas
-- separadamente, pois o equipamento só entra no caminhão no cliente.
CREATE OR REPLACE FUNCTION public.mc_manifesto_parada_motorista(p_entrega_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SET search_path = '' AS $fn$
  WITH origem AS (
    SELECT d.*, s.id AS solicitacao_ref, s.cliente_id AS cliente_solicitacao
    FROM public.entregas_equipamentos d
    LEFT JOIN public.solicitacoes s ON s.id = d.solicitacao_id
    WHERE d.id = p_entrega_id
  ), itens AS (
    SELECT 1 AS prioridade, 'comodato:'||e.id AS chave, e.descricao AS descricao,
      e.patrimonio::text, greatest(coalesce(e.quantidade,1)::int,1) AS quantidade, 'entregar' AS movimento
    FROM origem d JOIN public.comodato_equipamentos e ON e.entrega_id = d.id
    WHERE coalesce(d.tipo_demanda,'envio') IN ('envio','entrega')
    UNION ALL
    SELECT 2, 'solicitacao:'||e.id, e.equipamento, e.patrimonio::text,
      greatest(coalesce(e.quantidade,1)::int,1),
      CASE WHEN d.tipo_demanda='retirada' OR e.movimento='coletar' THEN 'coletar' ELSE 'entregar' END
    FROM origem d JOIN public.solicitacao_equipamentos e ON e.solicitacao_id = d.solicitacao_ref
    UNION ALL
    SELECT 3, 'demanda:coleta', coalesce(d.equipamento_coleta,
      CASE WHEN d.tipo_demanda='retirada' THEN d.equipamento_resumo END, 'Equipamento a retirar'),
      d.patrimonio_coleta::text, 1, 'coletar'
    FROM origem d WHERE d.tipo_demanda IN ('troca','retirada')
    UNION ALL
    SELECT 3, 'demanda:entrega', coalesce(d.equipamento_entrega,
      CASE WHEN d.tipo_demanda IS DISTINCT FROM 'troca' THEN d.equipamento_resumo END, 'Equipamento a entregar'),
      d.patrimonio_entrega::text, 1, 'entregar'
    FROM origem d WHERE d.tipo_demanda IS DISTINCT FROM 'retirada'
  ), unidades AS (
    SELECT chave||':'||n AS id, descricao, patrimonio, movimento, n, quantidade
    FROM itens i CROSS JOIN LATERAL generate_series(1, i.quantidade) n
    WHERE i.prioridade = (SELECT min(j.prioridade) FROM itens j WHERE j.movimento=i.movimento)
  )
  SELECT jsonb_build_object(
    'id',d.id,'tipo',coalesce(d.tipo_demanda,'envio'),'status_demanda',d.status,
    'codigo',c.codigo_totvs,'cliente',coalesce(c.razao_social,f.razao_social,'Cliente'),
    'endereco',concat_ws(', ',d.endereco_rua,d.endereco_numero,d.endereco_bairro,d.endereco_cidade,d.endereco_estado,d.endereco_cep),
    'itens',(SELECT coalesce(jsonb_agg(to_jsonb(u) ORDER BY u.movimento DESC,u.descricao,u.id),'[]'::jsonb) FROM unidades u)
  )
  FROM origem d LEFT JOIN public.clientes c ON c.id = coalesce(d.cliente_id,d.cliente_solicitacao)
  LEFT JOIN public.fichas_clientes f ON f.id = d.ficha_id
$fn$;

CREATE OR REPLACE FUNCTION public.mc_parada_motorista_aprovada(p_rota_id uuid,p_entrega_id uuid)
RETURNS boolean LANGUAGE sql STABLE SET search_path = '' AS $fn$
  SELECT coalesce(bool_and(a.status IS NOT DISTINCT FROM 'aprovado'),false)
  FROM public.rota_programacao_aprovacoes a WHERE a.rota_id=p_rota_id AND a.entrega_id=p_entrega_id
$fn$;

CREATE OR REPLACE FUNCTION public.mc_listar_rotas_motorista()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $fn$
  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'id',r.id,'nome',r.nome,'data_rota',r.data_rota,'placa',c.placa,'caminhao',c.nome,
    'inicio_em',r.motorista_inicio_em,'encerrada_em',r.concluida_em,'paradas',p.lista
  ) ORDER BY (r.concluida_em IS NOT NULL), r.data_rota, r.id),'[]'::jsonb)
  FROM public.rotas_equipamentos r JOIN public.caminhoes_equipamentos c ON c.id=r.caminhao_equipamentos_id
  CROSS JOIN LATERAL (
    SELECT jsonb_agg(s.parada ORDER BY s.ordem,s.entrega_id) AS lista,
      bool_or(s.parada->>'status' <> 'aguardando_aprovacao') AS visivel
    FROM (
      SELECT i.ordem,i.entrega_id,
        CASE WHEN d.status='concluida' OR public.mc_parada_motorista_aprovada(i.rota_id,i.entrega_id)
          THEN coalesce(m.parada,public.mc_manifesto_parada_motorista(i.entrega_id))
          ELSE jsonb_build_object('id',i.entrega_id) END ||
        jsonb_build_object('status',CASE
          WHEN d.status='concluida' THEN 'entregue'
          WHEN NOT public.mc_parada_motorista_aprovada(i.rota_id,i.entrega_id) THEN 'aguardando_aprovacao'
          WHEN m.carregado_em IS NULL THEN 'aguardando_carregamento'
          WHEN r.motorista_inicio_em IS NULL THEN 'carregado' ELSE 'em_rota' END,
          'ordem',i.ordem,'recebedor',m.recebedor,'entregue_em',coalesce(m.entregue_em,d.concluida_em)) AS parada
      FROM public.rota_equipamento_itens i
      JOIN public.entregas_equipamentos d ON d.id=i.entrega_id
      LEFT JOIN public.rota_motorista_paradas m ON m.rota_id=i.rota_id AND m.entrega_id=i.entrega_id
      WHERE i.rota_id=r.id
      UNION ALL
      SELECT (m.parada->>'ordem')::int,m.entrega_id,m.parada||jsonb_build_object(
        'status','intercorrencia','motivo',m.intercorrencia_motivo,'intercorrencia_em',m.intercorrencia_em)
      FROM public.rota_motorista_paradas m WHERE m.rota_id=r.id AND m.intercorrencia_em IS NOT NULL
    ) s
  ) p
  WHERE r.setor_responsavel='manutencao' AND p.visivel
    AND public.mc_pode_executar_rota_frota(r.setor_responsavel,r.caminhao_equipamentos_id)
$fn$;

CREATE OR REPLACE FUNCTION public.mc_registrar_etapa_motorista(
  p_rota_id uuid, p_acao text, p_entrega_id uuid DEFAULT NULL,
  p_itens text[] DEFAULT NULL, p_recebedor text DEFAULT NULL, p_assinatura text DEFAULT NULL,
  p_tipo text DEFAULT NULL, p_motivo text DEFAULT NULL
)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE
  v_rota public.rotas_equipamentos%ROWTYPE;
  v_operacao public.rota_motorista_paradas%ROWTYPE;
  v_manifesto jsonb;
  v_status text;
  v_ordem int;
  v_usuario uuid := auth.uid();
BEGIN
  SELECT * INTO v_rota FROM public.rotas_equipamentos WHERE id=p_rota_id FOR UPDATE;
  IF NOT FOUND OR v_rota.setor_responsavel IS DISTINCT FROM 'manutencao'
    OR NOT public.mc_pode_executar_rota_frota(v_rota.setor_responsavel,v_rota.caminhao_equipamentos_id) THEN
    RAISE EXCEPTION 'Esta rota não está atribuída ao seu perfil.';
  END IF;
  IF v_rota.concluida_em IS NOT NULL THEN
    IF p_acao='checkout' THEN RETURN; END IF;
    RAISE EXCEPTION 'A rota já foi encerrada.';
  END IF;

  IF p_acao='iniciar' THEN
    IF v_rota.motorista_inicio_em IS NOT NULL THEN RETURN; END IF;
    IF NOT EXISTS (
      SELECT 1 FROM public.rota_equipamento_itens i JOIN public.entregas_equipamentos d ON d.id=i.entrega_id
      WHERE i.rota_id=p_rota_id AND d.status='roteirizada'
    ) OR EXISTS (
      SELECT 1 FROM public.rota_equipamento_itens i JOIN public.entregas_equipamentos d ON d.id=i.entrega_id
      LEFT JOIN public.rota_motorista_paradas m ON m.rota_id=i.rota_id AND m.entrega_id=i.entrega_id
      WHERE i.rota_id=p_rota_id AND d.status IS DISTINCT FROM 'concluida'
        AND (d.status IS DISTINCT FROM 'roteirizada' OR m.carregado_em IS NULL
          OR NOT public.mc_parada_motorista_aprovada(i.rota_id,i.entrega_id))
    ) THEN
      RAISE EXCEPTION 'Aguarde a aprovação e confirme o carregamento de todas as paradas antes de iniciar.';
    END IF;
    UPDATE public.rotas_equipamentos SET motorista_inicio_em=now(),motorista_inicio_por=v_usuario WHERE id=p_rota_id;
    RETURN;
  END IF;

  IF p_acao='checkout' THEN
    IF v_rota.motorista_inicio_em IS NULL OR EXISTS (
      SELECT 1 FROM public.rota_equipamento_itens i JOIN public.entregas_equipamentos d ON d.id=i.entrega_id
      WHERE i.rota_id=p_rota_id AND d.status IS DISTINCT FROM 'concluida'
    ) THEN
      RAISE EXCEPTION 'Para fazer checkout, registre a entrega ou a intercorrência de cada parada.';
    END IF;
    UPDATE public.rotas_equipamentos SET concluida_em=now(),motorista_checkout_por=v_usuario WHERE id=p_rota_id;
    RETURN;
  END IF;

  IF p_acao IS NULL OR p_acao NOT IN ('carregar','entregar','intercorrencia') THEN
    RAISE EXCEPTION 'Ação de motorista inválida.';
  END IF;

  SELECT * INTO v_operacao FROM public.rota_motorista_paradas
  WHERE rota_id=p_rota_id AND entrega_id=p_entrega_id;
  IF (p_acao='intercorrencia' AND v_operacao.intercorrencia_em IS NOT NULL)
    OR (p_acao='entregar' AND v_operacao.entregue_em IS NOT NULL) THEN RETURN; END IF;

  SELECT d.status::text,i.ordem INTO v_status,v_ordem
  FROM public.rota_equipamento_itens i JOIN public.entregas_equipamentos d ON d.id=i.entrega_id
  WHERE i.rota_id=p_rota_id AND i.entrega_id=p_entrega_id FOR UPDATE OF d;
  IF v_status IS DISTINCT FROM 'roteirizada' OR NOT public.mc_parada_motorista_aprovada(p_rota_id,p_entrega_id) THEN
    RAISE EXCEPTION 'Esta parada não está disponível ou ainda depende de aprovação.';
  END IF;

  IF p_acao='carregar' THEN
    IF v_operacao.carregado_em IS NOT NULL THEN RETURN; END IF;
    IF v_rota.motorista_inicio_em IS NOT NULL THEN RAISE EXCEPTION 'A rota já foi iniciada.'; END IF;
    v_manifesto := public.mc_manifesto_parada_motorista(p_entrega_id)||jsonb_build_object('ordem',v_ordem);
    IF jsonb_array_length(v_manifesto->'itens')=0 OR
      ARRAY(SELECT j->>'id' FROM jsonb_array_elements(v_manifesto->'itens') j ORDER BY 1)
      IS DISTINCT FROM ARRAY(SELECT DISTINCT id FROM unnest(coalesce(p_itens,'{}'::text[])) id ORDER BY 1) THEN
      RAISE EXCEPTION 'Confira todos os itens da parada. Se a lista mudou, atualize a tela.';
    END IF;
    INSERT INTO public.rota_motorista_paradas(rota_id,entrega_id,parada,carregado_por)
    VALUES(p_rota_id,p_entrega_id,v_manifesto,v_usuario);
    RETURN;
  END IF;

  IF v_operacao.carregado_em IS NULL OR v_rota.motorista_inicio_em IS NULL THEN
    RAISE EXCEPTION 'Confirme o carregamento e inicie a rota primeiro.';
  END IF;

  IF p_acao='entregar' THEN
    IF length(btrim(coalesce(p_recebedor,''))) NOT BETWEEN 1 AND 150 THEN
      RAISE EXCEPTION 'Informe o nome de quem assinou.';
    END IF;
    IF p_assinatura IS NULL OR length(p_assinatura) NOT BETWEEN 100 AND 500000
      OR p_assinatura !~ '^data:image/png;base64,iVBORw0KGgo[A-Za-z0-9+/]+={0,2}$' THEN
      RAISE EXCEPTION 'Colha a assinatura do cliente antes de confirmar.';
    END IF;
    UPDATE public.rota_motorista_paradas SET entregue_em=now(),entregue_por=v_usuario,
      recebedor=btrim(p_recebedor),assinatura=p_assinatura WHERE rota_id=p_rota_id AND entrega_id=p_entrega_id;
    UPDATE public.entregas_equipamentos SET status='concluida',concluida_em=now(),
      concluida_por=v_usuario WHERE id=p_entrega_id;
    RETURN;
  END IF;

  IF p_tipo IS DISTINCT FROM 'nao_consegui_entregar' OR length(btrim(coalesce(p_motivo,''))) NOT BETWEEN 1 AND 2000 THEN
    RAISE EXCEPTION 'Selecione o tipo da intercorrência e descreva o motivo.';
  END IF;
  UPDATE public.rota_motorista_paradas SET intercorrencia_tipo=p_tipo,intercorrencia_motivo=btrim(p_motivo),
    intercorrencia_em=now(),intercorrencia_por=v_usuario WHERE rota_id=p_rota_id AND entrega_id=p_entrega_id;

  -- Retira da rota ativa e reabre a mesma demanda na fila da Manutenção.
  -- O manifesto e a intercorrência ficam no histórico desta tentativa.
  DELETE FROM public.rota_equipamento_itens WHERE rota_id=p_rota_id AND entrega_id=p_entrega_id;
  UPDATE public.entregas_equipamentos SET status='pendente',data_prevista=NULL,programada_em=NULL,
    ultima_intercorrencia_motorista=btrim(p_motivo) WHERE id=p_entrega_id;
END;
$fn$;

-- Impede que a baixa antiga contorne assinatura e checkout nas rotas de motorista.
-- Para a Logística, continua valendo o fluxo de baixa anterior.
CREATE OR REPLACE FUNCTION public.mc_validar_execucao_frota()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE
  v_rota public.rotas_equipamentos%ROWTYPE;
BEGIN
  IF TG_OP = 'DELETE' THEN
    SELECT * INTO v_rota FROM public.rotas_equipamentos WHERE id = OLD.rota_id FOR UPDATE;
    IF v_rota.setor_responsavel='manutencao' AND v_rota.motorista_inicio_em IS NOT NULL
      AND EXISTS (SELECT 1 FROM public.rota_motorista_paradas p
        WHERE p.rota_id=OLD.rota_id AND p.entrega_id=OLD.entrega_id AND p.intercorrencia_em IS NOT NULL) THEN
      RETURN OLD;
    END IF;
    IF v_rota.setor_responsavel IS NOT NULL AND EXISTS (
      SELECT 1 FROM public.rota_equipamento_itens i
      JOIN public.entregas_equipamentos d ON d.id = i.entrega_id
      WHERE i.rota_id = OLD.rota_id AND d.status = 'concluida'
    ) THEN
      RAISE EXCEPTION 'A rota possui uma parada concluída e não pode ser desmontada.';
    END IF;
    RETURN OLD;
  END IF;

  IF NEW.status = 'concluida' AND OLD.status IS DISTINCT FROM NEW.status THEN
    SELECT r.* INTO v_rota FROM public.rotas_equipamentos r
    JOIN public.rota_equipamento_itens i ON i.rota_id = r.id
    WHERE i.entrega_id = NEW.id AND r.setor_responsavel IS NOT NULL;
    IF FOUND AND NOT public.mc_pode_executar_rota_frota(v_rota.setor_responsavel, v_rota.caminhao_equipamentos_id) THEN
      RAISE EXCEPTION 'A parada deve ser concluída pelo setor responsável pela rota.';
    END IF;
    IF FOUND AND (
      NOT EXISTS (SELECT 1 FROM public.rota_programacao_aprovacoes a
        WHERE a.rota_id = v_rota.id AND a.entrega_id = NEW.id)
      OR EXISTS (SELECT 1 FROM public.rota_programacao_aprovacoes a
        WHERE a.rota_id = v_rota.id AND a.entrega_id = NEW.id AND a.status IS DISTINCT FROM 'aprovado')
    ) THEN
      RAISE EXCEPTION 'A data desta parada precisa da aprovação do Supervisor.';
    END IF;
  END IF;
  RETURN NEW;
END;
$fn$;

CREATE OR REPLACE FUNCTION public.mc_proteger_etapas_motorista()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE v_rota public.rotas_equipamentos%ROWTYPE;
BEGIN
  IF TG_TABLE_NAME='rotas_equipamentos' THEN
    IF TG_OP='UPDATE' THEN
      IF NEW.setor_responsavel='manutencao' AND OLD.concluida_em IS NULL AND NEW.concluida_em IS NOT NULL
        AND (NEW.motorista_checkout_por IS NULL OR NEW.motorista_checkout_por IS DISTINCT FROM auth.uid()
          OR NOT public.mc_pode_executar_rota_frota(NEW.setor_responsavel,NEW.caminhao_equipamentos_id)
          OR OLD.motorista_inicio_em IS NULL
          OR EXISTS (SELECT 1 FROM public.rota_equipamento_itens i
            JOIN public.entregas_equipamentos d ON d.id=i.entrega_id
            WHERE i.rota_id=OLD.id AND d.status IS DISTINCT FROM 'concluida')) THEN
        RAISE EXCEPTION 'A rota deve ser encerrada pelo checkout do motorista.';
      END IF;
      RETURN NEW;
    END IF;
    IF OLD.setor_responsavel='manutencao' AND OLD.motorista_inicio_em IS NOT NULL THEN
      RAISE EXCEPTION 'Uma rota iniciada pelo motorista não pode ser desmontada.';
    END IF;
    RETURN OLD;
  END IF;

  IF TG_OP='DELETE' THEN
    SELECT * INTO v_rota FROM public.rotas_equipamentos WHERE id=OLD.rota_id FOR UPDATE;
    IF v_rota.setor_responsavel='manutencao' AND v_rota.motorista_inicio_em IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM public.rota_motorista_paradas p
        WHERE p.rota_id=OLD.rota_id AND p.entrega_id=OLD.entrega_id AND p.intercorrencia_em IS NOT NULL) THEN
      RAISE EXCEPTION 'Uma rota iniciada só pode liberar paradas por intercorrência do motorista.';
    END IF;
    RETURN OLD;
  END IF;

  IF NEW.status='concluida' AND OLD.status IS DISTINCT FROM NEW.status AND EXISTS (
    SELECT 1 FROM public.rota_equipamento_itens i JOIN public.rotas_equipamentos r ON r.id=i.rota_id
    LEFT JOIN public.rota_motorista_paradas p ON p.rota_id=i.rota_id AND p.entrega_id=i.entrega_id
    WHERE i.entrega_id=NEW.id AND r.setor_responsavel='manutencao' AND p.entregue_em IS NULL
  ) THEN
    RAISE EXCEPTION 'A entrega precisa ser confirmada no módulo do motorista com a assinatura do cliente.';
  END IF;
  RETURN NEW;
END;
$fn$;
DROP TRIGGER IF EXISTS trg_mc_proteger_baixa_motorista ON public.entregas_equipamentos;
CREATE TRIGGER trg_mc_proteger_baixa_motorista BEFORE UPDATE OF status ON public.entregas_equipamentos
  FOR EACH ROW EXECUTE FUNCTION public.mc_proteger_etapas_motorista();
DROP TRIGGER IF EXISTS trg_mc_proteger_item_motorista ON public.rota_equipamento_itens;
CREATE TRIGGER trg_mc_proteger_item_motorista BEFORE DELETE ON public.rota_equipamento_itens
  FOR EACH ROW EXECUTE FUNCTION public.mc_proteger_etapas_motorista();
DROP TRIGGER IF EXISTS trg_mc_proteger_rota_motorista ON public.rotas_equipamentos;
CREATE TRIGGER trg_mc_proteger_rota_motorista BEFORE DELETE OR UPDATE OF concluida_em ON public.rotas_equipamentos
  FOR EACH ROW EXECUTE FUNCTION public.mc_proteger_etapas_motorista();

REVOKE ALL ON FUNCTION public.mc_manifesto_parada_motorista(uuid),public.mc_parada_motorista_aprovada(uuid,uuid),
  public.mc_proteger_etapas_motorista() FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.mc_listar_rotas_motorista(),
  public.mc_registrar_etapa_motorista(uuid,text,uuid,text[],text,text,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.mc_listar_rotas_motorista(),
  public.mc_registrar_etapa_motorista(uuid,text,uuid,text[],text,text,text,text) TO authenticated;

NOTIFY pgrst,'reload schema';
COMMIT;
