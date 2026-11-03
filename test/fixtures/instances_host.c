#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include "suppify/calc.h"
typedef int (*greet_fn)(const char *, size_t, const char **, size_t *);
typedef struct { greet_fn greet; const char *name; int bad; } caller;
static void *run(void *p) {
  caller *c = p;
  char want[64];
  snprintf(want, sizeof want, "hi, %s", c->name);
  for (int i = 0; i < 200000; i++) {
    const char *s; size_t n;
    if (c->greet(c->name, strlen(c->name), &s, &n) || n != strlen(want) || memcmp(s, want, n)) c->bad++;
  }
  return 0;
}
int main(int argc, char **argv) {
  int shared = argc > 1 && strcmp(argv[1], "shared") == 0;
  caller a = { calc_Calc_greet, "vm-side", 0 };
  caller b = { shared ? calc_Calc_greet : calc_w1_Calc_greet, "worker-side", 0 };
  pthread_t ta, tb;
  calc_init();
  calc_w1_init();
  pthread_create(&ta, 0, run, &a);
  pthread_create(&tb, 0, run, &b);
  pthread_join(ta, 0);
  pthread_join(tb, 0);
  printf("bad %d %d\n", a.bad, b.bad);
  return 0;
}
