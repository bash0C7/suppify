#include <stdio.h>
#include <string.h>
#include "suppify/calc.h"
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
  const uint8_t half32[] = { 0x91, 0xca, 0x40, 0x40, 0x00, 0x00 };
  const uint8_t one[] = { 0x91, 0x01 };
  uint8_t greet16[4 + 40] = { 0x91, 0xda, 0x00, 40 };
  memset(greet16 + 4, 'a', 40);
  for (const suppify_kernel_t *k = calc_kernels; k->name; k++) printf("kernel %s %s\n", k->name, k->signature());
  calc_kernels[0].init();
  dump("add", calc_Calc_add_call(add, sizeof add, out, sizeof out), out);
  dump("greet", calc_Calc_greet_call(greet, sizeof greet, out, sizeof out), out);
  dump("half", calc_Calc_half_call(half, sizeof half, out, sizeof out), out);
  int32_t r = calc_Calc_check_call(neg, sizeof neg, out, sizeof out);
  printf("check raised %d %s: %s\n", r, calc_error_class(), calc_error_message());
  dump("blen", calc_Calc_blen_call(blen, sizeof blen, out, sizeof out), out);
  dump("half32", calc_Calc_half_call(half32, sizeof half32, out, sizeof out), out);
  dump("ignore", calc_Calc_ignore_call(one, sizeof one, out, sizeof out), out);
  int32_t g = calc_Calc_greet_call(greet16, sizeof greet16, out, sizeof out);
  printf("greet16 %d: %02x %02x %.4s\n", g, out[0], out[1], (const char *)out + 2);
  printf("big %d\n", calc_Calc_add_call(big, sizeof big, out, sizeof out));
  printf("malformed %d\n", calc_Calc_add_call(bad, sizeof bad, out, sizeof out));
  printf("cleared [%s] [%s]\n", calc_error_class(), calc_error_message());
  printf("negative %d %d\n", calc_Calc_add_call(add, -1, out, sizeof out), calc_Calc_add_call(add, sizeof add, out, -1));
  printf("nospace %d\n", calc_Calc_greet_call(greet, sizeof greet, out, 3));
  intptr_t sum; const char *s; size_t n;
  int ra = calc_Calc_add(40, 2, &sum); printf("typed add %d %ld\n", ra, (long)sum);
  int rg = calc_Calc_greet("x", 1, &s, &n); printf("typed greet %d %.*s\n", rg, (int)n, s);
  const uint8_t past[] = { 0x91, 0x05 };
  dump("slot", calc_Calc_slot_call(one, sizeof one, out, sizeof out), out);
  r = calc_Calc_slot_call(past, sizeof past, out, sizeof out);
  printf("slot nil %d %s: %s\n", r, calc_error_class(), calc_error_message());
  intptr_t count = 0;
  int rc = calc_Calc_count(0, &count); printf("typed count %d %ld\n", rc, (long)count);
  rc = calc_Calc_count(5, &count); printf("typed count nil %d %s: %s\n", rc, calc_error_class(), calc_error_message());
  return 0;
}
