-- Meu Cliente — Grespan
-- Solicitação de Troca e de Aumento de Equipamento: o solicitante informa se o equipamento
-- solicitado é Novo ou Usado.
--
--   1) solicitacoes.equipamento_condicao ('Novo' | 'Usado'; vazio nas solicitações antigas
--      e nos demais tipos).
--   2) Quando a solicitação aprovada vira demanda da Manutenção (entregas_equipamentos),
--      a condição é copiada para a demanda, que já tem o campo equipamento_condicao.
--      A cópia é feita por um gatilho na demanda, sem alterar as funções que a criam.
--
-- Idempotente. Não altera registros existentes.

begin;

alter table public.solicitacoes add column if not exists equipamento_condicao text;

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.solicitacoes'::regclass and conname = 'solicitacoes_equipamento_condicao_check'
  ) then
    alter table public.solicitacoes add constraint solicitacoes_equipamento_condicao_check
      check (equipamento_condicao is null or equipamento_condicao in ('Novo', 'Usado'));
  end if;
end $$;

comment on column public.solicitacoes.equipamento_condicao is
  'Troca e aumento de equipamento: condição do equipamento solicitado (Novo ou Usado).';

create or replace function public.mc_condicao_demanda_da_solicitacao()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.equipamento_condicao is null and new.solicitacao_id is not null then
    select s.equipamento_condicao into new.equipamento_condicao
      from public.solicitacoes s
     where s.id = new.solicitacao_id;
  end if;
  return new;
end;
$$;

revoke all on function public.mc_condicao_demanda_da_solicitacao() from public, anon, authenticated;

drop trigger if exists trg_mc_condicao_demanda_da_solicitacao on public.entregas_equipamentos;
create trigger trg_mc_condicao_demanda_da_solicitacao
  before insert or update of solicitacao_id, equipamento_condicao on public.entregas_equipamentos
  for each row execute function public.mc_condicao_demanda_da_solicitacao();

commit;

notify pgrst, 'reload schema';
