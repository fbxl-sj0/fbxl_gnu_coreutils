static void c2fbUnconvertibleStatic(void) {
    int value = __builtin_constant_p(0);
    (void)value;
}
int c2fbCaller(void) {
    c2fbUnconvertibleStatic();
    return 1;
}
