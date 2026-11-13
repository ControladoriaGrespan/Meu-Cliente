-- MEU CLIENTE v109 | Solicitações novas: originador confirmado -> próximo aprovador pendente.
-- Corrige vendedor=pendente e supervisor=aguardando depois do envio.
-- Inclui fluxos iniciados em Supervisor/Coordenador.
-- Exige v99+v103 e estrutura das etapas. Execute com backup.
BEGIN;

CREATE OR REPLACE FUNCTION public.v45_montar_fluxo_solicitacao_core(p_sol uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE
 s public.solicitacoes%ROWTYPE;
 v_papel text; v_sup uuid; v_coord uuid;
 v_vendedor uuid; v_ini integer; v_ord integer:=0;
 v_etapas text[]; v_et text; v_res uuid;
 v_i integer; v_estado text; v_auto boolean;
BEGIN
 SELECT * INTO s FROM public.solicitacoes WHERE id=p_sol;
 IF NOT FOUND THEN RAISE EXCEPTION 'Solicitação não encontrada'; END IF;
 -- Não reconstruir a fila existente: histórico e decisões ficam imutáveis.
 IF EXISTS(SELECT 1 FROM public.solicitacao_aprovacoes WHERE solicitacao_id=p_sol) THEN RETURN; END IF;
 SELECT u.papel::text,u.supervisor_id,u.coordenador_id INTO v_papel,v_sup,v_coord
 FROM public.usuarios u WHERE u.id=s.solicitante_id;
 IF v_papel IS NULL THEN RAISE EXCEPTION 'Solicitante sem perfil cadastrado'; END IF;
 SELECT c.vendedor_id INTO v_vendedor FROM public.clientes c WHERE c.id=s.cliente_id;
 IF v_sup IS NULL AND v_vendedor IS NOT NULL THEN
    SELECT u.supervisor_id INTO v_sup FROM public.usuarios u WHERE u.id=v_vendedor;
 END IF;
 IF v_coord IS NULL AND v_sup IS NOT NULL THEN
    SELECT u.coordenador_id INTO v_coord FROM public.usuarios u WHERE u.id=v_sup;
 END IF;
 IF v_coord IS NULL AND v_vendedor IS NOT NULL THEN
    SELECT u.coordenador_id INTO v_coord FROM public.usuarios u WHERE u.id=v_vendedor;
 END IF;
 IF s.categoria='bonificacao' THEN
   v_etapas:=ARRAY['vendedor','supervisor','coordenador','gestao_adm_vendas','financeiro','diretoria'];
 ELSIF s.categoria='equipamento' AND s.tipo='aumento' THEN
   v_etapas:=ARRAY['vendedor','supervisor','coordenador','gestao_adm_vendas','diretoria'];
 ELSIF s.categoria='equipamento' AND s.tipo='troca' THEN
   v_etapas:=ARRAY['vendedor','supervisor','coordenador','manutencao','diretoria'];
 ELSIF s.categoria='equipamento' AND s.tipo='retirada' THEN
   v_etapas:=ARRAY['vendedor','supervisor','coordenador'];
 ELSE
   -- Categorias fora do escopo permanecem com caminho legado.
   IF s.categoria='amostra' THEN
      v_etapas:=ARRAY['supervisor','coordenador','gestao_adm_vendas'];
   ELSIF s.tipo='manutencao' THEN
      v_etapas:=ARRAY['manutencao'];
   ELSE
      RAISE EXCEPTION 'Categoria/tipo não suportado para fluxo %/%',s.categoria,s.tipo;
   END IF;
 END IF;
 IF v_papel='vendedor' THEN v_ini:=1;
 ELSIF v_papel='supervisor' THEN v_ini:=2;
 ELSIF v_papel='coordenador' THEN v_ini:=3;
 ELSIF v_papel='admin' THEN v_ini:=2; -- admin usa fila operacional sem etapa pessoal
 ELSIF s.categoria='amostra' OR s.tipo='manutencao' THEN v_ini:=1;
 ELSE RAISE EXCEPTION 'Perfil % não pode iniciar este workflow',v_papel; END IF;

 FOR v_i IN v_ini..array_length(v_etapas,1) LOOP
   v_et:=v_etapas[v_i];
   v_res:=CASE v_et
      WHEN 'vendedor' THEN s.solicitante_id
      WHEN 'supervisor' THEN CASE WHEN v_papel='supervisor' THEN s.solicitante_id ELSE v_sup END
      WHEN 'coordenador' THEN CASE WHEN v_papel='coordenador' THEN s.solicitante_id ELSE v_coord END
      ELSE NULL END;
   -- Exigir hierarquia válida para não aprovar por ator não designado.
   IF v_et IN ('vendedor','supervisor','coordenador') AND v_res IS NULL THEN
      RAISE EXCEPTION 'Responsável não identificado para etapa % da solicitação %',v_et,p_sol;
   END IF;
   -- Bonificação: coordenador + gestão formam uma etapa compartilhada,
   -- com a mesma ordem; apenas uma das duas decisões será consumada.
   IF s.categoria='bonificacao' AND v_et='gestao_adm_vendas' THEN
      IF v_i>v_ini THEN CONTINUE; END IF;
   END IF;
   v_ord:=v_ord+1;
   -- Quem inicia a solicitação já manifestou sua decisão ao enviar.
   -- Registrar essa etapa como aprovada e liberar a próxima etapa,
   -- sem exigir que o originador aprove sua própria solicitação novamente.
   v_auto:=v_i=v_ini AND v_papel IN ('vendedor','supervisor','coordenador')
       AND v_et=v_papel AND s.categoria IN ('bonificacao','equipamento');
   v_estado:=CASE WHEN v_auto THEN 'aprovado'
      WHEN v_ord=1 OR (v_ord=2 AND v_ini<=3 AND v_papel IN ('vendedor','supervisor','coordenador')
                        AND s.categoria IN ('bonificacao','equipamento'))
      THEN 'pendente' ELSE 'aguardando' END;
   INSERT INTO public.solicitacao_aprovacoes
      (solicitacao_id,etapa,ordem,status,responsavel_id,aprovador_id,decidido_em)
   VALUES(p_sol,v_et,v_ord,v_estado,v_res,
     CASE WHEN v_auto THEN s.solicitante_id ELSE NULL END,
     CASE WHEN v_auto THEN s.created_at ELSE NULL END);
   IF s.categoria='bonificacao' AND v_et='coordenador' THEN
     INSERT INTO public.solicitacao_aprovacoes
       (solicitacao_id,etapa,ordem,status,responsavel_id)
     VALUES(p_sol,'gestao_adm_vendas',v_ord,
       CASE WHEN v_auto THEN 'nao_aplica' ELSE v_estado END,NULL);
   END IF;
 END LOOP;
END;
$$;


-- Regularização conservadora das solicitações abertas recentes, que ainda
-- não receberam nenhuma decisão, e que ficaram aguardando o próprio originador.
-- O código abaixo altera apenas solicitação criada em 13/11/2026 ou depois,
-- primeira etapa = papel do solicitante, status pendente, próxima etapa aguardando,
-- sem decisões existentes, sem etapas reprovadas ou aprovadas.
-- A conclusão é registrada como decisão de envio, sem inventar decisão do Supervisor.
DO $fix$
DECLARE r record; v_proxima integer;
BEGIN
 FOR r IN
  SELECT s.id,s.codigo,s.solicitante_id,s.created_at,u.papel::text AS papel,
         a.id AS primeira_id,a.ordem AS primeira_ordem
  FROM public.solicitacoes s
  JOIN public.usuarios u ON u.id=s.solicitante_id
  JOIN public.solicitacao_aprovacoes a ON a.solicitacao_id=s.id
  WHERE s.status_fluxo='aberta'
    AND s.created_at >= timestamptz '2026-11-13 00:00:00+00'
    AND s.categoria IN ('bonificacao','equipamento')
    AND u.papel::text IN ('vendedor','supervisor','coordenador')
    AND a.etapa=u.papel::text AND a.status='pendente'
    AND a.ordem=(SELECT MIN(aa.ordem) FROM public.solicitacao_aprovacoes aa WHERE aa.solicitacao_id=s.id)
    AND NOT EXISTS(
       SELECT 1 FROM public.solicitacao_aprovacoes aa WHERE aa.solicitacao_id=s.id
         AND aa.status IN ('aprovado','reprovado') OR aa.solicitacao_id=s.id AND aa.aprovador_id IS NOT NULL
    )
    AND NOT EXISTS(
       SELECT 1 FROM public.solicitacao_aprovacoes aa WHERE aa.solicitacao_id=s.id
         AND aa.status='pendente' AND aa.id<>a.id
    )
  FOR UPDATE OF s
 LOOP
   SELECT min(ordem) INTO v_proxima FROM public.solicitacao_aprovacoes
   WHERE solicitacao_id=r.id AND ordem>r.primeira_ordem AND status='aguardando';
   IF v_proxima IS NULL THEN CONTINUE; END IF;
   UPDATE public.solicitacao_aprovacoes
      SET status='aprovado',aprovador_id=r.solicitante_id,decidido_em=r.created_at
      WHERE id=r.primeira_id AND status='pendente';
   UPDATE public.solicitacao_aprovacoes
      SET status='pendente'
      WHERE solicitacao_id=r.id AND ordem=v_proxima AND status='aguardando';
   RAISE NOTICE '%: origem registrada e etapa % liberada',r.codigo,v_proxima;
 END LOOP;
END;
$fix$;
COMMIT;

-- Verificação das solicitações recentes e suas etapas
SELECT s.codigo,s.categoria,s.tipo,s.status_fluxo,
       a.ordem,a.etapa,a.status,a.responsavel_id,a.aprovador_id
FROM public.solicitacoes s
JOIN public.solicitacao_aprovacoes a ON a.solicitacao_id=s.id
WHERE s.created_at >= timestamptz '2026-11-13 00:00:00+00'
ORDER BY s.created_at DESC,a.ordem LIMIT 120;
