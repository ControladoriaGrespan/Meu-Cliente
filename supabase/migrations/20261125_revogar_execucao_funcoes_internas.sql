-- 2026-11-25 — Revoga a execução externa (anon/authenticated/PUBLIC) de funções
-- SECURITY DEFINER de uso interno, que não têm checagem do usuário chamador.
--
-- Contexto:
--   * Nenhuma delas é chamada pelo frontend (index.html / viabilidade-financeira.js).
--   * As chamadoras no banco (atualizar_tabela_preco_ficha, enviar_programacao_rota,
--     trg_sincronizar_aprovacoes_programacao_rota, v45_reset_fluxo_ficha,
--     v45_reset_fluxo_solicitacao) são SECURITY DEFINER do dono postgres e
--     continuam com permissão de execução.
--   * contato_administrador_sistema devolvia nome e telefone de um administrador
--     a chamadas sem login.
--
-- Idempotente. Já aplicado em produção em 25/11/2026.
-- Para reverter: GRANT EXECUTE ON FUNCTION <função> TO anon, authenticated;

revoke execute on function public.contato_administrador_sistema() from public, anon, authenticated;
revoke execute on function public.sincronizar_aprovacoes_programacao_rota(uuid) from public, anon, authenticated;
revoke execute on function public.v45_montar_fluxo_ficha_core(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.v45_montar_fluxo_solicitacao_core(uuid) from public, anon, authenticated;
revoke execute on function public.detectar_tabela_preco(numeric) from public, anon, authenticated;
revoke execute on function public.exemplo() from public, anon, authenticated;
