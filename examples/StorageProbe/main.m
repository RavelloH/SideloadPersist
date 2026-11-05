#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <sqlite3.h>
#import <CoreData/CoreData.h>
#import <WebKit/WebKit.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>

@interface StorageProbeController : UIViewController <WKNavigationDelegate>
@property(nonatomic,strong) UITextView *output;
@property(nonatomic,strong) NSMutableString *history;
@property(nonatomic,strong) WKWebView *webKitProbe;
@end

@implementation StorageProbeController
- (void)line:(NSString *)text {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self line:text]; });
        return;
    }
    if (!self.history) self.history=[NSMutableString string];
    [self.history appendFormat:@"%@\n",text];
    NSLog(@"[StorageProbe] %@",text);
    self.output.text=self.history;
}
- (void)check:(BOOL)good label:(NSString *)label {
    [self line:[NSString stringWithFormat:@"%@ %@",good?@"PASS":@"FAIL",label]];
}
- (UIButton *)button:(NSString *)title action:(SEL)action {
    UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font=[UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor=UIColor.systemBackgroundColor;
    UILabel *label=[[UILabel alloc] init];
    label.text=@"SideloadPersist StorageProbe";
    label.font=[UIFont boldSystemFontOfSize:21];
    label.textAlignment=NSTextAlignmentCenter;
    UILabel *subtitle=[[UILabel alloc] init];
    subtitle.text=@"签名工具中注入新版 SideloadPersist.dylib 后测试。\n此 App 不自动包含插件，用于比较有/无注入的行为。";
    subtitle.font=[UIFont systemFontOfSize:12];
    subtitle.textColor=UIColor.secondaryLabelColor;
    subtitle.numberOfLines=0;
    subtitle.textAlignment=NSTextAlignmentCenter;
    UIButton *run=[self button:@"运行存储 API 测试" action:@selector(runTests)];
    UIButton *copy=[self button:@"复制结果" action:@selector(copyResults)];
    UIButton *repeat=[self button:@"再次运行（验证持久化）" action:@selector(runTests)];
    UIButton *webKit=[self button:@"研究 WebKit / Preferences 存储范围" action:@selector(runExtendedScope)];
    UIStackView *buttons=[[UIStackView alloc] initWithArrangedSubviews:@[run,repeat,webKit,copy]];
    buttons.axis=UILayoutConstraintAxisVertical;
    buttons.spacing=10;
    self.output=[[UITextView alloc] init];
    self.output.font=[UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.output.editable=NO;
    self.output.backgroundColor=UIColor.secondarySystemBackgroundColor;
    self.output.layer.cornerRadius=8;
    UIStackView *stack=[[UIStackView alloc] initWithArrangedSubviews:@[label,subtitle,buttons,self.output]];
    stack.axis=UILayoutConstraintAxisVertical;
    stack.spacing=12;
    stack.translatesAutoresizingMaskIntoConstraints=NO;
    [self.view addSubview:stack];
    UILayoutGuide *safe=self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:safe.topAnchor constant:16],
        [stack.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-16],
        [stack.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [self.output.heightAnchor constraintGreaterThanOrEqualToConstant:120],
    ]];
    [self line:[NSString stringWithFormat:@"iOS=%@ bundle=%@",UIDevice.currentDevice.systemVersion,NSBundle.mainBundle.bundleIdentifier]];
    [self line:@"注入 dylib 后首次运行可能先显示持久化介绍页。关闭后测试。"];
}
- (void)reportScopeFootprints:(NSString *)phase {
    NSString *library=[NSHomeDirectory() stringByAppendingPathComponent:@"Library"];
    NSArray<NSString *> *paths=@[@"WebKit",@"Cookies",@"Caches/com.apple.WebKit.Networking",@"Preferences",@"Caches"];
    NSFileManager *fm=NSFileManager.defaultManager;
    for(NSString *relative in paths) {
        NSString *full=[library stringByAppendingPathComponent:relative];
        BOOL isDir=NO;
        BOOL exists=[fm fileExistsAtPath:full isDirectory:&isDir];
        NSUInteger count=0;
        unsigned long long bytes=0;
        if(exists && isDir) {
            NSDirectoryEnumerator *items=[fm enumeratorAtPath:full];
            NSString *next=nil;
            while(count<5000 && (next=[items nextObject])) {
                NSDictionary *attributes=[fm attributesOfItemAtPath:[full stringByAppendingPathComponent:next] error:nil];
                if([attributes[NSFileType] isEqualToString:NSFileTypeRegular]) {
                    count++;
                    bytes += [attributes[NSFileSize] unsignedLongLongValue];
                }
            }
        }
        [self line:[NSString stringWithFormat:@"SCOPE_FOOTPRINT phase=%@ path=%@ exists=%@ files=%lu bytes=%llu%@",
            phase,relative,exists?@"yes":@"no",(unsigned long)count,bytes,
            count>=5000 ? @" capped" : @""]];
    }
}
- (void)reportWebsiteRecords {
    NSSet<NSString *> *types=[NSSet setWithArray:@[WKWebsiteDataTypeLocalStorage,
        WKWebsiteDataTypeIndexedDBDatabases,WKWebsiteDataTypeCookies,WKWebsiteDataTypeDiskCache]];
    [WKWebsiteDataStore.defaultDataStore fetchDataRecordsOfTypes:types
        completionHandler:^(NSArray<WKWebsiteDataRecord *> *records) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSUInteger local=0,cookies=0,indexed=0;
                for(WKWebsiteDataRecord *record in records) {
                    if([record.dataTypes containsObject:WKWebsiteDataTypeLocalStorage]) local++;
                    if([record.dataTypes containsObject:WKWebsiteDataTypeCookies]) cookies++;
                    if([record.dataTypes containsObject:WKWebsiteDataTypeIndexedDBDatabases]) indexed++;
                }
                [self line:[NSString stringWithFormat:@"WEBKIT_DATA_RECORDS total=%lu localStorage=%lu indexedDB=%lu cookies=%lu",
                    (unsigned long)records.count,(unsigned long)local,(unsigned long)indexed,(unsigned long)cookies]];
            });
        }];
}
- (void)runExtendedScope {
    NSString *library=[NSHomeDirectory() stringByAppendingPathComponent:@"Library"];
    NSArray<NSString *> *names=@[@"WebKit",@"Preferences",@"Cookies",@"Caches",@"Saved Application State"];
    [self line:@"=== WebKit & Preferences research probe ==="];
    NSString *persistRoot=[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/SideloadPersist"];
    NSData *manifestData=[NSData dataWithContentsOfFile:[persistRoot stringByAppendingPathComponent:@"manifest.json"]];
    NSData *receiptData=[NSData dataWithContentsOfFile:[persistRoot stringByAppendingPathComponent:@"restore-last.json"]];
    NSDictionary *manifest=manifestData ? [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:nil] : nil;
    NSDictionary *receipt=receiptData ? [NSJSONSerialization JSONObjectWithData:receiptData options:0 error:nil] : nil;
    [self line:[NSString stringWithFormat:@"PERSISTENCE_MANIFEST format=%@ scopes=%@",
        manifest[@"format"] ?: @"unknown",manifest[@"scopes"] ?: @[]]];
    [self line:[NSString stringWithFormat:@"RESTORE_V2_LAST result=%@ scopes=%@ id=%@",
        receipt[@"result"] ?: @"not-recorded",receipt[@"scopes"] ?: @[],receipt[@"id"] ?: @"none"]];
    NSString *statusFile=[NSHomeDirectory() stringByAppendingPathComponent:
        @"Documents/SideloadPersist/webkit-experiment-result.txt"];
    NSString *status=[NSString stringWithContentsOfFile:statusFile encoding:NSUTF8StringEncoding error:nil];
    [self line:[NSString stringWithFormat:@"WEBKIT_RELOCATION_MODE=%@",status ?: @"off"]];
    for(NSString *name in @[@"WebKit",@"Cookies"]) {
        NSString *source=[library stringByAppendingPathComponent:name];
        NSString *target=[NSHomeDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"Documents/SideloadPersist/Data/%@",name]];
        char bytes[4096]={0};
        ssize_t length=readlink(source.fileSystemRepresentation,bytes,sizeof(bytes)-1);
        BOOL linked=length>0 && [target isEqualToString:[NSString stringWithUTF8String:bytes]];
        [self line:[NSString stringWithFormat:@"EXPERIMENT_LINK %@=%@",name,linked?@"yes":@"no"]];
    }
    [self reportScopeFootprints:@"before"];
    NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;
    NSInteger previous=[defaults integerForKey:@"StorageProbe.ExtendedPreferencesCounter"];
    [defaults setInteger:previous+1 forKey:@"StorageProbe.ExtendedPreferencesCounter"];
    [self line:[NSString stringWithFormat:@"PREFERENCES_COUNTER before=%ld after=%ld (compare across real cold starts)",
                 (long)previous,(long)previous+1]];
    for (NSString *name in names) {
        NSString *p=[library stringByAppendingPathComponent:name];
        BOOL isDirectory=NO;
        BOOL exists=[[NSFileManager defaultManager] fileExistsAtPath:p isDirectory:&isDirectory];
        NSArray<NSString *> *contents=exists && isDirectory ?
            [[NSFileManager defaultManager] contentsOfDirectoryAtPath:p error:nil] : nil;
        [self line:[NSString stringWithFormat:@"LIBRARY_SCOPE %@: exists=%@ entries=%lu",
            name,exists?@"yes":@"no",(unsigned long)contents.count]];
    }
    NSString *prefs=[library stringByAppendingPathComponent:@"Preferences"];
    NSString *prefsFile=[prefs stringByAppendingPathComponent:
        [NSString stringWithFormat:@"%@.plist",NSBundle.mainBundle.bundleIdentifier ?: @"unknown"]];
    [self line:[NSString stringWithFormat:@"DEFAULTS_PLIST_PRESENT=%@ (current process may cache writes)",
        [[NSFileManager defaultManager] fileExistsAtPath:prefsFile]?@"yes":@"no"]];
    if (!self.webKitProbe) {
        WKWebViewConfiguration *config=[WKWebViewConfiguration new];
        config.websiteDataStore=WKWebsiteDataStore.defaultDataStore;
        self.webKitProbe=[[WKWebView alloc] initWithFrame:CGRectMake(0,0,1,1) configuration:config];
        self.webKitProbe.navigationDelegate=self;
        self.webKitProbe.alpha=0.01;
        [self.view addSubview:self.webKitProbe];
    }
    // CookieStore is mediated by WebKit's separate network process, and may
    // live outside Library/WebKit. Only the synthetic probe cookie is touched.
    WKHTTPCookieStore *cookies=self.webKitProbe.configuration.websiteDataStore.httpCookieStore;
    [cookies getAllCookies:^(NSArray<NSHTTPCookie *> *allCookies) {
        NSInteger oldValue=0;
        for(NSHTTPCookie *cookie in allCookies) {
            if([cookie.name isEqualToString:@"SideloadPersistStorageProbe"] &&
               [cookie.domain containsString:@"storageprobe.invalid"]) {
                oldValue=cookie.value.integerValue;
                break;
            }
        }
        NSDictionary *properties=@{
           NSHTTPCookieName: @"SideloadPersistStorageProbe",
           NSHTTPCookieValue: [NSString stringWithFormat:@"%ld",(long)(oldValue+1)],
           NSHTTPCookieDomain: @"storageprobe.invalid",
           NSHTTPCookiePath: @"/",
           NSHTTPCookieExpires: [NSDate dateWithTimeIntervalSinceNow:60*60*24*30]
        };
        NSHTTPCookie *cookie=[NSHTTPCookie cookieWithProperties:properties];
        if (!cookie) {
            [self line:@"WEBKIT_COOKIE_ERROR: could not construct test cookie"];
            return;
        }
        [cookies setCookie:cookie completionHandler:^{
            [self line:[NSString stringWithFormat:@"WEBKIT_COOKIE_COUNTER before=%ld after=%ld",
                (long)oldValue,(long)(oldValue+1)]];
            [self reportWebsiteRecords];
        }];
    }];
    [self line:@"WEBKIT_TEST: loading local HTML using a stable base URL (no network navigation expected)"];
    [self.webKitProbe loadHTMLString:@"<!doctype html><html><body>StorageProbe WebKit</body></html>"
                                  baseURL:[NSURL URLWithString:@"https://storageprobe.invalid/"]];
}
- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self line:[NSString stringWithFormat:@"WEBKIT_NAVIGATION_ERROR=%@",error.localizedDescription]];
}
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    NSString *script=@"(function(){try{var k='SideloadPersistProbe';var before=localStorage.getItem(k);var after=String((Number(before)||0)+1);localStorage.setItem(k,after);return JSON.stringify({before:before,after:after});}catch(e){return 'ERROR:'+String(e);}})()";
    [webView evaluateJavaScript:script completionHandler:^(id value,NSError *error) {
        [self line:[NSString stringWithFormat:@"WEBKIT_LOCALSTORAGE=%@ error=%@",
                    value ?: @"none",error.localizedDescription ?: @"none"]];
        NSString *path=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/WebKit"];
        [self line:[NSString stringWithFormat:@"WEBKIT_LIBRARY_DIR_EXISTS=%@",
                    [[NSFileManager defaultManager] fileExistsAtPath:path] ? @"yes":@"no"]];
        NSString *indexedScript=@"return await new Promise((resolve) => { try { const request=indexedDB.open('SideloadPersistStorageProbe',1); request.onupgradeneeded=() => { if (!request.result.objectStoreNames.contains('values')) request.result.createObjectStore('values'); }; request.onerror=() => resolve('open failed: '+request.error); request.onsuccess=() => { const database=request.result; const tx=database.transaction('values','readwrite'); const store=tx.objectStore('values'); const get=store.get('counter'); let oldValue=0; get.onsuccess=() => { oldValue=Number(get.result)||0; store.put(oldValue+1,'counter'); }; tx.oncomplete=() => { database.close(); resolve(JSON.stringify({before:oldValue,after:oldValue+1})); }; tx.onerror=() => { database.close(); resolve('transaction failed: '+tx.error); }; }; } catch(error) { resolve('exception: '+String(error)); } });";
        [webView callAsyncJavaScript:indexedScript arguments:@{} inFrame:nil
                           inContentWorld:WKContentWorld.pageWorld
                        completionHandler:^(id value,NSError *jsError) {
            [self line:[NSString stringWithFormat:@"WEBKIT_INDEXEDDB=%@ error=%@",
                value ?: @"none",jsError.localizedDescription ?: @"none"]];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(2*NSEC_PER_SEC)),
                           dispatch_get_main_queue(),^{
                [self reportScopeFootprints:@"after"];
                [self reportWebsiteRecords];
            });
        }];
    }];
}
- (void)runTests {
    self.history=[NSMutableString string];
    [self line:[NSString stringWithFormat:@"StorageProbe %@ / %@",
        UIDevice.currentDevice.systemVersion,NSBundle.mainBundle.bundleIdentifier]];
    NSUserDefaults *defaults=[NSUserDefaults standardUserDefaults];
    NSString *installationID=[defaults stringForKey:@"StorageProbe.InstallationID"];
    if (!installationID.length) {
        installationID=NSUUID.UUID.UUIDString;
        [defaults setObject:installationID forKey:@"StorageProbe.InstallationID"];
    }
    [self line:[NSString stringWithFormat:@"INSTALLATION_ID=%@ (App-local; changes after uninstall)",installationID]];
    NSString *home=NSHomeDirectory();
    NSString *source=[home stringByAppendingPathComponent:@"Library/Application Support"];
    NSString *target=[home stringByAppendingPathComponent:@"Documents/SideloadPersist/Data/Application Support"];
    char buffer[4096]={0};
    ssize_t length=readlink(source.fileSystemRepresentation,buffer,sizeof(buffer)-1);
    BOOL linked=length>0 && [target isEqualToString:[NSString stringWithUTF8String:buffer]];
    [self check:linked label:@"Application Support symlink (expected only with plugin)"];
    [self line:[NSString stringWithFormat:@"Documents visible folder exists=%@",
        [[NSFileManager defaultManager] fileExistsAtPath:[home stringByAppendingPathComponent:@"Documents/SideloadPersist"]] ? @"yes":@"no"]];
    NSString *test=[source stringByAppendingPathComponent:@"StorageProbe"];
    NSError *error=nil;
    BOOL mk=[[NSFileManager defaultManager] createDirectoryAtPath:test
          withIntermediateDirectories:YES attributes:nil error:&error];
    [self check:mk label:[NSString stringWithFormat:@"NSFileManager createDirectory %@",error ?: @""]];
    NSString *markerPath=[test stringByAppendingPathComponent:@"persistent-marker.txt"];
    NSString *dataMarker=[NSString stringWithContentsOfFile:markerPath encoding:NSUTF8StringEncoding error:nil];
    BOOL markerExists=dataMarker.length>0;
    if (!markerExists) {
        dataMarker=NSUUID.UUID.UUIDString;
        [dataMarker writeToFile:markerPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    [self line:[NSString stringWithFormat:@"PERSISTENT_DATA_MARKER=%@ (%@)",
                 dataMarker ?: @"ERROR",markerExists ? @"restored/existing" : @"newly created"]];
    [self check:dataMarker.length>0 label:@"Persistent marker read/write through symlink"];
    NSString *stringFile=[test stringByAppendingPathComponent:@"nsdata.txt"];
    NSData *payload=[@"HELLO_FOUNDATION_2026" dataUsingEncoding:NSUTF8StringEncoding];
    BOOL wroteNSData=[payload writeToFile:stringFile options:NSDataWritingAtomic error:&error];
    [self check:wroteNSData && [[[NSData dataWithContentsOfFile:stringFile] description] length]>0
          label:@"NSData atomic write / read"];
    BOOL exists=[[NSFileManager defaultManager] fileExistsAtPath:stringFile];
    [self check:exists label:@"NSFileManager fileExistsAtPath"];
    NSString *posix=[test stringByAppendingPathComponent:@"posix.bin"];
    int fd=open(posix.fileSystemRepresentation,O_WRONLY|O_CREAT|O_TRUNC,0600);
    BOOL posixGood=fd>=0;
    if (fd>=0) {const char bytes[]="PERSIST_POSIX"; posixGood=write(fd,bytes,sizeof(bytes))==(ssize_t)sizeof(bytes); close(fd);}
    struct stat statbuf={0};
    posixGood=posixGood && stat(posix.fileSystemRepresentation,&statbuf)==0 && statbuf.st_size>0;
    [self check:posixGood label:@"POSIX open/write/close/stat"];
    NSString *stdio=[test stringByAppendingPathComponent:@"stdio.txt"];
    FILE *f=fopen(stdio.fileSystemRepresentation,"wb");
    BOOL stdioGood=f!=NULL;
    if(f) {stdioGood=fputs("HELLO_STDIO",f)>=0; fclose(f);}
    [self check:stdioGood label:@"C stdio fopen/fputs"];
    NSString *handle=[test stringByAppendingPathComponent:@"handle.bin"];
    [[NSFileManager defaultManager] createFileAtPath:handle contents:[NSData data] attributes:nil];
    NSFileHandle *fh=[NSFileHandle fileHandleForWritingAtPath:handle];
    BOOL handleOK=fh!=nil;
    @try {
        if (fh) {[fh writeData:payload]; [fh closeFile];}
    } @catch(NSException *e) { handleOK=NO; }
    [self check:handleOK label:@"NSFileHandle writeData"];
    NSString *sqlite=[test stringByAppendingPathComponent:@"database.sqlite"];
    sqlite3 *db=NULL;
    sqlite3_int64 sqliteBefore=-1,sqliteAfter=-1;
    int sqlStatus=sqlite3_open(sqlite.fileSystemRepresentation,&db);
    BOOL sqlGood=sqlStatus==SQLITE_OK;
    if(sqlGood) {
        char *errMsg=NULL;
        sqlGood=sqlite3_exec(db,"PRAGMA journal_mode=WAL; CREATE TABLE IF NOT EXISTS t(k INTEGER PRIMARY KEY, v TEXT);",NULL,NULL,&errMsg)==SQLITE_OK;
        if(errMsg) { sqlite3_free(errMsg);errMsg=NULL; }
        sqlite3_stmt *countStatement=NULL;
        if(sqlGood && sqlite3_prepare_v2(db,"SELECT COUNT(*) FROM t",-1,&countStatement,NULL)==SQLITE_OK) {
            if(sqlite3_step(countStatement)==SQLITE_ROW) sqliteBefore=sqlite3_column_int64(countStatement,0);
        }
        if(countStatement) sqlite3_finalize(countStatement);
        if(sqliteBefore<0) sqlGood=NO;
        if(sqlGood) sqlGood=sqlite3_exec(db,"INSERT INTO t(v) VALUES ('persisted');",NULL,NULL,&errMsg)==SQLITE_OK;
        if(errMsg) sqlite3_free(errMsg);
        sqlite3_close(db); db=NULL;
    }
    if (sqlite3_open(sqlite.fileSystemRepresentation,&db)==SQLITE_OK) {
        sqlite3_stmt *stmt=NULL;
        if(sqlGood && sqlite3_prepare_v2(db,"SELECT COUNT(*) FROM t",-1,&stmt,NULL)==SQLITE_OK &&
           sqlite3_step(stmt)==SQLITE_ROW) sqliteAfter=sqlite3_column_int64(stmt,0);
        else sqlGood=NO;
        if(stmt) sqlite3_finalize(stmt);
        sqlite3_close(db);
    } else sqlGood=NO;
    sqlGood=sqlGood && sqliteBefore>=0 && sqliteAfter==sqliteBefore+1;
    [self check:sqlGood label:@"SQLite WAL create/insert/reopen/query"];
    [self line:[NSString stringWithFormat:@"SQLITE_ROWS: before=%lld after=%lld",sqliteBefore,sqliteAfter]];

    // CoreData's SQLite store goes through the same filesystem path, without
    // relying on any Objective-C method swizzling in the plugin.
    NSEntityDescription *entity=[[NSEntityDescription alloc] init];
    entity.name=@"Item"; entity.managedObjectClassName=@"NSManagedObject";
    NSAttributeDescription *attribute=[[NSAttributeDescription alloc] init];
    attribute.name=@"name"; attribute.attributeType=NSStringAttributeType; attribute.optional=YES;
    entity.properties=@[attribute];
    NSManagedObjectModel *model=[[NSManagedObjectModel alloc] init];
    model.entities=@[entity];
    NSPersistentStoreCoordinator *coordinator=[[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
    NSString *coredata=[test stringByAppendingPathComponent:@"coredata.sqlite"];
    NSError *coreError=nil;
    NSPersistentStore *store=[coordinator addPersistentStoreWithType:NSSQLiteStoreType
       configuration:nil URL:[NSURL fileURLWithPath:coredata] options:nil error:&coreError];
    BOOL coreGood=(store!=nil);
    NSInteger coreBefore=-1,coreAfter=-1;
    if(store) {
        NSManagedObjectContext *ctx=[[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
        ctx.persistentStoreCoordinator=coordinator;
        NSFetchRequest *request=[NSFetchRequest fetchRequestWithEntityName:@"Item"];
        coreBefore=[ctx countForFetchRequest:request error:&coreError];
        NSManagedObject *item=[NSEntityDescription insertNewObjectForEntityForName:@"Item" inManagedObjectContext:ctx];
        [item setValue:@"test" forKey:@"name"];
        coreGood=([ctx save:&coreError] && coreGood);
        coreAfter=[ctx countForFetchRequest:request error:&coreError];
        coreGood=coreGood && coreBefore>=0 && coreAfter==coreBefore+1;
        [coordinator removePersistentStore:store error:nil];
    }
    [self check:coreGood label:@"CoreData SQLite persistent store"];
    [self line:[NSString stringWithFormat:@"COREDATA_ROWS: before=%ld after=%ld",(long)coreBefore,(long)coreAfter]];
    [[NSUserDefaults standardUserDefaults] setInteger:42 forKey:@"StorageProbe.Test"];
    [self check:[[NSUserDefaults standardUserDefaults] integerForKey:@"StorageProbe.Test"]==42
          label:@"NSUserDefaults (not redirected; App-local)"];
    [self check:[[NSFileManager defaultManager] fileExistsAtPath:
       [target stringByAppendingPathComponent:@"StorageProbe/database.sqlite"]]
          label:@"Real SQLite data in Documents/SideloadPersist/Data"];
    [self line:@"严格恢复测试：删除 App 前记录 INSTALLATION_ID、PERSISTENT_DATA_MARKER 和数据库条数；恢复后前者应变化，标记应保持，数据库数量应接续增加。"];
}
- (void)copyResults {
    UIPasteboard.generalPasteboard.string=self.history;
}
@end

@interface StorageProbeSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic,strong) UIWindow *window;
@end
@implementation StorageProbeSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    if (![scene isKindOfClass:[UIWindowScene class]]) return;
    self.window=[[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController=[[StorageProbeController alloc] init];
    [self.window makeKeyAndVisible];
}
@end
@interface StorageProbeAppDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation StorageProbeAppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options { return YES; }
@end
int main(int argc,char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc,argv,nil,NSStringFromClass([StorageProbeAppDelegate class])); }
}
