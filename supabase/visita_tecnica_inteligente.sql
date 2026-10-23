-- Migração 02: Visita Técnica inteligente. Aplicar após visita_tecnica.sql.
-- Exige que clientes tenha latitude/longitude preenchidos por geocodificação autorizada.
alter table public.visitas_tecnicas add column if not exists duracao_min integer not null default 120 check (duracao_min between 15 and 600);
alter table public.visitas_tecnicas add column if not exists checkin_latitude double precision;
alter table public.visitas_tecnicas add column if not exists checkin_longitude double precision;
alter table public.visitas_tecnicas add column if not exists checkin_precisao_m double precision;
alter table public.visitas_tecnicas add column if not exists checkout_latitude double precision;
alter table public.visitas_tecnicas add column if not exists checkout_longitude double precision;
alter table public.visitas_tecnicas add column if not exists checkout_precisao_m double precision;
alter table public.clientes add column if not exists latitude double precision;
alter table public.clientes add column if not exists longitude double precision;
create index if not exists visita_tecnica_roteiro_idx on public.visitas_tecnicas(tecnico_id,data_visita,hora_inicio);
-- Consulta de localização exclusivamente dentro da visibilidade RLS de visitas_tecnicas.
-- Somente o próprio técnico registra coordenadas; o relógio vem do servidor.
create or replace function public.registrar_visita_tecnica(
 p_id uuid,p_acao text,p_relatorio text default '',
 p_latitude double precision default null,p_longitude double precision default null,p_precisao_m double precision default null
) returns void language plpgsql security definer set search_path=public as $$
declare v public.visitas_tecnicas%rowtype;
begin
 select * into v from public.visitas_tecnicas where id=p_id for update;
 if not found or v.tecnico_id<>auth.uid() or public.visita_tecnica_papel()<>'tec_panificacao' then
   raise exception 'Visita não autorizada';
 end if;
 if p_latitude is null or p_longitude is null or p_latitude not between -90 and 90 or p_longitude not between -180 and 180 then
   raise exception 'Localização inválida';
 end if;
 if p_acao='checkin' and v.status='agendada' then
   update public.visitas_tecnicas set checkin_em=now(),status='em_andamento',
     checkin_latitude=p_latitude,checkin_longitude=p_longitude,checkin_precisao_m=p_precisao_m where id=p_id;
 elsif p_acao='checkout' and v.status='em_andamento' and length(trim(p_relatorio))>0 then
   update public.visitas_tecnicas set checkout_em=now(),status='concluida',relatorio_qualidade=p_relatorio,
     checkout_latitude=p_latitude,checkout_longitude=p_longitude,checkout_precisao_m=p_precisao_m where id=p_id;
 else
   raise exception 'Transição inválida ou relatório ausente';
 end if;
end $$;
revoke execute on function public.registrar_visita_tecnica(uuid,text,text) from public,anon,authenticated;
grant execute on function public.registrar_visita_tecnica(uuid,text,text,double precision,double precision,double precision) to authenticated;
-- O bloqueio definitivo de conflitos concorrentes requer transação RPC no servidor.
-- A interface faz pré-validação e nunca confirma se a API de rotas falhar.
