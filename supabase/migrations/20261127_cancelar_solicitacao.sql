-- Meu Cliente — Grespan
-- Cancelamento de solicitação pelo Administrador, com observação obrigatória.
--
-- Pode cancelar solicitação em aprovação, aprovada ou reprovada. Não pode cancelar:
--   * solicitação já concluída ou vinculada a pedido;
--   * bonificação já usada em algum pedido;
--   * solicitação com entrega em rota, agendada ou concluída (retire da rota antes).
-- Ao cancelar:
--   * a solicitação fica com status "cancelada", com data, autor e motivo;
--   * as etapas de aprovação ainda abertas passam a "não se aplica" (saem das filas);
--   * as demandas da Manutenção ainda não roteirizadas passam a "cancelada" (saem da fila).
-- Nada é apagado.
--
-- Idempotente.

begin;

alter table public.solicitacoes
  add column if not exists cancelada_em timestamptz,
  add column if not exists cancelada_por uuid references public.usuarios(id),
  add column if not exists cancelamento_motivo text;

alter table public.entregas_equipamentos drop constraint if exists entregas_equipamentos_status_v50_check;
alter table public.entregas_equipamentos add constraint entregas_equipamentos_status_v50_check
  check (status = any (array['pendente', 'ag_rota', 'roteirizada', 'programada', 'concluida', 'cancelada']));

create or replace function public.mc_cancelar_solicitacao(p_solicitacao_id uuid, p_motivo text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  s public.solicitacoes%rowtype;
  v_motivo text := btrim(coalesce(p_motivo, ''));
  v_entregas integer := 0;
  v_etapas integer := 0;
begin
  if not exists (
    select 1 from public.usuarios u
     where u.id = (select auth.uid()) and u.papel = 'admin' and u.ativo is distinct from false
  ) then
    raise exception 'Somente o Administrador pode cancelar solicitações.' using errcode = '42501';
  end if;
  if length(v_motivo) < 6 then
    raise exception 'Informe a observação do cancelamento (mínimo de 6 caracteres).';
  end if;
  if length(v_motivo) > 1000 then
    raise exception 'Observação muito longa (máximo de 1.000 caracteres).';
  end if;

  select * into s from public.solicitacoes where id = p_solicitacao_id for update;
  if not found then raise exception 'Solicitação não localizada.'; end if;
  if s.status_fluxo = 'cancelada' then raise exception 'Esta solicitação já está cancelada.'; end if;
  if s.status_fluxo in ('concluida', 'vinculada') or s.pedido_id is not null then
    raise exception 'Solicitação já concluída ou vinculada a pedido não pode ser cancelada.';
  end if;
  if s.categoria = 'bonificacao'
     and exists (select 1 from public.pedido_itens pi where pi.solicitacao_bonificacao_id = s.id) then
    raise exception 'Esta bonificação já foi usada em pedido e não pode ser cancelada.';
  end if;
  if exists (
    select 1 from public.entregas_equipamentos e
     where e.solicitacao_id = s.id
       and (e.status in ('roteirizada', 'programada', 'concluida')
            or exists (select 1 from public.rota_equipamento_itens ri where ri.entrega_id = e.id))
  ) then
    raise exception 'Há entrega desta solicitação em rota, agendada ou concluída. Retire a entrega da rota antes de cancelar.';
  end if;

  update public.entregas_equipamentos e
     set status = 'cancelada', data_prevista = null, updated_at = now(),
         observacao_conclusao = 'Cancelada pelo Administrador: ' || v_motivo
   where e.solicitacao_id = s.id and e.status in ('pendente', 'ag_rota');
  get diagnostics v_entregas = row_count;

  update public.solicitacao_aprovacoes a
     set status = 'nao_aplica',
         observacao = concat_ws(' | ', nullif(btrim(a.observacao), ''), 'Solicitação cancelada pelo Administrador')
   where a.solicitacao_id = s.id and a.status in ('pendente', 'aguardando');
  get diagnostics v_etapas = row_count;

  update public.solicitacoes
     set status_fluxo = 'cancelada', cancelada_em = now(), cancelada_por = (select auth.uid()),
         cancelamento_motivo = v_motivo
   where id = s.id;

  return jsonb_build_object('id', s.id, 'status_anterior', s.status_fluxo,
    'etapas_encerradas', v_etapas, 'entregas_canceladas', v_entregas);
end;
$$;

revoke all on function public.mc_cancelar_solicitacao(uuid, text) from public, anon;
grant execute on function public.mc_cancelar_solicitacao(uuid, text) to authenticated;

commit;

notify pgrst, 'reload schema';
