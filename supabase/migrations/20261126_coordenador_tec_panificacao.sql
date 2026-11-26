-- Meu Cliente — Grespan
-- Hierarquia técnica separada da comercial:
--   Comercial: Vendedor -> Supervisor -> Coordenador
--   Técnica:   Técnico -> Líder Técnico -> Supervisor Técnico -> Coordenador Técnico
--
-- Cria o perfil coordenador_tec_panificacao e passa para ele, no módulo de Visita Técnica,
-- tudo o que hoje é do Coordenador Comercial: aprovar a agenda semanal dos Supervisores
-- Técnicos, aprovar visitas de exceção e enxergar agendas e visitas. O Coordenador
-- Comercial sai do módulo de Visita Técnica; nada muda para ele em Vendas.
--
-- Idempotente. Não apaga registros. Alterações de dados: desativa a liberação do módulo
-- de Visita Técnica dos Coordenadores Comerciais e limpa o vínculo de coordenador gravado
-- em Líderes/Técnicos (campo que nenhuma regra usa e que passaria a ser inválido).
-- O vínculo dos Supervisores Técnicos NÃO é alterado aqui: deve ser refeito para o
-- Coordenador Técnico pela tela de usuários (ou por SQL específico).

begin;

-- 1) Perfil novo aceito no cadastro de usuários.
alter table public.usuarios drop constraint if exists usuarios_papel_check;
alter table public.usuarios add constraint usuarios_papel_check check (
  papel = any (array[
    'vendedor','supervisor','coordenador','analise_credito','financeiro','manutencao',
    'adm_vendas','gestao_adm_vendas','tecnico','supervisor_tec_panificacao',
    'lider_tec_panificacao','tec_panificacao','coordenador_tec_panificacao',
    'diretoria','admin','motorista_manutencao'
  ])
);

-- 2) Validação da hierarquia: equipe técnica só aceita Coordenador Técnico;
--    os demais perfis continuam aceitando só o Coordenador Comercial.
create or replace function public.validar_hierarquia_usuario_ativo()
returns trigger
language plpgsql
set search_path = public
as $$
DECLARE
  v_papel text;
  v_papel_coord text;
BEGIN
  IF NEW.supervisor_id IS NOT NULL
     AND (
       TG_OP = 'INSERT'
       OR OLD.supervisor_id IS DISTINCT FROM NEW.supervisor_id
       OR OLD.papel IS DISTINCT FROM NEW.papel
     )
  THEN
    SELECT s.papel::text
      INTO v_papel
      FROM public.usuarios s
     WHERE s.id = NEW.supervisor_id
       AND s.ativo = true;

    IF NOT (
      (NEW.papel::text = 'vendedor'
        AND v_papel = 'supervisor')
      OR
      (NEW.papel::text = 'lider_tec_panificacao'
        AND v_papel = 'supervisor_tec_panificacao')
      OR
      (NEW.papel::text = 'tec_panificacao'
        AND v_papel = 'lider_tec_panificacao')
    ) THEN
      RAISE EXCEPTION
        'Hierarquia inválida para o perfil % e responsável %',
        NEW.papel, COALESCE(v_papel, 'inativo ou inexistente');
    END IF;
  END IF;

  IF NEW.coordenador_id IS NOT NULL
     AND (
       TG_OP = 'INSERT'
       OR OLD.coordenador_id IS DISTINCT FROM NEW.coordenador_id
     )
  THEN
    v_papel_coord := CASE
      WHEN NEW.papel::text IN ('supervisor_tec_panificacao','lider_tec_panificacao','tec_panificacao')
        THEN 'coordenador_tec_panificacao'
      ELSE 'coordenador'
    END;
    IF NOT EXISTS (
      SELECT 1
        FROM public.usuarios c
       WHERE c.id = NEW.coordenador_id
         AND c.papel::text = v_papel_coord
         AND c.ativo = true
    ) THEN
      IF v_papel_coord = 'coordenador_tec_panificacao' THEN
        RAISE EXCEPTION
          'O coordenador selecionado está inativo ou não possui papel de Coordenador Técnico';
      END IF;
      RAISE EXCEPTION
        'O coordenador selecionado está inativo ou não possui papel de Coordenador';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

-- 3) Funções do módulo de Visita Técnica: onde a regra citava o Coordenador Comercial,
--    passa a valer o Coordenador Técnico. A troca é feita sobre a definição que está no
--    banco, conferindo a quantidade de ocorrências esperada em cada função.
do $troca$
declare
  r record;
  v_def text;
  v_n int;
begin
  for r in
    select * from (values
      ('vt_agenda_visivel', 1),
      ('vt_visita_visivel', 1),
      ('vt_buscar_clientes', 2),
      ('vt_decidir_excecao', 1),
      ('vt_tramitar_agenda', 2)
    ) as t(nome, esperado)
  loop
    select pg_get_functiondef(p.oid) into strict v_def
      from pg_proc p
     where p.pronamespace = 'public'::regnamespace and p.proname = r.nome;
    select count(*) into v_n from regexp_matches(v_def, '''coordenador''', 'g');
    if v_n = 0 then
      continue; -- já migrada
    elsif v_n <> r.esperado then
      raise exception 'Função %: esperava % ocorrência(s) de coordenador, encontrei %. Revisar antes de migrar.',
        r.nome, r.esperado, v_n;
    end if;
    v_def := replace(v_def, '''coordenador''', '''coordenador_tec_panificacao''');
    v_def := replace(v_def, 'Somente Coordenador Comercial pode aprovar exceções',
                            'Somente Coordenador Técnico pode aprovar exceções');
    execute v_def;
  end loop;
end
$troca$;

-- 4) Regras de leitura (RLS) das agendas e das exceções: mesma troca.
do $pol$
declare
  r record;
  v_qual text;
begin
  for r in
    select * from (values
      ('agendas_tecnicas_semanais', 'vt_agendas_select'),
      ('vt_aprovacoes_excecao', 'vt_excecoes_select')
    ) as t(tabela, politica)
  loop
    select qual into strict v_qual
      from pg_policies
     where schemaname = 'public' and tablename = r.tabela and policyname = r.politica;
    if position('''coordenador''::text' in v_qual) = 0 then
      continue; -- já migrada
    end if;
    execute format('alter policy %I on public.%I using (%s)', r.politica, r.tabela,
      replace(v_qual, '''coordenador''::text', '''coordenador_tec_panificacao''::text'));
  end loop;
end
$pol$;

-- 5) Quando o Coordenador de um Supervisor Técnico muda, as agendas dele que ainda não
--    foram aprovadas passam a apontar para o novo Coordenador (senão ficariam presas ao antigo).
create or replace function public.mc_sincronizar_coordenador_agendas()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.papel = 'supervisor_tec_panificacao'
     and new.coordenador_id is distinct from old.coordenador_id then
    update public.agendas_tecnicas_semanais a
       set coordenador_id = new.coordenador_id, atualizado_em = now()
     where a.supervisor_id = new.id
       and a.origem_papel = 'supervisor_tec_panificacao'
       and a.status in ('rascunho', 'devolvida', 'pendente')
       and a.coordenador_id is distinct from new.coordenador_id;
  end if;
  return null;
end;
$$;

revoke all on function public.mc_sincronizar_coordenador_agendas() from public, anon, authenticated;

drop trigger if exists trg_mc_sincronizar_coordenador_agendas on public.usuarios;
create trigger trg_mc_sincronizar_coordenador_agendas
  after update of coordenador_id on public.usuarios
  for each row execute function public.mc_sincronizar_coordenador_agendas();

-- 6) Coordenador Comercial sai do módulo de Visita Técnica.
update public.usuario_modulos m
   set ativo = false
  from public.usuarios u
 where u.id = m.usuario_id
   and u.papel = 'coordenador'
   and m.modulo = 'visita_tecnica'
   and m.ativo;

-- 7) Vínculo de coordenador em Líder/Técnico: nenhuma regra usa esse campo e o valor
--    gravado (Coordenador Comercial) deixou de ser válido para a equipe técnica.
update public.usuarios
   set coordenador_id = null
 where papel in ('lider_tec_panificacao', 'tec_panificacao')
   and coordenador_id is not null;

commit;

notify pgrst, 'reload schema';
