# Protocolo KubaOpen

Protocolo aberto e simples para controlar fones por BLE. Ele é usado pelo modo demonstração,
pelo módulo C em `firmware/kubaopen` e pelo perfil `Profiles/kubaopen.json`.

## Bluetooth

| Item | UUID |
|---|---|
| Serviço | `6B756261-4F50-454E-0000-000000000001` |
| Escrita (celular → fone), write without response | `6B756261-4F50-454E-0000-000000000002` |
| Notificação (fone → celular) | `6B756261-4F50-454E-0000-000000000003` |

Nome anunciado sugerido: `KubaOpen <modelo>`.
Um quadro pode chegar dividido em várias escritas (MTU pequeno): o fone remonta pelo `len`.

## Quadro

```
55 AA  len  seq  cmd  dados...  soma
```

- `len`: número de bytes de `seq` até o último dado (`2 + tamanho dos dados`)
- `seq`: contador do remetente (0–255, dá a volta)
- `soma`: soma de 8 bits de `len` até o último dado
- inteiros multibyte em little-endian

## Comandos (celular → fone)

| cmd | Nome | Dados | Resposta |
|---|---|---|---|
| `01` | Modo de ruído | `modo` (0 desligado, 1 ANC, 2 ambiente, 3 vento) | ACK + evento `81` |
| `02` | Equalizador | `n` + `n` bytes com sinal, passos de 0,5 dB (−24..24) | ACK |
| `03` | Toque | `lado` (0 esq., 1 dir.), `gesto` (0 simples, 1 duplo, 2 triplo, 3 longo), `ação` | ACK |
| `04` | Modo jogo | 0/1 | ACK |
| `05` | Bateria | — | evento `85` |
| `06` | Informações | — | eventos `86` e `81` |
| `10` | OTA início | `tamanho` (u32), `crc32` (u32), `bloco` (u16) | ACK |
| `11` | OTA dados | `posição` (u32) + dados | ACK |
| `12` | OTA fim | `crc32` (u32) | ACK (e reinicia) ou NACK `7E` |

Bandas do EQ: 31, 62, 125, 250, 500, 1k, 2k, 4k, 8k, 16k Hz.

Ações de toque: 0 nenhuma, 1 play/pause, 2 próxima, 3 anterior, 4 volume +, 5 volume −,
6 assistente de voz, 7 alternar ANC/ambiente, 8 modo jogo, 9 atender/desligar.

## Eventos (fone → celular)

| cmd | Nome | Dados |
|---|---|---|
| `7F` | ACK | `cmd` original, `status` (0 ok, 1 erro) |
| `7E` | NACK de OTA | `cmd`, `1` |
| `81` | Modo de ruído | `modo` — enviar também quando o usuário troca pelo toque |
| `85` | Bateria | `esquerdo`, `direito`, `estojo` (0–100; bit 7 = carregando) |
| `86` | Versão | `maior`, `menor`, `correção` |

## Regras de OTA

- Blocos em ordem; um bloco repetido (posição já recebida) é só confirmado de novo.
- Bloco fora de ordem ou além do tamanho: ACK com status 1.
- `12` só aceita se o tamanho e o CRC-32 do que foi recebido conferem; senão aborta e responde
  `7E`.
- Gravar em banco separado e só trocar depois de validar (veja [FIRMWARE.md](FIRMWARE.md)).
