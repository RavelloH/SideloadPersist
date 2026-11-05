#import "PDV2Restore.h"
#import "PDV2Archive.h"
#import "PDStorage.h"
#import <sys/stat.h>
#import <unistd.h>
#import <errno.h>
#import <limits.h>
#import <string.h>
#import <TargetConditionals.h>

static BOOL PDV2Stat(NSString *path,struct stat *st) {
    return lstat(path.fileSystemRepresentation,st)==0;
}
static BOOL PDV2Dir(NSString *path) {
    struct stat st={0};
    return PDV2Stat(path,&st) && S_ISDIR(st.st_mode);
}
static BOOL PDV2Link(NSString *source,NSString *target) {
    struct stat st={0};
    if(!PDV2Stat(source,&st) || !S_ISLNK(st.st_mode)) return NO;
    char buffer[PATH_MAX]={0};
    ssize_t len=readlink(source.fileSystemRepresentation,buffer,sizeof(buffer)-1);
    if(len<=0 || len>=(ssize_t)sizeof(buffer)) return NO;
    buffer[len]=0;
    return [target isEqualToString:[NSString stringWithUTF8String:buffer]];
}
static BOOL PDV2Empty(NSString *path) {
    NSArray *files=[NSFileManager.defaultManager contentsOfDirectoryAtPath:path error:nil];
    return files && files.count==0;
}
static BOOL PDV2Mkdir(NSString *path) {
    NSError *error=nil;
    BOOL success=[NSFileManager.defaultManager createDirectoryAtPath:path
                      withIntermediateDirectories:YES attributes:nil error:&error];
    if(!success) PDStorageTrace(@"V2 restore mkdir %@ failed: %@",path,error);
    return success;
}
static BOOL PDV2Move(NSString *old,NSString *to) {
    if(rename(old.fileSystemRepresentation,to.fileSystemRepresentation)==0) return YES;
    PDStorageTrace(@"V2 restore rename failed %@ -> %@: %s",old,to,strerror(errno));
    return NO;
}
static BOOL PDV2ValidScope(NSString *value) {
    return [@[@"Application Support",@"WebKit",@"Cookies"] containsObject:value];
}
static BOOL PDV2PreflightScope(NSString *name,NSString *root,NSString *directory,NSString *backup) {
    NSString *stage=[directory stringByAppendingPathComponent:name];
    NSString *target=[[root stringByAppendingPathComponent:@"Data"] stringByAppendingPathComponent:name];
    NSString *old=[backup stringByAppendingPathComponent:name];
    NSString *source=[[[NSHomeDirectory() stringByAppendingPathComponent:@"Library"]
                       stringByAppendingPathComponent:name] stringByStandardizingPath];
    struct stat src={0},dst={0},stg={0},bak={0};
    BOOL hasSource=PDV2Stat(source,&src),hasTarget=PDV2Stat(target,&dst);
    BOOL hasStage=PDV2Stat(stage,&stg),hasBackup=PDV2Stat(old,&bak);
    if((hasTarget && !S_ISDIR(dst.st_mode)) ||
       (hasStage && !S_ISDIR(stg.st_mode)) ||
       (hasBackup && !S_ISDIR(bak.st_mode))) return NO;
    if(hasSource) {
        if(S_ISLNK(src.st_mode)) {
            if(!PDV2Link(source,target)) return NO;
        } else if(!S_ISDIR(src.st_mode) || !PDV2Empty(source)) {
            // Do not discard existing real Library directories. The opt-in
            // experiment must have mounted them first, or they must be empty.
            return NO;
        }
    }
    // Safe replay states:
    // before: target + stage, no backup;
    // parked: backup + stage, no target;
    // installed: backup + target, no stage.
    if(hasStage && !hasBackup && hasTarget) return YES;
    if(hasStage && hasBackup && !hasTarget) return YES;
    if(!hasStage && hasBackup && hasTarget) return YES;
    return NO;
}
static BOOL PDV2Rollback(NSArray<NSString *> *scopes,NSString *root,
                         NSString *stageRoot,NSString *backupRoot) {
    BOOL okay=YES;
    for(NSString *name in [scopes reverseObjectEnumerator]) {
        NSString *stage=[stageRoot stringByAppendingPathComponent:name];
        NSString *target=[[root stringByAppendingPathComponent:@"Data"] stringByAppendingPathComponent:name];
        NSString *backup=[backupRoot stringByAppendingPathComponent:name];
        BOOL hasStage=PDV2Dir(stage),hasTarget=PDV2Dir(target),hasBackup=PDV2Dir(backup);
        if(!hasBackup) continue; // never touched, or failed before parking
        if(hasStage && !hasTarget) {
            if(!PDV2Move(backup,target)) okay=NO;
        } else if(!hasStage && hasTarget) {
            if(!PDV2Move(target,stage)) { okay=NO; continue; }
            if(!PDV2Move(backup,target)) okay=NO;
        } else if(hasStage && hasTarget) {
            // Conflict: do not delete either version.
            PDStorageTrace(@"V2 rollback ambiguous %@, retaining all directories",name);
            okay=NO;
        }
    }
    return okay;
}
BOOL PDV2ApplyPendingRestore(NSString *identifier) {
    NSString *root=PDStorageRoot();
    NSString *stageDir=[[root stringByAppendingPathComponent:@"Incoming"]
                         stringByAppendingPathComponent:identifier];
    NSString *planPath=[stageDir stringByAppendingPathComponent:@"restore-plan.json"];
    NSData *bytes=[NSData dataWithContentsOfFile:planPath];
    NSError *error=nil;
    id decoded=bytes ? [NSJSONSerialization JSONObjectWithData:bytes options:0 error:&error] : nil;
    if(![decoded isKindOfClass:NSDictionary.class]) return NO;
    NSDictionary *plan=decoded;
    if(![plan[@"format"] isEqualToString:@"SideloadPersist.Restore.V2"] ||
       ![plan[@"id"] isEqualToString:identifier] ||
       ![plan[@"scopes"] isKindOfClass:NSArray.class]) return NO;
    NSArray *scopes=plan[@"scopes"];
    if(!scopes.count || scopes.count>3 || ![scopes containsObject:@"Application Support"]) return NO;
    NSMutableSet *unique=[NSMutableSet set];
    for(id scope in scopes) {
        if(![scope isKindOfClass:NSString.class] || !PDV2ValidScope(scope) ||
           [unique containsObject:scope]) return NO;
        [unique addObject:scope];
    }
    BOOL extra=[unique containsObject:@"WebKit"] || [unique containsObject:@"Cookies"];
    if(extra && !PDV2AllowsExtraScopes()) {
        PDStorageTrace(@"V2 restore refused: extended scopes are not allowed for this app");
        return NO;
    }
    NSString *stageRoot=[stageDir stringByAppendingPathComponent:@"Data"];
    NSString *backupRoot=[[[root stringByAppendingPathComponent:@"Backups"]
                           stringByAppendingPathComponent:identifier] stringByAppendingPathComponent:@"Data"];
    NSString *pending=[root stringByAppendingPathComponent:@"restore-pending.txt"];
    // Validate the entire transaction BEFORE any directory gets moved.
    for(NSString *scope in scopes) {
        if(!PDV2PreflightScope(scope,root,stageRoot,backupRoot)) {
            PDStorageTrace(@"V2 restore preflight rejected scope %@",scope);
            return NO;
        }
    }
    if(!PDV2Mkdir(backupRoot)) return NO;
    // A persistent marker in Backups documents the transaction for manual
    // recovery; no backup is ever silently removed after success.
    NSString *auditPath=[[backupRoot stringByDeletingLastPathComponent]
                         stringByAppendingPathComponent:@"restore-plan.json"];
    if(![bytes writeToFile:auditPath options:NSDataWritingAtomic error:&error]) {
        PDStorageTrace(@"V2 cannot persist restore audit: %@",error);
        return NO;
    }
    for(NSString *scope in scopes) {
        NSString *stage=[stageRoot stringByAppendingPathComponent:scope];
        NSString *target=[[root stringByAppendingPathComponent:@"Data"] stringByAppendingPathComponent:scope];
        NSString *backup=[backupRoot stringByAppendingPathComponent:scope];
        if(PDV2Dir(target) && PDV2Dir(backup) && !PDV2Dir(stage)) continue;
        if(!PDV2Dir(backup)) {
            if(!PDV2Move(target,backup)) goto failure;
        }
#if TARGET_OS_OSX
        // Deterministic macOS CI fault injection: crash window after the old
        // directory is parked but before the replacement is installed.
        const char *inject=getenv("PD_V2_SMOKE_FAIL_SCOPE");
        if(inject && [scope isEqualToString:[NSString stringWithUTF8String:inject]]) {
            PDStorageTrace(@"TEST ONLY: injecting restore failure at %@",scope);
            goto failure;
        }
#endif
        if(!PDV2Move(stage,target)) goto failure;
    }
    if(unlink(pending.fileSystemRepresentation)!=0) {
        PDStorageTrace(@"V2 restore committed, but pending marker could not be cleared: %s",strerror(errno));
        return NO; // next cold start sees fully installed state and retries unlink
    }
    PDStorageTrace(@"V2 restore committed %@ scopes=%@",identifier,scopes);
    return YES;
failure:
    PDStorageTrace(@"V2 restore failed; attempting rollback without deleting staged data");
    if(!PDV2Rollback(scopes,root,stageRoot,backupRoot))
        PDStorageTrace(@"V2 rollback incomplete, refusing to continue until manual repair");
    return NO;
}
