-- Execute no SQL Editor do Supabase antes de publicar a nova interface.
-- Relatórios vinculados à visita, sem alterar a estrutura existente.
create table if not exists public.vt_relatorios (
  visita_id uuid primary key references public.visitas_tecnicas(id) on delete cascade,
  tecnico_id uuid not null,
  conteudo jsonb not null,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  constraint vt_relatorio_assinatura_obrigatoria check (
    length(coalesce(conteudo->>'assinatura','')) > 100
    and length(trim(coalesce(conteudo->>'responsavel_nome',''))) > 0
    and length(trim(coalesce(conteudo->>'relato_execucao',''))) > 0
  )
);
create index if not exists vt_relatorios_tecnico_idx on public.vt_relatorios(tecnico_id);
alter table public.vt_relatorios enable row level security;
-- A leitura segue a visibilidade das visitas no banco.
drop policy if exists vt_relatorios_select on public.vt_relatorios;
create policy vt_relatorios_select on public.vt_relatorios for select to authenticated
using (exists (select 1 from public.visitas_tecnicas v where v.id=visita_id));
drop policy if exists vt_relatorios_insert on public.vt_relatorios;
create policy vt_relatorios_insert on public.vt_relatorios for insert to authenticated
with check (exists (select 1 from public.visitas_tecnicas v where v.id=visita_id and v.tecnico_id=tecnico_id and v.status='em_andamento'));
drop policy if exists vt_relatorios_update on public.vt_relatorios;
create policy vt_relatorios_update on public.vt_relatorios for update to authenticated
using (exists (select 1 from public.visitas_tecnicas v where v.id=visita_id and v.tecnico_id=tecnico_id and v.status='em_andamento'))
with check (exists (select 1 from public.visitas_tecnicas v where v.id=visita_id and v.tecnico_id=tecnico_id and v.status='em_andamento'));
-- Defesa no banco: uma visita não pode ser concluída sem relatório assinado.
create or replace function public.vt_exigir_relatorio_checkout()
returns trigger language plpgsql as $$
begin
  if new.status = 'concluida' and old.status is distinct from 'concluida'
     and not exists (select 1 from public.vt_relatorios r where r.visita_id = new.id) then
    raise exception 'Check-out bloqueado: relatório e assinatura do cliente são obrigatórios.';
  end if;
  return new;
end $$;
drop trigger if exists vt_exigir_relatorio_checkout_trg on public.visitas_tecnicas;
create trigger vt_exigir_relatorio_checkout_trg
before update of status on public.visitas_tecnicas
for each row execute function public.vt_exigir_relatorio_checkout();
-- Observação: fotos e assinatura são armazenadas no JSONB nesta primeira versão;
-- para grande volume, migrar imagens para Supabase Storage privado.
