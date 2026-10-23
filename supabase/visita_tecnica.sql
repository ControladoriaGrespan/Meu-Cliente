-- Meu Cliente / Visita Técnica — executar no SQL Editor do Supabase de PRODUÇÃO
-- Revise políticas existentes antes de aplicar. Não desativa RLS.
begin;
-- Se houver CHECK/ENUM legado em usuarios.papel, adequar manualmente a restrição
-- ao incluir supervisor_tec_panificacao e tec_panificacao.
create table if not exists public.visitas_tecnicas (
  id uuid primary key default gen_random_uuid(),
  cliente_id uuid not null references public.clientes(id),
  tecnico_id uuid not null references public.usuarios(id),
  supervisor_id uuid references public.usuarios(id),
  data_visita date not null,
  hora_inicio time not null,
  objetivo text not null default '',
  observacoes text not null default '',
  status text not null default 'agendada' check(status in ('agendada','em_andamento','concluida','cancelada')),
  checkin_em timestamptz,
  checkout_em timestamptz,
  relatorio_qualidade text not null default '',
  criado_em timestamptz not null default now(),
  criado_por uuid default auth.uid(),
  constraint checkout_depois_checkin check(checkout_em is null or (checkin_em is not null and checkout_em>=checkin_em))
);
create index if not exists visitas_tecnicas_data_idx on public.visitas_tecnicas(data_visita,tecnico_id);
create index if not exists visitas_tecnicas_supervisor_idx on public.visitas_tecnicas(supervisor_id,data_visita);
alter table public.visitas_tecnicas enable row level security;
create or replace function public.visita_tecnica_papel() returns text language sql stable security definer set search_path=public as $$
  select papel::text from public.usuarios where id=auth.uid() and ativo=true limit 1
$$;
create or replace function public.visita_tecnica_equipe(p_tecnico uuid) returns boolean language sql stable security definer set search_path=public as $$
  select exists(
    select 1 from public.usuarios t join public.usuarios s on s.id=t.supervisor_id
    where t.id=p_tecnico and t.papel::text='tec_panificacao'
      and s.papel::text='supervisor_tec_panificacao' and s.id=auth.uid()
  )
$$;
create policy visitas_tecnicas_select on public.visitas_tecnicas for select to authenticated using (
  public.visita_tecnica_papel() in ('admin','coordenador','gestao_adm_vendas')
  or tecnico_id=auth.uid()
  or (public.visita_tecnica_papel()='supervisor_tec_panificacao' and public.visita_tecnica_equipe(tecnico_id))
);
create policy visitas_tecnicas_insert on public.visitas_tecnicas for insert to authenticated with check (
  public.visita_tecnica_papel() in ('admin','coordenador','gestao_adm_vendas')
  or (public.visita_tecnica_papel()='supervisor_tec_panificacao' and public.visita_tecnica_equipe(tecnico_id))
);
-- Atualização limitada via função para impedir que o técnico altere horários manualmente.
create or replace function public.registrar_visita_tecnica(p_id uuid,p_acao text,p_relatorio text default '')
returns void language plpgsql security definer set search_path=public as $$
declare v public.visitas_tecnicas%rowtype;
begin
  select * into v from public.visitas_tecnicas where id=p_id for update;
  if not found or v.tecnico_id<>auth.uid() or public.visita_tecnica_papel()<>'tec_panificacao' then
    raise exception 'Visita não autorizada';
  end if;
  if p_acao='checkin' and v.status='agendada' then
    update public.visitas_tecnicas set checkin_em=now(),status='em_andamento' where id=p_id;
  elsif p_acao='checkout' and v.status='em_andamento' and length(trim(p_relatorio))>0 then
    update public.visitas_tecnicas set checkout_em=now(),status='concluida',relatorio_qualidade=p_relatorio where id=p_id;
  else
    raise exception 'Transição de status inválida ou relatório não preenchido';
  end if;
end $$;
grant execute on function public.registrar_visita_tecnica(uuid,text,text) to authenticated;
commit;
-- IMPORTANTE: o cadastro de usuários pode exigir atualização da CHECK constraint
-- e da tabela usuario_modulos para aceitar visita_tecnica.
