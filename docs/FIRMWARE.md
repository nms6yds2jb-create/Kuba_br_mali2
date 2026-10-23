# Firmware: atualizar, fazer backup e criar o seu

> **Leia tudo antes de começar.** Gravar firmware errado pode deixar o fone sem funcionar
> ("brickar") e anula a garantia. Fones TWS são pequenos, colados e difíceis de consertar.

## O que o app já faz

A aba **Firmware** envia um arquivo `.bin` para o fone pelo Bluetooth (OTA), com:

- verificação do arquivo (vazio, só `FF`, grande demais, formato ELF) e CRC-32;
- trava de bateria (padrão: 50% nos dois fones);
- **modo simulação** ligado por padrão: monta todos os pacotes e mostra o resultado sem enviar;
- confirmação de cada bloco, novas tentativas e cancelamento.

O envio só funciona se o perfil do fone tiver a seção `ota`. Hoje só o protocolo **KubaOpen**
tem. Para o firmware original do Mali 2 é preciso descobrir o protocolo de atualização do chip,
que é diferente para cada fabricante e quase sempre tem verificação própria.

Teste no **modo demonstração**: o fone virtual aceita qualquer arquivo e sobe a versão.

## Caminho para um firmware próprio

### 1. Descobrir o chip

Sem saber o chip não dá para fazer nada. Em ordem de facilidade:

1. **Explorador do app**: o serviço `AE00` sugere JieLi; o serviço RACE sugere Airoha.
   Em "Informações do aparelho", o fabricante às vezes aparece.
2. **Certificado da Anatel**: o número de homologação vem na caixa. No sistema de consulta da
   Anatel (SCH), os relatórios de ensaio às vezes trazem **fotos internas** com o chip visível.
3. **Abrir um fone** (de preferência um com defeito): procure a marcação no chip principal.

Famílias comuns em fones TWS:

| Fabricante | SDK | Observação |
|---|---|---|
| JieLi (Zhuhai Jieli) | parte é pública em [github.com/Jieli-Tech](https://github.com/Jieli-Tech); a de fones TWS costuma ser distribuída a clientes | o mais comum em fones baratos; atualiza pelo pino de carga |
| Bluetrum | distribuído a clientes | comum em fones baratos |
| BES (Bestechnic) | sob acordo de confidencialidade | existe firmware aberto para o BES2300: [OpenPineBuds](https://github.com/pine64/OpenPineBuds) (PineBuds Pro) |
| Airoha | sob acordo de confidencialidade | atualização pelo protocolo RACE |
| Realtek, Qualcomm | sob acordo de confidencialidade | firmware assinado: na prática, inviável |

### 2. Fazer backup do original

**Antes de qualquer gravação**, leia a flash inteira e guarde (de preferência em dois lugares).
Sem backup, um erro não tem volta. O jeito de ler depende do chip: modo de gravação por USB,
UART pelos contatos de carga ou leitor direto na flash SPI (quando é externa).

Muitos fones TWS usam os **dois contatos de carga** também para dados (gravação na fábrica).
Uma placa de teste com pogo pins ajuda muito.

### 3. Escrever o firmware

1. Pegue o SDK do chip e compile o exemplo de fone TWS **sem mudanças**. Grave e confirme que
   funciona igual ao original (áudio, pareamento, ANC).
2. Adicione um serviço BLE com os UUIDs do KubaOpen
   ([PROTOCOLO_KUBAOPEN.md](PROTOCOLO_KUBAOPEN.md)).
3. Copie `firmware/kubaopen/kubaopen.c` e `kubaopen.h` para o projeto e implemente as funções de
   `kubaopen_hal.h` com as APIs do SDK (modo ANC, EQ, toques, bateria, gravação na flash).
4. Na escrita BLE recebida, chame `ko_feed()`. Pronto: o app reconhece o fone sozinho pelo
   perfil `kubaopen.json` e todas as telas funcionam.
5. Para o EQ: o SDK costuma ter um EQ de 10 bandas com coeficientes calculados no chip; converta
   os passos de 0,5 dB recebidos para o formato do SDK e grave na área de configuração.

### 4. Atualização pelo app com segurança

O módulo C só chama `ko_hal_ota_commit()` se o tamanho e o CRC-32 conferem. Ainda assim, para
nunca brickar pelo Bluetooth:

- grave o novo firmware numa **segunda área** da flash (banco B), nunca por cima do que está
  rodando;
- o bootloader só troca para o banco B depois da confirmação e **volta ao A** se o B não subir;
- nunca deixe o OTA apagar o bootloader nem a área de calibração (endereço Bluetooth, ajuste
  de ANC de fábrica). Guarde essa área no backup.

### 5. Os dois fones

Em fones TWS, o celular fala com um fone (o principal) e ele repassa ao outro. Comandos de EQ,
ANC e toques precisam ser sincronizados pelo canal entre os fones (o SDK tem função para isso).
No OTA, atualize os dois: o principal recebe e repassa, ou o app atualiza um de cada vez.

## Firmware não oficial de terceiros

Se você conseguir um arquivo de firmware para o mesmo chip e o mesmo modelo de placa, o app só
consegue enviá-lo se o perfil souber o protocolo de atualização daquele chip. Desconfie de
arquivos sem origem clara: firmware de outra placa pode ligar os pinos errados e queimar o fone.
