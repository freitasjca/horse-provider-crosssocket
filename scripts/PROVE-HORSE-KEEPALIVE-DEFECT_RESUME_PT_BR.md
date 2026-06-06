> ⚠️ **CORREÇÃO:** o defeito é **exclusivo do provedor Indy**. Os provedores CrossSocket e mORMot, quando compilados corretamente, atendem à mesma carga com **0%** de erros; apenas o Indy apresenta ~60%. A conclusão anterior de "todos os provedores / código compartilhado do Horse" veio de **binários CrossSocket/mORMot mal compilados que estavam rodando Indy** (o define `HORSE_PROVIDER_*` não estava em efeito). Este resumo está corrigido.

### Problema

Qualquer middleware do Horse que **adicione cabeçalhos (headers) à resposta HTTP**, **no provedor Indy**, passa a provocar erros **HTTP 500** em aproximadamente **60% das requisições** quando as três condições abaixo ocorrem simultaneamente:

1. **Reutilização de conexões HTTP Keep-Alive**
2. **Concorrência igual ou superior a aproximadamente 40 requisições simultâneas**
3. **Adição de headers na resposta**, por exemplo:

   * `SecurityHeaders` utilizando `Res.AddHeader`
   * `CORS` utilizando `Res.RawWebResponse.SetCustomHeader`

---

### Comportamento observado

* As falhas ocorrem **antes da execução do pipeline de roteamento**.
* O número de requisições que entram no pipeline do Horse é igual ao número de respostas 2xx (`entered == 2xx`) — ou seja, todo erro 500 corresponde a uma requisição que nunca entrou no pipeline.
* Nenhuma exceção é gerada.
* O 500 é emitido **abaixo do `HandlerAction`**, na camada Indy / `TIdHTTPWebBrokerBridge` (o WebModule e o pipeline do Horse estão íntegros).
* O problema reproduz **somente no provedor Indy**:

  * Indy — **~60%** (afetado)
  * CrossSocket — **0%** (não afetado)
  * mORMot — **0%** (não afetado)
* O comportamento ocorre de forma consistente em **compilações Release**.

---

### Impacto da remoção de qualquer condição

Ao remover qualquer um dos três fatores que desencadeiam o problema, a taxa de erro cai drasticamente:

| Configuração                       | Taxa de HTTP 500 |
| ---------------------------------- | ---------------- |
| Três condições presentes           | ~60%             |
| Sem middleware adicionando headers | ~3%              |
| Sem Keep-Alive (ApacheBench)       | ~1%              |
| Conexão única/sequencial           | 0%               |

---

### Evidências de que o defeito está no provedor Indy do Horse

O problema está isolado no **provedor Indy/Console do Horse**, e não nos transportes nem no código de resposta compartilhado do Horse.

#### Comparação entre provedores (binários compilados corretamente, c=100, Keep-Alive)

| Provedor | headers-only 5xx | cors 5xx |
| -------- | ---------------- | -------- |
| **Indy** | **~59%** | **~61%** |
| CrossSocket | **0%** | **0%** |
| mORMot | **0%** | **0%** |

O mesmo código de `THorseResponse`/`AddHeader` roda nos três provedores, mas apenas o Indy falha — logo, a causa **não** está no mecanismo compartilhado de resposta do Horse.

#### Verificação cruzada — transportes puros (sem Horse)

Os mesmos headers adicionados nativamente em servidores CrossSocket e mORMot puros (sem Horse) também resultam em **0% de erros** sob c=100 + Keep-Alive — ou seja, os transportes em si também estão íntegros.

---

### Por que é especificamente o provedor Indy

O Indy usa `TIdHTTPWebBrokerBridge` + um **`THorseWebModule` único compartilhado** + o despacho do WebBroker. O 500 é emitido nessa camada de despacho (abaixo do `HandlerAction`) quando uma resposta com headers, numa conexão reutilizada, é seguida por outra requisição sob concorrência ≥ ~40. CrossSocket e mORMot usam seus próprios servidores assíncronos nativos e não possuem esse caminho.

---

### Hipóteses já descartadas

Os testes realizados eliminaram as seguintes possibilidades:

* Condição de corrida (race condition) no pipeline do Horse (pré-pipeline; 0 exceções)
* Saturação do servidor ou do ambiente de testes
* Diferenças entre builds Debug e Release
* Problemas relacionados ao momento da chamada de `Send`
* Acúmulo progressivo de headers entre requisições
* **Bug de transporte** e **bug no código compartilhado do Horse** (provedores CrossSocket/mORMot e transportes puros: todos 0%)
* **Escopo "todos os provedores"** — foi um erro de compilação (binários CrossSocket/mORMot rodando Indy)

---

### Conclusão

Trata-se de um **defeito de concorrência no provedor Indy/Console do Horse** (o despacho do `TIdHTTPWebBrokerBridge` + o `THorseWebModule` único compartilhado), disparado por qualquer middleware que adicione headers à resposta sob cargas de produção com **Keep-Alive** e alta concorrência. Os provedores **CrossSocket e mORMot não são afetados** — são os recomendados para middleware de headers sob alta concorrência com Keep-Alive.

A linha exata do código ainda não foi identificada; o próximo passo é instrumentar a camada de **despacho do Indy/WebBroker** (a Etapa A localizou o ponto abaixo do `HandlerAction`).
