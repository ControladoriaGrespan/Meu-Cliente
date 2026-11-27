-- Meu Cliente — Grespan
-- Novo equipamento na ficha: Forno Titan Pão de Queijo (chave forno_queijo em
-- equipamentos_quantidades). A função que monta os itens de comodato da ficha passa a
-- incluí-lo, para aparecer no contrato e na lista de carga do motorista.
--
-- Idempotente. Não altera dados.

do $titan$
declare
  v_def text;
  v_velho text := '(1, ''freezer_horizontal'', ''FREEZER HORIZONTAL''),';
begin
  select pg_get_functiondef(p.oid) into strict v_def
    from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'mc_itens_comodato_da_ficha';
  if position('forno_queijo' in v_def) = 0 then
    if (length(v_def) - length(replace(v_def, v_velho, ''))) / length(v_velho) <> 1 then
      raise exception 'mc_itens_comodato_da_ficha: lista de equipamentos não encontrada. Revisar antes de migrar.';
    end if;
    execute replace(v_def, v_velho, '(0, ''forno_queijo'', ''FORNO TITAN PÃO DE QUEIJO''), ' || v_velho);
  end if;
end
$titan$;
