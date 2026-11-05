#import "PDRedirect.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <pthread.h>

static _Atomic(char *) s_externalDocuments = NULL;
static char *s_oldDocuments = NULL;
static char *s_oldDocumentsPrivate = NULL;
static pthread_once_t s_once = PTHREAD_ONCE_INIT;

static void PDInitializeOriginalPaths(void) {
    const char *home = getenv("HOME");
    if (!home || !*home) return;
    size_t n = strlen(home) + strlen("/Documents") + 1;
    s_oldDocuments = malloc(n);
    if (!s_oldDocuments) return;
    snprintf(s_oldDocuments, n, "%s/Documents", home);
    // iOS exposes the same app sandbox via both /var and /private/var.
    if (strncmp(s_oldDocuments, "/var/", 5) == 0) {
        size_t len = strlen(s_oldDocuments) + strlen("/private") + 1;
        s_oldDocumentsPrivate = malloc(len);
        if (s_oldDocumentsPrivate) snprintf(s_oldDocumentsPrivate, len, "/private%s", s_oldDocuments);
    } else if (strncmp(s_oldDocuments, "/private/var/", 13) == 0) {
        s_oldDocumentsPrivate = strdup(s_oldDocuments + strlen("/private"));
    }
}

static const char *PDMatchPrefix(const char *path) {
    if (!path) return NULL;
    if (s_oldDocuments) {
        size_t n = strlen(s_oldDocuments);
        if (strncmp(path, s_oldDocuments, n) == 0 && (path[n] == 0 || path[n] == '/'))
            return path + n;
    }
    if (s_oldDocumentsPrivate) {
        size_t n = strlen(s_oldDocumentsPrivate);
        if (strncmp(path, s_oldDocumentsPrivate, n) == 0 && (path[n] == 0 || path[n] == '/'))
            return path + n;
    }
    return NULL;
}

char *PDTranslatedCString(const char *path) {
    char *external = atomic_load_explicit(&s_externalDocuments, memory_order_acquire);
    if (!external || !path) return NULL;
    pthread_once(&s_once, PDInitializeOriginalPaths);
    const char *suffix = PDMatchPrefix(path);
    if (!suffix) return NULL;
    size_t n = strlen(external) + strlen(suffix) + 1;
    char *result = malloc(n);
    if (result) snprintf(result, n, "%s%s", external, suffix);
    return result;
}

NSString *PDTranslatedPath(NSString *path) {
    if (!path) return nil;
    char *replacement = PDTranslatedCString(path.fileSystemRepresentation);
    if (!replacement) return path;
    NSString *result = [NSString stringWithUTF8String:replacement];
    free(replacement);
    return result ?: path;
}

void PDSetExternalDocumentsPath(NSString *path) {
    if (!path.isAbsolutePath || path.length == 0) return;
    pthread_once(&s_once, PDInitializeOriginalPaths);
    char *replacement = strdup(path.fileSystemRepresentation);
    if (replacement) {
        // Old allocations intentionally remain valid for concurrent open() calls.
        atomic_store_explicit(&s_externalDocuments, replacement, memory_order_release);
    }
}

BOOL PDIsRedirectActive(void) {
    return atomic_load_explicit(&s_externalDocuments, memory_order_acquire) != NULL;
}
