-- Diagnóstico somente leitura: bonificação que falhou na aprovação da Diretoria.
-- NÃO modifica aprovações nem desbloqueia pedidos.
SELECT s.id,s.codigo,s.categoria,s.tipo,s.status_fluxo,s.pedido_id,
       s.cliente_id,c.codigo_totvs,c.razao_social
FROM public.solicitacoes s
LEFT JOIN public.clientes c ON c.id=s.cliente_id
WHERE s.id='df45a840-d935-40a0-98d4-eab4796b2ecb'::uuid;

SELECT s.codigo,a.id AS aprovacao_id,a.etapa,a.ordem,a.status,a.responsavel_id,a.aprovador_id,a.decidido_em
FROM public.solicitacao_aprovacoes a
JOIN public.solicitacoes s ON s.id=a.solicitacao_id
WHERE a.solicitacao_id='df45a840-d935-40a0-98d4-eab4796b2ecb'::uuid
ORDER BY a.ordem,a.id;

SELECT t.tgname AS trigger_nome,
       pg_get_triggerdef(t.oid,true) AS definicao,
       pg_get_functiondef(t.tgfoid) AS codigo_funcao
FROM pg_trigger t
WHERE t.tgrelid='public.solicitacao_aprovacoes'::regclass
  AND NOT t.tgisinternal
ORDER BY t.tgname;

-- Conferir se houve mudança inesperada no histórico:
SELECT a.solicitacao_id,
       count(*) FILTER(WHERE a.status='reprovado') AS reprovacoes,
       count(*) FILTER(WHERE a.status IN ('pendente','aguardando')) AS etapas_abertas,
       bool_or(a.etapa='financeiro' AND a.status='aprovado') AS financeiro_aprovou,
       bool_or(a.etapa='diretoria' AND a.status='aprovado') AS diretoria_aprovou
FROM public.solicitacao_aprovacoes a
WHERE a.solicitacao_id='df45a840-d935-40a0-98d4-eab4796b2ecb'::uuid
GROUP BY a.solicitacao_id;
