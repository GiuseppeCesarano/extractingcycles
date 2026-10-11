#include "simdzoneIp4.c"

int simdzone_regs_inet_pton(const char *src, size_t n, void *dst) {
  if (n < 7 || n > 15)
    return 0;

  uint64_t lo, hi;
  memcpy(&lo, src, 8);
  memcpy(&hi, src + n - 7, 8);
  hi = n > 7 ? hi >> (8 * (15 - n)) : 0;

  char tmp[16];
  _mm_storeu_si128((__m128i *)tmp,
                   _mm_set_epi64x((long long)hi, (long long)lo));

  size_t len;
  if (sse_inet_aton(tmp, (uint8_t *)dst, &len) != 1)
    return 0;

  return len == n;
}

#include <stdbool.h>

size_t (*strlen_ptr)(const char *);
void *(*memcpy_ptr)(void *, const void *, size_t);

bool bench_simdzone(const char *src, size_t len, uint32_t *out) {
  (void)len;
  return simdzone_inet_pton(AF_INET, src, out) == 1;
}

bool bench_simdzone_copy(const char *src, size_t len, uint32_t *out) {
  (void)len;
  char buf[16] = {0};
  size_t n = strnlen(src, sizeof buf);
  memcpy_ptr(buf, src, n);
  return simdzone_inet_pton(AF_INET, buf, out) == 1;
}

bool bench_simdzone_regs(const char *src, size_t len, uint32_t *out) {
  (void)len;
  return simdzone_regs_inet_pton(src, strlen_ptr(src), out) == 1;
}
