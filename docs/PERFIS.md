# Formato dos perfis de protocolo

Um perfil é um arquivo JSON que explica ao app como conversar com um fone.
Os perfis embutidos ficam em `Profiles/`; os seus ficam no app (Avançado › Perfis) e também
aparecem na pasta do app em **Arquivos › No meu iPhone › Kuba Control › Profiles**.

## Campos

| Campo | O que é |
|---|---|
| `id`, `name` | identificador e nome |
| `verified` | `true` só depois de testar num fone de verdade |
| `match.namePrefixes` | o perfil é escolhido sozinho se o nome do fone começar assim |
| `match.serviceUUIDs` | ...ou se o fone tiver algum destes serviços |
| `transport.service/write/notify` | UUIDs do serviço e das características de escrita e notificação |
| `transport.writeWithResponse` | `true` para escrever com confirmação |
| `equalizer` | frequências, ganho mínimo/máximo, passo (`step`), `offsetDb` e `encoding` de cada banda |
| `noiseModes` | código de cada modo: `off`, `anc`, `transparency`, `wind` |
| `touchSides`, `touchGestures`, `touchActions` | códigos usados no comando de toque |
| `commands` | modelo de bytes de cada comando (abaixo) |
| `events` | como ler as notificações do fone |
| `ota` | como enviar firmware (opcional) |

## Comandos (`commands`)

Chaves aceitas: `noiseMode`, `equalizer`, `touch`, `gameMode`, `battery`, `info`.

Cada valor é um **modelo** com bytes em hex e campos entre chaves:

| Trecho | Significado |
|---|---|
| `AA` | byte fixo |
| `{mode}` | modo de ruído (`noiseMode`) |
| `{gains}` | todas as bandas do EQ, já codificadas; `{count}` = número de bandas; `{g0}`…`{g9}` = banda isolada |
| `{side}` `{gesture}` `{action}` | comando de toque |
| `{enabled}` | 0/1 (`gameMode`) |
| `{nome:u16le}` | campo com outro formato: `u8`, `i8`, `u16le`, `u16be`, `i16le`, `i16be`, `u32le`, `u32be` |
| `{seq}` | número de sequência (1 byte, aumenta a cada comando) |
| `{len:FORMATO:N}` | tamanho dos bytes que vêm depois deste campo, sem contar os `N` últimos |
| `{sum8}` `{xor8}` `{crc16le}` `{crc16be}` | checksum dos bytes anteriores; `{sum8:2}` começa no byte 2 |

Exemplo (protocolo KubaOpen):

```
"noiseMode": "55 AA {len:u8:1} {seq} 01 {mode} {sum8:2}"
```

### Codificação do EQ

O valor enviado de cada banda é `(ganho_dB - offsetDb) / step`.
Exemplos: com `step` 1 e `offsetDb` 0, +3 dB vira 3. Com `step` 0,5, +3 dB vira 6.
Com `offsetDb` -12 (fones que usam 0..24), 0 dB vira 12.

## Eventos (`events`)

```json
{ "type": "battery", "match": "55 AA ?? ?? 85",
  "fields": { "left": { "offset": 5, "mask": 127 }, "right": { "offset": 6, "mask": 127 } } }
```

- `type`: `battery` (campos `left`, `right`, `case`), `noiseMode` (campo `mode`),
  `firmwareVersion` (campo `version`, com `format` `dotted`, `ascii` ou `hex`) ou `ack`.
- `match`: começo da mensagem; `??` vale qualquer byte.
- `offset`: posição do byte (começa em 0). `type` do campo segue os formatos acima. `mask` limpa
  bits (ex.: 127 tira o bit de "carregando").

## OTA (`ota`)

```json
"ota": {
  "chunkSize": 128,
  "start":  "... {size:u32le} {crc32:u32le} {chunkSize:u16le} ...",
  "chunk":  "... {offset:u32le} {data} ...",
  "finish": "... {crc32:u32le} ...",
  "ackMatch": "55 AA ?? ?? 7F ?? 00",
  "ackTimeoutMs": 3000, "retries": 3, "minBattery": 50
}
```

Campos disponíveis: `{size}`, `{crc32}` (CRC-32 do arquivo todo), `{chunkSize}`, `{chunks}`,
e no bloco `{offset}`, `{index}`, `{data}` e `{chunkCrc}` (CRC-16 do bloco).
Cada pacote espera uma resposta que case com `ackMatch`; sem resposta, repete até `retries` vezes
e depois para.
