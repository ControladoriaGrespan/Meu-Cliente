-- Meu Cliente: periodicidade do técnico e anexos privados da ficha
-- Aplicar no SQL Editor do Supabase do ambiente correto ANTES de testar a nova tela.
BEGIN;
ALTER TABLE public.fichas_clientes
  ADD COLUMN IF NOT EXISTS tecnico_periodicidade text;
ALTER TABLE public.fichas_clientes
  DROP CONSTRAINT IF EXISTS fichas_tecnico_periodicidade_check;
ALTER TABLE public.fichas_clientes
  ADD CONSTRAINT fichas_tecnico_periodicidade_check
  CHECK (tecnico_periodicidade IS NULL OR tecnico_periodicidade IN ('Diário','Semanal','Quinzenal','Mensal'));

INSERT INTO storage.buckets (id,name,public,file_size_limit,allowed_mime_types)
VALUES ('fichas-documentos','fichas-documentos',false,10485760,ARRAY['application/pdf','image/png','image/jpeg','image/webp'])
ON CONFLICT (id) DO UPDATE SET public=false,file_size_limit=10485760,allowed_mime_types=EXCLUDED.allowed_mime_types;

CREATE TABLE IF NOT EXISTS public.ficha_documentos (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ficha_id uuid NOT NULL REFERENCES public.fichas_clientes(id) ON DELETE CASCADE,
  nome_arquivo text NOT NULL,
  caminho_storage text NOT NULL UNIQUE,
  tipo_mime text,
  tamanho_bytes bigint NOT NULL CHECK (tamanho_bytes BETWEEN 0 AND 10485760),
  enviado_por uuid NOT NULL REFERENCES auth.users(id),
  criado_em timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ficha_documentos_ficha_idx ON public.ficha_documentos(ficha_id);
ALTER TABLE public.ficha_documentos ENABLE ROW LEVEL SECURITY;
GRANT SELECT,INSERT ON public.ficha_documentos TO authenticated;

-- Confere no banco, não no navegador, se o usuário autenticado é o vendedor da ficha.
CREATE OR REPLACE FUNCTION public.eh_vendedor_ficha(p_ficha uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$ SELECT EXISTS (
 SELECT 1 FROM public.fichas_clientes f
 WHERE f.id=p_ficha AND f.vendedor_id=(SELECT auth.uid())
) $$;
REVOKE ALL ON FUNCTION public.eh_vendedor_ficha(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.eh_vendedor_ficha(uuid) TO authenticated;

DROP POLICY IF EXISTS ficha_documentos_select_vendedor ON public.ficha_documentos;
CREATE POLICY ficha_documentos_select_vendedor ON public.ficha_documentos
FOR SELECT TO authenticated USING (public.eh_vendedor_ficha(ficha_id));

DROP POLICY IF EXISTS ficha_documentos_insert_vendedor ON public.ficha_documentos;
CREATE POLICY ficha_documentos_insert_vendedor ON public.ficha_documentos
FOR INSERT TO authenticated WITH CHECK (
 enviado_por=(SELECT auth.uid()) AND public.eh_vendedor_ficha(ficha_id)
 AND split_part(caminho_storage,'/',1)=ficha_id::text
);

DROP POLICY IF EXISTS fichas_documentos_storage_insert ON storage.objects;
CREATE POLICY fichas_documentos_storage_insert ON storage.objects
FOR INSERT TO authenticated WITH CHECK (
 bucket_id='fichas-documentos'
 AND public.eh_vendedor_ficha(
   CASE WHEN split_part(name,'/',1) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
   THEN split_part(name,'/',1)::uuid ELSE NULL END
 )
);
DROP POLICY IF EXISTS fichas_documentos_storage_select ON storage.objects;
CREATE POLICY fichas_documentos_storage_select ON storage.objects
FOR SELECT TO authenticated USING (
 bucket_id='fichas-documentos'
 AND public.eh_vendedor_ficha(
   CASE WHEN split_part(name,'/',1) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
   THEN split_part(name,'/',1)::uuid ELSE NULL END
 )
);
-- Remoção restrita ao proprietário para limpar falhas de registro após o upload.
DROP POLICY IF EXISTS fichas_documentos_storage_delete ON storage.objects;
CREATE POLICY fichas_documentos_storage_delete ON storage.objects
FOR DELETE TO authenticated USING (
 bucket_id='fichas-documentos'
 AND public.eh_vendedor_ficha(
   CASE WHEN split_part(name,'/',1) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
   THEN split_part(name,'/',1)::uuid ELSE NULL END
 )
);
COMMIT;
