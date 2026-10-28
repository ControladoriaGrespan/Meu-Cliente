ALTER TABLE public.clientes ADD COLUMN IF NOT EXISTS endereco_logradouro text;
ALTER TABLE public.clientes ADD COLUMN IF NOT EXISTS endereco_numero text;
ALTER TABLE public.clientes ADD COLUMN IF NOT EXISTS endereco_bairro text;
ALTER TABLE public.clientes ADD COLUMN IF NOT EXISTS endereco_cep text;
ALTER TABLE public.clientes ADD COLUMN IF NOT EXISTS endereco_latitude double precision;
ALTER TABLE public.clientes ADD COLUMN IF NOT EXISTS endereco_longitude double precision;
