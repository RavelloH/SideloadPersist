#import "FullCycle.h"
#import <CoreData/CoreData.h>
#import <CommonCrypto/CommonDigest.h>
#import <Security/Security.h>
#import <WebKit/WebKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <sqlite3.h>
#import <sys/stat.h>
#import <sys/mman.h>
#import <fcntl.h>
#import <dlfcn.h>
#import <unistd.h>

static NSString *SPFingerprint(NSData *data) {
    if (!data) return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]={0};
    CC_SHA256(data.bytes,(CC_LONG)data.length,digest);
    NSMutableString *result=[NSMutableString string];
    for(NSUInteger i=0;i<sizeof(digest);i++) [result appendFormat:@"%02x",digest[i]];
    return result;
}
static id SPJSON(NSString *path) {
    NSData *bytes=[NSData dataWithContentsOfFile:path];
    if (!bytes) return nil;
    return [NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil];
}
static NSInteger SPCountSQLite(NSString *path,const char *query) {
    sqlite3 *db=NULL;
    NSInteger count=-1;
    if(sqlite3_open_v2(path.fileSystemRepresentation,&db,SQLITE_OPEN_READONLY,NULL)==SQLITE_OK) {
        sqlite3_stmt *statement=NULL;
        if(sqlite3_prepare_v2(db,query,-1,&statement,NULL)==SQLITE_OK &&
           sqlite3_step(statement)==SQLITE_ROW)
            count=sqlite3_column_int64(statement,0);
        if(statement) sqlite3_finalize(statement);
    }
    if(db) sqlite3_close(db);
    return count;
}

@interface SPFullCycle ()
@property(nonatomic,weak) UIViewController *parent;
@property(nonatomic,copy) void (^report)(NSString *);
@property(nonatomic,copy) void (^completionBlock)(void);
@property(nonatomic,strong) NSMutableDictionary *values;
@property(nonatomic,strong) NSDictionary *baseline;
@property(nonatomic,strong) NSSet<NSString *> *mappedScopes;
@property(nonatomic,strong) NSString *installationID;
@property(nonatomic,strong) NSString *root;
@property(nonatomic,strong) NSString *snapshotPath;
@property(nonatomic,strong) WKWebView *webView;
@property(nonatomic,assign) BOOL verifying;
@property(nonatomic,assign) BOOL jsDone;
@property(nonatomic,assign) BOOL cookieDone;
@property(nonatomic,assign) BOOL finished;
@property(nonatomic,assign) NSUInteger passes;
@property(nonatomic,assign) NSUInteger failures;
@property(nonatomic,assign) NSUInteger skips;
@end

@implementation SPFullCycle
- (instancetype)initWithParent:(UIViewController *)parent
                            log:(void (^)(NSString *))log
                     completion:(void (^)(void))completion {
    self=[super init];
    if(self) {
        _parent=parent;
        _report=[log copy];
        _completionBlock=[completion copy];
        _values=[NSMutableDictionary dictionary];
    }
    return self;
}
- (void)line:(NSString *)message {
    if(self.report) self.report(message);
}
- (void)check:(BOOL)result label:(NSString *)label {
    if(result) self.passes++; else self.failures++;
    [self line:[NSString stringWithFormat:@"%@ %@",result?@"PASS":@"FAIL",label]];
}
- (void)skip:(NSString *)message {
    self.skips++;
    [self line:[@"SKIP " stringByAppendingString:message]];
}
- (void)compare:(NSString *)key actual:(id)actual {
    if(!self.verifying) return;
    id expected=[self.baseline[@"values"] isKindOfClass:NSDictionary.class] ?
        self.baseline[@"values"][key] : nil;
    if(!expected) {
        [self skip:[NSString stringWithFormat:@"RESTORE_COMPARE %@ missing baseline",key]];
        return;
    }
    [self check:(actual && [expected isEqual:actual])
         label:[NSString stringWithFormat:@"RESTORE_COMPARE %@ baseline=%@ observed=%@",
                key,expected,actual ?: @"missing"]];
}
- (void)record:(NSString *)key before:(id)before after:(id)after migrated:(BOOL)migrated {
    [self line:[NSString stringWithFormat:@"METRIC %@ before=%@ after=%@ scope=%@",
        key,before ?: @"missing",after ?: @"missing",migrated?@"migrated":@"native-local"]];
    if(after) self.values[key]=after;
    if(migrated) {
        NSString *scope=@"Application Support";
        if([key isEqualToString:@"webCookie"]) scope=@"Cookies";
        else if([key hasPrefix:@"web"]) scope=@"WebKit";
        else if([key isEqualToString:@"userDefaults"] ||
                [key isEqualToString:@"defaultsSuite"] ||
                [key isEqualToString:@"cfPreferences"] ||
                [key isEqualToString:@"cfDirect"]) scope=@"Preferences";
        if(![self.mappedScopes containsObject:scope]) {
            [self line:[NSString stringWithFormat:@"NOT_PERSISTED %@: no verified data backend for scope %@, direct Documents writes do not prove recovery",key,scope]];
        } else [self compare:key actual:before];
    }
    else if(self.verifying) {
        id expected=[self.baseline[@"values"] isKindOfClass:NSDictionary.class] ?
                     self.baseline[@"values"][key] : nil;
        [self line:[NSString stringWithFormat:@"OBS NATIVE_NOT_IN_ZIP %@ baseline=%@ current=%@",
                    key,expected ?: @"missing",before ?: @"missing"]];
    }
}
- (void)researchMetric:(NSString *)key before:(id)before after:(id)after {
    [self line:[NSString stringWithFormat:@"RESEARCH_METRIC %@ before=%@ after=%@",
        key,before ?: @"missing",after ?: @"missing"]];
    if(after) self.values[key]=after;
    if(self.verifying) {
        id expected=[self.baseline[@"values"] isKindOfClass:NSDictionary.class] ?
            self.baseline[@"values"][key] : nil;
        [self line:[NSString stringWithFormat:@"RESEARCH_REINSTALL %@ expected=%@ observed=%@ matched=%@",
            key,expected ?: @"missing",before ?: @"missing",
            (expected && [expected isEqual:before])?@"yes":@"no"]];
    }
}
- (void)start {
    NSFileManager *fm=NSFileManager.defaultManager;
    NSString *home=NSHomeDirectory();
    self.root=[home stringByAppendingPathComponent:@"Documents/SideloadPersist"];
    NSString *data=[self.root stringByAppendingPathComponent:@"Data/Application Support/StorageProbe"];
    self.snapshotPath=[data stringByAppendingPathComponent:@"fullcycle-baseline.json"];
    [fm createDirectoryAtPath:data withIntermediateDirectories:YES attributes:nil error:nil];
    // Preferences are now migrated, so installation identity must live in
    // Caches (intentionally NOT migrated). This is a reliable reinstall marker.
    NSString *identityFile=[home stringByAppendingPathComponent:@"Library/Caches/StorageProbe-fullcycle-installation.txt"];
    NSString *install=[[NSString stringWithContentsOfFile:identityFile encoding:NSUTF8StringEncoding error:nil]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if(!install.length) {
        install=NSUUID.UUID.UUIDString;
        [fm createDirectoryAtPath:[identityFile stringByDeletingLastPathComponent]
            withIntermediateDirectories:YES attributes:nil error:nil];
        [install writeToFile:identityFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    self.installationID=install;
    id loaded=SPJSON(self.snapshotPath);
    self.baseline=[loaded isKindOfClass:NSDictionary.class] &&
        [loaded[@"format"] isEqual:@"StorageProbe.FullCycle.V2"] ? loaded : nil;
    // The previous probe version mistakenly wrote 'complete=false' baselines.
    // They are diagnostics, not proof of an install to compare against. Preserve
    // them once and automatically start a fresh baseline without reinstalling.
    BOOL priorInvalid=self.baseline && ![self.baseline[@"complete"] boolValue];
    if(priorInvalid) {
        NSString *prior=[self.root stringByAppendingPathComponent:@"fullcycle-prior-incomplete.json"];
        if(![fm fileExistsAtPath:prior]) {
            NSData *bytes=[NSData dataWithContentsOfFile:self.snapshotPath];
            if(bytes) [bytes writeToFile:prior options:NSDataWritingAtomic error:nil];
        }
        self.baseline=nil;
    }
    NSString *previous=self.baseline[@"installationID"];
    self.verifying=(previous.length && ![previous isEqualToString:install]);
    [self line:@"===== ONE-TAP FULL STORAGE CYCLE / v3 (Preferences API Hook) ====="];
    if(priorInvalid) [self line:@"INVALID_BASELINE_ARCHIVED: old incomplete baseline ignored; starting a new local backup baseline without reinstalling"];
    [self line:[NSString stringWithFormat:@"PHASE=%@ installation=%@ baselineInstallation=%@",
        self.verifying?@"RESTORED_INSTALLATION_VERIFY":@"GENERATE_BACKUP_BASELINE",
        install,previous ?: @"none"]];
    if(self.baseline && !self.verifying)
        [self line:@"NOTE This installation has a baseline; it will be refreshed after all tests finish."];
    if(self.verifying && ![self.baseline[@"complete"] boolValue])
        [self check:NO label:@"RESTORE_BASELINE is incomplete; results must not be treated as a validated full recovery"];
    if(!self.baseline)
        [self line:@"NOTE No earlier full-cycle baseline found. This run prepares the FIRST backup; it cannot verify an older archive."];
    NSDictionary *manifest=SPJSON([self.root stringByAppendingPathComponent:@"manifest.json"]);
    NSDictionary *receipt=SPJSON([self.root stringByAppendingPathComponent:@"restore-last.json"]);
    [self line:[NSString stringWithFormat:@"PERSISTENCE_MANIFEST %@ scopes=%@",
        manifest[@"format"] ?: @"absent",manifest[@"scopes"] ?: @[]]];
    [self check:([manifest[@"scopes"] isKindOfClass:NSArray.class] &&
        [manifest[@"scopes"] containsObject:@"Application Support"])
         label:@"PERSISTENCE_MANIFEST valid with verified core scope"];
    NSDictionary *diagnostics=SPJSON([self.root stringByAppendingPathComponent:@"scope-mapping-result.json"]);
    if([diagnostics[@"scopes"] isKindOfClass:NSArray.class]) {
        for(NSDictionary *scope in diagnostics[@"scopes"]) {
            [self line:[NSString stringWithFormat:@"SCOPE_DIAGNOSTIC %@ mapped=%@ reason=%@ source=%@ target=%@ sourceEntries=%@ targetEntries=%@",
                scope[@"scope"],scope[@"mapped"],scope[@"reason"],scope[@"sourceType"],
                scope[@"targetType"],scope[@"sourceEntryCount"],scope[@"targetEntryCount"]]];
        }
    } else [self line:@"SCOPE_DIAGNOSTIC absent (older dylib or init stopped early)"];
    for(NSString *name in @[@"Preferences",@"Caches",@"tmp"]) {
        NSString *path=[name isEqualToString:@"tmp"] ? NSTemporaryDirectory() :
            [home stringByAppendingPathComponent:[@"Library" stringByAppendingPathComponent:name]];
        BOOL directory=NO;
        BOOL exists=[fm fileExistsAtPath:path isDirectory:&directory];
        NSArray *entries=exists && directory ? [fm contentsOfDirectoryAtPath:path error:nil] : nil;
        [self line:[NSString stringWithFormat:@"NATIVE_SCOPE %@ exists=%@ immediateEntries=%lu",
            name,exists?@"yes":@"no",(unsigned long)entries.count]];
    }
    [self line:[NSString stringWithFormat:@"RESTORE_RECEIPT result=%@ scopes=%@",
        receipt[@"result"] ?: @"absent",receipt[@"scopes"] ?: @[]]];
    NSString *readme=[NSString stringWithContentsOfFile:[self.root stringByAppendingPathComponent:@"README.md"]
        encoding:NSUTF8StringEncoding error:nil];
    [self check:([readme containsString:@"RavelloH"] &&
                 [readme containsString:@"github.com/RavelloH/SideloadPersist"] &&
                 [readme containsString:@"Library/Preferences"])
         label:@"SideloadPersist README.md created with author repository and directory mappings"];
    [self enumerateLibraryScopeCandidates];
    NSMutableSet<NSString *> *verified=[NSMutableSet set];
    for(NSString *scope in @[@"Application Support",@"WebKit",@"Cookies",@"Preferences"]) {
        NSString *original=[home stringByAppendingPathComponent:
            [@"Library" stringByAppendingPathComponent:scope]];
        NSString *destination=[self.root stringByAppendingPathComponent:
            [@"Data" stringByAppendingPathComponent:scope]];
        char buffer[4096]={0};
        ssize_t len=readlink(original.fileSystemRepresentation,buffer,sizeof(buffer)-1);
        BOOL matching=len>0 && [destination isEqualToString:[NSString stringWithUTF8String:buffer]];
        if([scope isEqualToString:@"Preferences"]) {
            BOOL (*hookActive)(void)=(BOOL(*)(void))dlsym(RTLD_DEFAULT,"PDPreferencesHookActive");
            BOOL active=hookActive && hookActive() &&
                [manifest[@"scopeModes"][@"Preferences"] isEqualToString:@"live-api-hook"];
            NSString *(*hookStatus)(void)=(NSString *(*)(void))dlsym(RTLD_DEFAULT,"PDPreferencesHookStatus");
            NSString *status=hookStatus?hookStatus():@"symbol-unavailable";
            [self line:[NSString stringWithFormat:@"PREFERENCES_HOOK_STATUS %@",status]];
            BOOL cfInstalled=[status containsString:@"CFPreferences app-level hook installed"];
            [self check:active label:@"SCOPE_HOOK Preferences live API storage (no symlink)"];
            [self check:cfInstalled label:@"CFPreferences imported-symbol hook reports installed"];
            if(active && cfInstalled) [verified addObject:scope];
        } else {
            [self check:matching label:[NSString stringWithFormat:@"SCOPE_LINK %@",scope]];
            if(matching) [verified addObject:scope];
        }
    }
    self.mappedScopes=[verified copy];
    NSDictionary *(*preferenceHealth)(void)=(NSDictionary *(*)(void))dlsym(RTLD_DEFAULT,"PDPreferencesHealth");
    NSDictionary *preferenceStats=preferenceHealth?preferenceHealth():nil;
    [self line:[NSString stringWithFormat:@"PREFERENCES_STORAGE_USAGE domains=%@ bytes=%@",
        preferenceStats[@"domainFiles"] ?: @"unknown",preferenceStats[@"bytes"] ?: @"unknown"]];
    if(self.verifying)
        [self check:[receipt[@"result"] isEqualToString:@"committed"]
             label:@"RESTORE_RECEIPT committed after reinstall"];
    [self testFiles:data];
    [self testSQLite:data];
    [self testCoreData:data];
    [self testUnmigrated];
    [self testNativeStores];
    [self testKeychain];
    [self testAppGroups];
    [self beginWebKit];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(30*NSEC_PER_SEC)),
                   dispatch_get_main_queue(),^{
        if(self.finished) return;
        if(!self.jsDone || !self.cookieDone) {
            [self check:NO label:@"WebKit asynchronous probe timed out; no complete baseline will be written"];
            [self complete:NO];
        }
    });
}
- (void)enumerateLibraryScopeCandidates {
    NSString *library=[NSHomeDirectory() stringByAppendingPathComponent:@"Library"];
    NSArray<NSString *> *entries=[NSFileManager.defaultManager contentsOfDirectoryAtPath:library error:nil];
    NSSet *mapped=[NSSet setWithArray:@[@"Application Support",@"WebKit",@"Cookies",@"Preferences"]];
    NSSet *transient=[NSSet setWithArray:@[@"Caches",@"Saved Application State"]];
    for(NSString *name in [entries sortedArrayUsingSelector:@selector(compare:)]) {
        NSString *path=[library stringByAppendingPathComponent:name];
        BOOL isDir=NO;
        if(![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDir] || !isDir) continue;
        NSString *classification=[mapped containsObject:name] ? @"mapped" :
            ([transient containsObject:name] ? @"transient" : @"unmapped-needs-research");
        [self line:[NSString stringWithFormat:@"LIBRARY_DISCOVERY %@ category=%@",name,classification]];
    }
    // A synthetic custom Library directory identifies an important scope
    // not covered by the four static mappings. It is a diagnostic, not a FAIL.
    NSString *custom=[library stringByAppendingPathComponent:@"StorageProbeCustomPersistent"];
    [NSFileManager.defaultManager createDirectoryAtPath:custom withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *marker=[custom stringByAppendingPathComponent:@"marker.txt"];
    NSString *old=[NSString stringWithContentsOfFile:marker encoding:NSUTF8StringEncoding error:nil];
    NSString *value=old ?: NSUUID.UUID.UUIDString;
    BOOL wrote=[value writeToFile:marker atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [self check:wrote label:@"Library custom directory synthetic marker writable"];
    // This private subdirectory was just created during the probe, after the
    // plugin's early bootstrap. Rescan once so the same expensive reinstall
    // checks both fresh discovery and the restored original Library path.
    void (*refresh)(void)=(void (*)(void))dlsym(RTLD_DEFAULT,"PDStorageRefreshOptionalMappings");
    if(refresh) refresh();
    NSString *backup=[NSHomeDirectory() stringByAppendingPathComponent:
        @"Documents/SideloadPersist/Data/Application Support/SideloadPersist.Library/StorageProbeCustomPersistent"];
    char linkDestination[4096]={0};
    ssize_t length=readlink(custom.fileSystemRepresentation,linkDestination,sizeof(linkDestination)-1);
    BOOL mapped=length>0 && [backup isEqualToString:[NSString stringWithUTF8String:linkDestination]];
    [self check:mapped label:@"APP_PRIVATE_LIBRARY StorageProbeCustomPersistent mapped to existing AppSupport backup"];
    NSDictionary *manifest=SPJSON([self.root stringByAppendingPathComponent:@"manifest.json"]);
    BOOL declared=NO;
    for(NSDictionary *mapping in manifest[@"additionalLibraryMappings"]) {
        if([mapping[@"source"] isEqualToString:@"Library/StorageProbeCustomPersistent"] &&
           [mapping[@"target"] isEqualToString:
               @"Data/Application Support/SideloadPersist.Library/StorageProbeCustomPersistent"]) declared=YES;
    }
    [self check:declared label:@"APP_PRIVATE_LIBRARY mapping recorded in manifest"];
    NSString *persisted=[NSString stringWithContentsOfFile:
        [backup stringByAppendingPathComponent:@"marker.txt"] encoding:NSUTF8StringEncoding error:nil];
    [self check:[persisted isEqualToString:value] label:@"APP_PRIVATE_LIBRARY original marker resides inside backup scope"];
    [self researchMetric:@"customLibraryMarker" before:old after:value];
    if(self.verifying && mapped) [self compare:@"customLibraryMarker" actual:old];
    NSDictionary *discovery=SPJSON([self.root stringByAppendingPathComponent:@"library-discovery.json"]);
    [self line:[NSString stringWithFormat:@"LIBRARY_MIGRATION_DIAGNOSTIC mapped=%@ conflicts=%@ unselected=%@",
        discovery[@"mapped"] ?: @[],discovery[@"conflicts"] ?: @"unknown",
        discovery[@"unselectedLibraryEntries"] ?: @"unknown"]];
}
- (void)testFiles:(NSString *)directory {
    NSFileManager *fm=NSFileManager.defaultManager;
    NSString *markerFile=[directory stringByAppendingPathComponent:@"fullcycle-marker.txt"];
    NSString *before=[NSString stringWithContentsOfFile:markerFile encoding:NSUTF8StringEncoding error:nil];
    if(!before.length && !self.verifying) {
        before=NSUUID.UUID.UUIDString;
        [before writeToFile:markerFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    [self check:before.length>0 label:@"Foundation persistent UUID marker"];
    [self record:@"appMarker" before:before after:before migrated:YES];

    NSString *bigFile=[directory stringByAppendingPathComponent:@"fullcycle-1MiB.bin"];
    NSData *existing=[NSData dataWithContentsOfFile:bigFile];
    NSString *priorHash=SPFingerprint(existing);
    if(!existing && !self.verifying) {
        NSMutableData *generated=[NSMutableData dataWithLength:1024*1024];
        unsigned char *bytes=generated.mutableBytes;
        for(NSUInteger i=0;i<generated.length;i++) bytes[i]=(unsigned char)((i*131+17)&255);
        BOOL wrote=[generated writeToFile:bigFile options:NSDataWritingAtomic error:nil];
        [self check:wrote label:@"1 MiB NSData atomic write"];
        existing=[NSData dataWithContentsOfFile:bigFile];
        priorHash=SPFingerprint(existing);
    }
    [self check:existing.length==1024*1024 label:@"1 MiB binary data preserved"];
    [self record:@"appLargeSHA256" before:priorHash after:priorHash migrated:YES];

    NSString *posix=[directory stringByAppendingPathComponent:@"fullcycle-posix.bin"];
    int fd=open(posix.fileSystemRepresentation,O_RDWR|O_CREAT,0600);
    BOOL ok=fd>=0;
    if(fd>=0) {
        const char payload[]="SideloadPersist full-cycle POSIX file";
        ok=ftruncate(fd,(off_t)sizeof(payload))==0 &&
           pwrite(fd,payload,sizeof(payload),0)==(ssize_t)sizeof(payload);
        void *address=mmap(NULL,sizeof(payload),PROT_READ,MAP_SHARED,fd,0);
        ok=ok && address!=MAP_FAILED;
        if(address!=MAP_FAILED) {
            ok=ok && memcmp(address,payload,sizeof(payload))==0;
            munmap(address,sizeof(payload));
        }
        fsync(fd);
        close(fd);
    }
    [self check:ok label:@"POSIX open/ftruncate/pwrite/mmap/fsync"];

    // Cover additional APIs used by third-party apps, not only NSData/POSIX.
    NSString *stdio=[directory stringByAppendingPathComponent:@"fullcycle-stdio.txt"];
    FILE *file=fopen(stdio.fileSystemRepresentation,"wb");
    BOOL stdioOK=file!=NULL;
    if(file) {
        stdioOK=fputs("STORAGEPROBE_STDIO",file)>=0 && fflush(file)==0;
        stdioOK=fclose(file)==0 && stdioOK;
    }
    NSString *stdioRead=[NSString stringWithContentsOfFile:stdio encoding:NSUTF8StringEncoding error:nil];
    [self check:stdioOK && [stdioRead isEqualToString:@"STORAGEPROBE_STDIO"]
         label:@"C stdio fopen/fputs/fflush/fclose + NSString read"];

    NSString *handlePath=[directory stringByAppendingPathComponent:@"fullcycle-handle.bin"];
    [fm createFileAtPath:handlePath contents:[NSData data] attributes:nil];
    NSFileHandle *handle=[NSFileHandle fileHandleForWritingAtPath:handlePath];
    NSData *handlePayload=[@"STORAGEPROBE_FILEHANDLE" dataUsingEncoding:NSUTF8StringEncoding];
    BOOL handleOK=handle!=nil;
    @try {
        if(handle) {
            [handle writeData:handlePayload];
            [handle synchronizeFile];
            [handle closeFile];
        }
    } @catch(__unused NSException *exception) {handleOK=NO;}
    [self check:handleOK && [[NSData dataWithContentsOfFile:handlePath] isEqualToData:handlePayload]
         label:@"NSFileHandle create/write/synchronize/read"];

    NSString *copy=[directory stringByAppendingPathComponent:@"fullcycle-copy.bin"];
    NSString *moved=[directory stringByAppendingPathComponent:@"fullcycle-moved.bin"];
    [fm removeItemAtPath:copy error:nil];
    [fm removeItemAtPath:moved error:nil];
    NSError *copyError=nil;
    BOOL copied=[fm copyItemAtPath:handlePath toPath:copy error:&copyError];
    BOOL renamed=copied && [fm moveItemAtPath:copy toPath:moved error:&copyError];
    [self check:renamed && [[NSData dataWithContentsOfFile:moved] isEqualToData:handlePayload]
         label:@"NSFileManager copy/move/read file"];
    [fm removeItemAtPath:moved error:nil];
    NSString *unicode=[directory stringByAppendingPathComponent:@"全量验证-中文-🧪.txt"];
    BOOL unicodeOK=[@"UNICODE_PATH" writeToFile:unicode atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [self check:unicodeOK && [[NSString stringWithContentsOfFile:unicode encoding:NSUTF8StringEncoding error:nil]
                        isEqualToString:@"UNICODE_PATH"]
         label:@"Unicode filename + Foundation path encoding"];
    NSString *coordinated=[directory stringByAppendingPathComponent:@"fullcycle-coordinated.txt"];
    [@"before-coordination" writeToFile:coordinated atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSFileCoordinator *coordinator=[[NSFileCoordinator alloc] initWithFilePresenter:nil];
    NSError *coordError=nil;
    __block BOOL coordinateOK=NO;
    [coordinator coordinateWritingItemAtURL:[NSURL fileURLWithPath:coordinated]
                                   options:0 error:&coordError byAccessor:^(NSURL *newURL) {
        coordinateOK=[@"coordinated" writeToURL:newURL atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }];
    [self check:coordinateOK && !coordError label:@"NSFileCoordinator coordinated write"];
    NSDictionary *attributes=[fm attributesOfItemAtPath:bigFile error:nil];
    NSData *mapped=[NSData dataWithContentsOfFile:bigFile options:NSDataReadingMappedIfSafe error:nil];
    [self check:mapped.length==1024*1024 && [SPFingerprint(mapped) isEqualToString:priorHash]
         label:@"NSData mapped read of 1 MiB persisted file"];
    [self line:[NSString stringWithFormat:@"FILE_ATTR fileProtection=%@ size=%@",
        attributes[NSFileProtectionKey] ?: @"not-reported",attributes[NSFileSize] ?: @"missing"]];
}
- (void)testSQLite:(NSString *)directory {
    NSString *file=[directory stringByAppendingPathComponent:@"fullcycle.sqlite"];
    sqlite3 *db=NULL;
    NSInteger before=-1,after=-1;
    BOOL ok=sqlite3_open(file.fileSystemRepresentation,&db)==SQLITE_OK;
    if(ok) {
        ok=sqlite3_exec(db,"PRAGMA journal_mode=WAL;CREATE TABLE IF NOT EXISTS events(id INTEGER PRIMARY KEY,stamp TEXT)",NULL,NULL,NULL)==SQLITE_OK;
        sqlite3_stmt *statement=NULL;
        if(ok && sqlite3_prepare_v2(db,"SELECT COUNT(*) FROM events",-1,&statement,NULL)==SQLITE_OK &&
           sqlite3_step(statement)==SQLITE_ROW) before=sqlite3_column_int64(statement,0);
        if(statement) sqlite3_finalize(statement);
        ok=ok && before>=0;
        if(ok) {
            ok=sqlite3_exec(db,"BEGIN IMMEDIATE;INSERT INTO events(stamp) VALUES('full-cycle');COMMIT;",NULL,NULL,NULL)==SQLITE_OK;
            after=SPCountSQLite(file,"SELECT COUNT(*) FROM events");
        }
        sqlite3_stmt *integrity=NULL;
        if(ok && sqlite3_prepare_v2(db,"PRAGMA integrity_check",-1,&integrity,NULL)==SQLITE_OK &&
           sqlite3_step(integrity)==SQLITE_ROW)
            ok=strcmp((const char *)sqlite3_column_text(integrity,0),"ok")==0;
        else ok=NO;
        if(integrity) sqlite3_finalize(integrity);
    }
    if(db) sqlite3_close(db);
    [self check:ok && after==before+1 label:@"SQLite WAL transaction + integrity_check"];
    [self record:@"sqliteRows" before:@(before) after:@(after) migrated:YES];
}
- (void)testCoreData:(NSString *)directory {
    NSEntityDescription *entity=[NSEntityDescription new];
    entity.name=@"FullEvent";
    entity.managedObjectClassName=@"NSManagedObject";
    NSAttributeDescription *field=[NSAttributeDescription new];
    field.name=@"name";field.attributeType=NSStringAttributeType;field.optional=YES;
    entity.properties=@[field];
    NSManagedObjectModel *model=[NSManagedObjectModel new];model.entities=@[entity];
    NSPersistentStoreCoordinator *coordinator=[[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
    NSURL *url=[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"fullcycle-coredata.sqlite"]];
    NSError *error=nil;
    NSPersistentStore *store=[coordinator addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:url options:nil error:&error];
    NSInteger before=-1,after=-1;
    BOOL ok=store!=nil;
    if(ok) {
        NSManagedObjectContext *context=[[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
        context.persistentStoreCoordinator=coordinator;
        NSFetchRequest *fetch=[NSFetchRequest fetchRequestWithEntityName:@"FullEvent"];
        before=[context countForFetchRequest:fetch error:&error];
        NSManagedObject *object=[NSEntityDescription insertNewObjectForEntityForName:@"FullEvent" inManagedObjectContext:context];
        [object setValue:@"full-cycle" forKey:@"name"];
        ok=[context save:&error];
        after=[context countForFetchRequest:fetch error:&error];
        ok=ok && before>=0 && after==before+1;
        [coordinator removePersistentStore:store error:nil];
    }
    [self check:ok label:[NSString stringWithFormat:@"CoreData SQLite %@",
        error ? error.localizedDescription : @"persistent store"]];
    [self record:@"coreDataRows" before:@(before) after:@(after) migrated:YES];
}
- (void)testUnmigrated {
    NSUserDefaults *prefs=NSUserDefaults.standardUserDefaults;
    NSInteger before=[prefs integerForKey:@"StorageProbe.FullCycle.Prefs"];
    [prefs setInteger:before+1 forKey:@"StorageProbe.FullCycle.Prefs"];
    [self check:[prefs integerForKey:@"StorageProbe.FullCycle.Prefs"]==before+1
         label:@"NSUserDefaults read/write (Preferences relocated)"];
    CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
    [self record:@"userDefaults" before:@(before) after:@(before+1) migrated:YES];
    NSUserDefaults *suite=[[NSUserDefaults alloc] initWithSuiteName:@"com.ravelloh.storageprobe.fullcycle.suite"];
    if(suite) {
        NSInteger original=[suite integerForKey:@"StorageProbe.FullCycle.SuiteCounter"];
        [suite setInteger:original+1 forKey:@"StorageProbe.FullCycle.SuiteCounter"];
        [self check:[suite integerForKey:@"StorageProbe.FullCycle.SuiteCounter"]==original+1
             label:@"NSUserDefaults custom suite read/write (Preferences relocated)"];
        [suite synchronize];
        [self record:@"defaultsSuite" before:@(original) after:@(original+1) migrated:YES];
    } else [self skip:@"NSUserDefaults custom suite unavailable"];
    [prefs setObject:@"remove-me" forKey:@"StorageProbe.FullCycle.DeletionProbe"];
    [prefs removeObjectForKey:@"StorageProbe.FullCycle.DeletionProbe"];
    [self check:![prefs objectForKey:@"StorageProbe.FullCycle.DeletionProbe"] &&
         ![prefs.dictionaryRepresentation objectForKey:@"StorageProbe.FullCycle.DeletionProbe"]
         label:@"NSUserDefaults deleted key absent from objectForKey and dictionaryRepresentation"];

    NSString *cache=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/StorageProbe-fullcycle.bin"];
    NSData *previous=[NSData dataWithContentsOfFile:cache];
    [self record:@"cacheFileHash" before:SPFingerprint(previous)
                                  after:SPFingerprint(previous) migrated:NO];
    BOOL wrote=[@"SideloadPersist-cache" writeToFile:cache atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [self check:wrote label:@"Library/Caches writable (not migrated)"];

    NSString *prefsDir=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Preferences"];
    struct stat st={0};
    BOOL isLink=lstat(prefsDir.fileSystemRepresentation,&st)==0 && S_ISLNK(st.st_mode);
    [self line:[NSString stringWithFormat:@"PREFERENCES_DIRECTORY_SYMLINK=%@ (expected no; live API Hook instead)",
                  isLink?@"yes":@"no"]];
}
- (void)testNativeStores {
    // CFPreferences has its own APIs. Test the imported C entry point to
    // determine whether fishhook really redirects this app's preference calls.
    CFStringRef key=CFSTR("StorageProbe.FullCycle.CFPreferencesCounter");
    CFPropertyListRef previous=CFPreferencesCopyAppValue(key,kCFPreferencesCurrentApplication);
    NSInteger before=0;
    if(previous && CFGetTypeID(previous)==CFNumberGetTypeID())
        CFNumberGetValue((CFNumberRef)previous,kCFNumberNSIntegerType,&before);
    if(previous) CFRelease(previous);
    NSInteger after=before+1;
    CFNumberRef value=CFNumberCreate(kCFAllocatorDefault,kCFNumberNSIntegerType,&after);
    CFPreferencesSetAppValue(key,value,kCFPreferencesCurrentApplication);
    CFRelease(value);
    BOOL synchronized=CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
    CFPropertyListRef current=CFPreferencesCopyAppValue(key,kCFPreferencesCurrentApplication);
    NSInteger observed=0;
    if(current && CFGetTypeID(current)==CFNumberGetTypeID())
        CFNumberGetValue((CFNumberRef)current,kCFNumberNSIntegerType,&observed);
    if(current) CFRelease(current);
    [self check:synchronized && observed==after label:@"CFPreferences write/synchronize/read (native-local)"];
    [self record:@"cfPreferences" before:@(before) after:@(after) migrated:YES];

    // The exact-domain CF API can bypass the higher-level app API. Include
    // it in the same expensive cross-install round rather than requiring a
    // separate reinstall just to discover a missing rebinding.
    CFStringRef directKey=CFSTR("StorageProbe.FullCycle.CFDirectCounter");
    CFPropertyListRef directOld=CFPreferencesCopyValue(directKey,kCFPreferencesCurrentApplication,
        kCFPreferencesCurrentUser,kCFPreferencesAnyHost);
    NSInteger directBefore=0;
    if(directOld && CFGetTypeID(directOld)==CFNumberGetTypeID())
        CFNumberGetValue((CFNumberRef)directOld,kCFNumberNSIntegerType,&directBefore);
    if(directOld) CFRelease(directOld);
    NSInteger directAfter=directBefore+1;
    CFNumberRef directValue=CFNumberCreate(kCFAllocatorDefault,kCFNumberNSIntegerType,&directAfter);
    CFPreferencesSetValue(directKey,directValue,kCFPreferencesCurrentApplication,
        kCFPreferencesCurrentUser,kCFPreferencesAnyHost);
    CFRelease(directValue);
    BOOL directSynced=CFPreferencesSynchronize(kCFPreferencesCurrentApplication,
        kCFPreferencesCurrentUser,kCFPreferencesAnyHost);
    CFPropertyListRef directNow=CFPreferencesCopyValue(directKey,kCFPreferencesCurrentApplication,
        kCFPreferencesCurrentUser,kCFPreferencesAnyHost);
    NSInteger directObserved=0;
    if(directNow && CFGetTypeID(directNow)==CFNumberGetTypeID())
        CFNumberGetValue((CFNumberRef)directNow,kCFNumberNSIntegerType,&directObserved);
    if(directNow) CFRelease(directNow);
    [self check:directSynced && directObserved==directAfter
         label:@"CFPreferences exact-domain set/copy/synchronize"];
    [self check:[NSUserDefaults.standardUserDefaults integerForKey:
        @"StorageProbe.FullCycle.CFDirectCounter"]==directAfter
         label:@"CFPreferences direct write visible through NSUserDefaults typed getter"];
    [self record:@"cfDirect" before:@(directBefore) after:@(directAfter) migrated:YES];

    // Foundation's shared HTTP cookie store is distinct from WKHTTPCookieStore.
    // Its cross-install behavior is still under investigation, so report it
    // without making the entire full-cycle baseline fail if it is absent.
    NSURL *cookieURL=[NSURL URLWithString:@"https://storageprobe.invalid/"];
    NSHTTPCookieStorage *cookieStore=NSHTTPCookieStorage.sharedHTTPCookieStorage;
    NSInteger oldCookie=0;
    for(NSHTTPCookie *cookie in [cookieStore cookiesForURL:cookieURL] ?: @[]) {
        if([cookie.name isEqualToString:@"StorageProbeFoundationCookie"])
            oldCookie=cookie.value.integerValue;
    }
    NSHTTPCookie *foundationCookie=[NSHTTPCookie cookieWithProperties:@{
        NSHTTPCookieName:@"StorageProbeFoundationCookie",
        NSHTTPCookieValue:[NSString stringWithFormat:@"%ld",(long)(oldCookie+1)],
        NSHTTPCookieDomain:@"storageprobe.invalid",
        NSHTTPCookiePath:@"/",
        NSHTTPCookieExpires:[NSDate dateWithTimeIntervalSinceNow:30*86400]
    }];
    if(foundationCookie) [cookieStore setCookie:foundationCookie];
    [self researchMetric:@"foundationCookie" before:@(oldCookie) after:@(oldCookie+1)];

    // Store a synthetic cache response offline. No network request is made.
    NSURLRequest *request=[NSURLRequest requestWithURL:
        [NSURL URLWithString:@"https://storageprobe.invalid/fullcycle-cached"]];
    NSCachedURLResponse *old=[NSURLCache.sharedURLCache cachedResponseForRequest:request];
    NSData *payload=[@"SideloadPersist synthetic cache" dataUsingEncoding:NSUTF8StringEncoding];
    NSHTTPURLResponse *response=[[NSHTTPURLResponse alloc] initWithURL:request.URL
        statusCode:200 HTTPVersion:@"HTTP/1.1"
        headerFields:@{@"Cache-Control":@"public, max-age=604800"}];
    NSCachedURLResponse *fresh=[[NSCachedURLResponse alloc] initWithResponse:response
        data:payload userInfo:nil storagePolicy:NSURLCacheStorageAllowed];
    [NSURLCache.sharedURLCache storeCachedResponse:fresh forRequest:request];
    NSCachedURLResponse *retrieved=[NSURLCache.sharedURLCache cachedResponseForRequest:request];
    [self check:[retrieved.data isEqualToData:payload] label:@"NSURLCache synthetic response (native cache)"];
    [self record:@"urlCacheSHA256" before:SPFingerprint(old.data)
         after:SPFingerprint(retrieved.data) migrated:NO];

    NSString *tmpPath=[NSTemporaryDirectory() stringByAppendingPathComponent:@"storageprobe-fullcycle.txt"];
    NSString *tmpBefore=[NSString stringWithContentsOfFile:tmpPath encoding:NSUTF8StringEncoding error:nil];
    BOOL tmpOK=[@"synthetic-temp" writeToFile:tmpPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [self check:tmpOK label:@"NSTemporaryDirectory atomic write (not migrated)"];
    [self record:@"tempMarker" before:tmpBefore after:@"synthetic-temp" migrated:NO];
}
- (void)testKeychain {
    NSDictionary *selector=@{
        (__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService:@"com.ravelloh.sideloadpersist.storageprobe.fullcycle",
        (__bridge id)kSecAttrAccount:@"synthetic-counter"
    };
    NSMutableDictionary *query=[selector mutableCopy];
    query[(__bridge id)kSecReturnData]=@YES;
    query[(__bridge id)kSecMatchLimit]=(__bridge id)kSecMatchLimitOne;
    CFTypeRef item=NULL;
    OSStatus found=SecItemCopyMatching((__bridge CFDictionaryRef)query,&item);
    NSData *existing=found==errSecSuccess ? CFBridgingRelease(item) : nil;
    if(found!=errSecSuccess && item) CFRelease(item);
    NSInteger before=existing ? [[[NSString alloc] initWithData:existing encoding:NSUTF8StringEncoding] integerValue] : 0;
    NSInteger after=before+1;
    NSData *payload=[[NSString stringWithFormat:@"%ld",(long)after] dataUsingEncoding:NSUTF8StringEncoding];
    OSStatus updated=errSecSuccess;
    if(found==errSecSuccess) {
        updated=SecItemUpdate((__bridge CFDictionaryRef)selector,
                              (__bridge CFDictionaryRef)@{(__bridge id)kSecValueData:payload});
    } else if(found==errSecItemNotFound) {
        NSMutableDictionary *add=[selector mutableCopy];
        add[(__bridge id)kSecValueData]=payload;
        add[(__bridge id)kSecAttrAccessible]=(__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
        updated=SecItemAdd((__bridge CFDictionaryRef)add,NULL);
    } else updated=found;
    [self line:[NSString stringWithFormat:@"KEYCHAIN_OSSTATUS query=%d update=%d",found,updated]];
    if(updated==errSecMissingEntitlement || found==errSecMissingEntitlement)
        [self skip:@"Keychain synthetic item unavailable under current signature entitlement"];
    else
        [self check:updated==errSecSuccess label:@"Keychain synthetic generic-password CRUD"];
    if(updated==errSecSuccess) [self record:@"keychain" before:@(before) after:@(after) migrated:NO];
}
- (void)testAppGroups {
    NSString *identifier=NSBundle.mainBundle.infoDictionary[@"StorageProbeTestAppGroup"];
    if(!identifier.length) {
        [self skip:@"App Groups: no group identifier configured in test IPA; do not infer entitlement"];
        return;
    }
    NSURL *container=[NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:identifier];
    if(!container) {
        [self skip:[NSString stringWithFormat:@"App Groups container unavailable for %@",identifier]];
        return;
    }
    NSString *file=[[container URLByAppendingPathComponent:@"storageprobe-fullcycle.txt"] path];
    NSString *before=[NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:nil];
    NSString *after=before ?: NSUUID.UUID.UUIDString;
    BOOL good=[after writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [self check:good label:@"App Groups shared-container file I/O"];
    [self record:@"appGroupMarker" before:before after:after migrated:NO];
}
- (void)beginWebKit {
    WKWebViewConfiguration *config=[WKWebViewConfiguration new];
    config.websiteDataStore=WKWebsiteDataStore.defaultDataStore;
    self.webView=[[WKWebView alloc] initWithFrame:CGRectMake(0,0,1,1) configuration:config];
    self.webView.navigationDelegate=self;
    self.webView.alpha=0.01;
    [self.parent.view addSubview:self.webView];
    WKHTTPCookieStore *store=config.websiteDataStore.httpCookieStore;
    [store getAllCookies:^(NSArray<NSHTTPCookie *> *cookies) {
        NSInteger before=0;
        for(NSHTTPCookie *cookie in cookies) {
            if([cookie.name isEqualToString:@"StorageProbeFullCycleCookie"] &&
               [cookie.domain containsString:@"storageprobe.invalid"])
                before=cookie.value.integerValue;
        }
        NSDictionary *properties=@{
            NSHTTPCookieName:@"StorageProbeFullCycleCookie",
            NSHTTPCookieValue:[NSString stringWithFormat:@"%ld",(long)(before+1)],
            NSHTTPCookieDomain:@"storageprobe.invalid",
            NSHTTPCookiePath:@"/",
            NSHTTPCookieExpires:[NSDate dateWithTimeIntervalSinceNow:30*86400]
        };
        NSHTTPCookie *cookie=[NSHTTPCookie cookieWithProperties:properties];
        if(!cookie) {
            [self check:NO label:@"WKHTTPCookieStore could not create synthetic cookie"];
            self.cookieDone=YES;
            [self tryComplete];
            return;
        }
        [store setCookie:cookie completionHandler:^{
            [self check:YES label:@"WKHTTPCookieStore persistent synthetic Cookie"];
            [self record:@"webCookie" before:@(before) after:@(before+1) migrated:YES];
            self.cookieDone=YES;
            [self tryComplete];
        }];
    }];
    [self.webView loadHTMLString:@"<!doctype html><html><body>StorageProbe FullCycle</body></html>"
                       baseURL:[NSURL URLWithString:@"https://storageprobe.invalid/"]];
}
- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self check:NO label:[NSString stringWithFormat:@"WKWebView navigation: %@",error.localizedDescription]];
    self.jsDone=YES; [self tryComplete];
}
- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self check:NO label:[NSString stringWithFormat:@"WKWebView navigation: %@",error.localizedDescription]];
    self.jsDone=YES; [self tryComplete];
}
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    NSString *script=@"let oldLocal=Number(localStorage.getItem('StorageProbeFullCycle'))||0;"
        @"localStorage.setItem('StorageProbeFullCycle',String(oldLocal+1));"
        @"return await new Promise((resolve)=>{try{"
        @"const req=indexedDB.open('StorageProbeFullCycle',1);"
        @"req.onupgradeneeded=()=>{if(!req.result.objectStoreNames.contains('kv'))req.result.createObjectStore('kv');};"
        @"req.onerror=()=>resolve({error:'IndexedDB open failed'});"
        @"req.onsuccess=()=>{const db=req.result;const tx=db.transaction('kv','readwrite');"
        @"const store=tx.objectStore('kv');const get=store.get('counter');let oldIndex=0;"
        @"get.onsuccess=()=>{oldIndex=Number(get.result)||0;store.put(oldIndex+1,'counter');};"
        @"tx.oncomplete=()=>{db.close();resolve({localBefore:oldLocal,localAfter:oldLocal+1,"
        @"indexedBefore:oldIndex,indexedAfter:oldIndex+1});};"
        @"tx.onerror=()=>{db.close();resolve({error:'IndexedDB transaction failed'});};};"
        @"}catch(e){resolve({error:String(e)});}});";
    [webView callAsyncJavaScript:script arguments:@{} inFrame:nil
                 inContentWorld:WKContentWorld.pageWorld completionHandler:^(id result,NSError *error) {
        NSDictionary *response=[result isKindOfClass:NSDictionary.class] ? result : nil;
        if(error || response[@"error"]) {
            [self check:NO label:[NSString stringWithFormat:@"WebKit storage error=%@ %@",
                error.localizedDescription ?: @"none",response[@"error"] ?: @""]];
        } else {
            [self check:YES label:@"WebKit localStorage + IndexedDB transactions"];
            [self record:@"webLocalStorage" before:response[@"localBefore"]
                 after:response[@"localAfter"] migrated:YES];
            [self record:@"webIndexedDB" before:response[@"indexedBefore"]
                 after:response[@"indexedAfter"] migrated:YES];
        }
        self.jsDone=YES;
        [self tryComplete];
    }];
}
- (void)tryComplete {
    if(![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self tryComplete]; });
        return;
    }
    if(self.finished || !self.jsDone || !self.cookieDone) return;
    [self complete:self.failures==0];
}
- (void)complete:(BOOL)valid {
    if(![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self complete:valid]; });
        return;
    }
    if(self.finished) return;
    self.finished=YES;
    NSString *phase=self.verifying ? @"RESTORE_VERIFICATION" : @"PRE_BACKUP_BASELINE";
    NSDictionary *snapshot=@{
        @"format":@"StorageProbe.FullCycle.V2",
        @"installationID":self.installationID ?: @"none",
        @"capturedAt":@([[NSDate date] timeIntervalSince1970]),
        @"values":[self.values copy],
        @"phase":phase,
        @"complete":@(valid)
    };
    NSData *bytes=[NSJSONSerialization dataWithJSONObject:snapshot
                                                options:NSJSONWritingPrettyPrinted error:nil];
    if(bytes) {
        // Never overwrite a valid backup baseline with observations from a
        // broken initialization. A partial diagnostic is not a backup baseline.
        NSString *path=self.verifying ?
            [self.root stringByAppendingPathComponent:@"fullcycle-verification.json"] :
            (valid ? self.snapshotPath : [self.root stringByAppendingPathComponent:@"fullcycle-diagnostics.json"]);
        NSError *error=nil;
        BOOL saved=[bytes writeToFile:path options:NSDataWritingAtomic error:&error];
        [self check:saved label:[NSString stringWithFormat:@"SAVE_REPORT %@",
                     self.verifying?@"fullcycle-verification.json":
                     (valid?@"fullcycle-baseline.json":@"fullcycle-diagnostics.json")]];
        valid=valid && saved;
    } else {
        [self line:@"INCOMPLETE: report serialization failed; no baseline saved"];
    }
    if(!valid) [self line:@"BACKUP_NOT_READY: initialization or data checks failed; diagnostic only. DO NOT delete/reinstall this App based on this run."];
    NSDictionary *(*preferenceHealth)(void)=(NSDictionary *(*)(void))dlsym(RTLD_DEFAULT,"PDPreferencesHealth");
    NSDictionary *preferences=preferenceHealth?preferenceHealth():nil;
    [self line:[NSString stringWithFormat:@"PREFERENCES_STORAGE_FINAL domains=%@ bytes=%@",
        preferences[@"domainFiles"] ?: @"unknown",preferences[@"bytes"] ?: @"unknown"]];
    [self line:[NSString stringWithFormat:@"FULL_CYCLE_SUMMARY phase=%@ pass=%lu fail=%lu skip=%lu",
        phase,(unsigned long)self.passes,(unsigned long)self.failures,(unsigned long)self.skips]];
    if(self.verifying)
        [self line:valid?@"RESTORE_VERIFIED: all checks passed; keep ZIP until satisfied." :
                    @"RESTORE_NOT_VERIFIED: some checks failed; retain ZIP, do not trust this restore."];
    else if(valid)
        [self line:@"BACKUP_BASELINE_READY: fully quit App, archive SideloadPersist to a safe location outside this App, reinstall and import ZIP, then run this test again."];
    else
        [self line:@"BACKUP_ABORTED: no valid baseline generated. Check scope-mapping-result.json and retry after fixing initialization."];
    [self.webView removeFromSuperview];
    self.webView=nil;
    if(self.completionBlock) self.completionBlock();
}
@end
