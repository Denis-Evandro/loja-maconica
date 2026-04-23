# Relatório de Débitos Técnicos — v2
## A.R.L.S. Fraternidade Acadêmica — Painel de Gestão
*Análise automática + revisão manual · Abril 2026*

---

## Resumo Executivo

| Indicador | Março 2026 | Abril 2026 | Variação |
|---|---|---|---|
| Total de linhas | 10.274 | 13.684 | +33% ↑ |
| Tamanho do arquivo | 610 KB | 801 KB | +31% ↑ |
| Funções JS | 241 | 334 | +39% ↑ |
| Funções duplicadas | 3 | **0** | ✅ Corrigido |
| Async sem try/catch | 47 | ~49 | ≈ Igual |
| Queries Supabase sem check de erro | 61 | **~77** | Piorou ↑ |
| Inline styles | 553 | **2.099** | +279% ↑↑↑ |
| loadAllData() chamado | 25× | **28×** | Piorou ↑ |
| Variáveis globais (var/let) | 9 | 12+ | Piorou ↑ |
| Campos de dados sem sanitização em innerHTML | — | **135** | Novo risco |
| onclick inline no HTML | — | **307** | Novo risco |

**Progresso positivo:** as 3 funções duplicadas foram removidas.  
**Regressão crítica:** os inline styles cresceram 4×; o arquivo cresceu mais rápido que os problemas foram resolvidos.

---

## ✅ O QUE FOI CORRIGIDO

### Funções duplicadas — RESOLVIDO
As três funções (`selectProfile`, `imprimirListaPresenca`, `excluirLancamento`) que existiam em duplicata foram eliminadas. Nenhuma função de nível superior aparece duplicada no código atual.

---

## 🔴 PRIORIDADE CRÍTICA

### 1. XSS: 135 campos de dados inseridos em innerHTML sem sanitização

A função `_esc()` existe e está corretamente implementada, mas é usada em apenas **1 lugar** no código. Há **135 ocorrências** onde campos vindos do banco de dados (`.nome_maconico`, `.nome`, `.observacoes`, `.descricao`, etc.) são inseridos diretamente em templates de innerHTML via template literals sem passar por `_esc()`.

```js
// ❌ Padrão atual — risco de XSS se um campo contiver <script> ou event handlers
el.innerHTML = `<td>${m.nome_maconico}</td>`;

// ✅ Correto
el.innerHTML = `<td>${_esc(m.nome_maconico)}</td>`;
```

**Impacto:** um administrador mal-intencionado (ou dado corrompido no banco) pode injetar HTML arbitrário em qualquer painel que renderize esses campos.  
**Ação imediata:** usar `_esc()` em todos os campos de texto de origem externa. Alternativamente, adotar `textContent` para elementos simples.

---

### 2. ~49 funções async sem try/catch — não resolvido desde v1

O arquivo tem 89 funções `async` e apenas 40 blocos `try/catch`. Aproximadamente metade das funções assíncronas não tem tratamento de exceção. Se a conexão com o Supabase cair no meio de uma operação de escrita, a função para silenciosamente — sem mensagem ao usuário, sem rollback, possivelmente com a interface travada em estado de loading.

**Funções críticas ainda sem try/catch (verificar e priorizar):**
`doLogin`, `salvarMembro`, `confirmarPresencas`, `salvarLancamento`, `renderDashboard`, `renderFrequencia`, `renderComissoes`, `renderTrabalhos`

```js
// ❌ Atual
async function salvarLancamento() {
  const {error} = await sb.from('financas').insert(dados);
  if (error) { toast('Erro'); return; }
}

// ✅ Correto
async function salvarLancamento() {
  try {
    const {error} = await sb.from('financas').insert(dados);
    if (error) throw error;
    toast('✅ Lançamento salvo');
  } catch(e) {
    console.error('salvarLancamento:', e);
    toast('❌ Erro ao salvar: ' + e.message);
  }
}
```

---

### 3. ~77 queries ao Supabase sem verificação de erro

O arquivo tem 97 chamadas `await sb.from(...)`. Apenas 20 verificam `if (error)` e apenas 2 usam o padrão correto de desestruturação `const {data, error}`. Isso significa que em ~77 queries, se o Supabase retornar um erro, o código prossegue com `data = null` e quebra silenciosamente em cascata.

```js
// ❌ Padrão problemático (encontrado ~75 vezes)
const {data} = await sb.from('membros').select('*');
// data é null se houver erro — o código quebra na próxima linha

// ✅ Correto
const {data, error} = await sb.from('membros').select('*');
if (error) { console.error(error); toast('Erro ao carregar membros'); return; }
```

---

## 🟠 PRIORIDADE ALTA

### 4. Inline styles cresceram 279% — de 553 para 2.099

Este é o maior crescimento proporcional do arquivo. A cada novo painel adicionado, centenas de novos inline styles são inseridos em vez de reutilizar as classes CSS já existentes. O mesmo bloco de CSS (`font-family:'Cinzel',serif;font-size:9px;font-weight:700;letter-spacing:0.15em;text-transform:uppercase`) se repete dezenas de vezes.

**Impacto:** qualquer mudança de design exige editar centenas de lugares. O browser precisa processar 2.099 declarações de estilo no parser HTML, além de no CSS.

**Classes utilitárias que devem ser criadas (exemplo):**
```css
.u-label     { font-family:'Cinzel',serif; font-size:9px; font-weight:700; letter-spacing:0.15em; text-transform:uppercase; }
.u-muted     { color: var(--text-muted); }
.u-gold      { color: var(--gold-dark); }
.u-italic    { font-style: italic; }
.u-mono-val  { font-family:'Cinzel',serif; font-size:24px; font-weight:700; }
```

---

### 5. loadAllData() chamado 28 vezes — piorou desde v1

O problema identificado em março (25 chamadas) piorou: agora são **28 chamadas**. A função carrega as 8 tabelas completas em paralelo toda vez que qualquer dado é salvo. Salvar uma presença recarrega membros, finanças, eventos, legislação, comissões — dados que não mudaram.

```
28 chamadas × ~8 queries = até 224 queries Supabase por sessão
```

**Funções de reload seletivo já existem** (`_reloadMembros`, `_reloadFinancas`, etc.) mas não são usadas nas operações de escrita. A substituição é mecânica: identificar qual tabela cada operação modifica e chamar apenas o reload correspondente.

```js
// ❌ Após salvar uma presença
await loadAllData(); // recarrega 8 tabelas

// ✅ Correto
await _reloadPresencas(); // recarrega apenas 1 tabela
```

---

### 6. 307 handlers onclick inline no HTML — acoplamento total entre template e lógica

Todos os 307 eventos onclick estão escritos diretamente nos atributos HTML como strings. Isso cria três problemas:

1. **Manutenção:** renomear uma função exige busca manual em strings de texto
2. **Testabilidade:** impossível testar event handlers isoladamente
3. **Segurança:** onclick inline é um vetor clássico de XSS quando combinado com dados não sanitizados

```js
// ❌ Atual — onclick com string, impossível de rastrear staticamente
el.innerHTML = `<button onclick="excluirMembro('${m.id}')">Excluir</button>`;

// ✅ Preferível — addEventListener após inserção no DOM
const btn = document.createElement('button');
btn.textContent = 'Excluir';
btn.addEventListener('click', () => excluirMembro(m.id));
el.appendChild(btn);
```

---

### 7. Funções render com tamanho absurdo — 8 funções acima de 400 linhas

| Função | Linhas | Linha no arquivo |
|---|---|---|
| `renderAssinaturas` | **1.667** | 12.017 |
| `renderInadimplenciaFiltrada` | **1.332** | 7.496 |
| `renderFrequencia` | **1.204** | 4.971 |
| `renderTrabalhos` | **751** | 10.261 |
| `renderSolicitacoesEdicao` | **696** | 6.175 |
| `renderFinancas` | **625** | 6.871 |
| `renderDashboard` | **586** | 3.755 |
| `renderComissoes` | **523** | 11.399 |
| `renderMeuFinanceiro` | **502** | 9.759 |
| `renderEventos` | **399** | 8.828 |

Cada função mistura: geração de HTML, lógica de negócio, cálculos, queries ao banco e formatação. Uma função com 1.667 linhas é impossível de revisar, testar ou depurar com segurança.

**Padrão de divisão recomendado:**
```js
// Em vez de renderFinancas() com 625 linhas:
function _calcularTotaisFinancas(lancamentos) { /* lógica pura */ }
function _htmlCardFinancas(totais) { /* só gera HTML */ }
async function _buscarLancamentos(filtros) { /* só faz query */ }
function renderFinancas(access) { /* orquestra as três */ }
```

---

### 8. Nenhum debounce nos filtros — renderização a cada tecla

Os campos de busca e filtros chamam funções de render pesadas diretamente no evento `oninput`, sem debounce. Digitar "João" no campo de busca de membros dispara `renderMembros()` 4 vezes (uma por tecla), cada uma percorrendo e redesenhando toda a lista.

```js
// ❌ Atual — re-render a cada tecla
<input oninput="renderMembros('${access}')">

// ✅ Com debounce — re-render só 300ms após parar de digitar
function debounce(fn, ms) {
  let t;
  return (...args) => { clearTimeout(t); t = setTimeout(() => fn(...args), ms); };
}
const renderMembrosDebounced = debounce(renderMembros, 300);
```

---

### 9. Dados sensíveis no localStorage — não resolvido desde v1

Mantém-se o mesmo problema identificado em março: chaves de alto risco ainda persistem em localStorage sem criptografia:

| Chave | Risco |
|---|---|
| `assinatura_veneravel`, `assinatura_secretario` | Imagens base64 de assinaturas oficiais |
| `fechamentos_mensais` | Histórico financeiro completo |
| `pix_loja` | Chave PIX da loja |
| `log_acessos` | Histórico de logins com nomes e cargos |
| `dados_loja` | Dados cadastrais da loja |
| `orcamento_anual` | Orçamento anual |

**Ação recomendada:** mover assinaturas para Supabase Storage; log de acessos para tabela `acessos_log`; nunca persistir dados financeiros no localStorage.

---

### 10. Timeout de rede apenas no loadAllData() — queries individuais ficam penduradas

O timeout de 8 segundos (`Promise.race`) existe apenas dentro de `loadAllData()`. As outras 77+ queries diretas ao Supabase não têm timeout. Se a rede travar durante uma operação de escrita (salvar membro, lançamento financeiro, etc.), a função fica esperando indefinidamente — o botão de salvar trava para sempre sem mensagem ao usuário.

```js
// Criar helper com timeout para todas as queries
const sbQuery = (promise, ms = 10000) =>
  Promise.race([promise, new Promise((_, r) => setTimeout(() => r(new Error('Timeout')), ms))]);

// Uso
const {data, error} = await sbQuery(sb.from('membros').insert(dados));
```

---

## 🟡 PRIORIDADE MÉDIA

### 11. Zero atributos de acessibilidade — 164 inputs sem label associado

O sistema tem 164 elementos `<input>` e apenas 2 atributos `aria-label` em todo o arquivo. Nenhum input usa `<label for="">` ou `aria-labelledby`. Das 17 imagens, apenas 3 têm `alt`. Isso torna o sistema inacessível para usuários com leitores de tela.

```html
<!-- ❌ Atual -->
<input id="filtro-membros-nome" type="text" placeholder="🔍 Nome...">

<!-- ✅ Correto -->
<label for="filtro-membros-nome" class="sr-only">Buscar por nome</label>
<input id="filtro-membros-nome" type="text" placeholder="Nome..." aria-label="Buscar membro por nome">
```

---

### 12. Sem detecção de modo offline

O sistema não verifica `navigator.onLine` nem escuta os eventos `offline`/`online`. Se a conexão cair durante o uso, o usuário não recebe aviso — a próxima operação simplesmente falha (ou trava, dado o problema #10).

```js
// Adicionar no início da aplicação
window.addEventListener('offline', () => toast('⚠️ Sem conexão com a internet'));
window.addEventListener('online',  () => toast('✅ Conexão restaurada'));
```

---

### 13. Arquivo monolítico de 801 KB — crescimento contínuo

O arquivo cresceu 31% em um mês (610 KB → 801 KB). No ritmo atual, ultrapassará 1 MB em poucos meses. O browser precisa fazer parse de **13.684 linhas de JavaScript** antes de renderizar qualquer coisa — isso representa 400–900 ms em dispositivos móveis.

**Causa raiz:** todo novo painel, modal e funcionalidade é adicionado ao mesmo arquivo único.  
**Solução estrutural:** separar em módulos com `<script type="module">` e carregamento por demanda (`import()` dinâmico).

---

### 14. `var _membroLogado` — única variável `var` restante

O código usa `let` e `const` em praticamente todo lugar, exceto em `var _membroLogado = null` (linha 1688). O uso de `var` cria escopo de função em vez de bloco, tornando o comportamento imprevisível em closures. Substituir por `let`.

---

### 15. 17 comparações `==` não estritas

Há 17 ocorrências de `==` (igualdade não estrita) no código. Em JavaScript, `==` faz coerção de tipos (`null == undefined` é `true`, `0 == ''` é `true`), o que pode causar comportamentos inesperados em comparações de IDs do banco de dados.

```js
// ❌ Perigoso — '0' == 0 é true, null == undefined é true
if (m.id == membroId) { ... }

// ✅ Seguro
if (m.id === membroId) { ... }
```

---

### 16. Variáveis globais cresceram de 9 para 12+

Novas variáveis de estado foram adicionadas no escopo global: `_filtroTipoCom`, `_relMembrosCols`, `CATEGORIAS_LEG`, entre outras. O estado global continua sendo o padrão de comunicação entre funções, tornando difícil rastrear quem modifica o quê.

---

## 🟢 PRIORIDADE BAIXA

### 17. Apenas 3 `console.log` — bom sinal, mas sem logging estruturado

O código tem poucos `console.log` de debug esquecidos (positivo). Porém, também não tem logging estruturado para erros de produção. Considerar integração com um serviço de monitoramento (ex: Sentry) para capturar erros reais dos usuários.

### 18. Nenhuma validação HTML5 nos formulários

Nenhum `<input>` usa os atributos `required`, `minlength`, `maxlength` ou `pattern` do HTML5. Toda a validação é feita via JavaScript, o que é redundante e frágil. A validação nativa do browser é gratuita e funciona mesmo se o JS falhar.

### 19. Campos de busca recriam DOM completo a cada keystroke

Funções como `renderMembros()` e `renderFrequencia()` recriam todo o HTML da tabela a cada chamada. Com 100+ membros, isso representa criar e destruir centenas de nós DOM a cada tecla pressionada. A adoção de filtragem no DOM existente (show/hide) ou de um framework de virtual DOM resolveria isso.

---

## Comparação com v1 — O que piorou, o que melhorou

| Item | Status |
|---|---|
| ✅ Funções duplicadas | **Corrigido** |
| 🔴 Async sem try/catch | Igual (~49) |
| 🔴 Queries sem check de erro | **Piorou** (61→77) |
| 🔴 XSS via innerHTML sem _esc() | **Novo — 135 ocorrências** |
| 🟠 loadAllData() excessivo | **Piorou** (25→28) |
| 🟠 Inline styles | **Muito pior** (553→2.099) |
| 🟠 Funções gigantes | **Muito pior** (475→1.667 linhas) |
| 🟠 Dados sensíveis no localStorage | Igual — não resolvido |
| 🟠 RLS do Supabase | Não verificado nesta análise |
| 🟡 Variáveis globais | **Piorou** (9→12+) |
| 🟡 Arquivo monolítico | **Piorou** (610KB→801KB) |

---

## Plano de Ação Revisado

### Fase 1 — Urgente (esta semana)
1. Passar `_esc()` em todos os 135 campos de dados inseridos em innerHTML
2. Adicionar try/catch nas 7 funções async de escrita mais críticas
3. Verificar policies RLS no Supabase (especialmente tabela `trabalhos`)

### Fase 2 — Curto prazo (2–3 semanas)
4. Substituir `loadAllData()` por reloads seletivos nas operações de escrita
5. Adicionar debounce nos 5 campos de busca/filtro principais
6. Mover assinaturas e dados financeiros do localStorage para Supabase
7. Adicionar timeout de rede às queries individuais

### Fase 3 — Médio prazo (mês 2)
8. Criar ~20 classes CSS utilitárias e eliminar inline styles repetidos
9. Quebrar as 3 maiores funções render (renderAssinaturas, renderInadimplenciaFiltrada, renderFrequencia)
10. Adicionar `aria-label` nos inputs principais e `alt` nas imagens
11. Adicionar detecção de modo offline

### Fase 4 — Longo prazo (mês 3+)
12. Modularizar o arquivo com `<script type="module">` e lazy loading
13. Encapsular estado global no objeto `APP`
14. Substituir onclick inline por addEventListener
15. Implementar cache local com invalidação seletiva por tabela

---

*Análise gerada em 22/04/2026 · arquivo index.html · 13.684 linhas · 801 KB*
