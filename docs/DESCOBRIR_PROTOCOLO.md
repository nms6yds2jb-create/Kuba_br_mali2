# Como descobrir o protocolo do Kuba Mali 2

O app já tem todas as telas. O que falta é saber **quais bytes** o Mali 2 entende.
Siga estes passos e anote tudo: cada descoberta vira uma linha no perfil
`Profiles/kuba-mali2.json` (ou num perfil novo, criado no próprio app).

## 1. Ver o que o fone mostra por BLE

1. Instale o app (veja o README) e abra a aba **Fone › Procurar fones**.
   O Mali 2 costuma aparecer marcado como **"Kuba?"** ou como **"conectado ao iPhone"**.
2. Conecte e abra **Avançado › Explorador Bluetooth**.
3. Anote:
   - os **serviços** (UUIDs). Os que têm uma pista em laranja são os mais promissores
     (ex.: `AE00` costuma indicar chip JieLi);
   - em **Informações do aparelho**, o fabricante, o modelo e a versão do firmware.
     Esses textos às vezes revelam o fabricante do chip.

**Se não aparecer nenhum serviço além dos padrões (`180A`, `180F`)**, o fone provavelmente só
recebe comandos pelo Bluetooth clássico (SPP). Nesse caso o iPhone não consegue controlá-lo
(limitação da Apple), e o único caminho é um firmware próprio (veja [FIRMWARE.md](FIRMWARE.md)).

## 2. Escutar o fone

1. No Explorador, entre em cada característica com **notificar** e ative **Receber notificações**.
2. Agora use o fone pelo toque: troque ANC/ambiente pelo toque longo, tire um fone da orelha,
   ponha no estojo.
3. Abra **Avançado › Registro de pacotes**. As linhas verdes (`←`) são o que o fone mandou.
   Uma mensagem que aparece sempre que você troca o modo e muda só um byte é o **evento de
   modo de ruído**. Aquele byte é o código do modo.
4. Compartilhe o registro (botão no topo) para guardar.

## 3. Capturar um app que já controla o fone (se existir)

Alguns fones de marca própria usam o mesmo chip e o mesmo app genérico do fabricante do chip.
Se você achar um app Android que controle o Mali 2:

1. No Android: **Opções do desenvolvedor › Ativar registro de rastreamento HCI Bluetooth**.
2. Desligue e ligue o Bluetooth, use o app: troque o ANC várias vezes, mexa em cada banda do EQ,
   mude cada toque. Faça **uma coisa de cada vez** e anote a hora.
3. Gere um relatório de bug (`adb bugreport`) e tire o arquivo `btsnoop_hci.log` de dentro dele.
4. Analise no computador:

   ```sh
   python3 tools/btsnoop_analyzer.py btsnoop_hci.log            # lista tudo
   python3 tools/btsnoop_analyzer.py btsnoop_hci.log --diff     # destaca o que muda
   ```

   No `--diff`, as colunas `..` são iguais em todos os pacotes; os bytes visíveis são os que
   mudam. Um comando de ANC costuma ficar como `AA 01 ??`: o `??` é o modo.

No Mac, dá para capturar do próprio iPhone com o **PacketLogger** (Ferramentas Adicionais do
Xcode) usando o perfil de log Bluetooth da Apple e exportar como btsnoop.

## 4. Escrever o perfil

No app: **Avançado › Perfis › Novo perfil a partir do fone conectado**. Ele já preenche o
serviço e as características. Depois complete `commands` e `events` seguindo
[PERFIS.md](PERFIS.md). Exemplo, se o ANC for `AA 01 <modo>` com 0 = desligado, 1 = ANC e
2 = ambiente:

```json
"noiseModes": { "off": 0, "anc": 1, "transparency": 2 },
"commands":   { "noiseMode": "AA 01 {mode}" }
```

Salve e teste na aba **Fone**. Se funcionar, troque `"verified"` para `true`.

## 5. Testar comandos na mão

No Explorador, abra a característica de escrita e envie bytes em hex. Regras de segurança:

- comece **repetindo** pacotes que você viu na captura;
- mude **um byte por vez**;
- evite códigos altos/aleatórios: fabricantes escondem comandos de teste de fábrica e de
  apagar a flash. Nunca envie nada que pareça início de atualização sem entender o que é.
