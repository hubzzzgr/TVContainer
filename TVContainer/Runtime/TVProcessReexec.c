#include "TVProcessReexec.h"
#include <dlfcn.h>
#include <errno.h>
#include <spawn.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static char *hostExecutable;
static char *hostDirectory;
static char **hostArguments;
static char **hostEnvironment;
static int preparationError = EINVAL;

static void freeStrings(char **strings) {
    if (!strings) return;
    for (size_t i = 0; strings[i]; i++) free(strings[i]);
    free(strings);
}

static char **copyStrings(char *const source[], size_t count) {
    char **result = calloc(count + 1, sizeof(char *));
    if (!result) return NULL;
    for (size_t i = 0; i < count; i++) {
        if (!(result[i] = strdup(source[i]))) { freeStrings(result); return NULL; }
    }
    return result;
}

int TVPrepareReexec(const char *executable, int argc, char *const argv[], char *const envp[]) {
    free(hostExecutable); hostExecutable = NULL;
    free(hostDirectory); hostDirectory = NULL;
    freeStrings(hostArguments); hostArguments = NULL;
    freeStrings(hostEnvironment); hostEnvironment = NULL;
    preparationError = EINVAL;
    if (!executable || executable[0] != '/' || argc < 1 || !argv || !envp) return preparationError;
    size_t envCount = 0;
    while (envp[envCount]) envCount++;
    hostExecutable = strdup(executable);
    hostDirectory = getcwd(NULL, 0);
    hostArguments = copyStrings(argv, (size_t)argc);
    hostEnvironment = copyStrings(envp, envCount);
    if (!hostExecutable || !hostDirectory || !hostArguments || !hostEnvironment) return preparationError = ENOMEM;
    // The guest may overwrite argv[0]. Always re-enter the signed host binary.
    free(hostArguments[0]);
    hostArguments[0] = strdup(executable);
    if (!hostArguments[0]) return preparationError = ENOMEM;
    return preparationError = 0;
}

int TVPerformReexec(void) {
    if (preparationError) return preparationError;
    // tvOS does not expose process spawning as a public API. Resolve at runtime
    // and only replace this process; never spawn a child or kill the host first.
    int (*spawnProcess)(pid_t *, const char *, const posix_spawn_file_actions_t *, const posix_spawnattr_t *, char *const[], char *const[]) = dlsym(RTLD_DEFAULT, "posix_spawn");
    int (*initAttributes)(posix_spawnattr_t *) = dlsym(RTLD_DEFAULT, "posix_spawnattr_init");
    int (*setFlags)(posix_spawnattr_t *, short) = dlsym(RTLD_DEFAULT, "posix_spawnattr_setflags");
    int (*destroyAttributes)(posix_spawnattr_t *) = dlsym(RTLD_DEFAULT, "posix_spawnattr_destroy");
    int (*initActions)(posix_spawn_file_actions_t *) = dlsym(RTLD_DEFAULT, "posix_spawn_file_actions_init");
    int (*addDirectory)(posix_spawn_file_actions_t *, const char *) = dlsym(RTLD_DEFAULT, "posix_spawn_file_actions_addchdir_np");
    int (*destroyActions)(posix_spawn_file_actions_t *) = dlsym(RTLD_DEFAULT, "posix_spawn_file_actions_destroy");
    if (!spawnProcess || !initAttributes || !setFlags || !destroyAttributes || !initActions || !addDirectory || !destroyActions) return ENOSYS;
    posix_spawnattr_t attributes;
    int result = initAttributes(&attributes);
    if (result) return result;
    // SETEXEC replaces the executable in the current PID. FrontBoard never sees
    // an app death followed by an already-consumed open request.
    result = setFlags(&attributes, POSIX_SPAWN_SETEXEC | POSIX_SPAWN_CLOEXEC_DEFAULT);
    if (!result) {
        posix_spawn_file_actions_t actions;
        result = initActions(&actions);
        if (!result) {
            result = addDirectory(&actions, hostDirectory);
            if (!result) result = spawnProcess(NULL, hostExecutable, &actions, &attributes, hostArguments, hostEnvironment);
            destroyActions(&actions);
        }
    }
    destroyAttributes(&attributes);
    return result;
}
