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
 *   4. Drop to the cco-svc uid/gid fully (real == effective) and exec the trusted,
 *      image-baked `cco __store <verb> [args...]`. The (G,Pc,Po) gate + output-scoping
 *      run inside that elevated cco (ADR-0046 §7), which is why a direct agent call of
 *      this helper still cannot leak: it only ever runs the scope-aware store reader.
 *
 * The exec target and the `__store` entry verb are HARDCODED — the agent controls only
 * the store verb/args, which `cco __store` validates and scopes. No shell, no argv/env
 * trust, no daemon, no RPC. Compiled static and baked at build time.
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

    /* 4. Drop fully to cco-svc (real == effective, no supplementary groups) so the
     * exec'd cco runs as the store owner and cannot be traced/ptraced back by claude. */
    struct passwd *svc = getpwnam(SVC_USER);
    if (!svc) {
        fprintf(stderr, "cco-svc-helper: user '%s' not found — refusing.\n", SVC_USER);
        return 2;
    }
    if (setgroups(0, NULL) != 0) {
        fprintf(stderr, "cco-svc-helper: setgroups failed: %s\n", strerror(errno));
        return 2;
    }
    if (setgid(svc->pw_gid) != 0 || setuid(svc->pw_uid) != 0) {
        fprintf(stderr, "cco-svc-helper: could not drop to %s: %s\n", SVC_USER, strerror(errno));
        return 2;
    }
    /* Defence in depth: if the setuid did not stick, do not run elevated. */
    if (getuid() != svc->pw_uid || geteuid() != svc->pw_uid) {
        fprintf(stderr, "cco-svc-helper: uid drop did not take — refusing.\n");
        return 2;
    }

    /* Build argv: cco __store <verb> [args...]. The exec target and the __store entry
     * are hardcoded; the caller only supplies the store verb and its arguments. */
    char *cco_argv[argc + 3];
    int ci = 0;
    cco_argv[ci++] = (char *)"cco";
    cco_argv[ci++] = (char *)"__store";
    for (int i = 1; i < argc; i++)
        cco_argv[ci++] = argv[i];
    cco_argv[ci] = NULL;

    execve(CCO_BIN, cco_argv, envp);
    fprintf(stderr, "cco-svc-helper: exec %s failed: %s\n", CCO_BIN, strerror(errno));
    return 2;
}
