#import "PDExperimentalScope.h"
#import "PDStorage.h"
#import <sys/stat.h>
#import <unistd.h>
#import <errno.h>
#import <limits.h>
#import <string.h>

static BOOL PDStatRaw(NSString *path, struct stat *out) {
    return lstat(path.fileSystemRepresentation,out)==0;
}
static BOOL PDIsEmpty(NSString *path) {
    NSError *error=nil;
    NSArray *files=[NSFileManager.defaultManager contentsOfDirectoryAtPath:path error:&error];
    return files && !error && files.count==0;
}
static BOOL PDIsOurLink(NSString *source,NSString *target) {
    struct stat st={0};
    if (!PDStatRaw(source,&st) || !S_ISLNK(st.st_mode)) return NO;
    char bytes[PATH_MAX]={0};
    ssize_t len=readlink(source.fileSystemRepresentation,bytes,sizeof(bytes)-1);
    if(len<=0 || len>=(ssize_t)sizeof(bytes)) return NO;
    bytes[len]=0;
    return [target isEqualToString:[NSString stringWithUTF8String:bytes]];
}
static BOOL PDCreateDirectory(NSString *path) {
    NSError *error=nil;
    BOOL result=[NSFileManager.defaultManager createDirectoryAtPath:path
                                 withIntermediateDirectories:YES attributes:nil error:&error];
    if(!result) PDStorageTrace(@"EXPERIMENT: directory create failed: %@",error);
    return result;
}
// For the two experimental paths only, inspect both before mutating either.
// Abort on conflicting/non-directory targets instead of attempting a merge.
BOOL PDRelocateWebKitAndCookies(NSString *home,NSString *root) {
    NSArray<NSString *> *names=@[@"WebKit",@"Cookies"];
    NSMutableArray<NSMutableDictionary *> *plans=[NSMutableArray array];
    for(NSString *name in names) {
        NSString *source=[[home stringByAppendingPathComponent:@"Library"] stringByAppendingPathComponent:name];
        NSString *target=[[root stringByAppendingPathComponent:@"Data"] stringByAppendingPathComponent:name];
        struct stat src={0},dst={0};
        BOOL hasSrc=PDStatRaw(source,&src);
        BOOL hasDst=PDStatRaw(target,&dst);
        if (hasSrc && S_ISLNK(src.st_mode)) {
            if(!PDIsOurLink(source,target) || !hasDst || !S_ISDIR(dst.st_mode)) {
                PDStorageTrace(@"EXPERIMENT: incompatible link at %@; aborting both paths",name);
                return NO;
            }
        } else {
            if (hasSrc && !S_ISDIR(src.st_mode)) {
                PDStorageTrace(@"EXPERIMENT: source not directory: %@",name);
                return NO;
            }
            if (hasDst && !S_ISDIR(dst.st_mode)) {
                PDStorageTrace(@"EXPERIMENT: destination not directory: %@",name);
                return NO;
            }
            if (hasSrc && hasDst && !PDIsEmpty(source)) {
                PDStorageTrace(@"EXPERIMENT: both source and target have data: %@",name);
                return NO;
            }
        }
        [plans addObject:[@{@"name":name,@"source":source,@"target":target,
                            @"linked":@(hasSrc && S_ISLNK(src.st_mode)),
                            @"hadSource":@(hasSrc),@"hadTarget":@(hasDst),
                            @"moved":@NO,@"removedEmpty":@NO,
                            @"createdTarget":@NO,@"linkedNow":@NO} mutableCopy]];
    }
    for(NSMutableDictionary *plan in plans) {
        if([plan[@"linked"] boolValue]) continue;
        NSString *source=plan[@"source"];
        NSString *target=plan[@"target"];
        BOOL hadSource=[plan[@"hadSource"] boolValue];
        BOOL hadTarget=[plan[@"hadTarget"] boolValue];
        if (!PDCreateDirectory([source stringByDeletingLastPathComponent]) ||
            !PDCreateDirectory([target stringByDeletingLastPathComponent])) goto rollback;
        if (!hadTarget && hadSource) {
            if (rename(source.fileSystemRepresentation,target.fileSystemRepresentation)!=0) goto rollback;
            plan[@"moved"]=@YES;
        } else if (!hadTarget) {
            if (!PDCreateDirectory(target)) goto rollback;
            plan[@"createdTarget"]=@YES;
        }
        if (hadSource && ![plan[@"moved"] boolValue]) {
            if (rmdir(source.fileSystemRepresentation)!=0) goto rollback;
            plan[@"removedEmpty"]=@YES;
        }
        if (symlink(target.fileSystemRepresentation,source.fileSystemRepresentation)!=0) goto rollback;
        plan[@"linkedNow"]=@YES;
        if(!PDIsOurLink(source,target)) goto rollback;
    }
    PDStorageTrace(@"WebKit + Cookies relocated as verified symlinks");
    return YES;
rollback:
    PDStorageTrace(@"EXPERIMENT: relocation failed (%s), attempting reverse rollback",strerror(errno));
    for(NSMutableDictionary *plan in [plans reverseObjectEnumerator]) {
        NSString *source=plan[@"source"];
        NSString *target=plan[@"target"];
        if ([plan[@"linkedNow"] boolValue] && PDIsOurLink(source,target))
            unlink(source.fileSystemRepresentation);
        if ([plan[@"moved"] boolValue]) {
            if(rename(target.fileSystemRepresentation,source.fileSystemRepresentation)!=0)
                PDStorageTrace(@"EXPERIMENT CRITICAL: rollback rename failed for %@ (%s)",plan[@"name"],strerror(errno));
        } else if ([plan[@"removedEmpty"] boolValue]) {
            if(!PDCreateDirectory(source))
                PDStorageTrace(@"EXPERIMENT CRITICAL: restoring empty source failed for %@",plan[@"name"]);
        }
        if([plan[@"createdTarget"] boolValue]) rmdir(target.fileSystemRepresentation);
    }
    return NO;
}
BOOL PDInitializeExtraScopes(void) {
    // Every injected app gets the same directory-level relocation on startup.
    // Do not gate the data path on a Bundle ID, Info.plist key or a marker that
    // disappears after reinstalling the app.
    NSString *home=[PDStorageDocuments() stringByDeletingLastPathComponent];
    BOOL ok=PDRelocateWebKitAndCookies(home,PDStorageRoot());
    NSString *report=[PDStorageRoot() stringByAppendingPathComponent:@"webkit-experiment-result.txt"];
    [(ok ? @"ready" : @"failed") writeToFile:report atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return ok;
}
