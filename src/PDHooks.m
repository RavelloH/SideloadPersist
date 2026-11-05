#import "PDRedirect.h"
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <sys/stat.h>
#import <dirent.h>
#import <fcntl.h>
#import <stdarg.h>
#import <stdio.h>
#import <stdlib.h>
#import <unistd.h>
#import "fishhook.h"

// A deliberately bounded compatibility shim: Documents paths only.
// Foundation methods and selected POSIX calls are covered. This is NOT a
// complete filesystem virtualizer and cannot redirect Keychain or databases
// using unhooked APIs. Test only on apps whose data has been backed up.

static NSArray<NSString *> *(*originalSearchPaths)(NSSearchPathDirectory, NSSearchPathDomainMask, BOOL);
static NSArray<NSString *> *PDSearchPaths(NSSearchPathDirectory directory, NSSearchPathDomainMask domain, BOOL expand) {
    if (directory == NSDocumentDirectory && (domain & NSUserDomainMask) && PDIsRedirectActive()) {
        NSArray *old = originalSearchPaths(directory, domain, expand);
        if (old.count) return @[PDTranslatedPath(old.firstObject)];
    }
    return originalSearchPaths(directory, domain, expand);
}

static int (*real_open)(const char *, int, ...);
static int PDOpen(const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) { va_list args; va_start(args, flags); mode = (mode_t)va_arg(args, int); va_end(args); }
    char *mapped = PDTranslatedCString(path);
    int r = (flags & O_CREAT) ? real_open(mapped ?: path, flags, mode) : real_open(mapped ?: path, flags);
    free(mapped); return r;
}
static int (*real_openat)(int, const char *, int, ...);
static int PDOpenAt(int fd, const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) { va_list args; va_start(args, flags); mode = (mode_t)va_arg(args, int); va_end(args); }
    char *mapped = PDTranslatedCString(path);
    int r = (flags & O_CREAT) ? real_openat(fd, mapped ?: path, flags, mode) : real_openat(fd, mapped ?: path, flags);
    free(mapped); return r;
}
static FILE *(*real_fopen)(const char *, const char *);
static FILE *PDFOpen(const char *path, const char *mode) {
    char *mapped = PDTranslatedCString(path);
    FILE *r = real_fopen(mapped ?: path, mode);
    free(mapped); return r;
}
static int (*real_stat)(const char *, struct stat *);
static int PDStat(const char *path, struct stat *st) {
    char *mapped = PDTranslatedCString(path);
    int r = real_stat(mapped ?: path, st);
    free(mapped); return r;
}
static int (*real_lstat)(const char *, struct stat *);
static int PDLStat(const char *path, struct stat *st) {
    char *mapped = PDTranslatedCString(path);
    int r = real_lstat(mapped ?: path, st);
    free(mapped); return r;
}
static int (*real_access)(const char *, int);
static int PDAccess(const char *path, int mode) {
    char *mapped = PDTranslatedCString(path);
    int r = real_access(mapped ?: path, mode);
    free(mapped); return r;
}
static int (*real_mkdir)(const char *, mode_t);
static int PDMkdir(const char *path, mode_t mode) {
    char *mapped = PDTranslatedCString(path);
    int r = real_mkdir(mapped ?: path, mode);
    free(mapped); return r;
}
static int (*real_unlink)(const char *);
static int PDUnlink(const char *path) {
    char *mapped = PDTranslatedCString(path);
    int r = real_unlink(mapped ?: path);
    free(mapped); return r;
}
static int (*real_rmdir)(const char *);
static int PDRmdir(const char *path) {
    char *mapped = PDTranslatedCString(path);
    int r = real_rmdir(mapped ?: path);
    free(mapped); return r;
}
static int (*real_rename)(const char *, const char *);
static int PDRename(const char *a, const char *b) {
    char *mappedA = PDTranslatedCString(a), *mappedB = PDTranslatedCString(b);
    int r = real_rename(mappedA ?: a, mappedB ?: b);
    free(mappedA); free(mappedB); return r;
}
static DIR *(*real_opendir)(const char *);
static DIR *PDOpenDir(const char *path) {
    char *mapped = PDTranslatedCString(path);
    DIR *r = real_opendir(mapped ?: path);
    free(mapped); return r;
}

// Foundation's higher-level operations frequently bypass a dylib's imported libc
// symbols, so support the most common NSFileManager entry points explicitly.
static BOOL (*oldFileExists)(id,SEL,NSString *);
static BOOL PDFileExists(id self, SEL cmd, NSString *p) { return oldFileExists(self,cmd,PDTranslatedPath(p)); }
static BOOL (*oldFileExistsDir)(id,SEL,NSString *,BOOL *);
static BOOL PDFileExistsDir(id self, SEL cmd, NSString *p, BOOL *isDir) { return oldFileExistsDir(self,cmd,PDTranslatedPath(p),isDir); }
static NSData *(*oldContentsAtPath)(id,SEL,NSString *);
static NSData *PDContentsAtPath(id self, SEL cmd, NSString *p) { return oldContentsAtPath(self,cmd,PDTranslatedPath(p)); }
static BOOL (*oldCreateFile)(id,SEL,NSString *,NSData *,NSDictionary *);
static BOOL PDCreateFile(id self, SEL cmd, NSString *p, NSData *data, NSDictionary *attrs) { return oldCreateFile(self,cmd,PDTranslatedPath(p),data,attrs); }
static BOOL (*oldCreateDir)(id,SEL,NSString *,BOOL,NSDictionary *,NSError **);
static BOOL PDCreateDir(id self, SEL cmd, NSString *p, BOOL i, NSDictionary *a, NSError **e) { return oldCreateDir(self,cmd,PDTranslatedPath(p),i,a,e); }
static BOOL (*oldRemove)(id,SEL,NSString *,NSError **);
static BOOL PDRemove(id self, SEL cmd, NSString *p, NSError **e) { return oldRemove(self,cmd,PDTranslatedPath(p),e); }
static BOOL (*oldMove)(id,SEL,NSString *,NSString *,NSError **);
static BOOL PDMove(id self, SEL cmd, NSString *a, NSString *b, NSError **e) { return oldMove(self,cmd,PDTranslatedPath(a),PDTranslatedPath(b),e); }
static BOOL (*oldCopy)(id,SEL,NSString *,NSString *,NSError **);
static BOOL PDCopy(id self, SEL cmd, NSString *a, NSString *b, NSError **e) { return oldCopy(self,cmd,PDTranslatedPath(a),PDTranslatedPath(b),e); }
static NSArray *(*oldList)(id,SEL,NSString *,NSError **);
static NSArray *PDList(id self, SEL cmd, NSString *p, NSError **e) { return oldList(self,cmd,PDTranslatedPath(p),e); }
static NSDirectoryEnumerator *(*oldEnumerator)(id,SEL,NSString *);
static NSDirectoryEnumerator *PDEnumerator(id self, SEL cmd, NSString *p) { return oldEnumerator(self,cmd,PDTranslatedPath(p)); }
static NSDictionary *(*oldAttributes)(id,SEL,NSString *,NSError **);
static NSDictionary *PDAttributes(id self, SEL cmd, NSString *p, NSError **e) { return oldAttributes(self,cmd,PDTranslatedPath(p),e); }
static BOOL (*oldSetAttributes)(id,SEL,NSDictionary *,NSString *,NSError **);
static BOOL PDSetAttributes(id self, SEL cmd, NSDictionary *a, NSString *p, NSError **e) { return oldSetAttributes(self,cmd,a,PDTranslatedPath(p),e); }
static NSArray<NSURL *> *(*oldURLsForDir)(id, SEL, NSSearchPathDirectory, NSSearchPathDomainMask);
static NSArray<NSURL *> *PDURLsForDir(id self, SEL cmd, NSSearchPathDirectory d, NSSearchPathDomainMask m) {
    NSArray<NSURL *> *urls = oldURLsForDir(self,cmd,d,m);
    if (d != NSDocumentDirectory || !(m & NSUserDomainMask) || !PDIsRedirectActive()) return urls;
    NSMutableArray<NSURL *> *mapped = [NSMutableArray arrayWithCapacity:urls.count];
    for (NSURL *u in urls) [mapped addObject:[NSURL fileURLWithPath:PDTranslatedPath(u.path) isDirectory:YES]];
    return mapped;
}
static NSURL *(*oldURLForDir)(id, SEL, NSSearchPathDirectory, NSSearchPathDomainMask, NSURL *, BOOL, NSError **);
static NSURL *PDURLForDir(id self, SEL cmd, NSSearchPathDirectory d, NSSearchPathDomainMask m, NSURL *base, BOOL create, NSError **err) {
    NSURL *url = oldURLForDir(self,cmd,d,m,base,create,err);
    if (!url || d != NSDocumentDirectory || !(m & NSUserDomainMask) || !PDIsRedirectActive()) return url;
    return [NSURL fileURLWithPath:PDTranslatedPath(url.path) isDirectory:YES];
}
static void PDSwap(Class cls, SEL sel, IMP imp, IMP *old) {
    Method m = class_getInstanceMethod(cls,sel);
    if (m) *old = method_setImplementation(m,imp);
}

void PDInstallHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        struct rebinding symbols[] = {
            {"NSSearchPathForDirectoriesInDomains",(void *)PDSearchPaths,(void **)&originalSearchPaths},
            {"open",(void *)PDOpen,(void **)&real_open},
            {"openat",(void *)PDOpenAt,(void **)&real_openat},
            {"fopen",(void *)PDFOpen,(void **)&real_fopen},
            {"stat",(void *)PDStat,(void **)&real_stat},
            {"lstat",(void *)PDLStat,(void **)&real_lstat},
            {"access",(void *)PDAccess,(void **)&real_access},
            {"mkdir",(void *)PDMkdir,(void **)&real_mkdir},
            {"unlink",(void *)PDUnlink,(void **)&real_unlink},
            {"rmdir",(void *)PDRmdir,(void **)&real_rmdir},
            {"rename",(void *)PDRename,(void **)&real_rename},
            {"opendir",(void *)PDOpenDir,(void **)&real_opendir},
        };
        rebind_symbols(symbols, sizeof(symbols)/sizeof(symbols[0]));
        Class cls = [NSFileManager class];
        PDSwap(cls,@selector(fileExistsAtPath:),(IMP)PDFileExists,(IMP *)&oldFileExists);
        PDSwap(cls,@selector(fileExistsAtPath:isDirectory:),(IMP)PDFileExistsDir,(IMP *)&oldFileExistsDir);
        PDSwap(cls,@selector(contentsAtPath:),(IMP)PDContentsAtPath,(IMP *)&oldContentsAtPath);
        PDSwap(cls,@selector(createFileAtPath:contents:attributes:),(IMP)PDCreateFile,(IMP *)&oldCreateFile);
        PDSwap(cls,@selector(createDirectoryAtPath:withIntermediateDirectories:attributes:error:),(IMP)PDCreateDir,(IMP *)&oldCreateDir);
        PDSwap(cls,@selector(removeItemAtPath:error:),(IMP)PDRemove,(IMP *)&oldRemove);
        PDSwap(cls,@selector(moveItemAtPath:toPath:error:),(IMP)PDMove,(IMP *)&oldMove);
        PDSwap(cls,@selector(copyItemAtPath:toPath:error:),(IMP)PDCopy,(IMP *)&oldCopy);
        PDSwap(cls,@selector(contentsOfDirectoryAtPath:error:),(IMP)PDList,(IMP *)&oldList);
        PDSwap(cls,@selector(enumeratorAtPath:),(IMP)PDEnumerator,(IMP *)&oldEnumerator);
        PDSwap(cls,@selector(attributesOfItemAtPath:error:),(IMP)PDAttributes,(IMP *)&oldAttributes);
        PDSwap(cls,@selector(setAttributes:ofItemAtPath:error:),(IMP)PDSetAttributes,(IMP *)&oldSetAttributes);
        PDSwap(cls,@selector(URLsForDirectory:inDomains:),(IMP)PDURLsForDir,(IMP *)&oldURLsForDir);
        PDSwap(cls,@selector(URLForDirectory:inDomain:appropriateForURL:create:error:),(IMP)PDURLForDir,(IMP *)&oldURLForDir);
    });
}
