-- Reutiliza a fila de programação dos supervisores para todas as demandas de rota.
BEGIN;

CREATE OR REPLACE FUNCTION public.mc_enviar_programacao_manutencao(p_rota_id uuid)
RETURNS uuid[]
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $fn$
DECLARE
  v_data_rota date;
  v_demanda record;
  v_supervisor uuid;
  v_supervisores uuid[];
  v_tem_demanda boolean := false;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.usuarios u
    WHERE u.id = auth.uid() AND u.ativo IS DISTINCT FROM false
      AND u.papel IN ('admin', 'manutencao')
  ) THEN
    RAISE EXCEPTION 'Somente a Manutenção ou o Administrador pode enviar a programação.';
  END IF;

  SELECT r.data_rota INTO v_data_rota
  FROM public.rotas_equipamentos r
  WHERE r.id = p_rota_id FOR UPDATE;

  IF NOT FOUND OR v_data_rota IS NULL THEN
    RAISE EXCEPTION 'Selecione uma rota com data programada.';
  END IF;

  FOR v_demanda IN
    SELECT DISTINCT d.id, c.vendedor_id AS vendedor_cliente,
           f.vendedor_id AS vendedor_ficha, s.solicitante_id,
           coalesce(nullif(c.codigo_totvs, ''), nullif(c.razao_social, ''),
                    nullif(f.razao_social, ''), d.id::text) AS cliente
    FROM public.rota_equipamento_itens i
    JOIN public.entregas_equipamentos d ON d.id = i.entrega_id
    LEFT JOIN public.solicitacoes s ON s.id = d.solicitacao_id
    LEFT JOIN public.clientes c ON c.id = coalesce(d.cliente_id, s.cliente_id)
    LEFT JOIN public.fichas_clientes f ON f.id = d.ficha_id
    WHERE i.rota_id = p_rota_id AND d.status = 'roteirizada'
      AND coalesce(d.tipo_demanda, 'envio') IN ('envio', 'entrega', 'troca', 'retirada')
  LOOP
    v_tem_demanda := true;

    IF EXISTS (
      SELECT 1 FROM public.rota_programacao_aprovacoes a
      WHERE a.rota_id = p_rota_id AND a.entrega_id = v_demanda.id
    ) THEN
      IF EXISTS (
        SELECT 1 FROM public.rota_programacao_aprovacoes a
        LEFT JOIN public.usuarios u ON u.id = a.supervisor_id
        WHERE a.rota_id = p_rota_id AND a.entrega_id = v_demanda.id
          AND a.status = 'pendente'
          AND (u.papel IS DISTINCT FROM 'supervisor' OR u.ativo IS FALSE)
      ) THEN
        RAISE EXCEPTION 'O cliente % possui uma programação atribuída a um supervisor indisponível.', v_demanda.cliente;
      END IF;
      CONTINUE;
    END IF;

    -- Usa a carteira comercial e, na ausência de vínculo, a ficha ou a solicitação.
    SELECT supervisor.id INTO v_supervisor
    FROM unnest(ARRAY[v_demanda.vendedor_cliente, v_demanda.vendedor_ficha,
                      v_demanda.solicitante_id]) WITH ORDINALITY AS origem(usuario_id, ordem)
    JOIN public.usuarios responsavel ON responsavel.id = origem.usuario_id
    JOIN public.usuarios supervisor
      ON supervisor.id = CASE WHEN responsavel.papel = 'supervisor'
                              THEN responsavel.id ELSE responsavel.supervisor_id END
    WHERE supervisor.papel = 'supervisor' AND supervisor.ativo IS DISTINCT FROM false
    ORDER BY origem.ordem
    LIMIT 1;

    IF v_supervisor IS NULL THEN
      RAISE EXCEPTION 'Vincule um supervisor comercial ativo ao cliente % antes de enviar a programação.', v_demanda.cliente;
    END IF;

    INSERT INTO public.rota_programacao_aprovacoes
      (rota_id, entrega_id, supervisor_id, status, criado_em, enviado_em)
    VALUES (p_rota_id, v_demanda.id, v_supervisor, 'pendente', now(), now());
  END LOOP;

  IF NOT v_tem_demanda THEN
    RAISE EXCEPTION 'A rota não possui entregas, trocas ou retiradas roteirizadas.';
  END IF;

  UPDATE public.rota_programacao_aprovacoes a
  SET enviado_em = now()
  FROM public.rota_equipamento_itens i, public.entregas_equipamentos d
  WHERE a.rota_id = p_rota_id AND i.rota_id = a.rota_id
    AND i.entrega_id = a.entrega_id AND d.id = i.entrega_id
    AND d.status = 'roteirizada'
    AND coalesce(d.tipo_demanda, 'envio') IN ('envio', 'entrega', 'troca', 'retirada')
    AND a.status = 'pendente' AND a.enviado_em IS NULL;

  SELECT coalesce(array_agg(DISTINCT a.supervisor_id), '{}'::uuid[]) INTO v_supervisores
  FROM public.rota_programacao_aprovacoes a
  JOIN public.rota_equipamento_itens i ON i.rota_id = a.rota_id AND i.entrega_id = a.entrega_id
  JOIN public.entregas_equipamentos d ON d.id = i.entrega_id
  WHERE a.rota_id = p_rota_id AND a.status = 'pendente' AND a.enviado_em IS NOT NULL
    AND d.status = 'roteirizada'
    AND coalesce(d.tipo_demanda, 'envio') IN ('envio', 'entrega', 'troca', 'retirada');

  RETURN v_supervisores;
END;
$fn$;

REVOKE ALL ON FUNCTION public.mc_enviar_programacao_manutencao(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.mc_enviar_programacao_manutencao(uuid) TO authenticated;

-- A fila retorna somente as programações do supervisor autenticado.
-- A data e os dados operacionais vêm juntos, mesmo se a ficha ou a rota tiver RLS própria.
CREATE OR REPLACE FUNCTION public.mc_listar_programacoes_supervisor()
RETURNS TABLE (
  id text, supervisor_id uuid, rota_id uuid, entrega_id uuid,
  rota jsonb, demanda jsonb, cliente jsonb
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $fn$
  SELECT a.id::text, a.supervisor_id, a.rota_id, a.entrega_id,
         jsonb_build_object('nome', r.nome, 'data_rota', r.data_rota),
         jsonb_build_object(
           'tipo_demanda', coalesce(d.tipo_demanda, 'envio'),
           'equipamento_resumo', d.equipamento_resumo,
           'equipamento_coleta', d.equipamento_coleta,
           'patrimonio_coleta', d.patrimonio_coleta,
           'equipamento_entrega', d.equipamento_entrega,
           'patrimonio_entrega', d.patrimonio_entrega,
           'endereco_rua', d.endereco_rua, 'endereco_numero', d.endereco_numero,
           'endereco_bairro', d.endereco_bairro, 'endereco_cidade', d.endereco_cidade,
           'endereco_estado', d.endereco_estado, 'endereco_cep', d.endereco_cep,
           'data_prevista', d.data_prevista
         ),
         jsonb_build_object(
           'codigo_totvs', c.codigo_totvs,
           'razao_social', coalesce(c.razao_social, f.razao_social),
           'nome_fantasia', coalesce(c.nome_fantasia, f.nome_fantasia)
         )
  FROM public.rota_programacao_aprovacoes a
  JOIN public.rotas_equipamentos r ON r.id = a.rota_id
  JOIN public.entregas_equipamentos d ON d.id = a.entrega_id
  JOIN public.usuarios u ON u.id = auth.uid() AND u.ativo IS DISTINCT FROM false
  LEFT JOIN public.solicitacoes s ON s.id = d.solicitacao_id
  LEFT JOIN public.clientes c ON c.id = coalesce(d.cliente_id, s.cliente_id)
  LEFT JOIN public.fichas_clientes f ON f.id = d.ficha_id
  WHERE (u.papel = 'admin' OR (u.papel = 'supervisor' AND a.supervisor_id = u.id))
    AND a.status = 'pendente' AND a.enviado_em IS NOT NULL
    AND EXISTS (
      SELECT 1 FROM public.rota_equipamento_itens i
      WHERE i.rota_id = a.rota_id AND i.entrega_id = a.entrega_id
    )
    AND d.status = 'roteirizada'
    AND coalesce(d.tipo_demanda, 'envio') IN ('envio', 'entrega', 'troca', 'retirada')
  ORDER BY a.criado_em DESC, a.id
$fn$;

REVOKE ALL ON FUNCTION public.mc_listar_programacoes_supervisor() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.mc_listar_programacoes_supervisor() TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
