-- Executar antes de publicar a interface de frota.
BEGIN;

-- O projeto usa papel textual. Se a instalação usar enum, acrescente
-- motorista_manutencao ao enum em uma transação separada antes desta migração.
DO $role$
DECLARE v_check text;
BEGIN
  SELECT pg_get_expr(conbin, conrelid) INTO v_check
  FROM pg_constraint
  WHERE conrelid = 'public.usuarios'::regclass AND conname = 'usuarios_papel_check';
  IF v_check IS NOT NULL AND strpos(v_check, 'motorista_manutencao') = 0 THEN
    ALTER TABLE public.usuarios DROP CONSTRAINT usuarios_papel_check;
    EXECUTE format(
      'ALTER TABLE public.usuarios ADD CONSTRAINT usuarios_papel_check CHECK ((%s) OR papel::text = %L)',
      v_check, 'motorista_manutencao'
    );
  END IF;
END;
$role$;

CREATE TABLE IF NOT EXISTS public.caminhoes_equipamentos (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  nome text NOT NULL CHECK (btrim(nome) <> ''),
  placa text UNIQUE CHECK (placa ~ '^[A-Z]{3}[0-9][A-Z0-9][0-9]{2}$'),
  propriedade text NOT NULL CHECK (propriedade IN ('manutencao', 'logistica')),
  ativo boolean NOT NULL DEFAULT true,
  CHECK (propriedade <> 'manutencao' OR placa IS NOT NULL)
);

ALTER TABLE public.usuarios ADD COLUMN IF NOT EXISTS caminhao_equipamentos_id uuid
  REFERENCES public.caminhoes_equipamentos(id);
CREATE UNIQUE INDEX IF NOT EXISTS usuarios_motorista_caminhao_ativo
  ON public.usuarios(caminhao_equipamentos_id)
  WHERE papel::text = 'motorista_manutencao' AND ativo IS DISTINCT FROM false;
ALTER TABLE public.rotas_equipamentos
  ADD COLUMN IF NOT EXISTS caminhao_equipamentos_id uuid REFERENCES public.caminhoes_equipamentos(id),
  ADD COLUMN IF NOT EXISTS rota_comercial_id uuid REFERENCES public.rotas(id),
  ADD COLUMN IF NOT EXISTS setor_responsavel text CHECK (setor_responsavel IN ('manutencao', 'logistica'));

ALTER TABLE public.caminhoes_equipamentos ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.caminhoes_equipamentos FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.caminhoes_equipamentos TO authenticated;

DROP POLICY IF EXISTS frota_gerenciar ON public.caminhoes_equipamentos;
CREATE POLICY frota_gerenciar ON public.caminhoes_equipamentos FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.usuarios u WHERE u.id = auth.uid()
    AND u.ativo IS DISTINCT FROM false AND u.papel IN ('admin', 'manutencao')))
  WITH CHECK (EXISTS (SELECT 1 FROM public.usuarios u WHERE u.id = auth.uid()
    AND u.ativo IS DISTINCT FROM false AND u.papel IN ('admin', 'manutencao')));

CREATE OR REPLACE FUNCTION public.mc_validar_motorista_caminhao()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $fn$
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF NEW.papel IS NOT DISTINCT FROM OLD.papel
      AND NEW.caminhao_equipamentos_id IS NOT DISTINCT FROM OLD.caminhao_equipamentos_id
      AND NEW.ativo IS NOT DISTINCT FROM OLD.ativo THEN
      RETURN NEW;
    END IF;
  END IF;
  IF NEW.papel::text <> 'motorista_manutencao' AND NEW.caminhao_equipamentos_id IS NULL THEN
    IF TG_OP = 'INSERT' THEN RETURN NEW; END IF;
    IF OLD.papel::text <> 'motorista_manutencao' AND OLD.caminhao_equipamentos_id IS NULL THEN
      RETURN NEW;
    END IF;
  END IF;

  IF auth.uid() IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.usuarios u WHERE u.id = auth.uid() AND u.papel = 'admin'
      AND u.ativo IS DISTINCT FROM false
  ) THEN
    RAISE EXCEPTION 'Somente o Administrador pode alterar o cadastro do motorista.';
  END IF;
  IF NEW.papel::text <> 'motorista_manutencao' THEN
    IF NEW.caminhao_equipamentos_id IS NOT NULL THEN
      RAISE EXCEPTION 'O vínculo de caminhão é exclusivo do Motorista (Manutenção).';
    END IF;
  ELSIF NOT EXISTS (
    SELECT 1 FROM public.caminhoes_equipamentos c WHERE c.id = NEW.caminhao_equipamentos_id
      AND c.propriedade = 'manutencao' AND c.placa IS NOT NULL
      AND (NEW.ativo IS FALSE OR c.ativo)
  ) THEN
    RAISE EXCEPTION 'Selecione a placa de um caminhão da Manutenção.';
  END IF;
  RETURN NEW;
END;
$fn$;
REVOKE ALL ON FUNCTION public.mc_validar_motorista_caminhao() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS trg_mc_validar_motorista_caminhao ON public.usuarios;
CREATE TRIGGER trg_mc_validar_motorista_caminhao BEFORE INSERT OR UPDATE OF papel, caminhao_equipamentos_id, ativo
  ON public.usuarios FOR EACH ROW EXECUTE FUNCTION public.mc_validar_motorista_caminhao();

CREATE OR REPLACE FUNCTION public.mc_rotas_comerciais_frota()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $fn$
  SELECT coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'nome', r.nome,
           'dia_semana', r.dia_semana, 'ativo', r.ativo) ORDER BY r.nome, r.dia_semana), '[]'::jsonb)
  FROM public.rotas r
  WHERE EXISTS (SELECT 1 FROM public.usuarios u WHERE u.id = auth.uid()
    AND u.ativo IS DISTINCT FROM false AND u.papel IN ('admin', 'manutencao'))
$fn$;

CREATE OR REPLACE FUNCTION public.mc_criar_rota_equipamentos_frota(
  p_nome text, p_data_rota date, p_entrega_ids uuid[], p_caminhao_id uuid, p_rota_comercial_id uuid
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE
  v_caminhao public.caminhoes_equipamentos%ROWTYPE;
  v_rota_id uuid;
  v_quantidade integer;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.usuarios u WHERE u.id = auth.uid()
    AND u.ativo IS DISTINCT FROM false AND u.papel IN ('admin', 'manutencao')) THEN
    RAISE EXCEPTION 'A criação de rotas está disponível para a Manutenção.';
  END IF;
  SELECT * INTO v_caminhao FROM public.caminhoes_equipamentos
  WHERE id = p_caminhao_id AND ativo FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Selecione um caminhão ativo.'; END IF;

  IF v_caminhao.propriedade = 'logistica' THEN
    PERFORM 1 FROM public.rotas WHERE id = p_rota_comercial_id AND ativo IS DISTINCT FROM false FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Selecione uma rota comercial ativa para a Logística.'; END IF;
  ELSIF p_rota_comercial_id IS NOT NULL THEN
    RAISE EXCEPTION 'A rota comercial deve ser informada somente para a Logística.';
  ELSIF NOT EXISTS (
    SELECT 1 FROM public.usuarios u WHERE u.caminhao_equipamentos_id = p_caminhao_id
      AND u.papel::text = 'motorista_manutencao' AND u.ativo IS DISTINCT FROM false
  ) THEN
    RAISE EXCEPTION 'Vincule um Motorista (Manutenção) ativo à placa % no cadastro de usuários.', v_caminhao.placa;
  END IF;

  IF p_data_rota IS NULL OR coalesce(cardinality(p_entrega_ids), 0) = 0 OR array_position(p_entrega_ids, NULL) IS NOT NULL THEN
    RAISE EXCEPTION 'Informe a data e selecione as demandas da rota.';
  END IF;
  PERFORM 1 FROM public.entregas_equipamentos d WHERE d.id = ANY(p_entrega_ids)
    ORDER BY d.id FOR UPDATE;
  SELECT count(DISTINCT d.id) INTO v_quantidade
  FROM public.entregas_equipamentos d
  WHERE d.id = ANY(p_entrega_ids) AND d.status = 'ag_rota'
    AND NOT EXISTS (SELECT 1 FROM public.rota_equipamento_itens i WHERE i.entrega_id = d.id);
  IF v_quantidade <> (SELECT count(DISTINCT item) FROM unnest(p_entrega_ids) AS ids(item)) THEN
    RAISE EXCEPTION 'Uma ou mais demandas já foram roteirizadas ou estão indisponíveis.';
  END IF;

  -- A rotina original mantém a ordenação e as regras operacionais da rota.
  PERFORM public.criar_rota_equipamentos_segura(p_nome, p_data_rota, p_entrega_ids);
  SELECT i.rota_id INTO STRICT v_rota_id
  FROM public.rota_equipamento_itens i WHERE i.entrega_id = p_entrega_ids[1];
  IF (SELECT count(DISTINCT i.entrega_id) FROM public.rota_equipamento_itens i
      WHERE i.rota_id = v_rota_id AND i.entrega_id = ANY(p_entrega_ids)) <> v_quantidade THEN
    RAISE EXCEPTION 'A rota não recebeu todas as demandas selecionadas.';
  END IF;
  UPDATE public.rotas_equipamentos SET caminhao_equipamentos_id = p_caminhao_id,
    rota_comercial_id = p_rota_comercial_id, setor_responsavel = v_caminhao.propriedade
  WHERE id = v_rota_id;
  RETURN jsonb_build_object('rota_id', v_rota_id, 'quantidade', v_quantidade);
END;
$fn$;

-- Lista e baixa compartilham a mesma regra. A atribuição do motorista acompanha
-- o vínculo atual com a placa, inclusive em caso de troca de motorista.
CREATE OR REPLACE FUNCTION public.mc_pode_executar_rota_frota(p_setor text, p_caminhao uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $fn$
  SELECT EXISTS (
    SELECT 1 FROM public.usuarios u WHERE u.id = auth.uid() AND u.ativo IS DISTINCT FROM false
      AND (
        (p_setor = 'manutencao' AND (u.papel = 'admin' OR (u.papel::text = 'motorista_manutencao'
          AND u.caminhao_equipamentos_id = p_caminhao)))
        OR (p_setor = 'logistica' AND u.papel::text <> 'motorista_manutencao'
          AND (u.papel::text IN ('admin', 'logistica') OR EXISTS (
            SELECT 1 FROM public.usuario_modulos m WHERE m.usuario_id = u.id AND m.modulo = 'logistica' AND m.ativo
          )))
      )
  )
$fn$;

CREATE OR REPLACE FUNCTION public.mc_listar_execucao_frota(p_setor text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $fn$
  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'id', r.id, 'nome', r.nome, 'data_rota', r.data_rota, 'concluida_em', r.concluida_em,
    'caminhao', c.nome, 'placa', c.placa, 'rota_comercial', rc.nome, 'paradas', pontos.lista
  ) ORDER BY (r.concluida_em IS NOT NULL), r.data_rota, r.id), '[]'::jsonb)
  FROM public.rotas_equipamentos r
  JOIN public.caminhoes_equipamentos c ON c.id = r.caminhao_equipamentos_id
  LEFT JOIN public.rotas rc ON rc.id = r.rota_comercial_id
  CROSS JOIN LATERAL (
    SELECT jsonb_agg(jsonb_build_object(
      'id', d.id, 'ordem', i.ordem, 'status', d.status, 'tipo', d.tipo_demanda,
      'codigo', cl.codigo_totvs, 'cliente', coalesce(cl.razao_social, f.razao_social),
      'endereco', concat_ws(', ', d.endereco_rua, d.endereco_numero, d.endereco_bairro,
                            d.endereco_cidade, d.endereco_estado, d.endereco_cep),
      'equipamento', d.equipamento_resumo, 'coleta', d.equipamento_coleta, 'entrega', d.equipamento_entrega,
      'patrimonio_coleta', d.patrimonio_coleta, 'patrimonio_entrega', d.patrimonio_entrega,
      'aprovada', a.total > 0 AND a.aprovadas = a.total
    ) ORDER BY i.ordem, d.id) AS lista
    FROM public.rota_equipamento_itens i
    JOIN public.entregas_equipamentos d ON d.id = i.entrega_id
    LEFT JOIN public.solicitacoes s ON s.id = d.solicitacao_id
    LEFT JOIN public.clientes cl ON cl.id = coalesce(d.cliente_id, s.cliente_id)
    LEFT JOIN public.fichas_clientes f ON f.id = d.ficha_id
    CROSS JOIN LATERAL (
      SELECT count(*) AS total, count(*) FILTER (WHERE ap.status = 'aprovado') AS aprovadas
      FROM public.rota_programacao_aprovacoes ap WHERE ap.rota_id = r.id AND ap.entrega_id = d.id
    ) a
    WHERE i.rota_id = r.id
      AND (p_setor = 'logistica' OR d.status = 'concluida' OR (a.total > 0 AND a.aprovadas = a.total))
  ) pontos
  WHERE r.setor_responsavel = p_setor
    AND pontos.lista IS NOT NULL
    AND public.mc_pode_executar_rota_frota(r.setor_responsavel, r.caminhao_equipamentos_id)
$fn$;

CREATE OR REPLACE FUNCTION public.mc_validar_execucao_frota()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE
  v_rota public.rotas_equipamentos%ROWTYPE;
BEGIN
  IF TG_OP = 'DELETE' THEN
    SELECT * INTO v_rota FROM public.rotas_equipamentos WHERE id = OLD.rota_id FOR UPDATE;
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

REVOKE ALL ON FUNCTION public.mc_validar_execucao_frota() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS trg_mc_validar_baixa_frota ON public.entregas_equipamentos;
CREATE TRIGGER trg_mc_validar_baixa_frota BEFORE UPDATE OF status ON public.entregas_equipamentos
  FOR EACH ROW EXECUTE FUNCTION public.mc_validar_execucao_frota();
DROP TRIGGER IF EXISTS trg_mc_validar_desmontagem_frota ON public.rota_equipamento_itens;
CREATE TRIGGER trg_mc_validar_desmontagem_frota BEFORE DELETE ON public.rota_equipamento_itens
  FOR EACH ROW EXECUTE FUNCTION public.mc_validar_execucao_frota();

CREATE OR REPLACE FUNCTION public.mc_concluir_parada_frota(p_rota_id uuid, p_entrega_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE
  v_rota public.rotas_equipamentos%ROWTYPE;
  v_status text;
BEGIN
  SELECT * INTO v_rota FROM public.rotas_equipamentos WHERE id = p_rota_id FOR UPDATE;
  IF NOT FOUND OR NOT public.mc_pode_executar_rota_frota(v_rota.setor_responsavel, v_rota.caminhao_equipamentos_id) THEN
    RAISE EXCEPTION 'Esta rota não está atribuída ao seu perfil.';
  END IF;
  SELECT d.status::text INTO v_status
  FROM public.entregas_equipamentos d JOIN public.rota_equipamento_itens i ON i.entrega_id = d.id
  WHERE i.rota_id = p_rota_id AND d.id = p_entrega_id FOR UPDATE OF d;
  IF v_status = 'concluida' THEN RETURN; END IF;
  IF v_status IS DISTINCT FROM 'roteirizada' OR v_rota.concluida_em IS NOT NULL THEN
    RAISE EXCEPTION 'Esta parada não está disponível para conclusão.';
  END IF;
  UPDATE public.entregas_equipamentos
  SET status = 'concluida', concluida_em = now(), concluida_por = auth.uid()
  WHERE id = p_entrega_id;

  IF NOT EXISTS (
    SELECT 1 FROM public.rota_equipamento_itens i JOIN public.entregas_equipamentos d ON d.id = i.entrega_id
    WHERE i.rota_id = p_rota_id AND d.status IS DISTINCT FROM 'concluida'
  ) THEN
    UPDATE public.rotas_equipamentos SET concluida_em = now() WHERE id = p_rota_id;
  END IF;
END;
$fn$;

REVOKE ALL ON FUNCTION public.mc_pode_executar_rota_frota(text, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.mc_rotas_comerciais_frota(), public.mc_criar_rota_equipamentos_frota(text, date, uuid[], uuid, uuid),
  public.mc_listar_execucao_frota(text), public.mc_concluir_parada_frota(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.mc_rotas_comerciais_frota(), public.mc_criar_rota_equipamentos_frota(text, date, uuid[], uuid, uuid),
  public.mc_listar_execucao_frota(text), public.mc_concluir_parada_frota(uuid, uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
