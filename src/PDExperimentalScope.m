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
    if(!PDStatRaw(source,&st) || !S_ISLNK(st.st_mode)) return NO;
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
    if(!result) PDStorageTrace(@"SCOPE: mkdir %@ failed: %@",path,error);
    return result;
}
static NSString *PDKind(NSString *path) {
    struct stat st={0};
    if(!PDStatRaw(path,&st)) return errno==ENOENT ? @"missing" :
        [NSString stringWithFormat:@"stat-error-%d",errno];
    if(S_ISLNK(st.st_mode)) return @"symlink";
    if(S_ISDIR(st.st_mode)) return @"directory";
    return @"other";
}
static NSNumber *PDEntryCount(NSString *path) {
    struct stat st={0};
    if(!PDStatRaw(path,&st) || !S_ISDIR(st.st_mode)) return @(-1);
    NSArray *entries=[NSFileManager.defaultManager contentsOfDirectoryAtPath:path error:nil];
    return entries ? @(entries.count) : @(-1);
}
// Each scope has its own transaction. One unmodifiable system-owned or
// conflicting directory must never disable Application Support or other
// already-working scopes. No nonempty directory is overwritten/deleted.
static BOOL PDRelocateOne(NSString *name, NSString *home, NSString *root,
                          NSString *targetOverride, NSString **reason) {
    NSString *source=[[home stringByAppendingPathComponent:@"Library"] stringByAppendingPathComponent:name];
    NSString *target=targetOverride ?: [[root stringByAppendingPathComponent:@"Data"] stringByAppendingPathComponent:name];
    struct stat src={0},dst={0};
    BOOL haveSrc=PDStatRaw(source,&src);
    BOOL haveDst=PDStatRaw(target,&dst);
    if(haveSrc && S_ISLNK(src.st_mode)) {
        BOOL ready=PDIsOurLink(source,target) && haveDst && S_ISDIR(dst.st_mode);
        *reason=ready ? @"already-linked" : @"source-is-foreign-or-broken-symlink";
        return ready;
    }
    if(haveSrc && !S_ISDIR(src.st_mode)) {
        *reason=@"source-not-directory"; return NO;
    }
    if(haveDst && !S_ISDIR(dst.st_mode)) {
        *reason=@"target-not-directory"; return NO;
    }
    BOOL srcNonempty=haveSrc && !PDIsEmpty(source);
    BOOL dstNonempty=haveDst && !PDIsEmpty(target);
    if(srcNonempty && dstNonempty) {
        *reason=@"source-and-target-both-nonempty"; return NO;
    }
    BOOL moved=NO,removedSrc=NO,createdDst=NO,removedEmptyDst=NO,linked=NO;
    if(!PDCreateDirectory([source stringByDeletingLastPathComponent]) ||
       !PDCreateDirectory([target stringByDeletingLastPathComponent])) {
        *reason=@"cannot-create-parent"; return NO;
    }
    // A pre-existing EMPTY destination is safe to replace with the
    // nonempty original source; the old implementation rejected this case.
    if(haveSrc && srcNonempty && haveDst && !dstNonempty) {
        if(rmdir(target.fileSystemRepresentation)!=0) {
            *reason=[NSString stringWithFormat:@"cannot-remove-empty-target-%d",errno];
            return NO;
        }
        haveDst=NO;
        removedEmptyDst=YES;
    }
    if(haveSrc && !haveDst) {
        if(rename(source.fileSystemRepresentation,target.fileSystemRepresentation)!=0) {
            *reason=[NSString stringWithFormat:@"rename-source-failed-%d",errno]; goto rollback;
        }
        moved=YES;
    } else if(!haveDst) {
        if(!PDCreateDirectory(target)) {
            *reason=@"cannot-create-target"; goto rollback;
        }
        createdDst=YES;
    }
    if(haveSrc && !moved) {
        if(rmdir(source.fileSystemRepresentation)!=0) {
            *reason=[NSString stringWithFormat:@"remove-empty-source-failed-%d",errno]; goto rollback;
        }
        removedSrc=YES;
    }
    if(symlink(target.fileSystemRepresentation,source.fileSystemRepresentation)!=0) {
        *reason=[NSString stringWithFormat:@"create-link-failed-%d",errno]; goto rollback;
    }
    linked=YES;
    if(!PDIsOurLink(source,target)) {
        *reason=@"link-verification-failed"; goto rollback;
    }
    *reason=@"linked";
    return YES;
rollback:
    PDStorageTrace(@"SCOPE: %@ failed: %@; restoring original state",name,*reason);
    if(linked && PDIsOurLink(source,target))
        unlink(source.fileSystemRepresentation);
    if(moved) {
        if(rename(target.fileSystemRepresentation,source.fileSystemRepresentation)!=0)
            PDStorageTrace(@"CRITICAL: scope %@ rollback source failed errno=%d",name,errno);
    } else if(removedSrc && !PDCreateDirectory(source)) {
        PDStorageTrace(@"CRITICAL: scope %@ rollback empty source failed",name);
    }
    if(createdDst) rmdir(target.fileSystemRepresentation);
    if(removedEmptyDst && !PDCreateDirectory(target))
        PDStorageTrace(@"SCOPE: %@ empty target not restored",name);
    return NO;
}
BOOL PDRelocateExtendedScopes(NSString *home,NSString *root) {
    BOOL allOkay=YES;
    NSMutableArray<NSDictionary *> *statuses=[NSMutableArray array];
    for(NSString *name in @[@"WebKit",@"Cookies"]) {
        NSString *src=[[home stringByAppendingPathComponent:@"Library"] stringByAppendingPathComponent:name];
        NSString *dst=[[root stringByAppendingPathComponent:@"Data"] stringByAppendingPathComponent:name];
        NSString *reason=nil;
        BOOL mapped=PDRelocateOne(name,home,root,nil,&reason);
        if(!mapped) allOkay=NO;
        [statuses addObject:@{
            @"scope":name,
            @"mapped":@(mapped),
            @"reason":reason ?: @"unknown",
            @"sourceType":PDKind(src),
            @"targetType":PDKind(dst),
            @"sourceEntryCount":PDEntryCount(src),
            @"targetEntryCount":PDEntryCount(dst)
        }];
        PDStorageTrace(@"SCOPE %@ mapped=%@ reason=%@ source=%@ destination=%@",
                       name,mapped?@"yes":@"no",reason,PDKind(src),PDKind(dst));
    }
    NSDictionary *report=@{
        @"format":@"SideloadPersist.ScopeStatus.V1",
        @"allMapped":@(allOkay),
        @"scopes":statuses,
        @"generatedAt":@([[NSDate date] timeIntervalSince1970])
    };
    NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
    if(json) [json writeToFile:[root stringByAppendingPathComponent:@"scope-mapping-result.json"]
                      options:NSDataWritingAtomic error:nil];
    return allOkay;
}
BOOL PDInitializeExtraScopes(void) {
    NSString *home=[PDStorageDocuments() stringByDeletingLastPathComponent];
    BOOL ok=PDRelocateExtendedScopes(home,PDStorageRoot());
    NSString *report=[PDStorageRoot() stringByAppendingPathComponent:@"scope-mapping-result.txt"];
    [(ok?@"ready":@"partial") writeToFile:report atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return ok;
}

BOOL PDRelocateLibraryDirectory(NSString *name,NSString *home,
                                NSString *target,NSString **reason) {
    if(!name.length || !home.length || !target.length) {
        if(reason) *reason=@"invalid-library-mapping";
        return NO;
    }
    NSString *fallback=nil;
    return PDRelocateOne(name,home,nil,target,reason ?: &fallback);
}
