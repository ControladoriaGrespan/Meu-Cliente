-- Meu Cliente - confirmação manual de descontos no Protheus
-- Execute no Supabase SQL Editor antes de usar a nova tela.
BEGIN;

CREATE TABLE IF NOT EXISTS public.bonificacao_descontos_protheus (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  apropriacao_id uuid NOT NULL UNIQUE REFERENCES public.bonificacao_apropriacoes(id),
  pedido_id uuid NOT NULL REFERENCES public.pedidos(id),
  valor_confirmado numeric(15,2) NOT NULL CHECK (valor_confirmado > 0),
  pedido_protheus text,
  observacao text,
  confirmado_por uuid NOT NULL,
  confirmado_em timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS bonif_descontos_protheus_pedido_idx
  ON public.bonificacao_descontos_protheus(pedido_id);

ALTER TABLE public.bonificacao_descontos_protheus ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.bonificacao_descontos_protheus FROM anon, authenticated;
GRANT SELECT ON public.bonificacao_descontos_protheus TO authenticated;

DROP POLICY IF EXISTS bonif_descontos_protheus_leitura
  ON public.bonificacao_descontos_protheus;
CREATE POLICY bonif_descontos_protheus_leitura
  ON public.bonificacao_descontos_protheus FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.usuarios u
      WHERE u.id=auth.uid() AND u.ativo=true
      AND u.papel::text IN ('admin','financeiro','adm_vendas','gestao_adm_vendas')
    )
  );

CREATE OR REPLACE FUNCTION public.confirmar_desconto_protheus(
  p_apropriacao_id uuid,
  p_pedido_protheus text DEFAULT NULL,
  p_observacao text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp
AS $func$
DECLARE v_ap public.bonificacao_apropriacoes%ROWTYPE; v_id uuid;
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS(
    SELECT 1 FROM public.usuarios u
    WHERE u.id=auth.uid() AND u.ativo=true
    AND u.papel::text IN ('admin','financeiro','adm_vendas','gestao_adm_vendas')
  ) THEN
    RAISE EXCEPTION 'Usuário sem permissão para confirmar desconto no Protheus';
  END IF;

  SELECT * INTO v_ap FROM public.bonificacao_apropriacoes
    WHERE id=p_apropriacao_id FOR UPDATE;
  IF NOT FOUND OR v_ap.estornado_em IS NOT NULL OR v_ap.modalidade<>'Desconto' THEN
    RAISE EXCEPTION 'Apropriação não encontrada, estornada ou não é desconto';
  END IF;
  IF EXISTS(SELECT 1 FROM public.bonificacao_descontos_protheus
            WHERE apropriacao_id=p_apropriacao_id) THEN
    RAISE EXCEPTION 'Este desconto já foi confirmado no Protheus';
  END IF;
  IF length(trim(coalesce(p_pedido_protheus,'')))<1 THEN
    RAISE EXCEPTION 'Informe o número do pedido no Protheus';
  END IF;

  INSERT INTO public.bonificacao_descontos_protheus
    (apropriacao_id,pedido_id,valor_confirmado,pedido_protheus,observacao,confirmado_por)
  VALUES
    (v_ap.id,v_ap.pedido_id,v_ap.valor,trim(p_pedido_protheus),
     nullif(trim(p_observacao),''),auth.uid())
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$func$;

REVOKE ALL ON FUNCTION public.confirmar_desconto_protheus(uuid,text,text)
  FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.confirmar_desconto_protheus(uuid,text,text)
  TO authenticated;

COMMIT;
