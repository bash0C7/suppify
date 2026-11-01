#include <stdio.h>
#include <string.h>
#include "calc.h"
static void dump(const char *label, int32_t n, const uint8_t *out) {
  printf("%s %d:", label, n);
  for (int i = 0; i < n; i++) printf(" %02x", out[i]);
  printf("\n");
}
int main(void) {
  uint8_t out[64];
  const uint8_t add[] = { 0x92, 0x02, 0x03 };
  const uint8_t greet[] = { 0x91, 0xa5, 'w', 'o', 'r', 'l', 'd' };
  const uint8_t half[] = { 0x91, 0x03 };
  const uint8_t neg[] = { 0x91, 0xff };
  const uint8_t big[] = { 0x92, 0xd3, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01 };
  const uint8_t bad[] = { 0x92, 0x02 };
  const uint8_t blen[] = { 0x91, 0xc4, 0x04, 'a', 0, 'b', 'c' };
  for (const suppify_kernel_t *k = calc_kernels; k->name; k++) printf("kernel %s %s\n", k->name, k->signature());
  calc_kernels[0].init();
  dump("add", calc_Calc_add_call(add, sizeof add, out, sizeof out), out);
  dump("greet", calc_Calc_greet_call(greet, sizeof greet, out, sizeof out), out);
  dump("half", calc_Calc_half_call(half, sizeof half, out, sizeof out), out);
  int32_t r = calc_Calc_check_call(neg, sizeof neg, out, sizeof out);
  printf("check raised %d %s: %s\n", r, calc_error_class(), calc_error_message());
  dump("blen", calc_Calc_blen_call(blen, sizeof blen, out, sizeof out), out);
  printf("big %d\n", calc_Calc_add_call(big, sizeof big, out, sizeof out));
  printf("malformed %d\n", calc_Calc_add_call(bad, sizeof bad, out, sizeof out));
  printf("nospace %d\n", calc_Calc_greet_call(greet, sizeof greet, out, 3));
  intptr_t sum; const char *s; size_t n;
  int ra = calc_Calc_add(40, 2, &sum); printf("typed add %d %ld\n", ra, (long)sum);
  int rg = calc_Calc_greet("x", 1, &s, &n); printf("typed greet %d %.*s\n", rg, (int)n, s);
  return 0;
}
