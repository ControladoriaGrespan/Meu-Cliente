-- Investigação da BON-000016 (cliente 003572)
-- Consultas somente leitura. Não alteram pedidos ou bonificações.
-- 1. Confere se o vínculo da solicitação é o mesmo cliente da rota.
SELECT
 s.id AS solicitacao_id, s.codigo AS codigo_bonificacao,
 s.categoria,s.tipo,s.status_fluxo,s.cliente_id AS cliente_id_bonificacao,
 c.codigo_totvs AS codigo_cliente_bonificacao,c.razao_social AS cliente_bonificacao,
 s.produto_id,s.quantidade,s.pedido_id,
 EXISTS(SELECT 1 FROM public.solicitacao_aprovacoes a WHERE a.solicitacao_id=s.id AND a.etapa='financeiro' AND a.status='aprovado') AS financeiro_aprovou,
 EXISTS(SELECT 1 FROM public.solicitacao_aprovacoes a WHERE a.solicitacao_id=s.id AND a.etapa='diretoria' AND a.status='aprovado') AS diretoria_aprovou,
 NOT EXISTS(SELECT 1 FROM public.solicitacao_aprovacoes a WHERE a.solicitacao_id=s.id AND a.status NOT IN ('aprovado','nao_aplica')) AS todas_etapas_concluidas
FROM public.solicitacoes s
LEFT JOIN public.clientes c ON c.id=s.cliente_id
WHERE s.codigo='BON-000016' OR c.codigo_totvs='003572'
ORDER BY s.created_at DESC;

-- 2. Confira possíveis cadastros duplicados de código TOTVS e seus IDs.
SELECT id,codigo_totvs,razao_social,vendedor_id
FROM public.clientes
WHERE codigo_totvs='003572'
ORDER BY razao_social;

-- 3. Verifique o status real das etapas da BON-000016.
SELECT s.codigo,a.etapa,a.ordem,a.status,a.responsavel_id,a.decidido_em
FROM public.solicitacao_aprovacoes a
JOIN public.solicitacoes s ON s.id=a.solicitacao_id
WHERE s.codigo='BON-000016'
ORDER BY a.ordem;
