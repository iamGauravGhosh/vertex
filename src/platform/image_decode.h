#ifndef VERTEX_IMAGE_DECODE_H
#define VERTEX_IMAGE_DECODE_H
#include <stddef.h>
unsigned char *vertex_image_decode(const unsigned char *, int, int *, int *);
void vertex_image_free(void *);
#endif
