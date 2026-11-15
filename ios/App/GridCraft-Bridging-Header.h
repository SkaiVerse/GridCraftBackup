#ifndef GRIDCRAFT_BRIDGING_H
#define GRIDCRAFT_BRIDGING_H

#include <stdint.h>
#include <stddef.h>

typedef struct GCCallbacks {
    void *user;
    void (*open_files)(void *user);
    void (*save_file)(void *user, const char *name, const uint8_t *data, size_t len);
    void (*open_url)(void *user, const char *url);
    void (*copy_text)(void *user, const char *text);
    void (*copy_html)(void *user, const char *html, const char *text);
    const char *(*paste_text)(void *user);
    const char *(*paste_html)(void *user);
    void (*pick_picture)(void *user);
    void (*print_pdf)(void *user, const uint8_t *data, size_t len);
} GCCallbacks;

void *gc_create(void *metal_layer, uint32_t width_px, uint32_t height_px, float scale, GCCallbacks cb);
void gc_destroy(void *h);
void gc_resize(void *h, uint32_t width_px, uint32_t height_px, float scale);
void gc_set_dark(void *h, int dark);
void gc_set_focused(void *h, int focused);
void gc_pointer_moved(void *h, float x, float y);
void gc_pointer_gone(void *h);
void gc_pointer_button(void *h, float x, float y, int button, int pressed, uint32_t mods);
void gc_scroll(void *h, float dx, float dy, uint32_t mods);
void gc_zoom(void *h, float factor);
void gc_key(void *h, uint32_t hid, int pressed, int repeat, uint32_t mods);
void gc_text(void *h, const char *utf8);
void gc_copy(void *h);
void gc_cut(void *h);
void gc_paste(void *h, const char *utf8);
void gc_open_file(void *h, const char *name, const uint8_t *data, size_t len);
void gc_picture_file(void *h, const char *name, const uint8_t *data, size_t len);
void gc_save_result(void *h, int ok, const char *final_name);
int gc_frame(void *h);
void gc_save_state(void *h);
int gc_is_dirty(void *h);

#endif
