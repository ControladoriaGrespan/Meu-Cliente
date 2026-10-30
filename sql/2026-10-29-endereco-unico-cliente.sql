-- Endereço único por cliente. Execute no SQL Editor do Supabase antes de publicar o frontend.
alter table public.clientes add column if not exists endereco_cep text;
alter table public.clientes add column if not exists endereco_logradouro text;
alter table public.clientes add column if not exists endereco_numero text;
alter table public.clientes add column if not exists endereco_complemento text;
alter table public.clientes add column if not exists endereco_bairro text;
-- cidade e estado já existem no cadastro de clientes.
-- Permissões de UPDATE devem continuar controladas pelas políticas RLS existentes.
