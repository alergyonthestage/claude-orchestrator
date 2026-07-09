/*
 * cco-svc-helper — minimal setuid boundary for the cco internal store (ADR-0047).
 *
 * The internal XDG store (STATE index, DATA registries, CACHE internals) is nested
 * under a dedicated privileged root — /var/lib/cco-internal — owned by the `cco-svc`
 * uid, mode 0700, on the container's REAL filesystem. The `claude` user (the agent's
 * shell, and the wrapped cco itself) cannot traverse that parent → EACCES, closing the
 * S1/S1b cross-scope read leak (a `read-project` agent can no longer `cat` the index).
 *
 * This helper is the ONLY path across that boundary. It is setuid-`cco-svc` (least
 * privilege — never root). Its whole job:
 *
 *   1. Fail closed unless the trusted session descriptor exists and is readable.
 *      The descriptor (/etc/cco/session-access) is written host-side by `cco start`
 *      and bind-mounted READ-ONLY, so the agent cannot forge a wider scope (R2).
 *   2. Read a whitelist of scoping keys from that descriptor.
 *   3. Build a SANITIZED environment from scratch — dropping every agent-set variable,
 *      re-injecting only the descriptor's trusted values plus the fixed bucket homes.
 *      This is what makes an agent-forged CCO_ACCESS_TRIPLE / PROJECT_NAME inert.
 *   4. Exec the trusted, image-baked `cco __store <verb> [args...]` as cco-svc. The
 *      setuid bit already set the EFFECTIVE uid to cco-svc — enough to traverse the
 *      0700 root and reach the store (file access is checked against euid). We do NOT
 *      setgid/setuid to real==effective: a setuid-to-NON-root helper lacks the caps, and
 *      requiring a setuid-ROOT helper is rejected (least privilege, ADR-0047 §2). cco is
 *      exec'd via `bash -p` (privileged mode) — load-bearing, since a plain bash with
 *      euid!=ruid resets euid to ruid. The (G,Pc,Po) gate + output-scoping run inside
 *      that elevated cco (ADR-0046 §7), which is why a direct agent call of this helper
 *      still cannot leak: it only ever runs the scope-aware store reader.
 *
 * The exec target and the `__store` entry verb are HARDCODED — the agent controls only
 * the store verb/args, which `cco __store` validates and scopes. No argv/env trust, no
 * daemon, no RPC. Compiled and baked at build time.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <ctype.h>
#include <pwd.h>
#include <grp.h>
#include <sys/types.h>
#include <errno.h>

#define DESCRIPTOR   "/etc/cco/session-access"
#define CCO_BIN      "/opt/cco/bin/cco"
#define BASH_BIN     "/bin/bash"
#define SVC_USER     "cco-svc"
#define MAX_LINE     4096
#define MAX_ENV      64

/* Scoping keys the descriptor may set. Only these are honoured; anything else in the
 * descriptor is ignored, and NOTHING from the caller's environment survives. Order is
 * irrelevant. Keep this list in sync with the descriptor writer (lib/cmd-start.sh). */
static const char *ALLOWED_KEYS[] = {
    "CCO_ACCESS_TRIPLE",
    "PROJECT_NAME",
    "CCO_CCO_ACCESS",
    "CCO_SHOW_HOST_PATHS",
    "CCO_PROJECT_PACKS",
    "CCO_PROJECT_LLMS",
    "CCO_CONFIG_TARGETS",
    NULL
};

static int key_allowed(const char *key) {
    for (int i = 0; ALLOWED_KEYS[i]; i++)
        if (strcmp(key, ALLOWED_KEYS[i]) == 0)
            return 1;
    return 0;
}

/* A descriptor value is a single logical line. Reject control characters so a crafted
 * descriptor can never inject an extra env entry or a newline into the child env. */
static int value_sane(const char *val) {
    for (const char *p = val; *p; p++)
        if (iscntrl((unsigned char)*p))
            return 0;
    return 1;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "cco-svc-helper: missing store verb (fail-closed)\n");
        return 2;
    }

    /* 1. Fail closed unless the trusted descriptor is present and readable. */
    FILE *fp = fopen(DESCRIPTOR, "r");
    if (!fp) {
        fprintf(stderr, "cco-svc-helper: no session descriptor (%s): %s — refusing (fail-closed).\n",
                DESCRIPTOR, strerror(errno));
        return 2;
    }

    /* 2+3. Build the sanitized child environment from scratch. Start with the fixed,
     * non-negotiable entries; then layer the whitelisted descriptor values on top. */
    char *envp[MAX_ENV];
    int envc = 0;
    envp[envc++] = strdup("PATH=/usr/local/bin:/usr/bin:/bin");
    envp[envc++] = strdup("HOME=/home/claude");
    envp[envc++] = strdup("CCO_IN_CONTAINER=1");
    envp[envc++] = strdup("CCO_CONTAINER_OPERATOR=1");
    /* Marks the child as the already-elevated cco: it reaches the store directly and
     * must NOT re-trampoline through this helper (see bin/cco). Inherited by any cco
     * subprocess the elevated verb spawns, so a nested store read stays direct. */
    envp[envc++] = strdup("CCO_STORE_ELEVATED=1");
    /* The bucket homes are fixed to the privileged root — never taken from the caller,
     * so the elevated cco always resolves the confined store, not a $HOME shadow. */
    envp[envc++] = strdup("CCO_STATE_HOME=/var/lib/cco-internal/state/cco");
    envp[envc++] = strdup("CCO_DATA_HOME=/var/lib/cco-internal/share/cco");
    envp[envc++] = strdup("CCO_CACHE_HOME=/var/lib/cco-internal/cache/cco");

    char line[MAX_LINE];
    while (fgets(line, sizeof(line), fp)) {
        /* Strip the trailing newline. */
        size_t n = strlen(line);
        while (n > 0 && (line[n-1] == '\n' || line[n-1] == '\r'))
            line[--n] = '\0';
        if (line[0] == '\0' || line[0] == '#')
            continue;
        char *eq = strchr(line, '=');
        if (!eq)
            continue;
        *eq = '\0';
        const char *key = line;
        const char *val = eq + 1;
        if (!key_allowed(key) || !value_sane(val))
            continue;
        if (envc >= MAX_ENV - 1)
            break;
        /* Re-join as KEY=VALUE for the child env. */
        size_t len = strlen(key) + 1 + strlen(val) + 1;
        char *entry = malloc(len);
        if (!entry)
            continue;
        snprintf(entry, len, "%s=%s", key, val);
        envp[envc++] = entry;
    }
    fclose(fp);
    envp[envc] = NULL;

    /* 4. Run as cco-svc. The setuid bit already set the EFFECTIVE uid to cco-svc, and
     * file access is checked against the effective uid — so euid=cco-svc is all that is
     * needed to traverse the 0700 cco-svc root and reach the store. We deliberately do
     * NOT setgid/setgroups/setuid to make real==effective: a setuid-to-NON-root helper
     * has no CAP_SETGID/CAP_SETUID, so those calls EPERM, and forcing real==effective
     * would require a setuid-ROOT helper (rejected — least privilege, ADR-0047 §2). The
     * real uid stays claude; that is harmless — the 0700 store is owner-only (cco-svc),
     * supplementary groups grant nothing on it, and a euid!=ruid process is non-dumpable
     * so claude cannot ptrace it. Supplementary-group drop is best-effort (no-op when
     * unprivileged). */
    struct passwd *svc = getpwnam(SVC_USER);
    if (!svc) {
        fprintf(stderr, "cco-svc-helper: user '%s' not found — refusing.\n", SVC_USER);
        return 2;
    }
    if (geteuid() != svc->pw_uid) {
        fprintf(stderr, "cco-svc-helper: not running as %s (setuid bit missing?) — refusing.\n", SVC_USER);
        return 2;
    }
    (void) setgroups(0, NULL);   /* best-effort; ignore EPERM under non-root setuid */

    /* Exec bash in PRIVILEGED mode (-p) on the hardcoded cco script. -p is load-bearing:
     * a plain bash started with euid!=ruid resets euid back to ruid (claude), which would
     * defeat the elevation and put us back outside the boundary. -p keeps euid=cco-svc
     * (and, as a bonus, makes bash ignore $BASH_ENV/$ENV and inherited functions). The
     * exec target + the __store entry verb are hardcoded; the caller supplies only the
     * store verb and its args, which `cco __store` validates and scopes. */
    char *cco_argv[argc + 5];
    int ci = 0;
    cco_argv[ci++] = (char *)"bash";
    cco_argv[ci++] = (char *)"-p";
    cco_argv[ci++] = (char *)CCO_BIN;
    cco_argv[ci++] = (char *)"__store";
    for (int i = 1; i < argc; i++)
        cco_argv[ci++] = argv[i];
    cco_argv[ci] = NULL;

    execve(BASH_BIN, cco_argv, envp);
    fprintf(stderr, "cco-svc-helper: exec %s (%s) failed: %s\n", BASH_BIN, CCO_BIN, strerror(errno));
    return 2;
}
