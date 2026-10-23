/*
 * Funções que o firmware do chip precisa fornecer para o KubaOpen.
 * Cada SDK (JieLi, Bluetrum, Airoha, BES...) tem suas próprias APIs para isso;
 * aqui fica só o contrato. Retorne 0 em caso de sucesso.
 */
#ifndef KUBAOPEN_HAL_H
#define KUBAOPEN_HAL_H

#include <stddef.h>
#include <stdint.h>

/* Envia bytes ao celular pela característica de notificação. */
void ko_hal_send(const uint8_t *data, size_t len);

/* 0 = desligado, 1 = ANC, 2 = ambiente, 3 = vento */
int ko_hal_set_noise_mode(uint8_t mode);
uint8_t ko_hal_get_noise_mode(void);

/* Ganhos em passos de 0,5 dB (-24..24 = -12..+12 dB) para as bandas
 * 31, 62, 125, 250, 500, 1k, 2k, 4k, 8k, 16k Hz. Deve gravar na flash. */
int ko_hal_set_eq(const int8_t *half_db, uint8_t bands);

/* lado 0/1, gesto 0..3, ação 0..9 (ver protocolo). Deve gravar na flash. */
int ko_hal_set_touch(uint8_t side, uint8_t gesture, uint8_t action);

int ko_hal_set_game_mode(uint8_t on);

/* Níveis 0..100; bit 7 = carregando. */
void ko_hal_get_battery(uint8_t *left, uint8_t *right, uint8_t *case_level);
void ko_hal_get_version(uint8_t *major, uint8_t *minor, uint8_t *patch);

/* OTA: grava numa área reservada (banco B). Nunca sobrescreva o bootloader.
 * commit só é chamado se tamanho e CRC32 conferem; ele marca o banco B como
 * bom e reinicia. Se o novo firmware não subir, o bootloader deve voltar ao A. */
int ko_hal_ota_begin(uint32_t size);
int ko_hal_ota_write(uint32_t offset, const uint8_t *data, size_t len);
int ko_hal_ota_commit(void);
void ko_hal_ota_abort(void);

#endif
