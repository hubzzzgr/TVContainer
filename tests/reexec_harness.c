#include "../TVContainer/Runtime/TVProcessReexec.h"
#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv, char **envp) {
    // This state comes from the captured environment, before it was changed to
    // resemble a guest's HOME/TMPDIR and a different working directory.
    if (getenv("TV_REEXEC_EXPECTED_PID")) {
        assert(getpid() == atoi(getenv("TV_REEXEC_EXPECTED_PID")));
        char *directory = getcwd(NULL, 0);
        assert(strcmp(directory, getenv("TV_REEXEC_EXPECTED_CWD")) == 0);
        assert(strcmp(getenv("HOME"), getenv("TV_REEXEC_EXPECTED_HOME")) == 0);
        assert(strcmp(getenv("TMPDIR"), getenv("TV_REEXEC_EXPECTED_TMP")) == 0);
        assert(argc == 2 && strcmp(argv[1], "preserved-argument") == 0);
        free(directory);
        puts("Re-exec passed: same PID, original executable, argv, HOME, TMPDIR, and working directory.");
        return 0;
    }
    assert(TVPerformReexec() == EINVAL);
    assert(TVPrepareReexec("/nonexistent-TVContainer", argc, argv, envp) == 0);
    assert(TVPerformReexec() == ENOENT); // Must return with this process alive.
    char pid[32]; snprintf(pid, sizeof(pid), "%d", getpid());
    char *directory = getcwd(NULL, 0);
    setenv("TV_REEXEC_EXPECTED_PID", pid, 1);
    setenv("TV_REEXEC_EXPECTED_CWD", directory, 1);
    setenv("TV_REEXEC_EXPECTED_HOME", getenv("HOME"), 1);
    setenv("TV_REEXEC_EXPECTED_TMP", getenv("TMPDIR") ?: "", 1);
    if (!getenv("TMPDIR")) setenv("TMPDIR", "", 1);
    // setenv may replace environ; use its current value for the snapshot.
    extern char **environ;
    char *executable = realpath(argv[0], NULL);
    assert(TVPrepareReexec(executable, argc, argv, environ) == 0);
    free(executable); free(directory);
    setenv("HOME", "/guest-home", 1);
    setenv("TMPDIR", "/guest-tmp", 1);
    assert(chdir("/tmp") == 0);
    int result = TVPerformReexec();
    fprintf(stderr, "Unexpected re-exec error: %s\n", strerror(result));
    return 1;
}
