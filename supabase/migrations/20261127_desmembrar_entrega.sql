-- Meu Cliente — Grespan
-- Desmembramento da entrega de equipamentos (Manutenção).
--
-- A Manutenção escolhe quais itens (e quantidades) de uma demanda saem para outra entrega.
-- Cada entrega parcial é uma demanda própria (linha em entregas_equipamentos) ligada à
-- original por demanda_origem_id. Por isso rota, baixa do motorista, aprovação do supervisor
-- e contrato de comodato continuam funcionando por entrega, como já funcionam hoje:
--   * cada parte é programada, roteirizada, aprovada e concluída separadamente;
--   * cada parte tem o seu contrato de comodato, só com os equipamentos daquela entrega;
--   * a solicitação só é dada como concluída quando todas as partes estiverem concluídas.
--
-- O que muda no banco:
--   1) entregas_equipamentos: colunas demanda_origem_id e parte_numero. A regra "uma demanda
--      por ficha / por solicitação" passa a valer só para a demanda original (as partes
--      repetem a ficha/solicitação). As funções que criam a demanda são ajustadas a essa regra.
--   2) entrega_itens: itens individualizados das demandas de solicitação que foram desmembradas
--      (troca, retirada, aumento). Demandas de ficha continuam usando comodato_equipamentos.
--   3) entrega_desmembramentos: registro de quem desmembrou, quando e o quê.
--   4) Funções: mc_itens_da_entrega, mc_atualizar_texto_entrega, mc_desmembrar_entrega,
--      mc_situacao_entrega.
--   5) Ajustes pontuais: conclusão da rota (solicitação só conclui com todas as partes),
--      manifesto do motorista (usa os itens da parte) e correção de quantidades da ficha
--      (bloqueada depois do desmembramento).
--
--   6) Itens de comodato das entregas de ficha: o gatilho da aprovação passa a gravar a lista
--      completa (antes faltavam freezers, armários, câmaras e fornos por modelo), e as entregas
--      de ficha ainda abertas, sem patrimônio e sem contrato, têm os itens refeitos.
--
-- Idempotente. Não apaga demandas. Única alteração de dados: o reparo dos itens de comodato
-- descrito no item 6.

begin;

-- ---------------------------------------------------------------------------------------
-- 1) Demanda original x partes
-- ---------------------------------------------------------------------------------------
alter table public.entregas_equipamentos
  add column if not exists demanda_origem_id uuid references public.entregas_equipamentos(id) on delete set null,
  add column if not exists parte_numero integer;

create index if not exists idx_entregas_equipamentos_origem on public.entregas_equipamentos(demanda_origem_id)
  where demanda_origem_id is not null;

alter table public.entregas_equipamentos drop constraint if exists entregas_equipamentos_ficha_id_key;
drop index if exists public.ux_entregas_equipamentos_ficha;
drop index if exists public.ux_entregas_equipamentos_solicitacao;
create unique index ux_entregas_equipamentos_ficha on public.entregas_equipamentos(ficha_id)
  where ficha_id is not null and demanda_origem_id is null;
create unique index ux_entregas_equipamentos_solicitacao on public.entregas_equipamentos(solicitacao_id)
  where solicitacao_id is not null and demanda_origem_id is null;

-- ---------------------------------------------------------------------------------------
-- 1b) Itens de comodato da ficha: lista completa
--     O gatilho que cria a entrega da ficha montava os itens de comodato pelos campos antigos
--     (forno_tipo, freezer_tipos, armario_tipo, camara_climatica) e deixava de fora o que hoje
--     é informado em equipamentos_quantidades (freezers, expositor, mini câmara, armários,
--     câmaras e fornos por modelo). A função abaixo é a mesma regra da tela.
-- ---------------------------------------------------------------------------------------
create or replace function public.mc_itens_comodato_da_ficha(f public.fichas_clientes)
returns table(ordem integer, quantidade integer, descricao text)
language plpgsql
stable
set search_path = ''
as $$
declare
  eq jsonb := coalesce(f.equipamentos_quantidades, '{}'::jsonb);
  v_tem_chaves boolean := eq <> '{}'::jsonb;
  v_ordem integer := 0;
  v_fornos integer := 0;
  v_qtd integer;
  v_modelos boolean;
  v_detalhe text;
  t record;
  m text;
  z text;
begin
  for t in
    select * from (values
      ('forno_gas', 'GÁS', nullif(btrim(coalesce(eq->>'forno_gas_combustivel', '')), '')),
      ('forno_eletrico', 'ELÉTRICO', nullif(btrim(concat_ws(' ', nullif(eq->>'forno_eletrico_ligacao', ''), nullif(eq->>'forno_eletrico_tensao', ''))), ''))
    ) as x(tipo, nome, detalhe)
  loop
    v_detalhe := case when t.detalhe is not null then ' - ' || upper(t.detalhe) else '' end;
    v_modelos := false;
    foreach m in array array['5', '8'] loop
      v_qtd := case when coalesce(eq->>(t.tipo || '_' || m || '_esteiras'), '') ~ '^[0-9]{1,5}$'
                    then (eq->>(t.tipo || '_' || m || '_esteiras'))::integer else 0 end;
      if v_qtd > 0 then
        v_modelos := true; v_fornos := v_fornos + 1; v_ordem := v_ordem + 1;
        ordem := v_ordem; quantidade := v_qtd;
        descricao := 'FORNO ' || t.nome || ' ' || m || ' ESTEIRAS' || v_detalhe;
        return next;
      end if;
    end loop;
    if not v_modelos then
      v_qtd := case when coalesce(eq->>t.tipo, '') ~ '^[0-9]{1,5}$' then (eq->>t.tipo)::integer else 0 end;
      if v_qtd > 0 then
        v_fornos := v_fornos + 1; v_ordem := v_ordem + 1;
        z := coalesce(nullif(btrim(coalesce(eq->>(t.tipo || '_esteiras'), '')), ''), nullif(btrim(coalesce(f.forno_esteiras::text, '')), ''));
        ordem := v_ordem; quantidade := v_qtd;
        descricao := 'FORNO ' || t.nome || case when z is not null then ' ' || z || ' ESTEIRAS' else '' end || v_detalhe;
        return next;
      end if;
    end if;
  end loop;
  if v_fornos = 0 and f.forno_tipo is not null then
    v_ordem := v_ordem + 1;
    ordem := v_ordem; quantidade := greatest(coalesce(f.forno_quantidade, 1)::integer, 1);
    descricao := 'FORNO ' || upper(f.forno_tipo)
      || case when nullif(btrim(coalesce(f.forno_esteiras::text, '')), '') is not null then ' ' || f.forno_esteiras || ' ESTEIRAS' else '' end;
    return next;
  end if;

  for t in
    select * from (values
      (1, 'freezer_horizontal', 'FREEZER HORIZONTAL'), (2, 'freezer_vertical', 'FREEZER VERTICAL'),
      (3, 'expositor', 'EXPOSITOR'), (4, 'mini_camara', 'MINI CÂMARA'),
      (5, 'armario_completo', 'ARMÁRIO COMPLETO'), (6, 'armario_vazio', 'ARMÁRIO VAZIO'),
      (7, 'armario_esqueleto', 'ARMÁRIO ESQUELETO'), (8, 'camara_20', 'CÂMARA CLIMÁTICA 20 ESTEIRAS'),
      (9, 'camara_40', 'CÂMARA CLIMÁTICA 40 ESTEIRAS')
    ) as x(seq, chave, nome) order by seq
  loop
    v_qtd := case when coalesce(eq->>t.chave, '') ~ '^[0-9]{1,5}$' then (eq->>t.chave)::integer else 0 end;
    if v_qtd > 0 then
      v_ordem := v_ordem + 1; ordem := v_ordem; quantidade := v_qtd; descricao := t.nome;
      return next;
    end if;
  end loop;

  -- Fichas antigas, sem quantidades por equipamento.
  if not v_tem_chaves then
    if f.freezer_tipos is not null then
      foreach z in array f.freezer_tipos loop
        v_ordem := v_ordem + 1; ordem := v_ordem; quantidade := 1; descricao := 'FREEZER ' || upper(z);
        return next;
      end loop;
    end if;
    if f.armario_tipo is not null then
      v_ordem := v_ordem + 1; ordem := v_ordem; quantidade := 1; descricao := 'ARMÁRIO ' || upper(f.armario_tipo);
      return next;
    end if;
    if f.camara_climatica is not null then
      v_ordem := v_ordem + 1; ordem := v_ordem; quantidade := 1; descricao := 'CÂMARA CLIMÁTICA ' || upper(f.camara_climatica);
      return next;
    end if;
  end if;

  if coalesce(f.assadeiras_quantidade, 0) > 0 then
    v_ordem := v_ordem + 1; ordem := v_ordem; quantidade := f.assadeiras_quantidade::integer; descricao := 'ASSADEIRA';
    return next;
  end if;
  if coalesce(f.esteiras_quantidade, 0) > 0 then
    v_ordem := v_ordem + 1; ordem := v_ordem; quantidade := f.esteiras_quantidade::integer; descricao := 'ESTEIRA';
    return next;
  end if;
end;
$$;

revoke all on function public.mc_itens_comodato_da_ficha(public.fichas_clientes) from public, anon, authenticated;

-- Gatilho da aprovação da Diretoria: mesma função de antes, com duas mudanças —
-- (a) a regra "uma demanda por ficha" vale para a demanda original;
-- (b) os itens de comodato vêm da lista completa acima.
create or replace function public.v46_criar_demanda_manutencao_ficha()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
DECLARE
  f public.fichas_clientes%ROWTYPE;
  v_entrega uuid;
  v_cond text;
BEGIN
  -- Somente a aprovação efetiva da Diretoria cria a demanda operacional.
  IF NEW.etapa <> 'diretoria'
     OR NEW.status <> 'aprovado'
     OR OLD.status IS NOT DISTINCT FROM NEW.status THEN
    RETURN NEW;
  END IF;

  SELECT * INTO f FROM public.fichas_clientes WHERE id=NEW.ficha_id;

  -- Ficha sem equipamento não gera demanda para Manutenção.
  IF NOT FOUND OR NOT COALESCE(f.precisa_equipamento,false) THEN
    RETURN NEW;
  END IF;

  v_cond := COALESCE(f.equipamento_condicao_manutencao, f.equipamento_condicao, 'Usado');

  -- Desde V48/V50 o tipo correto é "envio" e o status inicial é "pendente".
  INSERT INTO public.entregas_equipamentos(
    ficha_id, cliente_id, origem_tipo, tipo_demanda, status, data_prevista,
    endereco_rua, endereco_numero, endereco_bairro, endereco_cidade, endereco_estado, endereco_cep,
    equipamento_resumo, equipamento_entrega, equipamento_condicao, criado_por
  )
  VALUES(
    f.id, NULL, 'ficha_novo_cliente', 'envio', 'pendente', NULL,
    f.entrega_rua, f.entrega_numero, f.entrega_bairro, f.entrega_cidade, f.entrega_estado, f.entrega_cep,
    public.v46_resumo_equipamentos_ficha(f), public.v46_resumo_equipamentos_ficha(f), v_cond, NEW.aprovador_id
  )
  ON CONFLICT (ficha_id) WHERE ficha_id IS NOT NULL AND demanda_origem_id IS NULL
  DO UPDATE SET
    cliente_id=EXCLUDED.cliente_id,
    origem_tipo='ficha_novo_cliente',
    tipo_demanda='envio',
    -- Nunca reabre uma entrega já concluída. Qualquer demanda ainda operacional
    -- volta para a fila inicial da Manutenção.
    status=CASE WHEN public.entregas_equipamentos.status='concluida' THEN 'concluida' ELSE 'pendente' END,
    endereco_rua=EXCLUDED.endereco_rua,
    endereco_numero=EXCLUDED.endereco_numero,
    endereco_bairro=EXCLUDED.endereco_bairro,
    endereco_cidade=EXCLUDED.endereco_cidade,
    endereco_estado=EXCLUDED.endereco_estado,
    endereco_cep=EXCLUDED.endereco_cep,
    equipamento_resumo=EXCLUDED.equipamento_resumo,
    equipamento_entrega=EXCLUDED.equipamento_entrega,
    equipamento_condicao=EXCLUDED.equipamento_condicao
  RETURNING id INTO v_entrega;

  -- Individualiza os equipamentos para o comodato (lista completa da ficha).
  IF NOT EXISTS (SELECT 1 FROM public.comodato_equipamentos WHERE entrega_id=v_entrega) THEN
    INSERT INTO public.comodato_equipamentos(entrega_id, ordem, quantidade, descricao, condicao)
    SELECT v_entrega, i.ordem, i.quantidade, i.descricao, upper(v_cond)
    FROM public.mc_itens_comodato_da_ficha(f) i;
  END IF;

  RETURN NEW;
END;
$function$;

-- Reparo das entregas de ficha já abertas: refaz os itens de comodato pela lista completa.
-- Só mexe em entregas não concluídas, sem patrimônio atribuído, sem contrato gerado e que
-- não foram desmembradas; e só quando a lista gravada difere da lista da ficha.
do $reparo$
declare
  r record;
begin
  for r in
    select e.id, f as ficha, e.equipamento_condicao
      from public.entregas_equipamentos e
      join public.fichas_clientes f on f.id = e.ficha_id
     where e.origem_tipo = 'ficha_novo_cliente' and e.demanda_origem_id is null
       and e.status <> 'concluida'
       and not exists (select 1 from public.entregas_equipamentos p where p.demanda_origem_id = e.id)
       and not exists (select 1 from public.contratos_comodato k where k.entrega_id = e.id)
       and not exists (select 1 from public.comodato_equipamentos c
                        where c.entrega_id = e.id and nullif(btrim(c.patrimonio), '') is not null)
  loop
    if (select coalesce(jsonb_agg(jsonb_build_array(c.quantidade::integer, c.descricao) order by c.descricao, c.quantidade), '[]'::jsonb)
          from public.comodato_equipamentos c where c.entrega_id = r.id)
       is distinct from
       (select coalesce(jsonb_agg(jsonb_build_array(i.quantidade, i.descricao) order by i.descricao, i.quantidade), '[]'::jsonb)
          from public.mc_itens_comodato_da_ficha(r.ficha) i)
    then
      delete from public.comodato_equipamentos where entrega_id = r.id;
      insert into public.comodato_equipamentos(entrega_id, ordem, quantidade, descricao, condicao)
      select r.id, i.ordem, i.quantidade, i.descricao,
             upper(coalesce(r.equipamento_condicao, (r.ficha).equipamento_condicao_manutencao, (r.ficha).equipamento_condicao, 'Usado'))
        from public.mc_itens_comodato_da_ficha(r.ficha) i;
    end if;
  end loop;
end
$reparo$;

-- Funções que criam a demanda (ON CONFLICT): passam a apontar para a demanda original.
do $conflito$
declare
  r record;
  v_def text;
  v_n int;
begin
  for r in
    select * from (values
      ('v46_criar_demanda_manutencao_ficha'), ('v99_criar_demanda_troca_solicitacao'),
      ('v110_criar_demanda_retirada_solicitacao'), ('v48_demanda_operacional_solicitacao')
    ) as t(nome)
  loop
    select pg_get_functiondef(p.oid) into strict v_def
      from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = r.nome;
    if v_def ~ 'IS NOT NULL AND demanda_origem_id IS NULL' then
      continue; -- já ajustada
    end if;
    select count(*) into v_n
      from regexp_matches(v_def, 'ON CONFLICT \((ficha_id|solicitacao_id)\) WHERE (ficha_id|solicitacao_id) IS NOT NULL', 'g');
    if v_n <> 1 then
      raise exception 'Função %: esperava 1 ON CONFLICT por ficha/solicitação, encontrei %. Revisar antes de migrar.', r.nome, v_n;
    end if;
    execute regexp_replace(v_def,
      'ON CONFLICT \((ficha_id|solicitacao_id)\) WHERE (ficha_id|solicitacao_id) IS NOT NULL',
      'ON CONFLICT (\1) WHERE \2 IS NOT NULL AND demanda_origem_id IS NULL');
  end loop;
end
$conflito$;

-- ---------------------------------------------------------------------------------------
-- 2) Itens individualizados e registro dos desmembramentos
-- ---------------------------------------------------------------------------------------
create table if not exists public.entrega_itens (
  id uuid primary key default gen_random_uuid(),
  entrega_id uuid not null references public.entregas_equipamentos(id) on delete cascade,
  movimento text not null check (movimento in ('entregar', 'coletar')),
  descricao text not null check (btrim(descricao) <> ''),
  quantidade integer not null check (quantidade > 0),
  patrimonio text,
  ordem integer not null default 0,
  origem_ref text,
  created_at timestamptz not null default now()
);
create index if not exists idx_entrega_itens_entrega on public.entrega_itens(entrega_id, ordem);

create table if not exists public.entrega_desmembramentos (
  id uuid primary key default gen_random_uuid(),
  origem_id uuid not null references public.entregas_equipamentos(id) on delete cascade,
  parte_id uuid not null references public.entregas_equipamentos(id) on delete cascade,
  autor_id uuid references public.usuarios(id),
  itens jsonb not null,
  criado_em timestamptz not null default now()
);

alter table public.entrega_itens enable row level security;
alter table public.entrega_desmembramentos enable row level security;

drop policy if exists entrega_itens_leitura on public.entrega_itens;
create policy entrega_itens_leitura on public.entrega_itens for select to authenticated
  using (public.meu_papel() = any (array['manutencao', 'diretoria', 'admin']));
drop policy if exists entrega_desmembramentos_leitura on public.entrega_desmembramentos;
create policy entrega_desmembramentos_leitura on public.entrega_desmembramentos for select to authenticated
  using (public.meu_papel() = any (array['manutencao', 'diretoria', 'admin']));

revoke all on public.entrega_itens, public.entrega_desmembramentos from anon;
revoke insert, update, delete, truncate on public.entrega_itens, public.entrega_desmembramentos from authenticated;
grant select on public.entrega_itens, public.entrega_desmembramentos to authenticated;

-- ---------------------------------------------------------------------------------------
-- 3) Itens de uma demanda (fonte única para a tela, o desmembramento e a situação)
--    a) itens próprios (entrega_itens), quando a demanda já foi desmembrada;
--    b) comodato_equipamentos, nas entregas de ficha;
--    c) solicitacao_equipamentos, nas demandas de solicitação ainda não desmembradas.
-- ---------------------------------------------------------------------------------------
create or replace function public.mc_itens_da_entrega(p_entrega_id uuid)
returns table(chave text, movimento text, descricao text, quantidade integer, patrimonio text, ordem integer)
language sql
stable
security definer
set search_path = ''
as $$
  with d as (
    select e.id, e.solicitacao_id, coalesce(e.tipo_demanda, 'envio') as tipo
      from public.entregas_equipamentos e where e.id = p_entrega_id
  ), proprios as (
    select 'i:' || i.id as chave, i.movimento, i.descricao, i.quantidade,
           nullif(btrim(i.patrimonio), '') as patrimonio, i.ordem
      from public.entrega_itens i where i.entrega_id = p_entrega_id
  ), comodato as (
    select 'c:' || c.id as chave, 'entregar'::text as movimento, c.descricao,
           greatest(c.quantidade::integer, 1) as quantidade,
           nullif(btrim(c.patrimonio), '') as patrimonio, c.ordem
      from public.comodato_equipamentos c join d on d.id = c.entrega_id
     where d.tipo = 'envio'
  ), solicitacao as (
    select 's:' || s.id as chave,
           case when d.tipo = 'retirada' or s.movimento = 'coletar' then 'coletar' else 'entregar' end as movimento,
           s.equipamento as descricao, greatest(s.quantidade::integer, 1) as quantidade,
           nullif(btrim(s.patrimonio), '') as patrimonio,
           (row_number() over (order by s.created_at, s.id))::integer as ordem
      from public.solicitacao_equipamentos s join d on d.solicitacao_id = s.solicitacao_id
  )
  select * from proprios
  union all
  select * from comodato where not exists (select 1 from proprios)
  union all
  select * from solicitacao
   where not exists (select 1 from proprios) and not exists (select 1 from comodato)
$$;

revoke all on function public.mc_itens_da_entrega(uuid) from public, anon, authenticated;

-- Reescreve os textos da demanda (resumo, coleta, entrega) a partir dos itens dela.
create or replace function public.mc_atualizar_texto_entrega(p_entrega_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  d public.entregas_equipamentos%rowtype;
  v_col text;
  v_ent text;
  v_txt text;
  v_motivo text;
begin
  select * into d from public.entregas_equipamentos where id = p_entrega_id;
  if not found then return; end if;

  if exists (select 1 from public.entrega_itens i where i.entrega_id = p_entrega_id) then
    select
      string_agg(i.descricao
        || case when i.quantidade <> 1 then ' (Qtd. ' || i.quantidade || ')' else '' end
        || case when nullif(btrim(i.patrimonio), '') is not null then ' | Patrimônio ' || btrim(i.patrimonio) else '' end,
        ' • ' order by i.ordem, i.id) filter (where i.movimento = 'coletar'),
      string_agg(i.descricao
        || case when i.quantidade <> 1 then ' (Qtd. ' || i.quantidade || ')' else '' end
        || case when nullif(btrim(i.patrimonio), '') is not null then ' | Patrimônio ' || btrim(i.patrimonio) else '' end,
        ' • ' order by i.ordem, i.id) filter (where i.movimento = 'entregar')
      into v_col, v_ent
      from public.entrega_itens i where i.entrega_id = p_entrega_id;

    if d.tipo_demanda = 'troca' then
      update public.entregas_equipamentos
         set equipamento_resumo = 'COLETAR: ' || coalesce(v_col, '—') || ' • ENTREGAR: ' || coalesce(v_ent, '—'),
             equipamento_coleta = v_col, equipamento_entrega = v_ent, updated_at = now()
       where id = p_entrega_id;
    elsif d.tipo_demanda = 'retirada' then
      v_motivo := substring(d.equipamento_resumo from '•\s*MOTIVO:.*$');
      update public.entregas_equipamentos
         set equipamento_resumo = 'RETIRAR: ' || coalesce(v_col, '—') || coalesce(' ' || v_motivo, ''),
             equipamento_coleta = v_col, updated_at = now()
       where id = p_entrega_id;
    else
      select string_agg(i.descricao || ' x' || i.quantidade, '; ' order by i.ordem, i.id) into v_txt
        from public.entrega_itens i where i.entrega_id = p_entrega_id;
      update public.entregas_equipamentos
         set equipamento_resumo = v_txt, equipamento_entrega = v_txt, updated_at = now()
       where id = p_entrega_id;
    end if;
  else
    select string_agg(c.descricao || ' x' || greatest(c.quantidade::integer, 1), ' · ' order by c.ordem, c.id) into v_txt
      from public.comodato_equipamentos c where c.entrega_id = p_entrega_id;
    if v_txt is null then return; end if;
    v_txt := concat_ws(' · ', nullif(btrim(d.equipamento_condicao), ''), v_txt);
    update public.entregas_equipamentos
       set equipamento_resumo = v_txt, equipamento_entrega = v_txt, updated_at = now()
     where id = p_entrega_id;
  end if;
end;
$$;

revoke all on function public.mc_atualizar_texto_entrega(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------
-- 4) Desmembrar: p_itens = [{"chave": "...", "quantidade": n}] — o que sai para a nova entrega.
--    Devolve o id da nova demanda (parte), que nasce Pendente.
-- ---------------------------------------------------------------------------------------
create or replace function public.mc_desmembrar_entrega(p_entrega_id uuid, p_itens jsonb)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  d public.entregas_equipamentos%rowtype;
  v_fonte text;
  v_raiz uuid;
  v_parte integer;
  v_nova uuid;
  v_total integer;
  v_movido integer;
  r record;
begin
  if not exists (
    select 1 from public.usuarios u
     where u.id = (select auth.uid()) and u.ativo is distinct from false and u.papel in ('manutencao', 'admin')
  ) then
    raise exception 'Somente a Manutenção pode desmembrar entregas.' using errcode = '42501';
  end if;

  select * into d from public.entregas_equipamentos where id = p_entrega_id for update;
  if not found then raise exception 'Demanda não localizada.'; end if;
  if coalesce(d.tipo_demanda, 'envio') not in ('envio', 'troca', 'retirada') then
    raise exception 'Este tipo de demanda não pode ser desmembrado.';
  end if;
  if d.status is null or d.status not in ('pendente', 'ag_rota')
     or exists (select 1 from public.rota_equipamento_itens ri where ri.entrega_id = d.id) then
    raise exception 'Só é possível desmembrar demandas Pendentes ou em Ag. Rota. Retire a demanda da rota antes.';
  end if;

  if jsonb_typeof(p_itens) is distinct from 'array' or jsonb_array_length(p_itens) = 0 then
    raise exception 'Informe ao menos um item para a nova entrega.';
  end if;
  if exists (
    select 1 from jsonb_array_elements(p_itens) e
     where jsonb_typeof(e) is distinct from 'object' or nullif(e->>'chave', '') is null
        or coalesce(e->>'quantidade', '') !~ '^[0-9]{1,4}$' or (e->>'quantidade')::integer < 1
  ) then
    raise exception 'Itens inválidos: use quantidades inteiras maiores que zero.';
  end if;
  if (select count(*) <> count(distinct e->>'chave') from jsonb_array_elements(p_itens) e) then
    raise exception 'O mesmo item foi informado mais de uma vez.';
  end if;

  select case when bool_or(x.chave like 'i:%') then 'itens'
              when bool_or(x.chave like 'c:%') then 'comodato'
              when bool_or(x.chave like 's:%') then 'solicitacao' end,
         coalesce(sum(x.quantidade), 0)
    into v_fonte, v_total
    from public.mc_itens_da_entrega(d.id) x;
  if v_fonte is null then
    raise exception 'Esta demanda não tem itens individualizados para desmembrar.';
  end if;
  if exists (
    select 1 from jsonb_array_elements(p_itens) e
      left join public.mc_itens_da_entrega(d.id) x on x.chave = e->>'chave'
     where x.chave is null or (e->>'quantidade')::integer > x.quantidade
  ) then
    raise exception 'A demanda mudou ou a quantidade pedida é maior que a disponível. Atualize a tela e tente novamente.';
  end if;
  select sum((e->>'quantidade')::integer) into v_movido from jsonb_array_elements(p_itens) e;
  if v_movido >= v_total then
    raise exception 'Deixe ao menos um item nesta entrega: não é possível mover tudo.';
  end if;

  -- Demanda de solicitação: na primeira vez, individualiza os itens na própria demanda.
  if v_fonte = 'solicitacao' then
    insert into public.entrega_itens(entrega_id, movimento, descricao, quantidade, patrimonio, ordem, origem_ref)
    select d.id, x.movimento, x.descricao, x.quantidade, x.patrimonio, x.ordem, x.chave
      from public.mc_itens_da_entrega(d.id) x;
  end if;

  v_raiz := coalesce(d.demanda_origem_id, d.id);
  select coalesce(max(coalesce(e.parte_numero, 1)), 1) + 1 into v_parte
    from public.entregas_equipamentos e where e.id = v_raiz or e.demanda_origem_id = v_raiz;

  insert into public.entregas_equipamentos(
    ficha_id, solicitacao_id, cliente_id, origem_tipo, tipo_demanda, status, data_prevista,
    endereco_rua, endereco_numero, endereco_bairro, endereco_cidade, endereco_estado, endereco_cep,
    latitude, longitude, equipamento_resumo, equipamento_condicao, criado_por,
    demanda_origem_id, parte_numero
  ) values (
    d.ficha_id, d.solicitacao_id, d.cliente_id, d.origem_tipo, d.tipo_demanda, 'pendente', null,
    d.endereco_rua, d.endereco_numero, d.endereco_bairro, d.endereco_cidade, d.endereco_estado, d.endereco_cep,
    d.latitude, d.longitude, d.equipamento_resumo, d.equipamento_condicao, (select auth.uid()),
    v_raiz, v_parte
  ) returning id into v_nova;

  for r in
    select e->>'chave' as chave, (e->>'quantidade')::integer as qtd from jsonb_array_elements(p_itens) e
  loop
    if v_fonte = 'comodato' then
      update public.comodato_equipamentos c set entrega_id = v_nova
       where c.entrega_id = d.id and 'c:' || c.id = r.chave and greatest(c.quantidade::integer, 1) = r.qtd;
      if not found then
        update public.comodato_equipamentos c set quantidade = c.quantidade - r.qtd
         where c.entrega_id = d.id and 'c:' || c.id = r.chave;
        insert into public.comodato_equipamentos(entrega_id, ordem, quantidade, descricao, condicao, patrimonio)
        select v_nova, c.ordem, r.qtd, c.descricao, c.condicao, null
          from public.comodato_equipamentos c where c.entrega_id = d.id and 'c:' || c.id = r.chave;
      end if;
    else
      update public.entrega_itens i set entrega_id = v_nova
       where i.entrega_id = d.id and ('i:' || i.id = r.chave or i.origem_ref = r.chave) and i.quantidade = r.qtd;
      if not found then
        update public.entrega_itens i set quantidade = i.quantidade - r.qtd
         where i.entrega_id = d.id and ('i:' || i.id = r.chave or i.origem_ref = r.chave);
        insert into public.entrega_itens(entrega_id, movimento, descricao, quantidade, patrimonio, ordem)
        select v_nova, i.movimento, i.descricao, r.qtd, null, i.ordem
          from public.entrega_itens i
         where i.entrega_id = d.id and ('i:' || i.id = r.chave or i.origem_ref = r.chave);
      end if;
    end if;
  end loop;

  perform public.mc_atualizar_texto_entrega(d.id);
  perform public.mc_atualizar_texto_entrega(v_nova);

  insert into public.entrega_desmembramentos(origem_id, parte_id, autor_id, itens)
  values (d.id, v_nova, (select auth.uid()), p_itens);

  return v_nova;
end;
$$;

-- Situação de todas as partes de uma demanda, com os itens de cada uma.
create or replace function public.mc_situacao_entrega(p_entrega_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_raiz uuid;
  v_saida jsonb;
begin
  if not exists (
    select 1 from public.usuarios u
     where u.id = (select auth.uid()) and u.ativo is distinct from false
       and u.papel in ('manutencao', 'diretoria', 'admin')
  ) then
    raise exception 'Acesso restrito à Manutenção.' using errcode = '42501';
  end if;
  select coalesce(e.demanda_origem_id, e.id) into v_raiz
    from public.entregas_equipamentos e where e.id = p_entrega_id;
  if v_raiz is null then raise exception 'Demanda não localizada.'; end if;

  select jsonb_build_object('raiz', v_raiz, 'partes', coalesce(jsonb_agg(p.linha order by p.parte), '[]'::jsonb))
    into v_saida
    from (
      select coalesce(e.parte_numero, 1) as parte,
             jsonb_build_object(
               'id', e.id, 'parte', coalesce(e.parte_numero, 1), 'status', e.status,
               'data_prevista', e.data_prevista, 'concluida_em', e.concluida_em,
               'rota', (select jsonb_build_object('codigo', ro.codigo, 'nome', ro.nome, 'data_rota', ro.data_rota)
                          from public.rota_equipamento_itens ri
                          join public.rotas_equipamentos ro on ro.id = ri.rota_id
                         where ri.entrega_id = e.id limit 1),
               'itens', (select coalesce(jsonb_agg(to_jsonb(x) order by x.movimento desc, x.ordem, x.chave), '[]'::jsonb)
                           from public.mc_itens_da_entrega(e.id) x)
             ) as linha
        from public.entregas_equipamentos e
       where e.id = v_raiz or e.demanda_origem_id = v_raiz
    ) p;
  return v_saida;
end;
$$;

revoke all on function public.mc_desmembrar_entrega(uuid, jsonb) from public, anon;
revoke all on function public.mc_situacao_entrega(uuid) from public, anon;
grant execute on function public.mc_desmembrar_entrega(uuid, jsonb) to authenticated;
grant execute on function public.mc_situacao_entrega(uuid) to authenticated;

-- ---------------------------------------------------------------------------------------
-- 5) Ajustes pontuais em funções existentes (troca de texto conferida por contagem)
-- ---------------------------------------------------------------------------------------
do $ajustes$
declare
  v_def text;
  v_velho text;
  v_novo text;
begin
  -- 5a) Conclusão da rota: a solicitação só conclui quando não restar parte em aberto.
  select pg_get_functiondef(p.oid) into strict v_def
    from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'concluir_rota_equipamentos';
  if position('mc_parte_em_aberto' in v_def) = 0 then
    v_velho := E'AND COALESCE(s.status_fluxo,'''') <> ''concluida'';';
    v_novo := E'AND COALESCE(s.status_fluxo,'''') <> ''concluida''\r\n'
      || E'  AND NOT EXISTS ( -- mc_parte_em_aberto: entregas desmembradas ainda não concluídas\r\n'
      || E'    SELECT 1 FROM public.entregas_equipamentos x\r\n'
      || E'    WHERE x.solicitacao_id = s.id AND x.status <> ''concluida'');';
    if (length(v_def) - length(replace(v_def, v_velho, ''))) / length(v_velho) <> 1 then
      raise exception 'concluir_rota_equipamentos: trecho esperado não encontrado. Revisar antes de migrar.';
    end if;
    execute replace(v_def, v_velho, v_novo);
  end if;

  -- 5b) Manifesto do motorista: demanda desmembrada mostra só os itens da própria parte.
  select pg_get_functiondef(p.oid) into strict v_def
    from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'mc_manifesto_parada_motorista';
  if position('entrega_itens' in v_def) = 0 then
    v_velho := E'), itens AS (\r\n    SELECT 1 AS prioridade,';
    v_novo := E'), itens AS (\r\n'
      || E'    SELECT 0 AS prioridade, ''item:''||e.id AS chave, e.descricao AS descricao,\r\n'
      || E'      e.patrimonio::text, greatest(e.quantidade,1) AS quantidade, e.movimento AS movimento\r\n'
      || E'    FROM origem d JOIN public.entrega_itens e ON e.entrega_id = d.id\r\n'
      || E'    UNION ALL\r\n    SELECT 1 AS prioridade,';
    if (length(v_def) - length(replace(v_def, v_velho, ''))) / length(v_velho) <> 1 then
      raise exception 'mc_manifesto_parada_motorista: início da lista de itens não encontrado. Revisar antes de migrar.';
    end if;
    v_def := replace(v_def, v_velho, v_novo);
    v_velho := 'WHERE i.prioridade = (SELECT min(j.prioridade) FROM itens j WHERE j.movimento=i.movimento)';
    v_novo := v_velho || E'\r\n      AND (i.prioridade = 0 OR NOT EXISTS (SELECT 1 FROM itens z WHERE z.prioridade = 0))';
    if (length(v_def) - length(replace(v_def, v_velho, ''))) / length(v_velho) <> 1 then
      raise exception 'mc_manifesto_parada_motorista: filtro de prioridade não encontrado. Revisar antes de migrar.';
    end if;
    execute replace(v_def, v_velho, v_novo);
  end if;

  -- 5c) Correção de quantidades da ficha: vale para a demanda original e é bloqueada
  --     depois que a entrega foi desmembrada.
  select pg_get_functiondef(p.oid) into strict v_def
    from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'mc_corrigir_quantidades_ficha';
  if position('demanda_origem_id' in v_def) = 0 then
    v_velho := 'SELECT * INTO v_entrega FROM public.entregas_equipamentos WHERE ficha_id=p_ficha FOR UPDATE;';
    v_novo := E'IF EXISTS (SELECT 1 FROM public.entregas_equipamentos WHERE ficha_id=p_ficha AND demanda_origem_id IS NOT NULL) THEN\r\n'
      || E'    RAISE EXCEPTION ''A entrega desta ficha foi desmembrada pela Manutenção. Ajuste os itens de cada entrega com a equipe.'';\r\n'
      || E'  END IF;\r\n'
      || E'  SELECT * INTO v_entrega FROM public.entregas_equipamentos WHERE ficha_id=p_ficha AND demanda_origem_id IS NULL FOR UPDATE;';
    if (length(v_def) - length(replace(v_def, v_velho, ''))) / length(v_velho) <> 1 then
      raise exception 'mc_corrigir_quantidades_ficha: consulta da entrega não encontrada. Revisar antes de migrar.';
    end if;
    execute replace(v_def, v_velho, v_novo);
  end if;
end
$ajustes$;

commit;

notify pgrst, 'reload schema';
