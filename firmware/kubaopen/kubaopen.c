#include "kubaopen.h"
#include "kubaopen_hal.h"

#include <string.h>

uint8_t ko_sum8(const uint8_t *p, size_t n) {
    uint8_t s = 0;
    while (n--) s = (uint8_t)(s + *p++);
    return s;
}

uint32_t ko_crc32_update(uint32_t crc, const uint8_t *p, size_t n) {
    crc = ~crc;
    while (n--) {
        crc ^= *p++;
        for (int k = 0; k < 8; k++) crc = (crc & 1u) ? (crc >> 1) ^ 0xEDB88320u : crc >> 1;
    }
    return ~crc;
}

static uint32_t rd32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

void ko_init(ko_state *s) {
    memset(s, 0, sizeof(*s));
}

void ko_send_frame(ko_state *s, uint8_t cmd, const uint8_t *payload, uint8_t payload_len) {
    uint8_t f[KO_MAX_FRAME];
    if ((size_t)payload_len + 6 > sizeof(f)) return;
    f[0] = 0x55;
    f[1] = 0xAA;
    f[2] = (uint8_t)(payload_len + 2);
    f[3] = s->tx_seq++;
    f[4] = cmd;
    if (payload_len) memcpy(&f[5], payload, payload_len);
    f[5 + payload_len] = ko_sum8(&f[2], (size_t)payload_len + 3);
    ko_hal_send(f, (size_t)payload_len + 6);
}

static void reply_status(ko_state *s, uint8_t cmd, int ok) {
    uint8_t p[2] = {cmd, ok ? KO_OK : KO_ERR};
    ko_send_frame(s, KO_EVT_ACK, p, 2);
}

static void ota_reset(ko_state *s) {
    s->ota_active = 0;
    s->ota_received = 0;
    s->ota_running_crc = 0;
}

static void handle(ko_state *s, uint8_t cmd, const uint8_t *p, size_t n) {
    switch (cmd) {
    case KO_CMD_NOISE_MODE:
        if (n >= 1 && p[0] <= 3 && ko_hal_set_noise_mode(p[0]) == 0) {
            reply_status(s, cmd, 1);
            uint8_t m = ko_hal_get_noise_mode();
            ko_send_frame(s, KO_EVT_NOISE_MODE, &m, 1);
        } else {
            reply_status(s, cmd, 0);
        }
        break;
    case KO_CMD_EQ: {
        if (n < 1 || p[0] > KO_EQ_BANDS || n < (size_t)1 + p[0]) { reply_status(s, cmd, 0); break; }
        int8_t g[KO_EQ_BANDS];
        for (uint8_t i = 0; i < p[0]; i++) {
            int v = (int8_t)p[1 + i];
            g[i] = (int8_t)(v > 24 ? 24 : v < -24 ? -24 : v);
        }
        reply_status(s, cmd, ko_hal_set_eq(g, p[0]) == 0);
        break;
    }
    case KO_CMD_TOUCH:
        reply_status(s, cmd, n >= 3 && p[0] <= 1 && p[1] <= 3 && p[2] <= 9 &&
                                 ko_hal_set_touch(p[0], p[1], p[2]) == 0);
        break;
    case KO_CMD_GAME_MODE:
        reply_status(s, cmd, n >= 1 && ko_hal_set_game_mode(p[0] ? 1 : 0) == 0);
        break;
    case KO_CMD_BATTERY: {
        uint8_t b[3];
        ko_hal_get_battery(&b[0], &b[1], &b[2]);
        ko_send_frame(s, KO_EVT_BATTERY, b, 3);
        break;
    }
    case KO_CMD_INFO: {
        uint8_t v[3];
        ko_hal_get_version(&v[0], &v[1], &v[2]);
        ko_send_frame(s, KO_EVT_INFO, v, 3);
        uint8_t m = ko_hal_get_noise_mode();
        ko_send_frame(s, KO_EVT_NOISE_MODE, &m, 1);
        break;
    }
    case KO_CMD_OTA_START:
        if (n < 10) { reply_status(s, cmd, 0); break; }
        if (s->ota_active) ko_hal_ota_abort();
        ota_reset(s);
        s->ota_size = rd32(p);
        s->ota_crc = rd32(p + 4);
        if (s->ota_size == 0 || ko_hal_ota_begin(s->ota_size) != 0) { reply_status(s, cmd, 0); break; }
        s->ota_active = 1;
        reply_status(s, cmd, 1);
        break;
    case KO_CMD_OTA_DATA: {
        if (!s->ota_active || n < 4) { reply_status(s, cmd, 0); break; }
        uint32_t off = rd32(p);
        size_t len = n - 4;
        /* Bloco repetido (o app reenviou porque a confirmação se perdeu): só confirma. */
        if ((uint64_t)off + len <= s->ota_received) { reply_status(s, cmd, 1); break; }
        if (off != s->ota_received || (uint64_t)off + len > s->ota_size ||
            ko_hal_ota_write(off, p + 4, len) != 0) {
            reply_status(s, cmd, 0);
            break;
        }
        s->ota_running_crc = ko_crc32_update(s->ota_running_crc, p + 4, len);
        s->ota_received += (uint32_t)len;
        reply_status(s, cmd, 1);
        break;
    }
    case KO_CMD_OTA_END: {
        int ok = s->ota_active && s->ota_received == s->ota_size && s->ota_running_crc == s->ota_crc;
        if (!ok) {
            if (s->ota_active) ko_hal_ota_abort();
            ota_reset(s);
            uint8_t e[2] = {cmd, KO_ERR};
            ko_send_frame(s, KO_EVT_NACK, e, 2);
            break;
        }
        reply_status(s, cmd, 1);
        ota_reset(s);
        ko_hal_ota_commit(); /* normalmente reinicia e não volta */
        break;
    }
    default:
        reply_status(s, cmd, 0);
        break;
    }
}

void ko_feed(ko_state *s, const uint8_t *data, size_t len) {
    while (len--) {
        uint8_t b = *data++;
        if (s->used == 0 && b != 0x55) continue;
        if (s->used == 1 && b != 0xAA) {
            s->used = (b == 0x55) ? 1 : 0;
            continue;
        }
        s->buf[s->used++] = b;
        if (s->used == 3 && s->buf[2] < 2) { s->used = 0; continue; }
        if (s->used >= 3) {
            size_t total = (size_t)s->buf[2] + 4;
            if (s->used == total) {
                if (ko_sum8(&s->buf[2], total - 3) == s->buf[total - 1]) {
                    handle(s, s->buf[4], &s->buf[5], total - 6);
                }
                s->used = 0;
            }
        }
    }
}
