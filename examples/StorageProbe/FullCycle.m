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
#import <unistd.h>

static NSString *SPFingerprint(NSData *data) {
    if (!data) return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]={0};
    CC_SHA256(data.bytes,(CC_LONG)data.length,digest);
    NSMutableString *result=[NSMutableString string];
    for(NSUInteger i=0;i<sizeof(digest);i++) [result appendFormat:@"%02x",digest[i]];
    return result;
}
static NSInteger SPInt(id value) {
    return [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : 0;
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
    if(migrated) [self compare:key actual:before];
    else if(self.verifying) {
        id expected=[self.baseline[@"values"] isKindOfClass:NSDictionary.class] ?
                     self.baseline[@"values"][key] : nil;
        [self line:[NSString stringWithFormat:@"OBS NATIVE_NOT_IN_ZIP %@ baseline=%@ current=%@",
                    key,expected ?: @"missing",before ?: @"missing"]];
    }
}
- (void)start {
    NSFileManager *fm=NSFileManager.defaultManager;
    NSString *home=NSHomeDirectory();
    self.root=[home stringByAppendingPathComponent:@"Documents/SideloadPersist"];
    NSString *data=[self.root stringByAppendingPathComponent:@"Data/Application Support/StorageProbe"];
    self.snapshotPath=[data stringByAppendingPathComponent:@"fullcycle-baseline.json"];
    [fm createDirectoryAtPath:data withIntermediateDirectories:YES attributes:nil error:nil];
    NSUserDefaults *prefs=NSUserDefaults.standardUserDefaults;
    NSString *install=[prefs stringForKey:@"StorageProbe.FullCycle.InstallationID"];
    if(!install.length) {
        install=NSUUID.UUID.UUIDString;
        [prefs setObject:install forKey:@"StorageProbe.FullCycle.InstallationID"];
    }
    self.installationID=install;
    id loaded=SPJSON(self.snapshotPath);
    self.baseline=[loaded isKindOfClass:NSDictionary.class] &&
        [loaded[@"format"] isEqual:@"StorageProbe.FullCycle.V1"] ? loaded : nil;
    NSString *previous=self.baseline[@"installationID"];
    self.verifying=(previous.length && ![previous isEqualToString:install]);
    [self line:@"===== ONE-TAP FULL STORAGE CYCLE / v1 ====="];
    [self line:[NSString stringWithFormat:@"PHASE=%@ installation=%@ baselineInstallation=%@",
        self.verifying?@"RESTORED_INSTALLATION_VERIFY":@"GENERATE_BACKUP_BASELINE",
        install,previous ?: @"none"]];
    if(self.baseline && !self.verifying)
        [self line:@"NOTE This installation has a baseline; it will be refreshed after all tests finish."];
    if(!self.baseline)
        [self line:@"NOTE No earlier full-cycle baseline found. This run prepares the FIRST backup; it cannot verify an older archive."];
    NSDictionary *manifest=SPJSON([self.root stringByAppendingPathComponent:@"manifest.json"]);
    NSDictionary *receipt=SPJSON([self.root stringByAppendingPathComponent:@"restore-last.json"]);
    [self line:[NSString stringWithFormat:@"PERSISTENCE_MANIFEST %@ scopes=%@",
        manifest[@"format"] ?: @"absent",manifest[@"scopes"] ?: @[]]];
    [self line:[NSString stringWithFormat:@"RESTORE_RECEIPT result=%@ scopes=%@",
        receipt[@"result"] ?: @"absent",receipt[@"scopes"] ?: @[]]];
    for(NSString *scope in @[@"Application Support",@"WebKit",@"Cookies"]) {
        NSString *original=[home stringByAppendingPathComponent:
            [@"Library" stringByAppendingPathComponent:scope]];
        NSString *destination=[self.root stringByAppendingPathComponent:
            [@"Data" stringByAppendingPathComponent:scope]];
        char buffer[4096]={0};
        ssize_t len=readlink(original.fileSystemRepresentation,buffer,sizeof(buffer)-1);
        BOOL matching=len>0 && [destination isEqualToString:[NSString stringWithUTF8String:buffer]];
        [self check:matching label:[NSString stringWithFormat:@"SCOPE_LINK %@",scope]];
    }
    if(self.verifying)
        [self check:[receipt[@"result"] isEqualToString:@"committed"]
             label:@"RESTORE_RECEIPT committed after reinstall"];
    [self testFiles:data];
    [self testSQLite:data];
    [self testCoreData:data];
    [self testUnmigrated];
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
         label:@"NSUserDefaults read/write (not redirected)"];
    CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
    [self record:@"userDefaults" before:@(before) after:@(before+1) migrated:NO];
    NSUserDefaults *suite=[[NSUserDefaults alloc] initWithSuiteName:@"com.ravelloh.storageprobe.fullcycle.suite"];
    if(suite) {
        NSInteger original=[suite integerForKey:@"StorageProbe.FullCycle.SuiteCounter"];
        [suite setInteger:original+1 forKey:@"StorageProbe.FullCycle.SuiteCounter"];
        [self check:[suite integerForKey:@"StorageProbe.FullCycle.SuiteCounter"]==original+1
             label:@"NSUserDefaults custom suite read/write (native-local)"];
        [self record:@"defaultsSuite" before:@(original) after:@(original+1) migrated:NO];
    } else [self skip:@"NSUserDefaults custom suite unavailable"];

    NSString *cache=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/StorageProbe-fullcycle.bin"];
    NSData *previous=[NSData dataWithContentsOfFile:cache];
    [self record:@"cacheFileHash" before:SPFingerprint(previous)
                                  after:SPFingerprint(previous) migrated:NO];
    BOOL wrote=[@"SideloadPersist-cache" writeToFile:cache atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [self check:wrote label:@"Library/Caches writable (not migrated)"];

    NSString *prefsDir=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Preferences"];
    struct stat st={0};
    BOOL isLink=lstat(prefsDir.fileSystemRepresentation,&st)==0 && S_ISLNK(st.st_mode);
    [self line:[NSString stringWithFormat:@"PREFERENCES_DIRECTORY_SYMLINK=%@ (expected no)",
                  isLink?@"yes":@"no"]];
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
    if(self.finished || !self.jsDone || !self.cookieDone) return;
    [self complete:self.failures==0];
}
- (void)complete:(BOOL)valid {
    if(self.finished) return;
    self.finished=YES;
    NSString *phase=self.verifying ? @"RESTORE_VERIFICATION" : @"PRE_BACKUP_BASELINE";
    NSDictionary *snapshot=@{
        @"format":@"StorageProbe.FullCycle.V1",
        @"installationID":self.installationID ?: @"none",
        @"capturedAt":@([[NSDate date] timeIntervalSince1970]),
        @"values":[self.values copy],
        @"phase":phase,
        @"complete":@(valid)
    };
    NSData *bytes=[NSJSONSerialization dataWithJSONObject:snapshot
                                                options:NSJSONWritingPrettyPrinted error:nil];
    if(bytes) {
        NSString *path=self.verifying ?
            [self.root stringByAppendingPathComponent:@"fullcycle-verification.json"] : self.snapshotPath;
        NSError *error=nil;
        BOOL saved=[bytes writeToFile:path options:NSDataWritingAtomic error:&error];
        [self check:saved label:[NSString stringWithFormat:@"SAVE_REPORT %@",
                     self.verifying?@"fullcycle-verification.json":@"fullcycle-baseline.json"]];
    } else {
        [self line:@"INCOMPLETE: report serialization failed; no baseline saved"];
    }
    if(!valid) [self line:@"WARNING: PARTIAL test results were saved. Missing/failed checks must be examined before relying on this backup."];
    [self line:[NSString stringWithFormat:@"FULL_CYCLE_SUMMARY phase=%@ pass=%lu fail=%lu skip=%lu",
        phase,(unsigned long)self.passes,(unsigned long)self.failures,(unsigned long)self.skips]];
    [self line:self.verifying ?
        @"RESTORE_TEST_FINISHED: compare PASS/FAIL; keep backup ZIP until satisfied." :
        @"BACKUP_BASELINE_READY: fully quit the App, archive the entire SideloadPersist folder, copy the ZIP OUTSIDE this App, reinstall, import ZIP, relaunch, then press the SAME button."];
    [self.webView removeFromSuperview];
    self.webView=nil;
    if(self.completionBlock) self.completionBlock();
}
@end
