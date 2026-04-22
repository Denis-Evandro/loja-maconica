# Relatório de Débitos Técnicos
## A.R.L.S. Fraternidade Acadêmica — Painel de Gestão
*Análise automática + revisão manual · Março 2026*

---

## Resumo Executivo

| Indicador | Valor |
|---|---|
| Total de linhas | 10.274 |
| Tamanho do arquivo | 610 KB |
| Funções JS | 241 |
| Funções duplicadas | 3 |
| Async sem try/catch | 47 |
| Chamadas Supabase sem check de erro | 61 |
| Inline styles longos (>100 chars) | 553 |
| loadAllData() chamado | 25× |
| Variáveis globais | 9 |

---

## 🔴 PRIORIDADE CRÍTICA

### 1. Funções duplicadas — bug latente

Três funções são definidas duas vezes no arquivo. A segunda definição sobrescreve silenciosamente a primeira — qualquer correção feita na primeira cópia não tem efeito.

```
selectProfile()          — 2× definida
imprimirListaPresenca()  — 2× definida
excluirLancamento()      — 2× definida
```

**Impacto:** comportamento imprevisível em produção.  
**Correção:** localizar e remover a cópia obsoleta de cada função.

---

### 2. 47 funções async sem try/catch

Funções críticas como `doLogin()`, `salvarMembro()`, `confirmarPresencas()`, `salvarLancamento()` não têm tratamento de exceção. Se a conexão com o Supabase cair no meio de uma operação, a função simplesmente para sem mostrar mensagem ao usuário, deixando a interface travada.

Exemplo do problema:
```js
// Atual — sem proteção
async function salvarMembro() {
  const {error} = await sb.from('membros').update(dados).eq('id', id);
  if (error) { toast('Erro'); return; }
}

// Correto
async function salvarMembro() {
  try {
    const {error} = await sb.from('membros').update(dados).eq('id', id);
    if (error) throw error;
    toast('✅ Salvo');
  } catch(e) {
    console.error('salvarMembro:', e);
    toast('❌ Erro ao salvar: ' + e.message);
  }
}
```

**Impacto:** travamento silencioso da interface, perda de dados sem aviso.  
**Funções mais críticas para corrigir primeiro:**
`doLogin`, `confirmarSalvarMembro`, `salvarSessao`, `confirmarPresencas`, `salvarLancamento`, `renderDashboard`, `renderDashboardIrmao`

---

### 3. 61 chamadas ao Supabase sem verificação de erro

Padrão recorrente onde o resultado da query não verifica `error`:
```js
// Problemático — ignora erros silenciosamente
const {data} = await sb.from('membros').select('*');
// Se error existir, data será null e o app quebra sem mensagem

// Correto
const {data, error} = await sb.from('membros').select('*');
if (error) { console.error(error); return; }
```

**Impacto:** dados nulos causam crashes em cascata sem indicação do motivo.

---

## 🟠 PRIORIDADE ALTA

### 4. loadAllData() chamado 25 vezes — performance crítica

A função `loadAllData()` busca **todas as 8 tabelas em paralelo** e é chamada após praticamente toda operação de escrita. Isso significa que salvar uma presença, por exemplo, recarrega membros, sessões, finanças, eventos, atas, comissões, trabalhos e legislação — mesmo que nenhum desses dados tenha mudado.

```
25 chamadas × ~8 queries = até 200 queries Supabase por sessão de uso
```

**Impacto:** lentidão perceptível, consumo excessivo de bandwidth, risco de atingir limites do plano Supabase.

**Solução recomendada:** criar funções de reload seletivo:
```js
async function _reloadMembros()   { DATA.membros   = (await sb.from('membros').select('*')).data||[]; }
async function _reloadFinancas()  { DATA.financas   = (await sb.from('financas').select('*')).data||[]; }
// Após salvar uma presença:
await _reloadPresencas(); // em vez de loadAllData()
```

---

### 5. Arquivo monolítico de 610 KB — carregamento lento

Todo o JavaScript (538 KB) é executado sincronamente durante o parse da página. O browser não renderiza nada até processar todo o script.

| O que acontece | Custo |
|---|---|
| Parse de 8.557 linhas de JS | ~300–800ms em mobile |
| 241 funções registradas na memória | ~15 MB RAM |
| 553 inline styles renderizados | Layout thrashing |

**Solução de longo prazo:** separar o arquivo em módulos com `<script type="module">` e lazy loading por painel. Cada módulo só carrega quando o painel é acessado.

---

### 6. Chave Supabase exposta no HTML público

```js
// Linha ~10 do arquivo
const sb = supabase.createClient(
  'https://trwhvecssvbxklqsbzsc.supabase.co',
  'sb_publishable_Wb0qVyphTQr8...'
);
```

A `sb_publishable` (equivale à `anon key`) **é projetada para ser pública** — ela sozinha não é um problema. O risco real está nas **políticas RLS (Row Level Security)** do Supabase.

**Verificar urgentemente:**
- Todas as tabelas têm RLS habilitado?
- A policy `allow_all` criada para trabalhos (`USING (true)`) permite que qualquer pessoa na internet leia, escreva e delete qualquer trabalho sem autenticação
- Tabelas `membros` e `financas` precisam de policies que restrinjam acesso por `auth.uid()`

```sql
-- Verificar quais tabelas têm RLS ativo
SELECT tablename, rowsecurity 
FROM pg_tables 
WHERE schemaname = 'public';
```

---

### 7. Três concatenações innerHTML com dados externos

```js
// Risco de XSS se os dados vierem de usuário mal-intencionado
el.innerHTML = renderSec(perm,'🏛️ Permanentes',...)
             + renderSec(temp,'⏳ Temporárias',...);
```

Embora o risco seja baixo dado o contexto (sistema fechado com autenticação), a prática de concatenar strings em `innerHTML` deve ser substituída por `textContent` para valores de usuário ou sanitização com `DOMPurify`.

---

## 🟡 PRIORIDADE MÉDIA

### 8. Variáveis globais — estado compartilhado frágil

9 variáveis vivem no escopo global: `currentRole`, `DATA`, `_membroLogado`, `_modoDemo`, etc. Qualquer função pode modificá-las a qualquer momento, tornando o rastreio de bugs muito difícil.

**Sintoma já visível:** o problema recorrente com `_membroLogado` sendo null no modo demo é diretamente causado por este padrão — qualquer função que chama `_membroLogado?.id` pode retornar resultados diferentes dependendo de quando é chamada.

**Solução:** encapsular em um objeto de estado:
```js
const APP = {
  role: null,
  data: {},
  usuario: null,
  modoDemo: false,
  // getter/setter com validação
  setUsuario(u) { this.usuario = u; },
  getUsuario()  { return this.usuario; }
};
```

---

### 9. Dados sensíveis no localStorage sem criptografia

O localStorage armazena em texto plano:
```
'log_acessos'       — histórico de logins com nomes e cargos
'assinatura_*'      — imagens base64 das assinaturas dos oficiais
'fechamentos_mensais'— dados financeiros
'pix_loja'          — dados do PIX da loja
```

**Risco:** qualquer extensão de browser maliciosa, script de terceiro ou acesso físico ao computador consegue ler esses dados.

**Para assinaturas:** mover para Supabase Storage (já existe o bucket `documentos`).  
**Para log de acessos:** mover para uma tabela `acessos_log` no Supabase.  
**Para dados financeiros:** nunca persistir no localStorage.

---

### 10. 553 inline styles — manutenção impossível

O padrão `style="font-family:'Cinzel',serif;font-size:9px;font-weight:700;letter-spacing:0.15em;color:var(--text-muted);text-transform:uppercase"` aparece dezenas de vezes quase idêntico. Qualquer mudança de design exige editar centenas de linhas.

**Solução incremental — criar classes utilitárias:**
```css
.label-cinzel    { font-family:'Cinzel',serif; font-size:9px; font-weight:700; letter-spacing:0.15em; text-transform:uppercase; }
.label-muted     { color:var(--text-muted); }
.card-valor-lg   { font-family:'Cinzel',serif; font-size:36px; font-weight:700; line-height:1; }
```

---

### 11. Funções de render com mais de 200 linhas

| Função | Linhas | Responsabilidades misturadas |
|---|---|---|
| `renderFinancas()` | 475 | UI + lógica de negócio + queries + gráfico |
| `renderDashboard()` | 270 | UI + cálculos + formatação + finanças + frequência |
| `renderDashboardIrmao()` | 235 | UI + queries async + cálculos |
| `abrirModalMembro()` | 232 | Form + validação + upload |
| `abrirModalComissao()` | 170 | Form + lógica de cargo |

Cada uma dessas funções deveria ser dividida em: função de dados, função de cálculo e função de render.

---

## 🟢 PRIORIDADE BAIXA (qualidade de código)

### 12. Inconsistência no padrão de fetch

O código usa três padrões diferentes para a mesma operação:
```js
// Padrão A — desestrutura direto
const {data, error} = await sb.from('x').select('*');

// Padrão B — chama .then()
sb.from('x').select('*').then(r => { ... });

// Padrão C — atribui o objeto inteiro
const res = await sb.from('x').select('*');
if (res.error) { ... }
```

Escolher um padrão e aplicar consistentemente em todo o código.

---

### 13. `fmtData`, `fmtVal`, `degreeBadge` — helpers duplicados em escopo

Essas três funções de formatação são usadas em todo o código mas não estão centralizadas em nenhum módulo. Se o formato de data precisar mudar, é difícil garantir que todas as ocorrências foram atualizadas.

---

### 14. Sem paginação nas tabelas

As queries `SELECT *` buscam todos os registros sem `.limit()`. Com o crescimento da loja (membros, presenças, finanças), isso se tornará lento. A tabela `presencas` em particular tende a crescer muito (1 registro por membro por sessão).

```js
// Adicionar paginação para tabelas que crescem
const {data} = await sb.from('presencas')
  .select('*')
  .order('criado_em', {ascending: false})
  .limit(500); // máximo razoável
```

---

## Plano de Refatoração Sugerido

### Fase 1 — Semana 1 (bugs e segurança)
1. Remover as 3 funções duplicadas
2. Adicionar try/catch nas 7 funções async mais críticas
3. Verificar e corrigir as policies RLS no Supabase

### Fase 2 — Semana 2-3 (performance)
4. Criar funções de reload seletivo e eliminar loadAllData() redundante
5. Mover assinaturas do localStorage para o Supabase Storage
6. Adicionar `.limit()` nas principais queries

### Fase 3 — Mês 2 (manutenibilidade)
7. Extrair ~30 classes CSS utilitárias para eliminar inline styles repetidos
8. Quebrar renderFinancas() e renderDashboard() em funções menores
9. Encapsular estado global no objeto APP

### Fase 4 — Mês 3+ (arquitetura)
10. Modularizar o arquivo em múltiplos scripts com lazy loading
11. Implementar cache local com invalidação seletiva
12. Adicionar sanitização de inputs com DOMPurify

---

*Análise gerada em 31/03/2026 · arquivo loja-v3.html · 10.274 linhas · 610 KB*
