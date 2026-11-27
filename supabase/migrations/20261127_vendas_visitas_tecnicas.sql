-- Meu Cliente — Grespan
-- Módulo Vendas: aba "Visitas Técnicas" (somente consulta).
--
-- Vendedor, Supervisor e Coordenador comerciais passam a consultar as visitas técnicas
-- dos clientes da própria carteira (mesma regra de carteira da tela de Clientes:
-- pode_ver_cliente_modular). Administrador consulta todas.
--
-- Nada é liberado nas tabelas do módulo técnico: o acesso é feito por duas funções de
-- leitura, que devolvem só o necessário. Não aparecem visitas canceladas, substituições
-- ainda não aprovadas, nem agendamentos cuja agenda semanal ainda não foi aprovada
-- (mesma regra que vale para o próprio técnico). Fotos e assinatura não são devolvidas.
--
-- Idempotente. Não altera dados, tabelas nem políticas existentes.

begin;

-- Regra única de acesso: a visita é de um cliente da carteira de quem consulta.
create or replace function public.mc_vendas_visita_visivel(v public.visitas_tecnicas)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select
    public.vt_papel() in ('vendedor', 'supervisor', 'coordenador', 'admin')
    and v.status is distinct from 'cancelada'
    and (v.substitui_visita_id is null or v.substituicao_aprovada_em is not null)
    and exists (
      select 1 from public.clientes c
       where c.id = v.cliente_id
         and public.pode_ver_cliente_modular(c.vendedor_id)
    )
    and (
      v.status in ('em_andamento', 'concluida')
      or v.checkin_em is not null
      or v.tipo_agendamento = 'imediato'
      or exists (
        select 1 from public.vt_aprovacoes_excecao e
         where e.atendimento_id = v.atendimento_id and e.status = 'aprovada'
      )
      or (
        v.tipo_agendamento = 'normal'
        and exists (
          select 1 from public.agendas_tecnicas_semanais a
           where a.id = v.agenda_semana_id and a.status = 'aprovada'
        )
        and not exists (
          select 1 from public.vt_aprovacoes_excecao e
           where e.atendimento_id = v.atendimento_id
        )
      )
    );
$$;

revoke all on function public.mc_vendas_visita_visivel(public.visitas_tecnicas) from public, anon, authenticated;

-- Lista do período (sem o conteúdo do relatório, que pode ser pesado).
create or replace function public.mc_vendas_visitas_tecnicas(p_inicio date, p_fim date)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_saida jsonb;
begin
  if public.vt_papel() is null
     or public.vt_papel() not in ('vendedor', 'supervisor', 'coordenador', 'admin') then
    raise exception 'Acesso restrito a Vendedor, Supervisor e Coordenador' using errcode = '42501';
  end if;
  if p_inicio is null or p_fim is null or p_fim < p_inicio or p_fim - p_inicio > 400 then
    raise exception 'Período inválido (máximo de 400 dias)';
  end if;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.data_visita desc, x.hora_inicio desc), '[]'::jsonb)
    into v_saida
    from (
      select v.id, v.data_visita, v.hora_inicio, v.duracao_min, v.status,
             v.tipo_atendimento, v.tipo_agendamento, v.objetivo,
             v.checkin_em, v.checkout_em,
             t.nome as tecnico_nome,
             c.id as cliente_id, c.codigo_totvs, c.razao_social, c.nome_fantasia, c.cidade, c.estado,
             vd.nome as vendedor_nome,
             exists (select 1 from public.vt_relatorios r where r.visita_id = v.id) as tem_relatorio
        from public.visitas_tecnicas v
        join public.clientes c on c.id = v.cliente_id
        left join public.usuarios t on t.id = v.tecnico_id
        left join public.usuarios vd on vd.id = c.vendedor_id
       where v.data_visita between p_inicio and p_fim
         and public.mc_vendas_visita_visivel(v)
       order by v.data_visita desc, v.hora_inicio desc
       limit 3000
    ) x;
  return v_saida;
end;
$$;

-- Relatório de uma visita (texto do checkout; sem fotos e sem assinatura).
create or replace function public.mc_vendas_visita_tecnica_relatorio(p_visita_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_saida jsonb;
begin
  if not exists (
    select 1 from public.visitas_tecnicas v
     where v.id = p_visita_id and public.mc_vendas_visita_visivel(v)
  ) then
    raise exception 'Visita não encontrada na sua carteira' using errcode = '42501';
  end if;

  select (r.conteudo - 'imagens' - 'assinatura' - 'visita_id')
         || jsonb_build_object('qtd_fotos',
              case when jsonb_typeof(r.conteudo -> 'imagens') = 'array'
                   then jsonb_array_length(r.conteudo -> 'imagens') else 0 end)
    into v_saida
    from public.vt_relatorios r
   where r.visita_id = p_visita_id;
  return v_saida; -- null quando a visita ainda não tem relatório
end;
$$;

revoke all on function public.mc_vendas_visitas_tecnicas(date, date) from public, anon;
revoke all on function public.mc_vendas_visita_tecnica_relatorio(uuid) from public, anon;
grant execute on function public.mc_vendas_visitas_tecnicas(date, date) to authenticated;
grant execute on function public.mc_vendas_visita_tecnica_relatorio(uuid) to authenticated;

commit;

notify pgrst, 'reload schema';
