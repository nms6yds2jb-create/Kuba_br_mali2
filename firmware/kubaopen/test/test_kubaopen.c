/* Testes do KubaOpen no computador: gcc + HAL falso. Rode com `make test`. */
#include "../kubaopen.h"
#include "../kubaopen_hal.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures = 0;
#define CHECK(c) do { if (!(c)) { printf("FALHOU %s:%d: %s\n", __FILE__, __LINE__, #c); failures++; } } while (0)

/* ---- HAL falso ---- */
static uint8_t out[64][KO_MAX_FRAME];
static size_t out_len[64];
static int out_count;
static uint8_t noise_mode;
static int8_t eq[KO_EQ_BANDS];
static uint8_t touch[2][4];
static uint8_t game;
static uint8_t flash[4096];
static uint32_t ota_size;
static int committed, aborted;

void ko_hal_send(const uint8_t *d, size_t n) { if (out_count == 64) out_count = 0; memcpy(out[out_count], d, n); out_len[out_count++] = n; }
int ko_hal_set_noise_mode(uint8_t m) { noise_mode = m; return 0; }
uint8_t ko_hal_get_noise_mode(void) { return noise_mode; }
int ko_hal_set_eq(const int8_t *g, uint8_t n) { memcpy(eq, g, n); return 0; }
int ko_hal_set_touch(uint8_t s, uint8_t g, uint8_t a) { touch[s][g] = a; return 0; }
int ko_hal_set_game_mode(uint8_t on) { game = on; return 0; }
void ko_hal_get_battery(uint8_t *l, uint8_t *r, uint8_t *c) { *l = 0x80 | 90; *r = 75; *c = 40; }
void ko_hal_get_version(uint8_t *a, uint8_t *b, uint8_t *c) { *a = 2; *b = 1; *c = 0; }
int ko_hal_ota_begin(uint32_t size) { if (size > sizeof(flash)) return -1; ota_size = size; return 0; }
int ko_hal_ota_write(uint32_t off, const uint8_t *d, size_t n) { memcpy(flash + off, d, n); return 0; }
int ko_hal_ota_commit(void) { committed = 1; return 0; }
void ko_hal_ota_abort(void) { aborted = 1; }

/* Monta um quadro igual ao app (perfil Profiles/kubaopen.json). */
static size_t frame(uint8_t *f, uint8_t seq, uint8_t cmd, const uint8_t *p, uint8_t n) {
    f[0] = 0x55; f[1] = 0xAA; f[2] = (uint8_t)(n + 2); f[3] = seq; f[4] = cmd;
    if (n) memcpy(f + 5, p, n);
    f[5 + n] = ko_sum8(f + 2, (size_t)n + 3);
    return (size_t)n + 6;
}

static int last_is_ack(uint8_t cmd, uint8_t status) {
    if (out_count == 0) return 0;
    const uint8_t *f = out[out_count - 1];
    return f[4] == KO_EVT_ACK && f[5] == cmd && f[6] == status;
}

int main(void) {
    ko_state s;
    ko_init(&s);
    uint8_t f[KO_MAX_FRAME];

    /* Mesmo quadro que o teste Swift espera: 55 AA 03 00 01 01 05 */
    const uint8_t anc[] = {0x55, 0xAA, 0x03, 0x00, 0x01, 0x01, 0x05};
    ko_feed(&s, anc, sizeof anc);
    CHECK(noise_mode == 1);
    CHECK(out_count == 2);
    CHECK(out[1][4] == KO_EVT_NOISE_MODE && out[1][5] == 1);

    /* Chega picado byte a byte, com lixo antes. */
    out_count = 0;
    const uint8_t junk[] = {0x00, 0x13, 0x55};
    ko_feed(&s, junk, sizeof junk);
    uint8_t p2[] = {2};
    size_t n = frame(f, 1, KO_CMD_NOISE_MODE, p2, 1);
    for (size_t i = 0; i < n; i++) ko_feed(&s, &f[i], 1);
    CHECK(noise_mode == 2);

    /* Checksum errado é ignorado. */
    out_count = 0;
    const uint8_t bad[] = {0x55, 0xAA, 0x03, 0x00, 0x01, 0x00, 0xFF};
    ko_feed(&s, bad, sizeof bad);
    CHECK(out_count == 0 && noise_mode == 2);

    /* Equalizador: 10 bandas, valores fora do limite são cortados. */
    uint8_t eqp[11] = {10, 2, (uint8_t)-2, 24, 100, 0, 0, 0, 0, 0, (uint8_t)-100};
    n = frame(f, 2, KO_CMD_EQ, eqp, 11);
    ko_feed(&s, f, n);
    CHECK(eq[0] == 2 && eq[1] == -2 && eq[2] == 24 && eq[3] == 24 && eq[9] == -24);
    CHECK(last_is_ack(KO_CMD_EQ, KO_OK));

    /* Toques e modo jogo. */
    uint8_t tp[] = {1, 1, 2};
    n = frame(f, 3, KO_CMD_TOUCH, tp, 3);
    ko_feed(&s, f, n);
    CHECK(touch[1][1] == 2 && last_is_ack(KO_CMD_TOUCH, KO_OK));
    uint8_t badtp[] = {5, 1, 2};
    n = frame(f, 4, KO_CMD_TOUCH, badtp, 3);
    ko_feed(&s, f, n);
    CHECK(last_is_ack(KO_CMD_TOUCH, KO_ERR));
    uint8_t on = 1;
    n = frame(f, 5, KO_CMD_GAME_MODE, &on, 1);
    ko_feed(&s, f, n);
    CHECK(game == 1);

    /* Bateria e versão. */
    out_count = 0;
    n = frame(f, 6, KO_CMD_BATTERY, NULL, 0);
    ko_feed(&s, f, n);
    CHECK(out_count == 1 && out[0][4] == KO_EVT_BATTERY && out[0][5] == (0x80 | 90) && out[0][6] == 75);
    out_count = 0;
    n = frame(f, 7, KO_CMD_INFO, NULL, 0);
    ko_feed(&s, f, n);
    CHECK(out_count == 2 && out[0][4] == KO_EVT_INFO && out[0][5] == 2 && out[0][6] == 1);

    /* OTA completo com um bloco repetido. */
    uint8_t image[1000];
    for (int i = 0; i < 1000; i++) image[i] = (uint8_t)(i * 31 + 7);
    uint32_t crc = ko_crc32_update(0, image, sizeof image);
    uint8_t st[10] = {0xE8, 0x03, 0, 0, (uint8_t)crc, (uint8_t)(crc >> 8), (uint8_t)(crc >> 16), (uint8_t)(crc >> 24), 128, 0};
    n = frame(f, 8, KO_CMD_OTA_START, st, 10);
    ko_feed(&s, f, n);
    CHECK(last_is_ack(KO_CMD_OTA_START, KO_OK));
    for (uint32_t off = 0; off < 1000; off += 128) {
        uint8_t d[4 + 128];
        uint8_t len = (uint8_t)(1000 - off < 128 ? 1000 - off : 128);
        d[0] = (uint8_t)off; d[1] = (uint8_t)(off >> 8); d[2] = 0; d[3] = 0;
        memcpy(d + 4, image + off, len);
        n = frame(f, 9, KO_CMD_OTA_DATA, d, (uint8_t)(4 + len));
        ko_feed(&s, f, n);
        CHECK(last_is_ack(KO_CMD_OTA_DATA, KO_OK));
        if (off == 256) { ko_feed(&s, f, n); CHECK(last_is_ack(KO_CMD_OTA_DATA, KO_OK)); }
    }
    uint8_t endp[4] = {(uint8_t)crc, (uint8_t)(crc >> 8), (uint8_t)(crc >> 16), (uint8_t)(crc >> 24)};
    n = frame(f, 10, KO_CMD_OTA_END, endp, 4);
    ko_feed(&s, f, n);
    CHECK(committed == 1);
    CHECK(memcmp(flash, image, sizeof image) == 0);

    /* OTA com dados faltando é recusado e abortado. */
    committed = 0;
    n = frame(f, 11, KO_CMD_OTA_START, st, 10);
    ko_feed(&s, f, n);
    n = frame(f, 12, KO_CMD_OTA_END, endp, 4);
    ko_feed(&s, f, n);
    CHECK(committed == 0 && aborted == 1);
    CHECK(out[out_count - 1][4] == KO_EVT_NACK);

    /* Bloco fora de ordem é recusado. */
    n = frame(f, 13, KO_CMD_OTA_START, st, 10);
    ko_feed(&s, f, n);
    uint8_t skip[8] = {0x80, 0, 0, 0, 1, 2, 3, 4};
    n = frame(f, 14, KO_CMD_OTA_DATA, skip, 8);
    ko_feed(&s, f, n);
    CHECK(last_is_ack(KO_CMD_OTA_DATA, KO_ERR));

    if (failures) { printf("%d falha(s)\n", failures); return 1; }
    printf("KubaOpen: todos os testes passaram\n");
    return 0;
}
