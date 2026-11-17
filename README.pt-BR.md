# 🗺️ lockMapSweep

**Exploração mais inteligente dos mapas no [OpenKore](https://github.com/OpenKore/openkore).**  
**Versão 2.0.0**

**🌐 Idioma:** [🇺🇸 English](README.md) | **Português**

## O que é o lockMapSweep?

O OpenKore consegue movimentar o personagem pelo mapa usando o `randomWalk`, mas escolher destinos aleatórios nem sempre resulta em uma exploração organizada. **O lockMapSweep planeja a exploração da área caminhável do `lockMap`:** mantém a grade de áreas menores (**blocos**), identifica regiões conectadas dentro delas e escolhe destinos considerando as quotas de visita restantes no mapa.

É como manter uma lista geral das áreas que ainda precisam de visitas e aproveitar boas oportunidades conforme as rotas avançam. O plugin continua sendo um planejador de destinos para caminhada aleatória; ele não define uma patrulha fixa.

**Importante:** o lockMapSweep muda **para onde a caminhada aleatória tenta ir**. O OpenKore continua responsável por calcular e executar o caminho. O plugin atua apenas quando está ativado e o personagem está no `lockMap` configurado.

## Como funciona

1. **Monta a topologia do mapa.** O plugin encontra as células caminháveis conectadas ao personagem pelas regras de movimento do OpenKore, mantém a grade configurada e identifica regiões internamente desconectadas dentro dos blocos. Regiões sem conexão com a área navegável do personagem não criam obrigações de visita.
2. **Mantém as quotas da rodada.** `lockMapSweep_cellsPerBlock` é o máximo de visitas confirmadas a destinos de cobertura atribuídas a cada bloco em uma rodada. As visitas a um bloco podem ser separadas por exploração em outros blocos; sair de um bloco não conclui nem reinicia sua quota.
3. **Escolhe destinos proporcionalmente.** A quantidade de células elegíveis determina a participação de cada região. O histórico de visitas confirmadas ajusta a seleção probabilística ao longo de várias rodadas, permitindo que regiões pequenas ganhem prioridade quando ficam esquecidas, sem garantir uma distribuição fixa em cada rodada.
4. **Planeja o deslocamento global.** Uma busca limitada considera as quotas restantes, os custos de chegada e saída e as regiões conectadas por blocos vizinhos. Uma obrigação distante pode ser alcançada por pontos de trânsito estratégico. O trânsito não conta como visita, e o plano é reavaliado conforme o personagem se movimenta ou as condições mudam.
5. **Aproveita oportunidades convenientes.** O histórico pode favorecer uma região próxima ou que faça parte de uma continuação útil. Uma região que exigiria deslocamento adicional excessivo pode ser adiada até surgir uma oportunidade adequada; ela pode continuar pendente indefinidamente, em vez de forçar um desvio.
6. **Confirma cada visita.** A quota do bloco e o histórico da região avançam somente quando o personagem chega a um destino de cobertura escolhido intencionalmente e a chegada é confirmada. Trânsito, rotas apenas enfileiradas, interrompidas ou malsucedidas não contam visitas.

O OpenKore continua calculando e executando cada rota. A topologia e as estimativas de custo do plugin orientam o planejamento dos destinos; elas não garantem que a rota nativa do OpenKore siga o caminho estimado ou tenha sucesso. Mudanças relevantes no mapa e na configuração invalidam ou reconstruem o estado de planejamento afetado.

## Primeiros passos

1. Coloque o arquivo `lockMapSweep.pl` no diretório de plugins utilizado pela sua instalação do OpenKore e confirme que ele está sendo carregado.
2. Configure o `lockMap` e a caminhada aleatória normal do OpenKore no arquivo `control/config.txt`.
3. Adicione as opções do lockMapSweep apresentadas abaixo e defina `lockMapSweep_enabled 1`.
4. Inicie o OpenKore e digite `lockMapSweep status` no console para conferir o planejamento atual.

> O plugin não teleporta o personagem, não escolhe um `lockMap` automaticamente e não substitui a navegação geral, o combate ou o movimento para NPCs do OpenKore.

### Exemplo de configuração

Adicione estas linhas ao arquivo `control/config.txt` do OpenKore (e configure separadamente o `lockMap` e o `randomWalk` normalmente):

```text
lockMapSweep_enabled 1
lockMapSweep_blocksX 3
lockMapSweep_blocksY 3
lockMapSweep_cellsPerBlock 2
lockMapSweep_useStateFile 1
```

Esse exemplo cria uma **grade 3 × 3** e busca realizar **até duas visitas confirmadas por bloco**.

![Exemplo de grade 3×3 no mapa ra_fild12](https://github.com/user-attachments/assets/eaca470e-e85f-4090-b76b-8d58f0654b21)

*Grade ilustrativa de 3 × 3 no mapa `ra_fild12`. Os limites reais dependem da área caminhável.*

## Referência das configurações

| Opção | Padrão | Função |
| --- | --- | --- |
| `lockMapSweep_enabled` | `0` | Defina `1` para ativar o plugin. |
| `lockMapSweep_blocksX` | `2` | Quantidade de blocos na horizontal. |
| `lockMapSweep_blocksY` | `2` | Quantidade de blocos na vertical. |
| `lockMapSweep_cellsPerBlock` | `3` | Máximo de visitas confirmadas a destinos de cobertura atribuídas a cada bloco por rodada global. As visitas podem ser não consecutivas. Um bloco com menos destinos elegíveis pode ter uma quota menor. |
| `lockMapSweep_useStateFile` | `1` | `1` salva o progresso em arquivo; `0` mantém o progresso somente em memória. |
| `lockMapSweep_stateDir` | `plugins/lockMapSweep/state` | Pasta utilizada para salvar os arquivos de estado. |

### Relação com as opções do OpenKore

O plugin respeita as configurações existentes `lockMap`, `lockMap_x`, `lockMap_y`, `lockMap_randX` e `lockMap_randY`. Essas coordenadas restringem **os destinos permitidos**, e não todas as células caminháveis por onde o personagem pode passar. Também considera as exclusões de destino registradas por meio do hook `add_dropDestinationCells` do OpenKore.

**Detalhe técnico:** um destino de cobertura precisa estar conectado à área navegável atual do personagem e obedecer às restrições configuradas. Outras células caminháveis podem ser usadas como trânsito, inclusive em blocos cujas quotas já foram concluídas. O planejador usa conectividade pelas regras de movimento e buscas limitadas de custo de rota; o OpenKore executa a rota selecionada de forma independente, e o comportamento do servidor, obstáculos ou falhas podem alterar o deslocamento real.

## Comandos do console

| Comando | O que faz |
| --- | --- |
| `lockMapSweep status` | Mostra se o planejamento está pronto, o mapa atual, os contadores de blocos e visitas e os blocos já visitados no ciclo. |
| `lockMapSweep rebuild` | Reconstrói o planejamento com o mapa e as configurações atuais. Se falhar, preserva o último estado válido em memória; configurações atuais incompatíveis ainda podem pausar a exploração. |
| `lockMapSweep clearstate` | Exclui o arquivo salvo sem limpar o planejamento em memória. Uma gravação posterior pode recriar o arquivo. |

## Salvamento de progresso e recuperação de falhas

Com a persistência ativada, o lockMapSweep salva as visitas confirmadas de cada bloco na rodada atual, o histórico de longo prazo das regiões, as obrigações adiadas, os destinos visitados e malsucedidos e qualquer destino pendente. Rotas pendentes são reconciliadas após uma reinicialização para evitar contabilizar a mesma chegada duas vezes. Na inicialização, os dados são verificados contra a geometria do mapa, a grade, a quota e as restrições de destino. **Estados incompatíveis são descartados e reconstruídos** para não orientar navegação inválida; mudar essas opções pode iniciar uma nova rodada e uma nova base de histórico regional.

A gravação utiliza um arquivo temporário e substituição atômica para reduzir o risco de arquivos parcialmente gravados.

Se uma alteração relevante de configuração invalidar uma rota iniciada pelo plugin, ela pode ser cancelada e recalculada. Caso não seja possível construir um planejamento válido com as novas opções, o plugin pausa a exploração para não continuar deliberadamente com restrições antigas. Obrigações conectadas globalmente podem continuar adiadas quando excedem o limite de desvios opcionais; não há garantia de que toda região adiada será atendida rapidamente. Em outras situações, quando existe um plano válido mas nenhum destino é selecionado, o `randomWalk` padrão do OpenKore ainda pode ser utilizado como alternativa. Quando falhas de rota esgotam temporariamente todos os destinos não visitados das quotas restantes, o plugin mantém essas quotas pendentes, impede o fallback do `randomWalk` padrão e tenta novamente os destinos falhos após uma espera de 30 segundos. Destinos que continuem indisponíveis ficam adiados e nunca são contabilizados como visitas.

## Compatibilidade e limites do planejamento

- O lockMapSweep usa hooks de plugin do OpenKore, as regras de caminhada e movimento de `Field` e a navegação nativa de `randomWalk`. Instale-o em uma versão do OpenKore que ofereça essas interfaces e os dados de campo do mapa configurado.
- O planejador usa seleção probabilística de regiões e busca limitada. As proporções de cobertura são tendências de longo prazo, não agendas fixas nem garantias para uma única rodada.
- Desvios opcionais de cobertura são limitados. O trânsito estratégico pode envolver várias rotas nativas, mas as estimativas não garantem o movimento confirmado pelo servidor.
- Uma região sem conexão global com a área navegável do personagem não é uma obrigação de cobertura. Uma região conectada pode continuar adiada se visitá-la for consistentemente caro.
- Repetir o trajeto por blocos ou corredores pode ser necessário para um plano eficiente. O trânsito não consome a quota de visitas do bloco, e a rodada não precisa terminar na posição inicial.

O planejamento por regiões não exige novas opções de configuração. As opções acima preservam a grade de blocos, as restrições de destino e os controles de persistência existentes.

---

*O lockMapSweep organiza os destinos da caminhada aleatória no mapa configurado. O OpenKore e o servidor continuam determinando se o movimento é possível e como ele será executado.*
