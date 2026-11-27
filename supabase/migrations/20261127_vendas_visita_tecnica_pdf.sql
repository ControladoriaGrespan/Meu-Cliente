-- Meu Cliente — Grespan
-- Módulo Vendas > Visitas Técnicas: PDF do relatório com as fotos do atendimento.
--
-- Devolve o relatório completo de UMA visita (texto, fotos e assinatura do responsável,
-- como no PDF da equipe técnica) e o endereço do cliente, somente quando a visita é de
-- um cliente da carteira de quem consulta (mesma regra da lista: mc_vendas_visita_visivel).
--
-- Idempotente. Não altera dados, tabelas nem políticas existentes.

begin;

create or replace function public.mc_vendas_visita_tecnica_pdf(p_visita_id uuid)
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

  select jsonb_build_object(
           'conteudo', r.conteudo,
           'cliente', jsonb_build_object(
             'codigo_totvs', c.codigo_totvs, 'razao_social', c.razao_social, 'nome_fantasia', c.nome_fantasia,
             'endereco_logradouro', c.endereco_logradouro, 'endereco_numero', c.endereco_numero,
             'endereco_bairro', c.endereco_bairro, 'cidade', c.cidade, 'estado', c.estado,
             'endereco_cep', c.endereco_cep))
    into v_saida
    from public.visitas_tecnicas v
    join public.clientes c on c.id = v.cliente_id
    join public.vt_relatorios r on r.visita_id = v.id
   where v.id = p_visita_id;
  return v_saida; -- null quando a visita ainda não tem relatório
end;
$$;

revoke all on function public.mc_vendas_visita_tecnica_pdf(uuid) from public, anon;
grant execute on function public.mc_vendas_visita_tecnica_pdf(uuid) to authenticated;

commit;

notify pgrst, 'reload schema';
