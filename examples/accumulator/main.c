#include <stdio.h>
#include <string.h>
#include "suppify/acc.h"
#ifdef EXAMPLE_THREADS
#include <pthread.h>
#endif

enum { N = 100000 };

typedef struct {
  int (*add)(intptr_t, double, double *);
  int (*label)(intptr_t, const char **, size_t *);
  double x;
  int bad;
} caller;

static void step(caller *c, int i) {
  double sum;
  if (c->add(0, c->x, &sum) || sum != c->x * i) c->bad++;
  if (i % 100 == 0) {
    char want[64];
    const char *s;
    size_t n;
    snprintf(want, sizeof want, "slot 0: %.1f", c->x * i);
    if (c->label(0, &s, &n) || n != strlen(want) || memcmp(s, want, n)) c->bad++;
  }
}

#ifdef EXAMPLE_THREADS
static void *run(void *p) {
  for (int i = 1; i <= N; i++) step(p, i);
  return 0;
}
#endif

int main(int argc, char **argv) {
  int shared = argc > 1 && strcmp(argv[1], "shared") == 0;
  caller vm = { acc_Acc_add, acc_Acc_label, 1.0, 0 };
  caller worker = { shared ? acc_Acc_add : acc_w1_Acc_add, shared ? acc_Acc_label : acc_w1_Acc_label, 2.0, 0 };
  acc_init();
  acc_w1_init();
#ifdef EXAMPLE_THREADS
  pthread_t a, b;
  pthread_create(&a, 0, run, &vm);
  pthread_create(&b, 0, run, &worker);
  pthread_join(a, 0);
  pthread_join(b, 0);
#else
  for (int i = 1; i <= N; i++) {
    step(&vm, i);
    step(&worker, i);
  }
#endif
  double a_sum = -1, w_sum = -1, past;
  acc_Acc_at(0, &a_sum);
  acc_w1_Acc_at(0, &w_sum);
  int raised = acc_w1_Acc_at(9, &past);
  printf("vm %.1f worker %.1f bad %d %d\n", a_sum, w_sum, vm.bad, worker.bad);
  printf("past the end %d %s\n", raised, acc_w1_error_class());
  return 0;
}
