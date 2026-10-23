# Kuba Control — app iOS para o fone Kuba Mali 2

App em SwiftUI para controlar o **Kuba Mali 2** pelo iPhone:

- **Controle de ruído**: cancelamento (ANC), modo ambiente, redução de vento, desligado e modo jogo
- **Equalizador** de 10 bandas (±12 dB), com gráfico da curva, predefinições prontas e predefinições suas
- **Toques**: escolha a ação de cada gesto (toque simples, duplo, triplo e longo) em cada lado
- **Bateria** dos dois fones e do estojo
- **Firmware**: envio de firmware pelo Bluetooth (OTA), com travas de segurança e modo simulação
- **Ferramentas para descobrir o protocolo**: explorador Bluetooth, registro de pacotes e editor de perfis
- **Base para um firmware próprio**: protocolo aberto (KubaOpen) com implementação em C pronta para o fone

## Situação atual (importante)

A Kuba não publica o protocolo do Mali 2 nem informa o chip usado, e não existe app oficial.
Por isso o app foi feito em camadas:

| Parte | Situação |
|---|---|
| Telas, equalizador, toques, firmware, explorador | Prontos |
| Modo demonstração (fone virtual) | Pronto: dá para usar tudo sem o fone |
| Comandos do Mali 2 | **Faltam descobrir**: o perfil `Profiles/kuba-mali2.json` está vazio |
| Firmware próprio | Protocolo e módulo em C prontos; falta portar para o SDK do chip |

Quando os comandos do Mali 2 forem descobertos, basta preencher o perfil JSON (pelo próprio app,
em **Avançado › Perfis**). Não precisa mudar código. O passo a passo está em
[docs/DESCOBRIR_PROTOCOLO.md](docs/DESCOBRIR_PROTOCOLO.md).

## Como instalar no iPhone

**Sem Mac:** cada execução do CI (aba *Actions* do GitHub) gera o arquivo
`KubaControl-unsigned-ipa`. Instale com [AltStore](https://altstore.io) ou
[Sideloadly](https://sideloadly.io), que assinam com seu Apple ID gratuito (a assinatura vale 7 dias).

**Com Mac:**

```sh
brew install xcodegen
xcodegen generate
open KubaControl.xcodeproj   # escolha seu time em Signing e rode no iPhone
```

## Estrutura

```
App/                  app iOS (SwiftUI + CoreBluetooth)
Sources/KubaCore/     lógica sem iOS: perfis, comandos, EQ, firmware/OTA, simulador
Tests/KubaCoreTests/  testes do núcleo (rodam no Linux e no macOS)
Profiles/             perfis de protocolo (JSON) embutidos no app
firmware/kubaopen/    lado do fone do protocolo KubaOpen, em C99, com testes
tools/                btsnoop_analyzer.py: analisa capturas Bluetooth
docs/                 guias
```

## Guias

- [Descobrir o protocolo do Mali 2](docs/DESCOBRIR_PROTOCOLO.md)
- [Formato dos perfis JSON](docs/PERFIS.md)
- [Firmware: atualizar, fazer backup e criar o seu](docs/FIRMWARE.md)
- [Protocolo aberto KubaOpen](docs/PROTOCOLO_KUBAOPEN.md)

## Testes

```sh
swift test                                   # núcleo (precisa do Swift 5.9+)
python3 -m unittest discover -s tools/tests  # analisador de capturas
make -C firmware/kubaopen test               # firmware em C
```

## Limitações do iPhone

- O iOS só deixa apps usarem **Bluetooth Low Energy (BLE)**. Se o Mali 2 só aceitar comandos pelo
  Bluetooth clássico (SPP), um app iOS não consegue falar com ele sem certificação MFi da Apple.
  O Explorador mostra logo se o fone tem serviços BLE.
- O equalizador atua **no fone** (vale para qualquer app). Se o fone não tiver comando de EQ,
  não há como equalizar o som do sistema inteiro pelo iOS.

## Aviso

Projeto independente, sem ligação com a Kuba. Gravar firmware não oficial pode inutilizar o fone
e anula a garantia. Faça por sua conta e risco, e leia [docs/FIRMWARE.md](docs/FIRMWARE.md) antes.
