#import "PDStorage.h"
#import "PDExperimentalScope.h"
#import "PDV2Restore.h"
#import <sys/stat.h>
#import <unistd.h>
#import <errno.h>
#import <stdio.h>
#import <string.h>
#import <limits.h>
#import <stdarg.h>

static PDStorageState s_state = PDStorageStateUnknown;
static NSString *s_status = @"尚未初始化";
static NSString *s_home = nil;

NSString *PDStorageDocuments(void) {
    return [[(s_home ?: NSHomeDirectory()) stringByAppendingPathComponent:@"Documents"] stringByStandardizingPath];
}
NSString *PDStorageRoot(void) {
    return [PDStorageDocuments() stringByAppendingPathComponent:@"SideloadPersist"];
}
NSString *PDStorageSource(void) {
    return [[(s_home ?: NSHomeDirectory()) stringByAppendingPathComponent:@"Library"] stringByAppendingPathComponent:@"Application Support"];
}
NSString *PDStorageTarget(void) {
    return [[PDStorageRoot() stringByAppendingPathComponent:@"Data"] stringByAppendingPathComponent:@"Application Support"];
}
NSString *PDStorageInbox(void) { return [PDStorageRoot() stringByAppendingPathComponent:@"Inbox"]; }
PDStorageState PDStorageGetState(void) { return s_state; }
NSString *PDStorageStatusText(void) { return s_status ?: @"未知状态"; }
BOOL PDStorageIsFileSharingEnabled(void) {
    id a = NSBundle.mainBundle.infoDictionary[@"UIFileSharingEnabled"];
    id b = NSBundle.mainBundle.infoDictionary[@"LSSupportsOpeningDocumentsInPlace"];
    return [a respondsToSelector:@selector(boolValue)] && [a boolValue] &&
           [b respondsToSelector:@selector(boolValue)] && [b boolValue];
}
void PDStorageTrace(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[SideloadPersist Storage] %@",message);
}
static BOOL PDStat(NSString *path, struct stat *st) {
    return lstat(path.fileSystemRepresentation,st) == 0;
}
static BOOL PDCreateDir(NSString *path) {
    NSError *error = nil;
    if ([[NSFileManager defaultManager] createDirectoryAtPath:path
             withIntermediateDirectories:YES attributes:nil error:&error]) return YES;
    PDStorageTrace(@"mkdir failed %@: %@",path,error);
    return NO;
}
static BOOL PDDirIsEmpty(NSString *path) {
    NSError *e = nil;
    NSArray *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:&e];
    return contents && !e && contents.count == 0;
}
static BOOL PDLinkMatches(NSString *src, NSString *target) {
    struct stat st;
    if (!PDStat(src,&st) || !S_ISLNK(st.st_mode)) return NO;
    char buffer[PATH_MAX] = {0};
    ssize_t n = readlink(src.fileSystemRepresentation,buffer,sizeof(buffer)-1);
    if (n < 0 || n >= (ssize_t)sizeof(buffer)) return NO;
    buffer[n] = 0;
    return [target isEqualToString:[NSString stringWithUTF8String:buffer]];
}
BOOL PDStorageIsLinked(void) { return PDLinkMatches(PDStorageSource(),PDStorageTarget()); }

static void PDSetStatus(PDStorageState state, NSString *message) {
    s_state = state;
    s_status = [message copy];
    PDStorageTrace(@"state=%ld %@",(long)state,message);
}
static void PDWriteManifest(void) {
    NSMutableArray<NSString *> *scopes=[NSMutableArray arrayWithObject:@"Application Support"];
    NSString *home=[PDStorageDocuments() stringByDeletingLastPathComponent];
    for(NSString *scope in @[@"WebKit",@"Cookies"]) {
        NSString *source=[[home stringByAppendingPathComponent:@"Library"] stringByAppendingPathComponent:scope];
        NSString *target=[[PDStorageRoot() stringByAppendingPathComponent:@"Data"] stringByAppendingPathComponent:scope];
        if(PDLinkMatches(source,target)) [scopes addObject:scope];
    }
    NSDictionary *manifest = @{
        @"format": scopes.count>1 ? @"SideloadPersist.Directory.V2" : @"SideloadPersist.Directory.V1",
        @"scopes":scopes,
        @"mode": @"symlink",
        @"source": @"Library/Application Support",
        @"target": @"Data/Application Support",
        @"originalBundleID": NSBundle.mainBundle.bundleIdentifier ?: @"unknown",
        @"lastBootstrap": @([[NSDate date] timeIntervalSince1970])
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:manifest options:NSJSONWritingPrettyPrinted error:nil];
    if (data) [data writeToFile:[PDStorageRoot() stringByAppendingPathComponent:@"manifest.json"]
                       options:NSDataWritingAtomic error:nil];
}
static BOOL PDIsSafeID(NSString *value) {
    if (value.length != 36) return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF-"];
    return [[value stringByTrimmingCharactersInSet:allowed] length] == 0;
}

// A staged restore is applied BEFORE app main runs, not while databases are open.
// Recovery rule: keep last data in Backups/uuid until a future manual cleanup.
static BOOL PDApplyPendingRestore(void) {
    NSString *pending = [PDStorageRoot() stringByAppendingPathComponent:@"restore-pending.txt"];
    NSString *identifier = [[NSString stringWithContentsOfFile:pending encoding:NSUTF8StringEncoding error:nil]
                              stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!PDIsSafeID(identifier)) {
        if (identifier.length) PDStorageTrace(@"Invalid pending restore ID, ignoring");
        return YES;
    }
    NSString *root=PDStorageRoot();
    NSString *stageRoot=[[root stringByAppendingPathComponent:@"Incoming"] stringByAppendingPathComponent:identifier];
    NSString *v2Plan=[stageRoot stringByAppendingPathComponent:@"restore-plan.json"];
    if([NSFileManager.defaultManager fileExistsAtPath:v2Plan])
        return PDV2ApplyPendingRestore(identifier);
    NSString *incoming=[stageRoot stringByAppendingPathComponent:@"Application Support"];
    NSString *backup=[[root stringByAppendingPathComponent:@"Backups"] stringByAppendingPathComponent:identifier];
    NSString *target=PDStorageTarget();
    struct stat st={0};
    BOOL haveStage=PDStat(incoming,&st) && S_ISDIR(st.st_mode);
    BOOL haveTarget=PDStat(target,&st);
    BOOL haveBackup=PDStat(backup,&st);
    if (haveStage && haveTarget && haveBackup) {
        PDStorageTrace(@"Ambiguous pending restore: target, backup and stage all exist. Refusing overwrite.");
        return NO;
    }
    if (!haveStage) {
        if (!haveTarget && haveBackup && rename(backup.fileSystemRepresentation,target.fileSystemRepresentation)==0) {
            PDStorageTrace(@"Recovered previous data after interrupted restore");
            return YES;
        }
        if (haveTarget) { unlink(pending.fileSystemRepresentation); return YES; }
        PDStorageTrace(@"Pending restore lacks both stage and target; needs manual repair");
        return NO;
    }
    if (haveTarget && !haveBackup) {
        if (!PDCreateDir([backup stringByDeletingLastPathComponent]) ||
            rename(target.fileSystemRepresentation,backup.fileSystemRepresentation) != 0) {
            PDStorageTrace(@"Cannot park existing target before restore: %s",strerror(errno));
            return NO;
        }
        haveTarget=NO;
        haveBackup=YES;
    }
    if (!haveTarget && rename(incoming.fileSystemRepresentation,target.fileSystemRepresentation) != 0) {
        PDStorageTrace(@"Cannot install staged restore: %s",strerror(errno));
        if (haveBackup) rename(backup.fileSystemRepresentation,target.fileSystemRepresentation);
        return NO;
    }
    unlink(pending.fileSystemRepresentation);
    PDStorageTrace(@"Staged restore committed. Previous data preserved in Backups/%@",identifier);
    return YES;
}

PDStorageState PDStorageBootstrap(void) {
    if (s_state != PDStorageStateUnknown) return s_state;
    @autoreleasepool {
        const char *env = getenv("HOME");
        s_home = (env && env[0] == '/' ? [NSString stringWithUTF8String:env] : NSHomeDirectory()).copy;
        if (!s_home.length) {
            PDSetStatus(PDStorageStateFailed,@"无法确定 App 沙盒目录");
            return s_state;
        }
        NSString *source = PDStorageSource();
        NSString *target = PDStorageTarget();
        NSString *root = PDStorageRoot();
        if (!PDCreateDir(PDStorageDocuments()) ||
            !PDCreateDir([source stringByDeletingLastPathComponent]) ||
            !PDCreateDir(root) ||
            !PDCreateDir([target stringByDeletingLastPathComponent]) ||
            !PDCreateDir(PDStorageInbox())) {
            PDSetStatus(PDStorageStateFailed,@"无法建立 Documents 持久化目录");
            return s_state;
        }
        // Restore only into an existing target or BEFORE mounting a new link.
        if (!PDApplyPendingRestore()) {
            PDSetStatus(PDStorageStateConflict,@"检测到未完成的数据恢复，请先检查 Inbox、Incoming 和 Backups");
            return s_state;
        }
        if (PDLinkMatches(source,target)) {
            PDExperimentalTryFromStorageProbe();
            PDWriteManifest();
            PDSetStatus(PDStorageStateReady,@"目录映射已存在");
            return s_state;
        }
        struct stat src={0},dst={0};
        BOOL hasSource=PDStat(source,&src);
        BOOL hasTarget=PDStat(target,&dst);
        BOOL movedOriginal=NO;
        if (hasSource && !S_ISDIR(src.st_mode)) {
            PDSetStatus(PDStorageStateConflict,@"原始目录不是普通文件夹，已停止迁移");
            return s_state;
        }
        if (hasTarget && !S_ISDIR(dst.st_mode)) {
            PDSetStatus(PDStorageStateConflict,@"持久化目标不是普通文件夹，已停止迁移");
            return s_state;
        }
        if (hasSource && hasTarget && !PDDirIsEmpty(source)) {
            PDSetStatus(PDStorageStateConflict,@"原始与持久化目录均含数据，已停止以防覆盖");
            return s_state;
        }
        if (!hasTarget && hasSource) {
            if (rename(source.fileSystemRepresentation,target.fileSystemRepresentation)!=0) {
                PDSetStatus(PDStorageStateFailed,[NSString stringWithFormat:@"目录原子迁移失败：%s",strerror(errno)]);
                return s_state;
            }
            hasSource=NO; hasTarget=YES;
            movedOriginal=YES;
            PDStorageTrace(@"Moved original Application Support by atomic rename");
        } else if (!hasTarget) {
            if (!PDCreateDir(target)) {
                PDSetStatus(PDStorageStateFailed,@"无法创建持久化数据目录");
                return s_state;
            }
            hasTarget=YES;
        }
        if (hasSource && PDDirIsEmpty(source)) {
            if (rmdir(source.fileSystemRepresentation)!=0) {
                PDSetStatus(PDStorageStateFailed,@"无法移除空的原始目录");
                return s_state;
            }
            hasSource=NO;
        }
        if (!hasSource && symlink(target.fileSystemRepresentation,source.fileSystemRepresentation)!=0) {
            int errorNumber=errno;
            if (movedOriginal) {
                if (rename(target.fileSystemRepresentation,source.fileSystemRepresentation)==0)
                    PDStorageTrace(@"Symbolic link creation failed; original directory restored by rollback");
                else
                    PDStorageTrace(@"CRITICAL: symlink failed and rollback failed (%s); data remains at %@",strerror(errno),target);
            } else if (!PDStat(source,&src)) {
                // Preserve ordinary Application Support behavior on an empty first launch.
                PDCreateDir(source);
            }
            PDSetStatus(PDStorageStateFailed,[NSString stringWithFormat:@"符号链接创建失败（已尝试回滚）：%s",strerror(errorNumber)]);
            return s_state;
        }
        if (!PDLinkMatches(source,target)) {
            PDSetStatus(PDStorageStateFailed,@"符号链接验证失败");
            return s_state;
        }
        PDExperimentalTryFromStorageProbe();
        PDWriteManifest();
        PDSetStatus(PDStorageStateRecovered,@"持久化目录已建立并验证");
        return s_state;
    }
}
