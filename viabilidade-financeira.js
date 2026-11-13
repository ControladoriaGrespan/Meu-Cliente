// Referências TABARATO.xlsx (valores históricos; forno provisório, catálogo externo ausente).
const MC_CUSTOS_TABARATO={forno_gas:4998,forno_eletrico:4998,forno:4998,
freezer_horizontal:2984.46,freezer_vertical:7174.18,expositor:9750,mini_camara:8444.17,
armario_completo:2077.99,armario_vazio:1277.79,armario_esqueleto:1023.82,
camara_20:11250,camara_40:12250,esteiras:40.01,assadeiras:54.76,forno_queijo:3089.71};
const MC_PREMISSAS_TABARATO={custo_pct:60,tributos_pct:7,ir_csll_pct:34,despesa_kg:3.4728980165837706};

/* Meu Cliente v111 - Análise Financeira. Requer React, h, sb, Campo, fmtMoeda do index.html. */
function mcCalculoViabilidade(f,p,eq){
 const n=x=>Number(x)||0;
 const kg=n(f.consumo_previsto)*0.080*26,receita=kg*n(f.preco_kg);
 const custo=p.custo_pct===''?null:n(p.custo_pct)/100;
 const trib=p.tributos_pct===''?null:n(p.tributos_pct)/100;
 const bon=n(f.bonificacao_percentual)/100;
 const periodicidade=String(f.bonificacao_periodicidade||'todos os pedidos').toLowerCase();
 const desconto=String(f.bonificacao_modalidade||'Produto').toLowerCase().includes('desconto');
 const introducao=n(f.verba_introducao),prazo=parseInt(f.duracao_verba,10)||0;
 const faltas=[];
 if(!receita)faltas.push('Preço ou consumo da Ficha');
 if(custo===null)faltas.push('Custo de produção');
 if(trib===null)faltas.push('Tributos');
 if(introducao&&prazo<1)faltas.push('Prazo da introdução');
 if(eq.some(x=>x.valor===''))faltas.push('Custo de equipamentos');
 if(bon&&periodicidade.includes('1 pedido')&&p.pedido_ref==='')faltas.push('Valor de um pedido');
 const investimento=eq.reduce((s,x)=>s+n(x.qtd)*n(x.valor),0)*
  (String(f.equipamento_condicao||'').toLowerCase().includes('usado')?n(p.fator_usado)/100:1);
 let acumulado=-investimento,payback=null,primeiro=null;const anos=[];
 for(let mes=1;mes<=60;mes++){
  const fat=receita*Math.pow(1+n(p.reajuste)/100,Math.floor((mes-1)/12));
  const bonBase=periodicidade.includes('1 pedido')?n(p.pedido_ref)*fat/(receita||1):fat;
  const bonificacao=periodicidade.includes('1 parcela')&&mes>1?0:bonBase*bon;
  const custoBonus=bonificacao*(desconto?1:(custo||0));
  const intMes=mes<=prazo&&prazo?introducao/prazo:0;
  const prod=fat*(custo||0),impostos=fat*(trib||0);
  const despesas=n(p.despesas)+n(p.pix)+n(p.boleto)+n(p.nota);
  const operacionaisKg=kg*n(p.despesa_kg);
  const lucroTributavel=Math.max(0,fat-prod-impostos-despesas-operacionaisKg-custoBonus-intMes);
  const ircsll=lucroTributavel*n(p.ir_csll_pct)/100;
  const resultado=fat-prod-impostos-despesas-operacionaisKg-custoBonus-intMes-ircsll;
  if(mes===1)primeiro={fat,prod,impostos,despesas,operacionaisKg,ircsll,custoBonus,intMes,resultado};
  acumulado+=resultado;
  if(!faltas.length&&payback===null&&acumulado>=0)payback=mes;
  const idx=Math.floor((mes-1)/12);
  if(!anos[idx])anos[idx]={ano:idx+1,receita:0,prod:0,impostos:0,despesas:0,acordos:0,resultado:0};
  const a=anos[idx];a.receita+=fat;a.prod+=prod;a.impostos+=impostos;
  a.despesas+=despesas+operacionaisKg+ircsll;a.acordos+=custoBonus+intMes;a.resultado+=resultado;
 }
 return {kg,receita,investimento,primeiro,anos,payback,faltas,completo:!faltas.length};
}
function PaginaViabilidadeFinanceira({profile}){
 const toast=useToast();
 const ok=['financeiro','admin'].includes(profile.papel);
 const [busca,setBusca]=React.useState(''),[lista,setLista]=React.useState([]);
 const [fila,setFila]=React.useState('pendentes'),[situacoes,setSituacoes]=React.useState({});
 const [ficha,setFicha]=React.useState(null),[historico,setHistorico]=React.useState([]);
 const padrao={...MC_PREMISSAS_TABARATO,despesas:0,pix:0,boleto:0,nota:0,pedido_ref:'',reajuste:0,fator_usado:50};
 const [p,setP]=React.useState(padrao),[equip,setEquip]=React.useState([]);
 const [status,setStatus]=React.useState('rascunho'),[parecer,setParecer]=React.useState('');
 const [aba,setAba]=React.useState('premissas'),[erro,setErro]=React.useState(''),[busy,setBusy]=React.useState(false);
 const dinheiro=v=>fmtMoeda(Number(v)||0);
 const calc=ficha?mcCalculoViabilidade(ficha,p,equip):null;
 async function pesquisar(){
  setBusy(true);
  const [fr,ar]=await Promise.all([
   sb.rpc('mc_viabilidade_listar_fichas',{p_busca:busca.trim(),p_limite:300}),
   sb.from('mc_viabilidade_analises').select('ficha_id,situacao,atualizado_em')
  ]);
  setBusy(false);
  if(fr.error||ar.error){setErro('Falha ao consultar: '+(fr.error?.message||ar.error?.message));return;}
  const mapa={};(ar.data||[]).forEach(a=>mapa[a.ficha_id]=a);
  setSituacoes(mapa);setLista(Array.isArray(fr.data)?fr.data:[]);setErro('');
 }
 React.useEffect(()=>{if(ok)pesquisar();},[profile.id]);
 async function escolher(f){
  setFicha(f);setAba('premissas');setErro('');
  const {data:a,error}=await sb.from('mc_viabilidade_analises').select('*').eq('ficha_id',f.id).maybeSingle();
  if(error){setErro(error.message);return;}
  setP({...padrao,...(a?.parametros||{})});
  const anteriores=a?.parametros?.equipamentos||[];
  const itens=Object.entries(f.equipamentos_quantidades||{})
    .filter(([k,v])=>!k.endsWith('_esteiras')&&Number(v)>0)
    .map(([k,v])=>({chave:k,qtd:Number(v),valor:anteriores.find(x=>x.chave===k)?.valor??MC_CUSTOS_TABARATO[k]??''}));
  if(!itens.some(x=>x.chave.startsWith('forno'))&&Number(f.forno_quantidade)>0)
   itens.push({chave:'forno',qtd:Number(f.forno_quantidade),valor:anteriores.find(x=>x.chave==='forno')?.valor??MC_CUSTOS_TABARATO.forno});
  for(const [chave,coluna] of [['esteiras','esteiras_quantidade'],['assadeiras','assadeiras_quantidade']]){
   const qtd=Number(f[coluna])||0;
   if(qtd>0&&!itens.some(x=>x.chave===chave))itens.push({chave,qtd,valor:anteriores.find(x=>x.chave===chave)?.valor??MC_CUSTOS_TABARATO[chave]});
  }
  setEquip(itens);setStatus(a?.situacao||'rascunho');setParecer(a?.parecer||'');
  if(a){
   const {data}=await sb.from('mc_viabilidade_historico').select('*').eq('analise_id',a.id).order('versao',{ascending:false}).limit(100);
   setHistorico(data||[]);
  }else setHistorico([]);
 }
 async function salvar(){
  if(!ficha||!calc)return;
  if([p.custo_pct,p.tributos_pct,p.reajuste,p.fator_usado,p.ir_csll_pct].some(x=>x!==''&&(!Number.isFinite(Number(x))||Number(x)<0||Number(x)>100)))
   return toast('Percentuais devem estar entre 0 e 100.','error');
  if([p.despesas,p.pix,p.boleto,p.nota,p.pedido_ref,p.despesa_kg,...equip.map(x=>x.valor)].some(x=>x!==''&&(!Number.isFinite(Number(x))||Number(x)<0)))
   return toast('Os valores devem ser não negativos.','error');
  if(status==='favoravel'&&!calc.completo)return toast('Complete as premissas antes de registrar parecer favorável.','error');
  if(['favoravel','desfavoravel','condicionada'].includes(status)&&!parecer.trim())return toast('Informe a justificativa.','error');
  setBusy(true);
  const snapshot={id:ficha.id,preco_kg:ficha.preco_kg,consumo_previsto:ficha.consumo_previsto,
   peso_pao_kg:0.08,dias_mes:26,verba_introducao:ficha.verba_introducao,
   duracao_verba:ficha.duracao_verba,bonificacao_percentual:ficha.bonificacao_percentual,
   bonificacao_periodicidade:ficha.bonificacao_periodicidade,
   bonificacao_modalidade:ficha.bonificacao_modalidade,
   equipamentos_quantidades:ficha.equipamentos_quantidades};
  const {data,error}=await sb.rpc('mc_viabilidade_salvar',{
   p_ficha_id:ficha.id,p_parametros:{...p,equipamentos:equip},
   p_dados_ficha:snapshot,p_resultados:calc,p_situacao:status,p_parecer:parecer});
  setBusy(false);
  if(error)return toast('Erro ao salvar análise: '+error.message,'error');
  toast('Análise salva · versão '+data.versao,'success');await pesquisar();await escolher(ficha);
 }
 function campo(k,l){
  return h(Campo,{label:l,key:k},h('input',{className:'form-input',type:'number',min:0,step:'0.01',
   value:p[k],onChange:e=>setP(v=>({...v,[k]:e.target.value}))}));
 }
 function celula(t){return h('td',null,t);}
 function linha(a,b){return h('tr',{key:a},celula(a),celula(b));}
 function indicador(a,b){return h('div',{key:a,style:{padding:10,border:'1px solid var(--border)',borderRadius:8}},
  h('div',{className:'page-sub'},a),h('b',null,b));}
 if(!ok)return h('div',{className:'empty-state'},'Acesso restrito ao Financeiro e Administrador.');
 const titulo=h('div',{className:'page-head'},h('div',null,
  h('div',{className:'page-title'},'Análise de Viabilidade Financeira'),
  h('div',{className:'page-sub'},'Ficha · custos e bonificações · investimento · cinco anos · parecer')));

 const condicaoDe=f=>situacoes[f.id]?.situacao||'rascunho';
 const naFila=f=>{
  const st=condicaoDe(f);
  return fila==='aprovados'?st==='favoravel':
   fila==='desfavoraveis'?st==='desfavoravel':!['favoravel','desfavoravel'].includes(st);
 };
 const exibidos=lista.filter(naFila);
 const totais={pendentes:0,aprovados:0,desfavoraveis:0};
 lista.forEach(f=>{const st=condicaoDe(f);
  if(st==='favoravel')totais.aprovados++;
  else if(st==='desfavoravel')totais.desfavoraveis++;
  else totais.pendentes++;
 });
 const pesquisa=h('div',{className:'card',style:{marginBottom:14}},
  h('div',{style:{display:'flex',gap:8,flexWrap:'wrap',marginBottom:14}},
   ...[['pendentes','Pendentes de Aprovação'],['aprovados','Aprovados'],
    ['desfavoraveis','Parecer Desfavorável']].map(([k,l])=>
     h('button',{key:k,className:'btn '+(fila===k?'btn-primary':'btn-secondary')+' btn-sm',
      onClick:()=>{setFila(k);setFicha(null);}},l+' ('+totais[k]+')'))),
  h('div',{style:{display:'flex',gap:8,flexWrap:'wrap'}},
   h('input',{className:'form-input',placeholder:'Pesquisar razão social, fantasia ou CNPJ',
    value:busca,onChange:e=>setBusca(e.target.value),onKeyDown:e=>{if(e.key==='Enter')pesquisar();}}),
   h('button',{className:'btn btn-primary',disabled:busy,onClick:pesquisar},busy?'Buscando...':'Pesquisar')),
  erro&&h('p',{style:{color:'#b91c1c'}},erro),
  h('p',{className:'page-sub'},'Exibindo '+exibidos.length+' cliente(s). Use a pesquisa para localizar Fichas anteriores.'),
  !exibidos.length&&h('p',null,'Nenhuma Ficha nesta situação.'),
  ...exibidos.map(f=>h('div',{key:f.id,style:{padding:12,marginTop:9,
    border:'1px solid var(--border)',borderRadius:8,
    display:'flex',alignItems:'center',justifyContent:'space-between',gap:12,flexWrap:'wrap'}},
   h('div',null,
    h('div',{style:{fontWeight:700}},f.razao_social||f.nome_fantasia||'Cliente'),
    h('div',{className:'page-sub'},(f.cnpj_cpf||'')+' · '+dinheiro(f.faturamento_previsto)+'/mês'),
    h('div',{className:'page-sub'},'Análise: '+(condicaoDe(f)==='favoravel'?'Aprovado':
      condicaoDe(f)==='desfavoravel'?'Parecer desfavorável':'Pendente de decisão'))),
   h('button',{className:'btn btn-primary btn-sm',onClick:()=>escolher(f)},'Analisar cliente'))));
 if(!ficha||!calc)return h('div',null,titulo,pesquisa);
 const resumo=h('div',{className:'card'},h('h3',null,ficha.razao_social),
  h('div',{style:{display:'grid',gridTemplateColumns:'repeat(auto-fit,minmax(165px,1fr))',gap:10}},
   indicador('Receita mensal',dinheiro(calc.receita)),indicador('Consumo mensal',fmtNum(calc.kg)+' kg'),
   indicador('Introdução',dinheiro(ficha.verba_introducao)),
   indicador('Investimento',equip.some(x=>x.valor==='')?'A precificar':dinheiro(calc.investimento)),
   indicador('Resultado mês 1',calc.completo?dinheiro(calc.primeiro.resultado):'Incompleto'),
   indicador('Margem mês 1',calc.completo&&calc.receita?(100*calc.primeiro.resultado/calc.receita).toFixed(2)+'%':'Incompleta')));
 const tabs=h('div',{style:{display:'flex',gap:8,flexWrap:'wrap',margin:'14px 0'}},
  ...[['premissas','Premissas'],['equipamentos','Equipamentos'],['projecao','Projeção 5 anos'],['parecer','Parecer']].map(([k,l])=>
   h('button',{key:k,className:'btn '+(aba===k?'btn-primary':'btn-secondary')+' btn-sm',onClick:()=>setAba(k)},l)));
 const campos=[['custo_pct','Custo de produção (%)'],['tributos_pct','Tributos (%)'],
  ['despesas','Despesas mensais (R$)'],['pix','PIX mensal (R$)'],
  ['boleto','Desconto boleto (R$)'],['nota','Desconto NF (R$)'],
  ['pedido_ref','Valor de um pedido (R$)'],['reajuste','Reajuste anual (%)'],
  ['fator_usado','Valor relativo equipamento usado (%)'],
  ['despesa_kg','Despesas operacionais por kg (R$) — Excel'],
  ['ir_csll_pct','IR/CSLL sobre lucro positivo (%) — Excel']];
 const c=calc.primeiro;
 const premissas=h('div',{className:'card'},h('h3',null,'Premissas financeiras'),
  h('p',{className:'page-sub'},'Referência TABARATO: produção 60%, ICMS 7%, PIS/COFINS 0%, IR/CSLL 34%. Valores históricos revisáveis. Consumo Meu Cliente: 80g e 26 dias/mês.'),
  h('p',null,'Preço/kg '+dinheiro(ficha.preco_kg)+' · Consumo diário '+fmtNum(ficha.consumo_previsto)+' pães'),
  h('p',null,'Introdução '+dinheiro(ficha.verba_introducao)+' · '+(ficha.duracao_verba||0)+' meses'),
  h('p',null,'Bonificação '+(ficha.bonificacao_percentual||0)+'% · '+(ficha.bonificacao_periodicidade||'—')+' · '+(ficha.bonificacao_modalidade||'Produto')),
  h('div',{className:'form-grid'},...campos.map(x=>campo(x[0],x[1]))),
  calc.faltas.length>0&&h('p',{style:{color:'#a15c00'}},'Pendências: '+calc.faltas.join(' · ')),
  h('h3',null,'Composição do primeiro mês'),
  h('table',{className:'data-table'},h('tbody',null,
   linha('Receita',dinheiro(c.fat)),linha('Produção',dinheiro(c.prod)),linha('Tributos',dinheiro(c.impostos)),linha('Despesas operacionais/kg',dinheiro(c.operacionaisKg)),linha('IR/CSLL estimados',dinheiro(c.ircsll)),
   linha('Custo de bonificação',dinheiro(c.custoBonus)),linha('Introdução',dinheiro(c.intMes)),
   linha('Despesas e descontos',dinheiro(c.despesas)),
   linha('Resultado',calc.completo?dinheiro(c.resultado):'Pendente'))));
 const equipamentos=h('div',{className:'card'},h('h3',null,'Equipamentos quantificados na Ficha'),
  !equip.length&&h('p',null,'Nenhum equipamento quantificado na Ficha.'),
  ...equip.map((x,i)=>h('div',{key:x.chave,style:{display:'flex',gap:10,alignItems:'center',marginBottom:8,flexWrap:'wrap'}},
   h('span',{style:{flex:1}},x.chave.replace(/_/g,' ')+' · '+x.qtd+' un.'),
   h('input',{className:'form-input',type:'number',min:0,step:'0.01',value:x.valor,placeholder:'Custo unitário R$',
    onChange:e=>setEquip(a=>a.map((z,j)=>i===j?{...z,valor:e.target.value}:z))}),
   h('b',null,x.valor===''?'A precificar':dinheiro(x.qtd*Number(x.valor))))),
  h('p',null,'Investimento: '+(equip.some(x=>x.valor==='')?'A precificar':dinheiro(calc.investimento))));
 const projecao=h('div',{className:'card'},h('h3',null,'Projeção de cinco anos'),
  !calc.completo&&h('p',{style:{color:'#a15c00'}},'Premissas incompletas: resultado ainda não validado.'),
  h('div',{style:{overflowX:'auto'}},h('table',{className:'data-table',style:{minWidth:660}},
   h('thead',null,h('tr',null,...['Ano','Receita','Produção','Tributos','Acordos','Despesas','Resultado'].map(x=>h('th',{key:x},x)))),
   h('tbody',null,...calc.anos.map(a=>h('tr',{key:a.ano},...[
    a.ano,dinheiro(a.receita),dinheiro(a.prod),dinheiro(a.impostos),
    dinheiro(a.acordos),dinheiro(a.despesas),calc.completo?dinheiro(a.resultado):'Pendente'
   ].map(celula)))))),
  h('p',null,'Payback estimado do equipamento: '+(!calc.completo?'Pendente':calc.payback?calc.payback+' meses':'Não recuperado em 60 meses')),
  h('p',{className:'page-sub'},'Simulação gerencial; receita reajusta por ano, despesas fixas não. Não equivale a fluxo de caixa contábil.'));
 const parecerTab=h('div',{className:'card'},h('h3',null,'Parecer e versões'),
  h('p',{className:'page-sub'},'O parecer não modifica o workflow de aprovação da Ficha.'),
  h(Campo,{label:'Situação'},h('select',{className:'form-select',value:status,onChange:e=>setStatus(e.target.value)},
   ...[['rascunho','Rascunho'],['em_analise','Em análise'],['favoravel','Favorável'],
    ['condicionada','Condicionada'],['desfavoravel','Desfavorável']].map(([k,l])=>h('option',{key:k,value:k},l)))),
  h(Campo,{label:'Parecer'},h('textarea',{className:'form-input',rows:5,value:parecer,
   onChange:e=>setParecer(e.target.value)})),
  h('h4',null,'Histórico de versões'),
  ...historico.map(x=>h('div',{key:x.id,style:{padding:8,borderBottom:'1px solid var(--border)'}},
   h('b',null,'Versão '+x.versao+' · '+x.situacao),
   h('div',{className:'page-sub'},fmtData(x.registrado_em)),x.parecer&&h('p',null,x.parecer))));
 const atual=aba==='premissas'?premissas:aba==='equipamentos'?equipamentos:aba==='projecao'?projecao:parecerTab;
 const botao=h('div',{style:{display:'flex',justifyContent:'flex-end',marginTop:14}},
  h('button',{className:'btn btn-primary',disabled:busy,onClick:salvar},busy?'Salvando...':'Salvar análise e registrar versão'));
 return h('div',null,titulo,pesquisa,h('button',{className:'btn btn-secondary btn-sm',style:{marginBottom:12},onClick:()=>setFicha(null)},'Voltar à lista'),resumo,tabs,atual,botao);
}
