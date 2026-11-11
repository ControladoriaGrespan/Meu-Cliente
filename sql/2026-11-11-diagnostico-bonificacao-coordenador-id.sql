-- Diagnóstico seguro da bonificação do Coordenador (sem alterações)
-- O ID previamente utilizado não foi confirmado na base.
-- Não presumir que o UUID exibido na mensagem de erro pertence ao registro certo.
SELECT
  s.id,s.codigo,s.status_fluxo,s.categoria,s.pedido_id,s.created_at,
  c.codigo_totvs,c.razao_social,
  COUNT(a.id) AS etapas_total,
  COUNT(a.id) FILTER (WHERE a.etapa='coordenador' AND a.status='aprovado') AS coordenador_aprovado,
  COUNT(a.id) FILTER (WHERE a.status='pendente') AS etapas_pendentes,
  COUNT(a.id) FILTER (WHERE a.status='aguardando') AS etapas_aguardando,
  COUNT(a.id) FILTER (WHERE a.status='reprovado') AS etapas_reprovadas
FROM public.solicitacoes s
LEFT JOIN public.clientes c ON c.id=s.cliente_id
LEFT JOIN public.solicitacao_aprovacoes a ON a.solicitacao_id=s.id
WHERE s.id='0e5f373f-b7ba-4672-baa6-e9bebb02b978'::uuid
   OR (s.categoria='bonificacao' AND s.created_at>=now()-interval '14 days')
GROUP BY s.id,s.codigo,s.status_fluxo,s.categoria,s.pedido_id,s.created_at,c.codigo_totvs,c.razao_social
ORDER BY s.created_at DESC
LIMIT 100;

-- Verifique as etapas após identificar o código ou UUID correto:
-- SELECT s.codigo, a.id,a.etapa,a.ordem,a.status,a.aprovador_id,a.decidido_em
-- FROM public.solicitacao_aprovacoes a JOIN public.solicitacoes s ON s.id=a.solicitacao_id
-- WHERE s.id='<UUID-CONFIRMADO>'::uuid ORDER BY a.ordem;
