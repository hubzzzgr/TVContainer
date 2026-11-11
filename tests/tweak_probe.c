static int count;
__attribute__((constructor)) static void initialize(void) { count++; }
int TVTweakProbeCount(void) { return count; }
