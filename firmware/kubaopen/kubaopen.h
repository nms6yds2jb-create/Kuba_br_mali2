/*
 * KubaOpen — protocolo aberto de controle de fones (lado do fone).
 *
 * Módulo portátil em C99, sem alocação dinâmica. Para usar num firmware:
 *   1. implemente as funções de kubaopen_hal.h com o SDK do chip;
 *   2. chame ko_init() na partida;
 *   3. entregue cada escrita BLE recebida a ko_feed();
 *   4. o módulo responde chamando ko_hal_send() (notificação BLE).
 *
 * Formato do quadro: 55 AA <len> <seq> <cmd> <dados...> <soma>
 *   len  = bytes de seq até o fim dos dados (sem a soma)
 *   soma = soma de 8 bits de len até o último dado
 * Especificação completa: docs/PROTOCOLO_KUBAOPEN.md
 */
#ifndef KUBAOPEN_H
#define KUBAOPEN_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define KO_MAX_FRAME 260
#define KO_EQ_BANDS 10

enum ko_cmd {
    KO_CMD_NOISE_MODE = 0x01,
    KO_CMD_EQ = 0x02,
    KO_CMD_TOUCH = 0x03,
    KO_CMD_GAME_MODE = 0x04,
    KO_CMD_BATTERY = 0x05,
    KO_CMD_INFO = 0x06,
    KO_CMD_OTA_START = 0x10,
    KO_CMD_OTA_DATA = 0x11,
    KO_CMD_OTA_END = 0x12,

    KO_EVT_NOISE_MODE = 0x81,
    KO_EVT_BATTERY = 0x85,
    KO_EVT_INFO = 0x86,
    KO_EVT_NACK = 0x7E,
    KO_EVT_ACK = 0x7F,
};

enum ko_status { KO_OK = 0, KO_ERR = 1 };

typedef struct {
    /* receptor */
    uint8_t buf[KO_MAX_FRAME];
    size_t used;
    uint8_t tx_seq;
    /* OTA */
    int ota_active;
    uint32_t ota_size;
    uint32_t ota_crc;
    uint32_t ota_received;
    uint32_t ota_running_crc;
} ko_state;

void ko_init(ko_state *s);
/* Entrega bytes recebidos (podem chegar picados ou vários quadros juntos). */
void ko_feed(ko_state *s, const uint8_t *data, size_t len);
/* Envia um quadro do fone para o celular (ex.: avisar troca de modo pelo toque). */
void ko_send_frame(ko_state *s, uint8_t cmd, const uint8_t *payload, uint8_t payload_len);

uint8_t ko_sum8(const uint8_t *p, size_t n);
uint32_t ko_crc32_update(uint32_t crc, const uint8_t *p, size_t n);

#ifdef __cplusplus
}
#endif

#endif
