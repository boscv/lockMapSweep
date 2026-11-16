# 🗺️ lockMapSweep

**Exploração mais inteligente dos mapas no [OpenKore](https://github.com/OpenKore/openkore).**  
**Versão 2.0.0**

**🌐 Idioma:** [🇺🇸 English](README.md) | **Português**

## O que é o lockMapSweep?

O OpenKore consegue movimentar o personagem pelo mapa usando o `randomWalk`, mas escolher destinos aleatórios nem sempre resulta em uma exploração organizada. **O lockMapSweep torna essa movimentação mais sistemática:** divide a parte caminhável do mapa definido em `lockMap` em áreas menores (**blocos**) e seleciona destinos em cada uma antes de seguir para a próxima.

É como explorar um bairro por setores, em vez de ficar indo de uma rua aleatória a outra.

**Importante:** o lockMapSweep muda **para onde a caminhada aleatória tenta ir**. O OpenKore continua responsável por calcular e executar o caminho. O plugin atua apenas quando está ativado e o personagem está no `lockMap` configurado.

## Como funciona

1. **Identifica a área acessível.** O plugin encontra as células caminháveis conectadas à posição atual do personagem e ignora regiões isoladas.
2. **Divide o mapa em blocos.** Essa área é organizada em uma grade com quantidade configurável de blocos horizontais e verticais.
3. **Escolhe um destino.** O plugin procura um ponto válido no bloco atual, evitando repetições desnecessárias.
4. **Confirma a chegada.** Uma visita só é contabilizada **depois que a chegada é confirmada**. Rotas canceladas, interrompidas ou travadas não contam.
5. **Avança para outro bloco.** Após atingir a quantidade de visitas, o plugin prefere um bloco vizinho ainda não visitado. Quando os blocos ativos são percorridos, um novo ciclo pode começar.

As transições entre blocos passam por verificações de conectividade. O plugin também reage a mudanças relevantes de mapa ou configuração, em vez de continuar usando um planejamento desatualizado.

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
| `lockMapSweep_cellsPerBlock` | `3` | Máximo de visitas confirmadas em um bloco antes de trocar. Blocos com menos destinos válidos podem ter uma quota menor. |
| `lockMapSweep_useStateFile` | `1` | `1` salva o progresso em arquivo; `0` mantém o progresso somente em memória. |
| `lockMapSweep_stateDir` | `plugins/lockMapSweep/state` | Pasta utilizada para salvar os arquivos de estado. |

### Relação com as opções do OpenKore

O plugin respeita as configurações existentes `lockMap`, `lockMap_x`, `lockMap_y`, `lockMap_randX` e `lockMap_randY`. Essas coordenadas restringem **os destinos permitidos**, e não todas as células caminháveis por onde o personagem pode passar. Também considera as exclusões de destino registradas por meio do hook `add_dropDestinationCells` do OpenKore.

**Detalhe técnico:** o destino precisa pertencer à região caminhável conectada ao personagem e obedecer às restrições configuradas. Nas mudanças de bloco, a seleção verifica a existência de um caminho pela área dos blocos de origem e destino. Isso reduz falhas evitáveis, mas não garante sucesso em qualquer servidor.

## Comandos do console

| Comando | O que faz |
| --- | --- |
| `lockMapSweep status` | Mostra se o planejamento está pronto, o mapa atual, os contadores de blocos e visitas e os blocos já visitados no ciclo. |
| `lockMapSweep rebuild` | Reconstrói o planejamento com o mapa e as configurações atuais. Se falhar, preserva o último estado válido em memória; configurações atuais incompatíveis ainda podem pausar a exploração. |
| `lockMapSweep clearstate` | Exclui o arquivo salvo sem limpar o planejamento em memória. Uma gravação posterior pode recriar o arquivo. |

## Salvamento de progresso e recuperação de falhas

Com a persistência ativada, o lockMapSweep salva o planejamento, o progresso, os destinos visitados e malsucedidos e qualquer destino pendente. Na inicialização, verifica se esses dados são compatíveis com a geometria do mapa, a grade e as restrições de destino. **Estados antigos ou incompatíveis são reconstruídos**, em vez de reutilizados sem verificação.

A gravação utiliza um arquivo temporário e substituição atômica para reduzir o risco de arquivos parcialmente gravados.

Se uma alteração relevante de configuração invalidar uma rota iniciada pelo plugin, ela pode ser cancelada e recalculada. Caso não seja possível construir um planejamento válido com as novas opções, o plugin pausa a exploração para não continuar deliberadamente com restrições antigas. Em outras situações, quando existe um plano válido mas nenhum destino é selecionado, o `randomWalk` padrão do OpenKore ainda pode ser utilizado como alternativa.

## O que mudou na versão 2.0.0?

- **Progresso mais preciso:** um destino só conta depois da chegada confirmada, não quando a rota é solicitada.
- **Melhor recuperação:** rotas interrompidas ou travadas não aumentam indevidamente as visitas; destinos malsucedidos são acompanhados.
- **Destinos mais seguros:** melhores verificações de conectividade e respeito às restrições de coordenadas e às exclusões de destino.
- **Atualização em tempo real:** o planejamento reage a mudanças relevantes nas configurações e no mapa.
- **Salvamento mais confiável:** validação mais rigorosa do estado persistido e substituição segura dos arquivos.

---

*O lockMapSweep organiza os destinos da caminhada aleatória no mapa configurado. O OpenKore e o servidor continuam determinando se o movimento é possível e como ele será executado.*
