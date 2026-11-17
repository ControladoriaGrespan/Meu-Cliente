BEGIN;

ALTER TABLE public.ficha_documentos
  ADD COLUMN IF NOT EXISTS tipo_documento text,
  ADD COLUMN IF NOT EXISTS origem_documento text;

-- A leitura dos anexos segue a política de leitura da própria ficha.
DROP POLICY IF EXISTS ficha_documentos_select_vendedor ON public.ficha_documentos;
DROP POLICY IF EXISTS ficha_documentos_select_ficha ON public.ficha_documentos;
CREATE POLICY ficha_documentos_select_ficha ON public.ficha_documentos
FOR SELECT TO authenticated USING (
  EXISTS (SELECT 1 FROM public.fichas_clientes f WHERE f.id=ficha_documentos.ficha_id)
);

DROP POLICY IF EXISTS fichas_documentos_storage_select ON storage.objects;
CREATE POLICY fichas_documentos_storage_select ON storage.objects
FOR SELECT TO authenticated USING (
  bucket_id='fichas-documentos' AND (
    EXISTS (SELECT 1 FROM public.ficha_documentos d WHERE d.caminho_storage=objects.name)
    OR public.eh_vendedor_ficha(
      CASE WHEN split_part(name,'/',1) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      THEN split_part(name,'/',1)::uuid END
    )
  )
);

CREATE TABLE IF NOT EXISTS public.ficha_reenvios (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ficha_id uuid NOT NULL REFERENCES public.fichas_clientes(id) ON DELETE CASCADE,
  etapa text NOT NULL,
  motivo_recusa text,
  recusado_por uuid,
  recusado_em timestamptz,
  reenviado_por uuid NOT NULL,
  reenviado_em timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ficha_reenvios_ficha_idx ON public.ficha_reenvios(ficha_id,reenviado_em);
ALTER TABLE public.ficha_reenvios ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ficha_reenvios FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.ficha_reenvios TO authenticated;
DROP POLICY IF EXISTS ficha_reenvios_select_ficha ON public.ficha_reenvios;
CREATE POLICY ficha_reenvios_select_ficha ON public.ficha_reenvios
FOR SELECT TO authenticated USING (
  EXISTS (SELECT 1 FROM public.fichas_clientes f WHERE f.id=ficha_reenvios.ficha_id)
);

CREATE OR REPLACE FUNCTION public.mc_reenviar_ficha_com_documentos(
  p_ficha uuid,p_aprovacao uuid,p_recusado_em timestamptz
) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
DECLARE
  v_usuario uuid := auth.uid();
  v_recusa public.ficha_aprovacoes%ROWTYPE;
BEGIN
  IF v_usuario IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.usuarios u WHERE u.id=v_usuario AND u.ativo IS TRUE
  ) THEN
    RAISE EXCEPTION 'Usuário sem acesso ativo.';
  END IF;

  PERFORM 1 FROM public.fichas_clientes f
  WHERE f.id=p_ficha AND f.vendedor_id=v_usuario FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Somente o autor da ficha pode reenviá-la.';
  END IF;

  PERFORM 1 FROM public.ficha_aprovacoes a
  WHERE a.ficha_id=p_ficha ORDER BY a.ordem,a.id FOR UPDATE;

  SELECT * INTO v_recusa FROM public.ficha_aprovacoes a
  WHERE a.ficha_id=p_ficha AND a.id=p_aprovacao AND a.status='reprovado';
  IF NOT FOUND OR v_recusa.decidido_em IS DISTINCT FROM p_recusado_em THEN
    RAISE EXCEPTION 'A recusa foi alterada. Atualize a ficha antes de tentar novamente.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.ficha_aprovacoes a WHERE a.ficha_id=p_ficha AND a.id<>v_recusa.id
      AND (
        (a.ordem<v_recusa.ordem AND a.status NOT IN ('aprovado','nao_aplica'))
        OR a.ordem=v_recusa.ordem
        OR (a.ordem>v_recusa.ordem AND a.status NOT IN ('pendente','aguardando','nao_aplica'))
      )
  ) THEN
    RAISE EXCEPTION 'A fila da ficha possui decisões incompatíveis com o reenvio.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.ficha_documentos d
    JOIN storage.objects o ON o.bucket_id='fichas-documentos' AND o.name=d.caminho_storage
    WHERE d.ficha_id=p_ficha
  ) THEN
    RAISE EXCEPTION 'Anexe pelo menos um documento antes de reenviar.';
  END IF;

  INSERT INTO public.ficha_reenvios(ficha_id,etapa,motivo_recusa,recusado_por,recusado_em,reenviado_por)
  VALUES(p_ficha,v_recusa.etapa,v_recusa.observacao,v_recusa.aprovador_id,v_recusa.decidido_em,v_usuario);

  UPDATE public.ficha_aprovacoes
  SET status='aguardando'
  WHERE ficha_id=p_ficha AND ordem>v_recusa.ordem AND status='pendente';

  UPDATE public.ficha_aprovacoes
  SET status='pendente',observacao=NULL,decidido_em=NULL,aprovador_id=NULL,criado_em=now()
  WHERE id=v_recusa.id;

  RETURN v_recusa.etapa;
END;
$fn$;

REVOKE ALL ON FUNCTION public.mc_reenviar_ficha_com_documentos(uuid,uuid,timestamptz) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.mc_reenviar_ficha_com_documentos(uuid,uuid,timestamptz) TO authenticated;

NOTIFY pgrst,'reload schema';
COMMIT;
