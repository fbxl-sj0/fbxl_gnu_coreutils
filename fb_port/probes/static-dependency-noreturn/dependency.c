static void beyond(void);
static void advance(void) { beyond(); }
static _Noreturn void beyond(void) {
    int value = __builtin_constant_p(0);
    (void)value;
}
