-- Meu Cliente — Grespan
-- Tela de Clientes: cliente nascido de uma ficha só aparece depois de aprovado em todas as etapas.
--
-- O cliente é criado junto com a ficha (gatilho trg_criar_cliente). Esta função é um
-- campo calculado da tabela clientes, usado pelo front como filtro (mc_cliente_liberado = true):
--   * cliente que não veio de ficha (ex.: importado do TOTVS): sempre liberado;
--   * cliente de ficha: liberado quando a Diretoria aprovou e não resta nenhuma etapa
--     pendente, aguardando ou reprovada.
--
-- Idempotente. Não altera dados nem regras de acesso (RLS).

begin;

create or replace function public.mc_cliente_liberado(c public.clientes)
returns boolean
language sql
stable
set search_path = ''
as $$
  select c.origem is distinct from 'ficha'
      or (
        exists (
          select 1 from public.ficha_aprovacoes a
          where a.ficha_id = c.ficha_id and a.etapa = 'diretoria' and a.status = 'aprovado'
        )
        and not exists (
          select 1 from public.ficha_aprovacoes a
          where a.ficha_id = c.ficha_id and a.status not in ('aprovado', 'nao_aplica')
        )
      );
$$;

comment on function public.mc_cliente_liberado(public.clientes) is
  'Campo calculado: cliente liberado para a tela de Clientes (não veio de ficha, ou ficha aprovada em todas as etapas).';

revoke all on function public.mc_cliente_liberado(public.clientes) from public, anon;
grant execute on function public.mc_cliente_liberado(public.clientes) to authenticated;

commit;

-- Faz a API enxergar a função nova imediatamente.
notify pgrst, 'reload schema';
