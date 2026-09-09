#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_PNG
#define STBI_ONLY_JPEG
#define STBI_ONLY_GIF
#define STBI_NO_STDIO
#define STBI_NO_LINEAR
#define STBI_NO_HDR
#define STBI_MAX_DIMENSIONS 4096
#include "stb_image.h"

int zt_stbi_load_rgba(const unsigned char *data, int len, int *w, int *h, unsigned char **out) {
    int comp = 0;
    unsigned char *p;
    if (data == NULL || len <= 0 || w == NULL || h == NULL || out == NULL) return 0;
    p = stbi_load_from_memory(data, len, w, h, &comp, 4);
    *out = p;
    return p != NULL;
}

void zt_stbi_free(unsigned char *p) {
    stbi_image_free(p);
}
