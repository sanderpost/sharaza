#ifndef SHARAZA_FFI_H
#define SHARAZA_FFI_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SharazaCoreHandle SharazaCoreHandle;

typedef struct SharazaByteBuffer {
    uint8_t *ptr;
    size_t len;
    uint32_t width;
    uint32_t height;
    int32_t status_code;
    char *error;
} SharazaByteBuffer;

SharazaCoreHandle *sharaza_core_open(const char *data_dir_utf8, char **error_out);
void sharaza_core_close(SharazaCoreHandle *handle);

void sharaza_string_free(char *ptr);
void sharaza_buffer_free(SharazaByteBuffer buf);

char *sharaza_core_request_json(
    SharazaCoreHandle *handle,
    const char *op_utf8,
    const char *payload_json_utf8
);

char *sharaza_execute_image_workflow_bytes(
    SharazaCoreHandle *handle,
    const uint8_t *image_ptr,
    size_t image_len,
    const char *metadata_json_utf8,
    const char *settings_json_utf8,
    const char *creds_json_utf8
);

SharazaByteBuffer sharaza_beautify_image_png(
    const uint8_t *png_ptr,
    size_t png_len,
    const char *effects_json_utf8
);

SharazaByteBuffer sharaza_generate_qr_png(
    const char *text_utf8,
    uint32_t module_px
);

SharazaByteBuffer sharaza_stitch_scrolling_pngs(
    const uint8_t *const *png_ptrs,
    const size_t *png_lens,
    size_t frame_count,
    bool auto_ignore_bottom
);

#ifdef __cplusplus
}
#endif

#endif /* SHARAZA_FFI_H */
