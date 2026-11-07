-- MEU CLIENTE - historico de exportacoes TOTVS
BEGIN;
CREATE TABLE IF NOT EXISTS public.totvs_exportacoes (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 rota_id uuid NOT NULL, data_pedido date NOT NULL,
 usuario_id uuid NOT NULL DEFAULT auth.uid(),
 gerado_em timestamptz NOT NULL DEFAULT now(),
 tentativa integer NOT NULL CHECK(tentativa>=1),
 tipo text NOT NULL CHECK(tipo IN ('inicial','reexportacao')),
 motivo_reexportacao text,
 arquivos jsonb NOT NULL CHECK(jsonb_typeof(arquivos)='array' AND jsonb_array_length(arquivos)>0),
 pedidos jsonb NOT NULL CHECK(jsonb_typeof(pedidos)='array' AND jsonb_array_length(pedidos)>0),
 itens_quantidade integer NOT NULL CHECK(itens_quantidade>0),
 assinatura_conteudo text NOT NULL,
 status text NOT NULL DEFAULT 'preparado_download' CHECK(status='preparado_download')
);
CREATE INDEX IF NOT EXISTS idx_totvs_exportacoes_rota_data ON public.totvs_exportacoes(rota_id,data_pedido,gerado_em DESC);
ALTER TABLE public.totvs_exportacoes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.totvs_exportacoes FROM anon,authenticated;
GRANT SELECT ON public.totvs_exportacoes TO authenticated;
DROP POLICY IF EXISTS totvs_exportacoes_leitura ON public.totvs_exportacoes;
CREATE POLICY totvs_exportacoes_leitura ON public.totvs_exportacoes FOR SELECT TO authenticated
 USING(EXISTS(SELECT 1 FROM public.usuarios u WHERE u.id=auth.uid() AND u.ativo=true));
CREATE OR REPLACE FUNCTION public.registrar_exportacao_totvs(
 p_rota_id uuid,p_data_pedido date,p_arquivos jsonb,p_pedidos jsonb,
 p_itens_quantidade integer,p_assinatura_conteudo text,p_motivo_reexportacao text DEFAULT NULL
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $body$
DECLARE v_user uuid;v_tentativa integer;v_id uuid;
BEGIN
 v_user:=auth.uid();
 IF v_user IS NULL OR NOT EXISTS(SELECT 1 FROM public.usuarios u WHERE u.id=v_user AND u.ativo=true) THEN
  RAISE EXCEPTION 'Usuario sem acesso para registrar exportacao';
 END IF;
 IF p_rota_id IS NULL OR p_data_pedido IS NULL OR p_arquivos IS NULL OR p_pedidos IS NULL
 OR jsonb_typeof(p_arquivos) IS DISTINCT FROM 'array' OR jsonb_typeof(p_pedidos) IS DISTINCT FROM 'array'
 OR jsonb_array_length(p_arquivos)=0 OR jsonb_array_length(p_pedidos)=0
 OR p_itens_quantidade IS NULL OR p_itens_quantidade<=0
 OR length(trim(coalesce(p_assinatura_conteudo,'')))<8 THEN
  RAISE EXCEPTION 'Dados de exportacao incompletos';
 END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(p_rota_id::text||':'||p_data_pedido::text,0));
 SELECT coalesce(max(tentativa),0)+1 INTO v_tentativa FROM public.totvs_exportacoes WHERE rota_id=p_rota_id AND data_pedido=p_data_pedido;
 IF v_tentativa>1 AND length(trim(coalesce(p_motivo_reexportacao,'')))<10 THEN
  RAISE EXCEPTION 'Reexportacao exige justificativa com pelo menos 10 caracteres';
 END IF;
 INSERT INTO public.totvs_exportacoes(rota_id,data_pedido,usuario_id,tentativa,tipo,motivo_reexportacao,arquivos,pedidos,itens_quantidade,assinatura_conteudo)
 VALUES(p_rota_id,p_data_pedido,v_user,v_tentativa,CASE WHEN v_tentativa=1 THEN 'inicial' ELSE 'reexportacao' END,
 CASE WHEN v_tentativa=1 THEN NULL ELSE trim(p_motivo_reexportacao) END,p_arquivos,p_pedidos,p_itens_quantidade,p_assinatura_conteudo)
 RETURNING id INTO v_id;
 RETURN v_id;
END;
$body$;
REVOKE ALL ON FUNCTION public.registrar_exportacao_totvs(uuid,date,jsonb,jsonb,integer,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.registrar_exportacao_totvs(uuid,date,jsonb,jsonb,integer,text,text) TO authenticated;
COMMIT;