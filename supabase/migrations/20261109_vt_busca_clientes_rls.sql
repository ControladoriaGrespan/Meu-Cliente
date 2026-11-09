-- MEU CLIENTE / GRESPAN - busca de clientes para Visita Tecnica
-- 2026-11-09. Executar uma vez no Supabase SQL Editor.
-- Resolve clientes invisiveis por RLS, sem liberar SELECT global na tabela.
-- Apenas usuarios autenticados de perfis tecnicos, coordenador e admin.
-- Nenhum dado e alterado.

CREATE OR REPLACE FUNCTION public.vt_buscar_clientes(p_busca text, p_limite integer DEFAULT 80)
RETURNS TABLE (
  id uuid,
  codigo_totvs text,
  razao_social text,
  nome_fantasia text,
  cidade text,
  estado text,
  vendedor_id uuid,
  endereco_logradouro text,
  endereco_numero text,
  endereco_bairro text,
  endereco_cep text,
  endereco_complemento text,
  dentro_carteira boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_papel text;
  v_supervisor uuid;
  v_termo text;
  v_partes text[];
BEGIN
  SELECT u.papel::text INTO v_papel
    FROM public.usuarios u
   WHERE u.id = auth.uid() AND u.ativo IS DISTINCT FROM false;
  IF v_papel IS NULL OR v_papel NOT IN (
    'admin','coordenador','gestao_adm_vendas',
    'supervisor_tec_panificacao','lider_tec_panificacao','tec_panificacao'
  ) THEN
    RAISE EXCEPTION 'Perfil sem permissao de consulta de clientes para visitas';
  END IF;

  v_termo := btrim(coalesce(p_busca,''));
  IF length(v_termo) < 2 OR length(v_termo) > 100 THEN
    RAISE EXCEPTION 'Informe de 2 a 100 caracteres para pesquisar';
  END IF;
  IF p_limite IS NULL OR p_limite < 1 OR p_limite > 100 THEN
    RAISE EXCEPTION 'Limite fora do intervalo 1 a 100';
  END IF;

  -- Mesmo supervisor territorial empregado no agendamento de equipe.
  IF v_papel = 'supervisor_tec_panificacao' THEN v_supervisor := auth.uid();
  ELSIF v_papel = 'lider_tec_panificacao' THEN
    SELECT u.supervisor_id INTO v_supervisor FROM public.usuarios u WHERE u.id=auth.uid();
  ELSIF v_papel = 'tec_panificacao' THEN
    SELECT l.supervisor_id INTO v_supervisor
      FROM public.usuarios t JOIN public.usuarios l ON l.id=t.supervisor_id
     WHERE t.id=auth.uid();
  END IF;

  v_partes := regexp_split_to_array(v_termo,'[[:space:]]+');

  RETURN QUERY
  SELECT
    c.id, c.codigo_totvs::text, c.razao_social::text, c.nome_fantasia::text,
    c.cidade::text, c.estado::text, c.vendedor_id,
    CASE WHEN x.autorizado THEN c.endereco_logradouro::text ELSE NULL::text END,
    CASE WHEN x.autorizado THEN c.endereco_numero::text ELSE NULL::text END,
    CASE WHEN x.autorizado THEN c.endereco_bairro::text ELSE NULL::text END,
    CASE WHEN x.autorizado THEN c.endereco_cep::text ELSE NULL::text END,
    CASE WHEN x.autorizado THEN c.endereco_complemento::text ELSE NULL::text END,
    x.autorizado
  FROM public.clientes c
  LEFT JOIN public.usuarios vend ON vend.id=c.vendedor_id
  CROSS JOIN LATERAL (
    SELECT (
      v_papel IN ('admin','coordenador','gestao_adm_vendas')
      OR EXISTS (
        SELECT 1 FROM public.vt_supervisor_comercial_tecnico vinc
        WHERE vinc.supervisor_tecnico_id=v_supervisor
          AND vinc.supervisor_comercial_id=vend.supervisor_id
      )
    ) AS autorizado
  ) x
  WHERE NOT EXISTS (
    SELECT 1 FROM unnest(v_partes) t(palavra)
    WHERE NOT (
      coalesce(c.codigo_totvs::text,'') ILIKE '%' || regexp_replace(t.palavra, '[%_]', '', 'g') || '%'
      OR coalesce(c.razao_social::text,'') ILIKE '%' || regexp_replace(t.palavra, '[%_]', '', 'g') || '%'
      OR coalesce(c.nome_fantasia::text,'') ILIKE '%' || regexp_replace(t.palavra, '[%_]', '', 'g') || '%'
    )
  )
  ORDER BY CASE WHEN c.codigo_totvs::text=v_termo THEN 0 ELSE 1 END, c.razao_social
  LIMIT p_limite;
END;
$$;

REVOKE ALL ON FUNCTION public.vt_buscar_clientes(text,integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.vt_buscar_clientes(text,integer) TO authenticated;

-- Diagnostico para administrador via SQL Editor:
-- SELECT codigo_totvs, razao_social, nome_fantasia FROM public.clientes
-- WHERE codigo_totvs ILIKE '%004371%' OR razao_social ILIKE '%Center%' OR nome_fantasia ILIKE '%Center%';
