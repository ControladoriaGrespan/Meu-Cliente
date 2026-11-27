-- Meu Cliente — Grespan
-- O equipamento "Armário Esqueleto" passa a se chamar "Esqueleto".
--
--   1) Função que monta os itens de comodato da ficha: novo nome.
--   2) Registros já gravados com o nome antigo: itens de comodato, textos das demandas da
--      Manutenção e itens/nome das solicitações. Só o nome muda; quantidades, status e
--      demais dados ficam como estão. A chave interna da ficha (armario_esqueleto) não muda.
--
-- Idempotente.

begin;

do $nome$
declare
  v_def text;
begin
  select pg_get_functiondef(p.oid) into strict v_def
    from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'mc_itens_comodato_da_ficha';
  if position('''ARMÁRIO ESQUELETO''' in v_def) > 0 then
    execute replace(v_def, '''ARMÁRIO ESQUELETO''', '''ESQUELETO''');
  end if;
end
$nome$;

update public.comodato_equipamentos
   set descricao = replace(replace(descricao, 'ARMÁRIO ESQUELETO', 'ESQUELETO'), 'Armário Esqueleto', 'Esqueleto')
 where descricao like '%ARMÁRIO ESQUELETO%' or descricao like '%Armário Esqueleto%';

update public.entregas_equipamentos
   set equipamento_resumo  = replace(replace(equipamento_resumo,  'ARMÁRIO ESQUELETO', 'ESQUELETO'), 'Armário Esqueleto', 'Esqueleto'),
       equipamento_entrega = replace(replace(equipamento_entrega, 'ARMÁRIO ESQUELETO', 'ESQUELETO'), 'Armário Esqueleto', 'Esqueleto'),
       equipamento_coleta  = replace(replace(equipamento_coleta,  'ARMÁRIO ESQUELETO', 'ESQUELETO'), 'Armário Esqueleto', 'Esqueleto')
 where concat_ws(' ', equipamento_resumo, equipamento_entrega, equipamento_coleta) like '%ARMÁRIO ESQUELETO%'
    or concat_ws(' ', equipamento_resumo, equipamento_entrega, equipamento_coleta) like '%Armário Esqueleto%';

update public.entrega_itens
   set descricao = replace(replace(descricao, 'ARMÁRIO ESQUELETO', 'ESQUELETO'), 'Armário Esqueleto', 'Esqueleto')
 where descricao like '%ARMÁRIO ESQUELETO%' or descricao like '%Armário Esqueleto%';

update public.solicitacao_equipamentos
   set equipamento = replace(replace(equipamento, 'ARMÁRIO ESQUELETO', 'ESQUELETO'), 'Armário Esqueleto', 'Esqueleto')
 where equipamento like '%ARMÁRIO ESQUELETO%' or equipamento like '%Armário Esqueleto%';

update public.solicitacoes
   set equipamento = replace(replace(equipamento, 'ARMÁRIO ESQUELETO', 'ESQUELETO'), 'Armário Esqueleto', 'Esqueleto')
 where equipamento like '%ARMÁRIO ESQUELETO%' or equipamento like '%Armário Esqueleto%';

commit;
