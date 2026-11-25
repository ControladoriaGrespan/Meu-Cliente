-- 2026-11-25 — Fluxo de ajuste da ficha de cliente.
--
-- Regra de negócio:
--   * Supervisor ou Coordenador reprova (com observação): o vendedor pode editar a
--     ficha inteira e reenviar.
--   * Financeiro ganha a decisão "Solicitar ajuste": devolve a ficha ao vendedor,
--     que edita e reenvia. O "Reprovar" do Financeiro continua como era.
--   * Ao reenviar uma ficha ajustada, a aprovação RECOMEÇA DO INÍCIO da fila
--     (inclusive Análise de Crédito), porque qualquer campo pode ter mudado.
--   * Diretoria e Análise de Crédito não têm ajuste.
--
-- O que este arquivo cria:
--   1. ficha_aprovacoes.ajuste_solicitado_em — marca o "Solicitar ajuste" do Financeiro.
--      Vale somente enquanto for igual a decidido_em da mesma linha; uma decisão
--      posterior na etapa invalida a marca sozinha.
--   2. ficha_reenvios.dados_anteriores — cópia da ficha e da fila antes do ajuste.
--   3. mc_solicitar_ajuste_ficha(...)   — Financeiro devolve a ficha para ajuste.
--   4. mc_reenviar_ficha_ajustada(...)  — vendedor grava a ficha ajustada e reinicia a fila.
--
-- Idempotente. Não altera dados existentes. Não mexe em decidir_ficha_workflow nem em
-- mc_reenviar_ficha_com_documentos (reenvio só com documentos, que continua valendo
-- para as recusas sem ajuste).
--
-- Para reverter:
--   drop function if exists public.mc_reenviar_ficha_ajustada(uuid, uuid, timestamptz, jsonb);
--   drop function if exists public.mc_solicitar_ajuste_ficha(uuid, text);
--   (as duas colunas podem ficar; são nulas e ninguém mais as lê)

alter table public.ficha_aprovacoes add column if not exists ajuste_solicitado_em timestamptz;
alter table public.ficha_reenvios   add column if not exists dados_anteriores jsonb;

comment on column public.ficha_aprovacoes.ajuste_solicitado_em is
  'Financeiro pediu ajuste ao vendedor. Só vale se for igual a decidido_em da mesma linha.';
comment on column public.ficha_reenvios.dados_anteriores is
  'Ficha e fila de aprovação como estavam antes do ajuste: {"ficha": {...}, "aprovacoes": [...]}.';

-- ---------------------------------------------------------------------------
-- Financeiro: devolver a ficha ao vendedor para ajuste
-- ---------------------------------------------------------------------------
create or replace function public.mc_solicitar_ajuste_ficha(p_aprovacao uuid, p_observacao text)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_etapa text;
begin
  if auth.uid() is null then
    raise exception 'Usuário não autenticado';
  end if;
  if nullif(btrim(coalesce(p_observacao, '')), '') is null then
    raise exception 'Informe o que o vendedor precisa ajustar.';
  end if;

  select a.etapa into v_etapa
  from public.ficha_aprovacoes a
  where a.id = p_aprovacao
  for update;
  if not found then
    raise exception 'Etapa de aprovação não localizada';
  end if;
  if v_etapa <> 'financeiro' then
    raise exception 'O pedido de ajuste está disponível somente na etapa Financeiro.';
  end if;

  -- Quem pode decidir, a ordem da fila e o bloqueio das etapas seguintes continuam
  -- sendo conferidos pela função e pelos gatilhos que já existem.
  perform public.decidir_ficha_workflow(p_aprovacao, 'reprovado', p_observacao);

  update public.ficha_aprovacoes
  set ajuste_solicitado_em = decidido_em
  where id = p_aprovacao and status = 'reprovado';
end;
$$;

-- ---------------------------------------------------------------------------
-- Vendedor: gravar a ficha ajustada e reiniciar a aprovação
-- ---------------------------------------------------------------------------
create or replace function public.mc_reenviar_ficha_ajustada(
  p_ficha uuid, p_aprovacao uuid, p_recusado_em timestamptz, p_dados jsonb)
returns text
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_usuario uuid := auth.uid();
  v_antiga  public.fichas_clientes%rowtype;
  v_nova    public.fichas_clientes%rowtype;
  d         public.fichas_clientes%rowtype;
  v_recusa  public.ficha_aprovacoes%rowtype;
  v_fila    jsonb;
  v_etapa   text;
begin
  if v_usuario is null or not exists (
    select 1 from public.usuarios u where u.id = v_usuario and u.ativo is true
  ) then
    raise exception 'Usuário sem acesso ativo.';
  end if;

  select * into v_antiga from public.fichas_clientes f
  where f.id = p_ficha and f.vendedor_id = v_usuario
  for update;
  if not found then
    raise exception 'Somente o autor da ficha pode ajustá-la.';
  end if;

  perform 1 from public.ficha_aprovacoes a
  where a.ficha_id = p_ficha order by a.ordem, a.id for update;

  select * into v_recusa from public.ficha_aprovacoes a
  where a.ficha_id = p_ficha and a.id = p_aprovacao and a.status = 'reprovado';
  if not found or v_recusa.decidido_em is distinct from p_recusado_em then
    raise exception 'A recusa foi alterada. Atualize a ficha antes de tentar novamente.';
  end if;

  if not (
    v_recusa.etapa in ('supervisor', 'coordenador')
    or (v_recusa.etapa = 'financeiro'
        and v_recusa.ajuste_solicitado_em is not null
        and v_recusa.ajuste_solicitado_em = v_recusa.decidido_em)
  ) then
    raise exception 'Esta recusa não permite ajuste da ficha.';
  end if;

  -- Mesma conferência do reenvio com documentos: nada decidido depois da recusa
  -- e tudo aprovado antes dela.
  if exists (
    select 1 from public.ficha_aprovacoes a
    where a.ficha_id = p_ficha and a.id <> v_recusa.id
      and (
        (a.ordem < v_recusa.ordem and a.status not in ('aprovado', 'nao_aplica'))
        or a.ordem = v_recusa.ordem
        or (a.ordem > v_recusa.ordem and a.status not in ('pendente', 'aguardando', 'nao_aplica'))
      )
  ) then
    raise exception 'A fila da ficha possui decisões incompatíveis com o reenvio.';
  end if;

  if p_dados is null or jsonb_typeof(p_dados) <> 'object' then
    raise exception 'Dados da ficha não informados.';
  end if;
  d := jsonb_populate_record(null::public.fichas_clientes, p_dados);

  if nullif(btrim(coalesce(d.razao_social, '')), '') is null then
    raise exception 'Informe a Razão Social.';
  end if;
  if length(regexp_replace(coalesce(d.cnpj_cpf, ''), '\D', '', 'g')) <> 14 then
    raise exception 'Informe o CNPJ com 14 dígitos.';
  end if;
  if d.preco_kg is null or d.preco_kg <= 0 then
    raise exception 'Informe o Preço por Kg.';
  end if;
  if d.consumo_previsto is null or d.consumo_previsto < 1 or d.consumo_previsto <> trunc(d.consumo_previsto) then
    raise exception 'Informe o Consumo Previsto em pães por dia, número inteiro.';
  end if;

  -- Guarda a versão anterior antes de qualquer alteração.
  select jsonb_agg(to_jsonb(a) order by a.ordem, a.id) into v_fila
  from public.ficha_aprovacoes a where a.ficha_id = p_ficha;

  insert into public.ficha_reenvios(
    ficha_id, etapa, motivo_recusa, recusado_por, recusado_em, reenviado_por, dados_anteriores)
  values (
    p_ficha, v_recusa.etapa, v_recusa.observacao, v_recusa.aprovador_id, v_recusa.decidido_em, v_usuario,
    jsonb_build_object('ficha', to_jsonb(v_antiga), 'aprovacoes', v_fila));

  -- Somente os campos do formulário do vendedor. Código, vendedor, número do acordo,
  -- análise de crédito e condição definida pela Diretoria não são tocados.
  -- tabela_preco_id é recalculada pelo gatilho trg_detectar_tabela_preco (preco_kg).
  update public.fichas_clientes f set
    razao_social = btrim(d.razao_social),
    nome_fantasia = d.nome_fantasia,
    cnpj_cpf = d.cnpj_cpf,
    representante_nome = d.representante_nome,
    representante_cpf = d.representante_cpf,
    rua = d.rua, numero = d.numero, bairro = d.bairro,
    cidade = d.cidade, estado = d.estado, cep = d.cep,
    entrega_rua = d.entrega_rua, entrega_numero = d.entrega_numero, entrega_bairro = d.entrega_bairro,
    entrega_cidade = d.entrega_cidade, entrega_estado = d.entrega_estado, entrega_cep = d.entrega_cep,
    telefone = d.telefone, email = d.email,
    numero_checkouts = d.numero_checkouts, numero_lojas = d.numero_lojas,
    contrato = d.contrato, contrato_prazo_meses = d.contrato_prazo_meses,
    preco_kg = d.preco_kg, prazo_pagamento = d.prazo_pagamento, consumo_previsto = d.consumo_previsto,
    verba_introducao = coalesce(d.verba_introducao, 0),
    verbas_acordo = coalesce(d.verbas_acordo, d.verba_introducao, 0),
    duracao_verba = d.duracao_verba,
    tecnico_panificacao = d.tecnico_panificacao,
    senioridade_tecnico = d.senioridade_tecnico,
    tecnico_periodicidade = d.tecnico_periodicidade,
    precisa_equipamento = d.precisa_equipamento,
    equipamento_condicao = d.equipamento_condicao,
    forno_tipo = d.forno_tipo, forno_quantidade = d.forno_quantidade, forno_esteiras = d.forno_esteiras,
    freezer_tipos = d.freezer_tipos, armario_tipo = d.armario_tipo, camara_climatica = d.camara_climatica,
    esteiras_quantidade = d.esteiras_quantidade, assadeiras_quantidade = d.assadeiras_quantidade,
    equipamentos_quantidades = coalesce(d.equipamentos_quantidades, '{}'::jsonb),
    bonificacao_percentual = coalesce(d.bonificacao_percentual, 0),
    bonificacao_periodicidade = d.bonificacao_periodicidade,
    bonificacao_modalidade = d.bonificacao_modalidade,
    observacoes = d.observacoes,
    updated_at = now()
  where f.id = p_ficha
  returning * into v_nova;

  -- O cadastro de cliente nasce junto com a ficha (trg_criar_cliente) copiando estes dados.
  -- Enquanto o cliente ainda não foi integrado ao TOTVS, acompanha a ficha — mas só nos
  -- campos que continuam iguais ao que a ficha antiga tinha gerado (não desfaz edição manual).
  update public.clientes c set
    razao_social  = case when c.razao_social  is not distinct from v_antiga.razao_social  then v_nova.razao_social  else c.razao_social  end,
    cnpj_cpf      = case when c.cnpj_cpf      is not distinct from v_antiga.cnpj_cpf      then v_nova.cnpj_cpf      else c.cnpj_cpf      end,
    nome_fantasia = case when c.nome_fantasia is not distinct from v_antiga.nome_fantasia then v_nova.nome_fantasia else c.nome_fantasia end,
    telefone      = case when c.telefone      is not distinct from v_antiga.telefone      then v_nova.telefone      else c.telefone      end,
    email         = case when c.email         is not distinct from v_antiga.email         then v_nova.email         else c.email         end,
    cidade = case when c.cidade is not distinct from v_antiga.cidade
                    or c.cidade is not distinct from v_antiga.entrega_cidade
                  then coalesce(nullif(btrim(v_nova.entrega_cidade), ''), nullif(btrim(v_nova.cidade), ''), c.cidade) else c.cidade end,
    estado = case when c.estado is not distinct from v_antiga.estado
                    or c.estado is not distinct from v_antiga.entrega_estado
                  then coalesce(nullif(btrim(v_nova.entrega_estado), ''), nullif(btrim(v_nova.estado), ''), c.estado) else c.estado end,
    endereco_logradouro = case when c.endereco_logradouro is not distinct from coalesce(nullif(btrim(v_antiga.entrega_rua), ''), nullif(btrim(v_antiga.rua), ''))
                  then coalesce(nullif(btrim(v_nova.entrega_rua), ''), nullif(btrim(v_nova.rua), '')) else c.endereco_logradouro end,
    endereco_numero = case when c.endereco_numero is not distinct from coalesce(nullif(btrim(v_antiga.entrega_numero), ''), nullif(btrim(v_antiga.numero), ''))
                  then coalesce(nullif(btrim(v_nova.entrega_numero), ''), nullif(btrim(v_nova.numero), '')) else c.endereco_numero end,
    endereco_bairro = case when c.endereco_bairro is not distinct from coalesce(nullif(btrim(v_antiga.entrega_bairro), ''), nullif(btrim(v_antiga.bairro), ''))
                  then coalesce(nullif(btrim(v_nova.entrega_bairro), ''), nullif(btrim(v_nova.bairro), '')) else c.endereco_bairro end,
    endereco_cep = case when c.endereco_cep is not distinct from coalesce(nullif(btrim(v_antiga.entrega_cep), ''), nullif(btrim(v_antiga.cep), ''))
                  then coalesce(nullif(btrim(v_nova.entrega_cep), ''), nullif(btrim(v_nova.cep), '')) else c.endereco_cep end
  where c.ficha_id = p_ficha and c.origem = 'ficha' and c.codigo_totvs is null;

  -- Tabela de preço do cliente: acompanha a da ficha somente se ainda era a mesma.
  if v_nova.tabela_preco_id is distinct from v_antiga.tabela_preco_id then
    update public.clientes c set tabela_preco_id = v_nova.tabela_preco_id
    where c.ficha_id = p_ficha and c.origem = 'ficha' and c.codigo_totvs is null
      and c.tabela_preco_id is not distinct from v_antiga.tabela_preco_id;
  end if;

  -- Reinicia a fila. Etapas "não se aplica" continuam assim; as demais voltam a
  -- aguardar, sem decisão, e a primeira delas fica na vez.
  update public.ficha_aprovacoes set
    status = case when status = 'nao_aplica' then 'nao_aplica' else 'aguardando' end,
    observacao = case when status = 'nao_aplica' then observacao else null end,
    aprovador_id = null,
    decidido_em = null,
    ajuste_solicitado_em = null
  where ficha_id = p_ficha;

  update public.ficha_aprovacoes set status = 'pendente', criado_em = now()
  where id = (
    select a.id from public.ficha_aprovacoes a
    where a.ficha_id = p_ficha and a.status = 'aguardando'
    order by a.ordem, a.id limit 1)
  returning etapa into v_etapa;

  if v_etapa is null then
    raise exception 'A ficha não tem etapa de aprovação disponível para o reenvio.';
  end if;
  return v_etapa;
end;
$$;

-- Somente usuários logados executam (o padrão do schema liberaria também chamadas sem login).
revoke execute on function public.mc_solicitar_ajuste_ficha(uuid, text) from public, anon;
revoke execute on function public.mc_reenviar_ficha_ajustada(uuid, uuid, timestamptz, jsonb) from public, anon;
grant execute on function public.mc_solicitar_ajuste_ficha(uuid, text) to authenticated;
grant execute on function public.mc_reenviar_ficha_ajustada(uuid, uuid, timestamptz, jsonb) to authenticated;
