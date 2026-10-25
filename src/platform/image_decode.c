/* Memory-only decoder. All stb allocations share a per-call 128 MiB budget. */
#include <stdlib.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include "image_decode.h"
typedef union { size_t size; max_align_t alignment; } allocation_header;
static _Thread_local size_t allocated;
static void *image_alloc(size_t size) {
    if (size > 128u * 1024u * 1024u - allocated || size > SIZE_MAX - sizeof(allocation_header)) return NULL;
    allocation_header *header = malloc(sizeof(*header) + size);
    if (!header) return NULL;
    header->size = size;
    allocated += size;
    return header + 1;
}
static void image_free(void *ptr) {
    if (!ptr) return;
    allocation_header *header = (allocation_header *)ptr - 1;
    allocated -= header->size;
    free(header);
}
static void *image_realloc(void *ptr, size_t size) {
    if (!ptr) return image_alloc(size);
    allocation_header *header = (allocation_header *)ptr - 1;
    void *replacement = image_alloc(size);
    if (!replacement) return NULL;
    memcpy(replacement, ptr, size < header->size ? size : header->size);
    image_free(ptr);
    return replacement;
}
#define STBI_MALLOC image_alloc
#define STBI_REALLOC image_realloc
#define STBI_FREE image_free
#define STBI_NO_STDIO
#define STBI_NO_HDR
#define STBI_NO_LINEAR
#define STBI_ONLY_PNG
#define STBI_ONLY_JPEG
#define STBI_ONLY_GIF
#define STBI_MAX_DIMENSIONS 8192
#define STB_IMAGE_IMPLEMENTATION
#include "../../vendor/stb/stb_image.h"
unsigned char *vertex_image_decode(const unsigned char *data, int length, int *width, int *height) {
    int components;
    if (!stbi_info_from_memory(data, length, width, height, &components)) return NULL;
    if (*width <= 0 || *height <= 0 || *width > 8192 || *height > 8192 ||
        (size_t)*width * (size_t)*height > 64u * 1024u * 1024u / 4u) return NULL;
    return stbi_load_from_memory(data, length, width, height, &components, 4);
}
void vertex_image_free(void *data) { image_free(data); }
