# Vitrine para Nautilus

**Modo Colunas, painel de pré-visualização e visualização por pasta para o Arquivos (Nautilus) do GNOME, inspirados no Finder do macOS, sem perder nenhuma função nativa.**

![Nautilus 51](https://img.shields.io/badge/Nautilus-51-4a86cf)
![Fedora 45](https://img.shields.io/badge/Fedora-45-51a2da)
![Python](https://img.shields.io/badge/Python-3-3776ab)
![Licença MIT](https://img.shields.io/badge/licen%C3%A7a-MIT-green)

<!-- Capturas de tela: salve as imagens em docs/ e descomente as linhas abaixo.
![Modo Colunas com pré-visualização](docs/colunas.png)
![Pasta Imagens em ícones grandes](docs/imagens.png)
-->

A Vitrine é uma extensão para o **Nautilus 51** (e, em princípio, o 50). Ela acrescenta ao gerenciador de arquivos do GNOME três recursos que fazem falta para quem vem do macOS:

- 🗂️ **Modo Colunas**: navegue pelas pastas em colunas, como no Finder.
- 🖼️ **Painel de pré-visualização**: veja imagens, textos, vídeos, PDFs e pastas ao lado da lista, sem abrir nada.
- 📌 **Visualização por pasta**: cada pasta lembra se você prefere lista, ícones, ícones grandes ou colunas.

A diferença em relação a outras soluções é o **modo híbrido**. A pasta atual continua sendo exibida pela **própria lista do Nautilus**, então menu de contexto, renomear, arrastar e soltar, recortar e colar, Desfazer, scripts e outras extensões funcionam exatamente como antes. A Vitrine só acrescenta coisas; não substitui nada.

---

## Recursos

### 🗂️ Modo Colunas

- Ative com **Ctrl+3** ou com o botão de colunas na barra superior.
- As pastas anteriores do caminho aparecem como colunas à esquerda, com o item do caminho destacado. A pasta atual fica na lista nativa do Nautilus, à direita.
- Clique numa pasta de qualquer coluna para ir até ela. Navegar com as setas do teclado funciona.
- Clique num arquivo de uma coluna anterior para abrir a pasta dele **já com o arquivo selecionado** na lista nativa, com todas as ações do Nautilus disponíveis.
- **Arraste e solte** entre colunas, da coluna para a lista e da lista para a coluna. Mover e copiar usam as operações do próprio Nautilus, com barra de progresso, diálogo de conflito e **Ctrl+Z**.
- Clique do meio numa pasta abre em nova janela. O clique direito traz Abrir, Abrir em nova janela, Mostrar na lista, Copiar caminho e Mover para a lixeira.
- Respeita a opção de **mostrar arquivos ocultos** do Nautilus.

### 🖼️ Painel de pré-visualização

Ative com **Ctrl+Shift+P** ou com o botão de painel. A largura pode ser ajustada arrastando a borda e fica salva.

| Seleção | O que o painel mostra |
|---|---|
| Imagem | A imagem com rotação EXIF correta, dimensões, tipo, tamanho e datas |
| Texto / código | O conteúdo, em fonte monoespaçada (até 400 linhas) |
| Vídeo, PDF, documentos | A miniatura do sistema (gerada na hora, se ainda não existir) |
| Pasta | A lista do conteúdo, com contagem de pastas e arquivos. Clique para entrar |
| Vários itens | A quantidade de itens e o tamanho total |
| Nada selecionado | As informações da pasta atual |

O botão **Abrir** usa o aplicativo padrão. O botão 👁 (ou a tecla **Espaço**) abre a visualização rápida do GNOME (Sushi).

**Rápido de verdade.** No Fedora 45 o carregador de imagens do sistema (glycin) abre um processo isolado para cada imagem. A Vitrine contorna isso:

- mostra a miniatura já existente na hora;
- decodifica JPEG, PNG e TIFF com o decodificador do GTK, lendo dimensões e rotação direto do cabeçalho;
- guarda em cache as imagens já vistas;
- pré-carrega as imagens vizinhas.

| Situação (medida no Nautilus 51) | Primeira imagem | Imagem nítida |
|---|---|---|
| Foto nova | ~40 ms | ~190 ms |
| Foto vizinha (pré-carregada) | ~38 ms | ~38 ms |
| Foto já vista | ~37 ms | ~37 ms |

### 📌 Visualização por pasta

- Trocou de visualização numa pasta, com **Ctrl+1** (lista), **Ctrl+2** (ícones), **Ctrl+3** (colunas), os botões ou o menu? A Vitrine **lembra a escolha para aquela pasta**. Pastas sem regra usam o seu padrão.
- O **zoom dos ícones também é salvo por pasta**: ícones gigantes em *Imagens*, ícones normais em *Downloads*.
- **Pastas de fotos e vídeos são detectadas automaticamente.** Se a maioria dos arquivos for imagem ou vídeo, a pasta abre em ícones grandes.
- Na primeira execução, *Imagens* e *Vídeos* já vêm configuradas para ícones grandes, **incluindo as subpastas**.
- Navegando em colunas, as subpastas continuam em colunas.

Clique com o botão direito no **fundo de qualquer pasta** e escolha **Visualização desta pasta**:

- Lista · Ícones · Ícones grandes · Colunas
- Aplicar também às subpastas / Não aplicar às subpastas
- Esquecer esta pasta (usar o padrão)
- Usar a visualização atual como padrão
- Mostrar/ocultar pré-visualização

---

## Instalação

### Requisitos

- **Nautilus 51** (GNOME 51, Fedora 45), versão em que a extensão foi testada. O Nautilus 50 (Fedora 44) tem a mesma estrutura de janela e deve funcionar, mas ainda não foi testado. Outras distribuições com essas versões também devem funcionar.
- `nautilus-python` (o instalador oferece instalar).

### Opção 1: clonar o repositório

```bash
git clone https://github.com/viniciusbispo19/nautilus-vitrine.git
```

```bash
cd nautilus-vitrine && ./install.sh
```

O `install.sh` instala o `nautilus-python` se faltar (pede sua senha), copia a extensão para `~/.local/share/nautilus-python/extensions/` e reinicia o Nautilus.

### Opção 2: script único

O arquivo `criar-vitrine.sh` contém o projeto inteiro. Baixe-o e rode:

```bash
bash criar-vitrine.sh --instalar
```

Ele cria a pasta `~/nautilus-vitrine` com todos os arquivos e já instala. Sem `--instalar`, só cria a pasta. Também dá para passar outro destino: `bash criar-vitrine.sh ~/Projetos/vitrine`.

### Desinstalar

```bash
./uninstall.sh
```

O Nautilus volta exatamente ao original. Suas regras ficam guardadas; use `./uninstall.sh --purge` para apagar tudo.

> **Não é uma extensão do GNOME Shell.** A Vitrine roda dentro do Nautilus, via nautilus-python, e por isso não aparece no app Extensões nem no extensions.gnome.org. Ela é gerenciada pelos scripts acima.

---

## Atalhos

| Atalho | Ação |
|---|---|
| **Ctrl+3** | Modo Colunas |
| **Ctrl+1** / **Ctrl+2** | Lista / Ícones (nativos do Nautilus, agora lembrados por pasta) |
| **Ctrl+Shift+P** | Mostrar/ocultar a pré-visualização |
| **Espaço** | Visualização rápida (Sushi) |
| **Ctrl + roda do mouse** | Zoom (salvo por pasta na visualização em ícones) |
| Clique do meio numa coluna | Abrir a pasta em nova janela |

---

## Configuração

Tudo funciona sem configurar nada. Para ajustes finos, edite os arquivos abaixo com o Nautilus fechado (`nautilus -q`).

**`~/.config/nautilus-vitrine/settings.json`**

| Chave | Padrão | Descrição |
|---|---|---|
| `preview_visible` | `true` | Painel de pré-visualização aberto |
| `preview_width` | `320` | Largura do painel (px), salva ao arrastar a borda |
| `column_width` | `230` | Largura de cada coluna (px) |
| `max_visible_columns` | `3` | Colunas visíveis antes de começar a rolar |
| `remember_per_folder` | `true` | Lembrar a visualização escolhida em cada pasta |
| `auto_media_grid` | `true` | Abrir pastas de fotos/vídeos em ícones grandes |
| `auto_media_zoom` | `"extra-large"` | Zoom usado nessas pastas |
| `auto_media_ratio` | `0.6` | Proporção mínima de mídia para considerar "pasta de fotos" |
| `default_mode` | do Nautilus | Visualização das pastas sem regra: `list`, `grid` ou `columns` |
| `default_grid_zoom` | do Nautilus | Zoom padrão dos ícones |

**`~/.config/nautilus-vitrine/folders.json`** guarda as regras por pasta:

```json
{
  "file:///home/voce/Imagens": { "mode": "grid", "zoom": "extra-large", "recursive": true },
  "file:///home/voce/Projetos": { "mode": "columns" }
}
```

Zooms válidos: `small`, `small-plus`, `medium`, `large`, `extra-large`.

---

## Como funciona

O Nautilus não tem API pública para novas visualizações ou painéis. Assim como o [My Computer for Nautilus](https://github.com/yannmasoch/nautilus-my-computer), a Vitrine roda dentro do processo do Nautilus (via nautilus-python) e insere seus widgets na janela em tempo de execução. Para quebrar o mínimo possível com atualizações do GNOME:

- **Um único ponto de injeção.** Só o conteúdo do `AdwToolbarView` que contém as abas é envolvido por `[colunas | abas do Nautilus] ‖ [pré-visualização]`. O resto da janela fica intocado.
- **Nada do Nautilus é reimplementado.** A pasta atual é sempre a lista nativa, e a seleção é lida do próprio `NautilusViewModel`.
- **Sem referências fortes.** Widgets e modelos do Nautilus nunca são mantidos vivos pela extensão; o modelo de seleção é acompanhado por *weak reference*.
- **Operações nativas.** Mover, copiar e lixeira passam pela API D-Bus `org.gnome.Nautilus.FileOperations2`, com progresso, conflitos e Desfazer.
- **Falha segura.** Se uma versão futura do Nautilus mudar a estrutura da janela, a Vitrine simplesmente não se injeta e registra o motivo no log. Exceções em callbacks também viram log, sem derrubar o Nautilus.

### Estrutura do código

```
nautilus-vitrine.py     ponto de entrada carregado pelo nautilus-python
vitrine/
  main.py               descobre as janelas, CSS, menu "Visualização desta pasta"
  window.py             injeção por janela, botões, atalhos, regras por pasta
  columns.py            Modo Colunas (Gtk.DirectoryList + ListView)
  preview.py            painel de pré-visualização
  imageload.py          carregamento rápido de imagens, cache e pré-carregamento
  native.py             ponte com o Nautilus (slot, lista/grade, seleção)
  config.py             preferências e regras (JSON)
  util.py               log, varredura de widgets, operações D-Bus
  selftest.py           autoteste dentro do Nautilus real
tools/
  smoke_test.py         teste das colunas e do preview fora do Nautilus
  build_bootstrap.py    gera o criar-vitrine.sh
```

---

## Desenvolvimento

```bash
./install.sh --dev
```

O modo dev usa links simbólicos: edite o código e só reinicie o Nautilus (`nautilus -q`).

O projeto inclui tarefas do **VS Code** (*Terminal → Run Task*):

| Tarefa | O que faz |
|---|---|
| **Ctrl+Shift+B** | Instala em modo dev e reinicia o Nautilus |
| Autoteste dentro do Nautilus | 19 verificações automáticas: injeção, colunas, preview, regras por pasta, zoom e tempo de carregamento das imagens. Suas regras e o zoom são restaurados no fim |
| Rodar em modo depuração | `VITRINE_DEBUG=1 VITRINE_DUMP=1 nautilus` (inclui a árvore de widgets da janela no log) |
| Acompanhar log | `tail -f ~/.cache/nautilus-vitrine/vitrine.log` |
| Teste fora do Nautilus | Abre colunas e preview numa janela própria |
| Gerar script único | Atualiza o `criar-vitrine.sh` |

Para rodar o autoteste pelo terminal:

```bash
nautilus -q; VITRINE_SELFTEST=1 nautilus --new-window ~ &
```

Depois de alguns segundos, veja o resultado:

```bash
grep SELFTEST ~/.cache/nautilus-vitrine/vitrine.log
```

---

## Solução de problemas

- **Nada mudou no Nautilus:** confira se o `nautilus-python` está instalado (`rpm -q nautilus-python`), feche o Nautilus por completo (`nautilus -q`) e abra de novo.
- **Algo estranho aconteceu:** veja `~/.cache/nautilus-vitrine/vitrine.log`. A linha `janela injetada com sucesso` confirma que a extensão carregou. Se o log apontar que o TabView não foi encontrado, a estrutura do Nautilus mudou: abra uma *issue* com o log.
- **Quer voltar ao Nautilus original:** `./uninstall.sh`.

## Limitações conhecidas

- A extensão usa estruturas internas do Nautilus, que podem mudar a cada versão do GNOME. Foi testada no Nautilus 51.1 (Fedora 45).
- Nas colunas anteriores o menu de clique direito é reduzido. Para o menu completo, use **Mostrar na lista**.
- O zoom dos ícones é uma preferência global do Nautilus. Ao entrar numa pasta com zoom salvo, outras janelas abertas em ícones acompanham.
- Locais especiais (Recentes, Favoritos, Lixeira, Rede, Pesquisa) mantêm o comportamento padrão do Nautilus.

## Próximos passos

- [ ] Pacote RPM e repositório COPR (`dnf install`)
- [ ] Tocar vídeo e áudio direto no painel
- [ ] Folhear páginas de PDF no painel
- [ ] Dados EXIF da foto (câmera, lente, GPS)
- [ ] Tela de preferências

Sugestões e *pull requests* são bem-vindos.

## Créditos

A técnica de injeção na janela foi inspirada no projeto **[My Computer for Nautilus](https://github.com/yannmasoch/nautilus-my-computer)**, de Yann Masoch (licença MIT).

## Licença

[MIT](LICENSE)
