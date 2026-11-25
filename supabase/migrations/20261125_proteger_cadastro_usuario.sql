-- Meu Cliente — Grespan
-- Segurança do cadastro de usuários.
--
-- 1) A política usuarios_update_proprio_perfil deixa cada usuário atualizar a própria
--    linha sem limitar as colunas; pelo banco, fora da tela, dava para trocar o próprio
--    perfil (papel), reativar-se ou mudar a hierarquia. O gatilho abaixo só permite ao
--    usuário comum gravar os dois campos que a tela de troca de senha usa
--    (exigir_troca_senha e senha_alterada_em). Administrador ativo continua editando tudo.
-- 2) meu_papel() passa a ignorar usuário inativo: ele deixa de ter perfil para as regras
--    de acesso (RLS). Também fixa o search_path da função.
--
-- Idempotente. Não altera nenhum dado existente.

begin;

create or replace function public.mc_proteger_cadastro_usuario()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_livres constant text[] := array['exigir_troca_senha', 'senha_alterada_em'];
begin
  -- Editor SQL, service role e rotinas internas (sem usuário logado) não são afetados.
  if (select auth.uid()) is null then
    return new;
  end if;

  -- Administrador ativo pode alterar qualquer cadastro.
  if exists (
    select 1 from public.usuarios u
    where u.id = (select auth.uid()) and u.papel = 'admin' and u.ativo is distinct from false
  ) then
    return new;
  end if;

  -- Demais usuários: nenhuma coluna além das liberadas pode mudar.
  if (to_jsonb(new) - v_livres) is distinct from (to_jsonb(old) - v_livres) then
    raise exception 'Somente o Administrador pode alterar o cadastro de usuários.'
      using errcode = '42501';
  end if;

  return new;
end;
$$;

comment on function public.mc_proteger_cadastro_usuario() is
  'Impede que usuário não administrador altere perfil, status, hierarquia ou outros dados do cadastro; libera apenas os campos da troca de senha.';

revoke all on function public.mc_proteger_cadastro_usuario() from public, anon, authenticated;

drop trigger if exists trg_mc_proteger_cadastro_usuario on public.usuarios;
create trigger trg_mc_proteger_cadastro_usuario
  before update on public.usuarios
  for each row execute function public.mc_proteger_cadastro_usuario();

-- Perfil do usuário logado; usuário inativo não tem perfil.
create or replace function public.meu_papel()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select u.papel
  from public.usuarios u
  where u.id = (select auth.uid())
    and u.ativo is distinct from false;
$$;

commit;
