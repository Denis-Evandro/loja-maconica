# TD-2: RLS Multi-tenant — Planejamento

Data: 15/05/2026  
Status: Planejado — execução pendente

## Objetivo
Implementar isolamento de dados por loja (loja_id) em todas as tabelas,
preparando o sistema para o modelo SaaS multi-tenant.

## Tabelas — Prioridade

### 🔴 Críticas (dados sensíveis por loja)
- membros
- financas
- sessoes
- mensalidades
- presencas
- eventos
- atas
- trabalhos

### 🟡 Importantes
- comissoes
- legislacao
- lojas_visitantes
- visitas_externas
- solicitacoes_edicao

### 🟢 Secundárias
- acessos_log

## Tabelas que NÃO precisam de loja_id
- `configuracoes` — já usa id como chave da loja
- `usuarios` — admin global do SaaS

## Plano de Execução

### Passo 1 — Criar tabela `lojas`
```sql
CREATE TABLE lojas (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  nome text NOT NULL,
  numero text,
  obediencia text,
  oriente text,
  rito text,
  ativo boolean DEFAULT true,
  criado_em timestamptz DEFAULT now()
);
```

### Passo 2 — Adicionar loja_id nas tabelas críticas
```sql
ALTER TABLE membros ADD COLUMN IF NOT EXISTS loja_id uuid REFERENCES lojas(id);
ALTER TABLE financas ADD COLUMN IF NOT EXISTS loja_id uuid REFERENCES lojas(id);
ALTER TABLE sessoes ADD COLUMN IF NOT EXISTS loja_id uuid REFERENCES lojas(id);
ALTER TABLE mensalidades ADD COLUMN IF NOT EXISTS loja_id uuid REFERENCES lojas(id);
ALTER TABLE presencas ADD COLUMN IF NOT EXISTS loja_id uuid REFERENCES lojas(id);
ALTER TABLE eventos ADD COLUMN IF NOT EXISTS loja_id uuid REFERENCES lojas(id);
ALTER TABLE atas ADD COLUMN IF NOT EXISTS loja_id uuid REFERENCES lojas(id);
ALTER TABLE trabalhos ADD COLUMN IF NOT EXISTS loja_id uuid REFERENCES lojas(id);
```

### Passo 3 — Popular loja_id nos registros existentes
Inserir a loja atual na tabela `lojas` e atualizar todos os registros
existentes com o UUID gerado.

### Passo 4 — Reescrever políticas RLS
Substituir `qual = true` por filtro baseado em `loja_id` do usuário logado.

### Passo 5 — Atualizar queries no index.html
Todas as queries precisam filtrar por `loja_id` do contexto do usuário.

## Riscos
- Operação destrutiva se mal executada — fazer backup antes
- Tabela `presencas` pode ter FK para `membros` — verificar cascata
- index.html tem ~13.000 linhas — impacto amplo nas queries

## Rollback
Manter branch `main` como backup (não deletar).
Testar em ambiente separado antes de aplicar em produção.
