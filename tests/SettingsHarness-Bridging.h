#include "../TVContainer/Runtime/TVProcessReexec.h"

static inline int TVPrepareReexecForTest(const char *executable, int argc, char **argv) {
    extern char **environ;
    return TVPrepareReexec(executable, argc, argv, environ);
}
