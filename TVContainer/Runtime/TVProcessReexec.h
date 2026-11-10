#pragma once

// Capture before any guest changes argv, the environment, or working directory.
// Returns an errno value on failure. A successful re-exec never returns.
int TVPrepareReexec(const char *executable, int argc, char *const argv[], char *const envp[]);
int TVPerformReexec(void);
