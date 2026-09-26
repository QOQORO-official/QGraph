/* libc.c -- the whole C runtime QGraph's wasm module needs.
 *
 * The Nim engine is compiled to C and then to a freestanding wasm32 object
 * with stub headers, so every libc symbol the generated code references is
 * defined here. Unlike a drawing app, a diagram editor rebuilds and discards
 * its document model constantly (undo snapshots, clones, JSON round trips),
 * so memory has to be reused: malloc is a segregated free-list allocator on
 * top of memory.grow rather than a bump pointer.
 *
 * Transcendental math is imported from the page (Math.sin and friends) so
 * geometry matches the JavaScript editor bit for bit.
 */

typedef unsigned long size_t;
typedef unsigned int u32;
extern unsigned char __heap_base;

#define WPAGE 65536u
#define ALIGN 8u
#define HEADER 8u

/* ---------------------------------------------------------------- heap -- */

static unsigned char *g_bump = 0;
static unsigned char *g_end = 0;

static void heap_init(void) {
  if (g_bump) return;
  g_bump = (unsigned char *)(((unsigned long)&__heap_base + 15u) & ~15ul);
  g_end = (unsigned char *)((unsigned long)__builtin_wasm_memory_size(0) * WPAGE);
}

static void *bump(size_t n) {
  heap_init();
  if (g_bump + n > g_end) {
    unsigned long need = (unsigned long)(g_bump + n) - (unsigned long)g_end;
    unsigned long pages = (need + WPAGE - 1) / WPAGE;
    unsigned long cur = (unsigned long)__builtin_wasm_memory_size(0);
    /* Grow geometrically so a large document does not grow page by page. */
    if (pages < cur / 4) pages = cur / 4;
    if (pages < 16) pages = 16;
    if (__builtin_wasm_memory_grow(0, pages) == (unsigned long)-1) {
      pages = (need + WPAGE - 1) / WPAGE;
      if (__builtin_wasm_memory_grow(0, pages) == (unsigned long)-1) __builtin_trap();
    }
    g_end = (unsigned char *)((unsigned long)__builtin_wasm_memory_size(0) * WPAGE);
  }
  void *p = g_bump;
  g_bump += n;
  return p;
}

/* Size classes step by roughly 1.25x so the internal waste stays small for
 * the many tiny ref objects the document model is made of. */
static const u32 CLASS_SIZE[] = {
  8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256,
  320, 384, 448, 512, 640, 768, 896, 1024, 1280, 1536, 1792, 2048,
  2560, 3072, 3584, 4096, 5120, 6144, 7168, 8192, 10240, 12288, 14336,
  16384, 20480, 24576, 28672, 32768
};
#define NCLASS ((int)(sizeof(CLASS_SIZE) / sizeof(CLASS_SIZE[0])))
#define LARGE_TAG 0xFFFFu

static void *free_list[NCLASS];

/* Large blocks: a singly linked free list, first fit with a 2x waste cap. */
typedef struct Large { struct Large *next; size_t size; } Large;
static Large *large_free = 0;

static int class_of(size_t n) {
  int lo = 0, hi = NCLASS - 1;
  if (n > CLASS_SIZE[hi]) return -1;
  while (lo < hi) {
    int mid = (lo + hi) >> 1;
    if (CLASS_SIZE[mid] >= n) hi = mid; else lo = mid + 1;
  }
  return lo;
}

/* Header layout (8 bytes before the payload):
 *   u32 tag   -- size class index, or LARGE_TAG
 *   u32 extra -- payload capacity for large blocks (in 8-byte units) */
static size_t capacity_of(void *p) {
  u32 *h = (u32 *)((unsigned char *)p - HEADER);
  if (h[0] == LARGE_TAG) return (size_t)h[1] * 8u;
  return CLASS_SIZE[h[0]];
}

void *malloc(size_t n) {
  if (n == 0) n = 1;
  int c = class_of(n);
  if (c >= 0) {
    void *p = free_list[c];
    if (p) {
      free_list[c] = *(void **)p;
      return p;
    }
    unsigned char *raw = (unsigned char *)bump(CLASS_SIZE[c] + HEADER);
    ((u32 *)raw)[0] = (u32)c;
    ((u32 *)raw)[1] = 0;
    return raw + HEADER;
  }

  size_t want = (n + 4095u) & ~(size_t)4095u;
  Large **link = &large_free;
  while (*link) {
    Large *blk = *link;
    if (blk->size >= want && blk->size <= want * 2) {
      *link = blk->next;
      unsigned char *raw = (unsigned char *)blk - HEADER;
      ((u32 *)raw)[0] = LARGE_TAG;
      ((u32 *)raw)[1] = (u32)(blk->size / 8u);
      return (void *)blk;
    }
    link = &blk->next;
  }
  unsigned char *raw = (unsigned char *)bump(want + HEADER);
  ((u32 *)raw)[0] = LARGE_TAG;
  ((u32 *)raw)[1] = (u32)(want / 8u);
  return raw + HEADER;
}

void free(void *p) {
  if (!p) return;
  u32 *h = (u32 *)((unsigned char *)p - HEADER);
  if (h[0] == LARGE_TAG) {
    Large *blk = (Large *)p;
    blk->size = (size_t)h[1] * 8u;
    blk->next = large_free;
    large_free = blk;
    return;
  }
  *(void **)p = free_list[h[0]];
  free_list[h[0]] = p;
}

void *calloc(size_t a, size_t b) {
  size_t n = a * b;
  void *p = malloc(n);
  __builtin_memset(p, 0, n);
  return p;
}

void *realloc(void *p, size_t n) {
  if (!p) return malloc(n);
  if (n == 0) { free(p); return 0; }
  size_t cap = capacity_of(p);
  if (n <= cap) return p;
  void *q = malloc(n);
  __builtin_memcpy(q, p, cap);
  free(p);
  return q;
}

/* Heap statistics for the status bar and tests. */
__attribute__((export_name("qg_heap_top"))) unsigned long qg_heap_top(void) {
  heap_init();
  return (unsigned long)g_bump;
}

/* ------------------------------------------------------------- memory -- */

void *memcpy(void *d, const void *s, size_t n) { return __builtin_memcpy(d, s, n); }
void *memmove(void *d, const void *s, size_t n) { return __builtin_memmove(d, s, n); }
void *memset(void *d, int c, size_t n) { return __builtin_memset(d, c, n); }
int memcmp(const void *a, const void *b, size_t n) {
  const unsigned char *x = (const unsigned char *)a, *y = (const unsigned char *)b;
  for (size_t i = 0; i < n; i++) if (x[i] != y[i]) return (int)x[i] - (int)y[i];
  return 0;
}
void *memchr(const void *s, int c, size_t n) {
  const unsigned char *p = (const unsigned char *)s;
  for (size_t i = 0; i < n; i++) if (p[i] == (unsigned char)c) return (void *)(p + i);
  return 0;
}
size_t strlen(const char *s) { size_t n = 0; while (s[n]) n++; return n; }
int strcmp(const char *a, const char *b) {
  while (*a && (*a == *b)) { a++; b++; }
  return (int)(unsigned char)*a - (int)(unsigned char)*b;
}
int strncmp(const char *a, const char *b, size_t n) {
  for (size_t i = 0; i < n; i++) {
    if (a[i] != b[i] || !a[i]) return (int)(unsigned char)a[i] - (int)(unsigned char)b[i];
  }
  return 0;
}
char *strcpy(char *d, const char *s) { char *r = d; while ((*d++ = *s++)) { } return r; }
char *strstr(const char *h, const char *n) {
  size_t ln = strlen(n);
  if (!ln) return (char *)h;
  for (; *h; h++) if (!strncmp(h, n, ln)) return (char *)h;
  return 0;
}

/* --------------------------------------------------------------- math -- */

/* Imported from the page: Math.* keeps results identical to the JS editor. */
__attribute__((import_module("env"), import_name("qg_math1"))) double qg_math1(int op, double x);
__attribute__((import_module("env"), import_name("qg_math2"))) double qg_math2(int op, double a, double b);

double sin(double x) { return qg_math1(0, x); }
double cos(double x) { return qg_math1(1, x); }
double tan(double x) { return qg_math1(2, x); }
double atan(double x) { return qg_math1(3, x); }
double asin(double x) { return qg_math1(4, x); }
double acos(double x) { return qg_math1(5, x); }
double exp(double x) { return qg_math1(6, x); }
double log(double x) { return qg_math1(7, x); }
double log10(double x) { return qg_math1(8, x); }
double log2(double x) { return qg_math1(9, x); }
double cbrt(double x) { return qg_math1(10, x); }
double sinh(double x) { return qg_math1(11, x); }
double cosh(double x) { return qg_math1(12, x); }
double tanh(double x) { return qg_math1(13, x); }
double atan2(double a, double b) { return qg_math2(0, a, b); }
double pow(double a, double b) { return qg_math2(1, a, b); }
double hypot(double a, double b) { return qg_math2(2, a, b); }
double fmod(double a, double b) { return qg_math2(3, a, b); }

double fabs(double x) { return __builtin_fabs(x); }
float fabsf(float x) { return __builtin_fabsf(x); }
double sqrt(double x) { return __builtin_sqrt(x); }
float sqrtf(float x) { return __builtin_sqrtf(x); }
double floor(double x) { return __builtin_floor(x); }
float floorf(float x) { return __builtin_floorf(x); }
double ceil(double x) { return __builtin_ceil(x); }
float ceilf(float x) { return __builtin_ceilf(x); }
double trunc(double x) { return __builtin_trunc(x); }
double round(double x) {
  return x < 0.0 ? -__builtin_floor(-x + 0.5) : __builtin_floor(x + 0.5);
}
int abs(int x) { return x < 0 ? -x : x; }
long labs(long x) { return x < 0 ? -x : x; }

double ldexp(double x, int e) {
  while (e > 0) { x *= 2.0; e--; }
  while (e < 0) { x *= 0.5; e++; }
  return x;
}
double frexp(double x, int *e) {
  int ex = 0;
  if (x == 0.0 || x != x) { *e = 0; return x; }
  while (__builtin_fabs(x) >= 1.0) { x *= 0.5; ex++; }
  while (__builtin_fabs(x) < 0.5) { x *= 2.0; ex--; }
  *e = ex;
  return x;
}

/* Number parsing goes through JavaScript's Number() for identical results. */
__attribute__((import_module("env"), import_name("qg_parse_num"))) double qg_parse_num(const char *p, int len);

double strtod(const char *s, char **end) {
  const char *p = s;
  while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p++;
  const char *start = p;
  if (*p == '+' || *p == '-') p++;
  while ((*p >= '0' && *p <= '9') || *p == '.') p++;
  if (*p == 'e' || *p == 'E') {
    const char *q = p + 1;
    if (*q == '+' || *q == '-') q++;
    if (*q >= '0' && *q <= '9') { p = q; while (*p >= '0' && *p <= '9') p++; }
  }
  if (end) *end = (char *)(p == start ? s : p);
  if (p == start) return 0.0;
  return qg_parse_num(start, (int)(p - start));
}

/* ---------------------------------------------------- inert leftovers -- */

void abort(void) { __builtin_trap(); }
void exit(int code) { (void)code; __builtin_trap(); }
int raise(int s) { (void)s; return 0; }
typedef void (*sighandler_t)(int);
sighandler_t signal(int s, sighandler_t h) { (void)s; return h; }
int printf(const char *f, ...) { (void)f; return 0; }
int fprintf(void *fp, const char *f, ...) { (void)fp; (void)f; return 0; }
int snprintf(char *b, size_t n, const char *f, ...) { (void)f; if (n) b[0] = 0; return 0; }
int sprintf(char *b, const char *f, ...) { (void)f; b[0] = 0; return 0; }
int fputs(const char *s, void *fp) { (void)s; (void)fp; return 0; }
int fputc(int c, void *fp) { (void)fp; return c; }
int puts(const char *s) { (void)s; return 0; }
int putchar(int c) { return c; }
int fflush(void *fp) { (void)fp; return 0; }
size_t fwrite(const void *p, size_t a, size_t b, void *fp) { (void)p; (void)fp; return a * b; }
void *stdout = 0;
void *stderr = 0;
void *stdin = 0;
int errno = 0;
