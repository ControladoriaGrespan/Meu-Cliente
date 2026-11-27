-- Meu Cliente — Grespan
-- Visita Técnica: o Coordenador Técnico pode aprovar (ou devolver) qualquer agenda semanal
-- pendente, seja enviada por Líder Técnico ou por Supervisor Técnico.
-- Antes, ele só decidia agendas de Supervisor Técnico vinculado a ele.
-- O Supervisor Técnico continua aprovando as agendas dos Líderes da sua equipe.
--
-- Troca um trecho da função vt_tramitar_agenda, conferido por contagem. Idempotente.
-- Não altera dados.

do $agenda$
declare
  v_def text;
  v_velho text := E'OR (a.origem_papel=''supervisor_tec_panificacao'' AND a.coordenador_id=auth.uid()\r\n      AND public.vt_papel()=''coordenador_tec_panificacao'')';
  v_novo text := E'OR public.vt_papel()=''coordenador_tec_panificacao'' -- mc: aprova todas as agendas técnicas';
begin
  select pg_get_functiondef(p.oid) into strict v_def
    from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'vt_tramitar_agenda';
  if position('mc: aprova todas as agendas' in v_def) = 0 then
    if (length(v_def) - length(replace(v_def, v_velho, ''))) / length(v_velho) <> 1 then
      raise exception 'vt_tramitar_agenda: regra de alçada do Coordenador não encontrada. Revisar antes de migrar.';
    end if;
    execute replace(v_def, v_velho, v_novo);
  end if;
end
$agenda$;
