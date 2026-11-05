#import <Foundation/Foundation.h>
#import <sys/stat.h>
#import <unistd.h>
#import <stdlib.h>
#import <string.h>
#import "PDStorage.h"
#import "PDArchive.h"
#import "PDExperimentalScope.h"
#import "PDV2Archive.h"
#import "PDReadme.h"
#import "miniz.h"

static void check(BOOL yes,NSString *message) {
    if(!yes) { NSLog(@"FAIL %@",message); exit(1); }
    NSLog(@"PASS %@",message);
}
static void put(NSString *path,NSString *value) {
    NSError *error=nil;
    check([NSFileManager.defaultManager createDirectoryAtPath:[path stringByDeletingLastPathComponent]
         withIntermediateDirectories:YES attributes:nil error:&error],@"create parent");
    check([value writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error],
          [NSString stringWithFormat:@"write %@",[path lastPathComponent]]);
}
static NSString *readFile(NSString *path) {
    return [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
}
static void makeUnsupportedArchive(NSString *path) {
    mz_zip_archive zip={0};
    check(mz_zip_writer_init_file(&zip,path.fileSystemRepresentation,0),@"create unsupported ZIP");
    for(NSString *name in @[@"SideloadPersist/Data/Application Support/file.txt",
                           @"SideloadPersist/Data/Unsupported/config.plist"]) {
        check(mz_zip_writer_add_mem(&zip,name.UTF8String,"X",1,MZ_BEST_SPEED),@"add unsupported scope fixture");
    }
    check(mz_zip_writer_finalize_archive(&zip),@"finalize unsupported ZIP");
    mz_zip_writer_end(&zip);
}
static void makeArchive(NSString *path,BOOL omitCookies,BOOL withPreferences) {
    mz_zip_archive zip={0};
    check(mz_zip_writer_init_file(&zip,path.fileSystemRepresentation,0),@"create v2 ZIP");
    NSMutableDictionary<NSString *,NSString *> *entries=[@{
        @"SideloadPersist/manifest.json":@"{\"format\":\"SideloadPersist.Directory.V2\",\"scopes\":[\"Application Support\",\"WebKit\",\"Cookies\"]}",
        @"SideloadPersist/Data/Application Support/test.sqlite":@"APP_RESTORED",
        @"SideloadPersist/Data/WebKit/localstorage.db":@"WEB_RESTORED",
        @"SideloadPersist/Data/Cookies/Cookies.binarycookies":@"COOKIE_RESTORED",
        @"SideloadPersist/Backups/unrelated.txt":@"MUST_NOT_IMPORT",
        @"__MACOSX/SideloadPersist/Data/WebKit/._localstorage.db":@"MAC_METADATA"
    } mutableCopy];
    if(withPreferences) {
        entries[@"SideloadPersist/manifest.json"]=@"{\"format\":\"SideloadPersist.Directory.V3\",\"scopes\":[\"Application Support\",\"WebKit\",\"Cookies\",\"Preferences\"]}";
        entries[@"SideloadPersist/Data/Preferences/testprefs.plist"]=@"PREF_RESTORED";
    }
    if(omitCookies) [entries removeObjectForKey:@"SideloadPersist/Data/Cookies/Cookies.binarycookies"];
    for(NSString *name in entries) {
        NSData *data=[entries[name] dataUsingEncoding:NSUTF8StringEncoding];
        check(mz_zip_writer_add_mem(&zip,name.UTF8String,data.bytes,data.length,MZ_BEST_SPEED),
              [NSString stringWithFormat:@"add v2 ZIP entry %@",name]);
    }
    check(mz_zip_writer_finalize_archive(&zip),@"finalize v2 ZIP");
    mz_zip_writer_end(&zip);
}
int main(int argc,char **argv) {
    @autoreleasepool {
        check(argc==2,@"required test mode");
        NSString *home=[NSString stringWithUTF8String:getenv("HOME")];
        NSString *root=[home stringByAppendingPathComponent:@"Documents/SideloadPersist"];
        NSString *data=[root stringByAppendingPathComponent:@"Data"];
        NSString *app=[data stringByAppendingPathComponent:@"Application Support"];
        NSString *web=[data stringByAppendingPathComponent:@"WebKit"];
        NSString *cookie=[data stringByAppendingPathComponent:@"Cookies"];
        NSString *prefsDir=[data stringByAppendingPathComponent:@"Preferences"];
        NSString *pending=[root stringByAppendingPathComponent:@"restore-pending.txt"];
        NSFileManager *fm=NSFileManager.defaultManager;
        if(strcmp(argv[1],"prepare-empty-target")==0) {
            NSString *prefSource=[home stringByAppendingPathComponent:@"Library/Preferences/current.plist"];
            put(prefSource,@"PREF_ORIGINAL");
            check([fm createDirectoryAtPath:prefsDir withIntermediateDirectories:YES attributes:nil error:nil],
                  @"pre-existing empty target directory");
            check(PDStorageBootstrap()==PDStorageStateRecovered,
                  @"nonempty original and empty target are merged by atomic rename");
            struct stat st={0};
            check(lstat([home stringByAppendingPathComponent:@"Library/Preferences"].fileSystemRepresentation,&st)==0 &&
                  S_ISLNK(st.st_mode),@"Preferences now a verified symlink");
            check([readFile([prefsDir stringByAppendingPathComponent:@"current.plist"])
                  isEqualToString:@"PREF_ORIGINAL"],@"original Preferences content preserved");
            NSDictionary *manifest=[NSJSONSerialization JSONObjectWithData:
                  [NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:@"manifest.json"]]
                  options:0 error:nil];
            check([manifest[@"format"] isEqualToString:@"SideloadPersist.Directory.V3"],
                  @"V3 manifest after successful empty-target migration");
        } else if(strcmp(argv[1],"prepare-foreign-link")==0) {
            NSString *foreign=[home stringByAppendingPathComponent:@"Library/PreferencesOld"];
            put([foreign stringByAppendingPathComponent:@"original.plist"],@"PREF_EXTERNAL_LINK");
            NSString *link=[home stringByAppendingPathComponent:@"Library/Preferences"];
            check(symlink(foreign.fileSystemRepresentation,link.fileSystemRepresentation)==0,
                  @"simulate system-owned Preferences symlink");
            check(PDStorageBootstrap()==PDStorageStateRecovered,
                  @"foreign Preferences link does not prevent core bootstrap");
            check([readFile([link stringByAppendingPathComponent:@"original.plist"])
                  isEqualToString:@"PREF_EXTERNAL_LINK"],
                  @"foreign link data intact");
            NSDictionary *diag=[NSJSONSerialization JSONObjectWithData:
                  [NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:@"scope-mapping-result.json"]]
                  options:0 error:nil];
            BOOL found=NO;
            for(NSDictionary *entry in diag[@"scopes"]) {
                if([entry[@"scope"] isEqualToString:@"Preferences"] &&
                   [entry[@"reason"] isEqualToString:@"source-is-foreign-or-broken-symlink"])
                    found=YES;
            }
            check(found,@"diagnostic identifies foreign Preferences symlink");
        } else if(strcmp(argv[1],"prepare-conflict")==0) {
            // Reproduce the exact regression: Preferences has an incompatible
            // pre-existing source and target, but other scopes are mountable.
            NSString *original=[home stringByAppendingPathComponent:@"Library/Preferences/user.plist"];
            NSString *saved=[prefsDir stringByAppendingPathComponent:@"old.plist"];
            put(original,@"CURRENT_USER_PREFS");
            put(saved,@"ALREADY_SAVED_PREFS");
            check(PDStorageBootstrap()==PDStorageStateRecovered,
                  @"conflicting Preferences must not prevent AppSupport bootstrap");
            check(PDStorageIsLinked(),@"core AppSupport symlink active despite optional conflict");
            struct stat st={0};
            for(NSString *scope in @[@"WebKit",@"Cookies"]) {
                NSString *src=[home stringByAppendingPathComponent:
                    [@"Library" stringByAppendingPathComponent:scope]];
                check(lstat(src.fileSystemRepresentation,&st)==0 && S_ISLNK(st.st_mode),
                      [NSString stringWithFormat:@"non-conflicting scope %@ mounted",scope]);
            }
            NSString *sourcePreferences=[home stringByAppendingPathComponent:@"Library/Preferences"];
            check(lstat(sourcePreferences.fileSystemRepresentation,&st)==0 && S_ISDIR(st.st_mode),
                  @"conflicting Preferences source retained as real directory");
            check([readFile(original) isEqualToString:@"CURRENT_USER_PREFS"],
                  @"original Preferences contents not overwritten");
            check([readFile(saved) isEqualToString:@"ALREADY_SAVED_PREFS"],
                  @"persisted target Preferences contents not overwritten");
            NSString *manifestPath=[root stringByAppendingPathComponent:@"manifest.json"];
            NSDictionary *manifest=[NSJSONSerialization JSONObjectWithData:
                  [NSData dataWithContentsOfFile:manifestPath] options:0 error:nil];
            check([manifest[@"format"] isEqualToString:@"SideloadPersist.Directory.V2"],
                  @"manifest lists only actually linked scopes");
            check(![manifest[@"scopes"] containsObject:@"Preferences"],
                  @"manifest does not falsely declare conflicting Preferences");
            check([readFile([root stringByAppendingPathComponent:@"README.md"])
                  containsString:@"| `Data/Preferences` | `Library/Preferences` | 未建立映射"],
                  @"README accurately shows omitted scope");
            NSDictionary *report=[NSJSONSerialization JSONObjectWithData:
                  [NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:@"scope-mapping-result.json"]]
                  options:0 error:nil];
            BOOL diagnosed=NO;
            for(NSDictionary *entry in report[@"scopes"]) if([entry[@"scope"] isEqualToString:@"Preferences"] &&
                ![entry[@"mapped"] boolValue] &&
                [entry[@"reason"] isEqualToString:@"source-and-target-both-nonempty"]) diagnosed=YES;
            check(diagnosed,@"diagnostic identifies the exact conflicting scope and reason");
            NSString *zip=[home stringByAppendingPathComponent:@"conflict-v2.zip"];
            makeArchive(zip,NO,NO);
            NSError *error=nil;
            check(PDArchiveStageZIP([NSURL fileURLWithPath:zip],&error).length==36,
                  @"older v2 backup stages without mutating conflicting Preferences");
        } else if(strcmp(argv[1],"apply-conflict")==0) {
            check(PDStorageBootstrap()==PDStorageStateReady,
                  @"older v2 backup restored despite unrelated Preferences conflict");
            check([readFile([app stringByAppendingPathComponent:@"test.sqlite"]) isEqualToString:@"APP_RESTORED"],
                  @"AppSupport restored in degraded mode");
            check([readFile([home stringByAppendingPathComponent:@"Library/Preferences/user.plist"])
                  isEqualToString:@"CURRENT_USER_PREFS"],
                  @"source Preferences preserved across restore");
            check([readFile([prefsDir stringByAppendingPathComponent:@"old.plist"])
                  isEqualToString:@"ALREADY_SAVED_PREFS"],
                  @"conflicting target Preferences preserved across restore");
        } else if(strcmp(argv[1],"readme")==0) {
            check(PDStorageBootstrap()==PDStorageStateRecovered,@"initialize README managed state");
            NSString *path=[root stringByAppendingPathComponent:@"README.md"];
            NSString *original=readFile(path);
            check([original containsString:@"SideloadPersist"] && [original containsString:@"RavelloH"],
                  @"README created on first bootstrap");
            PDReadmeUpdate(@[@"Application Support"]);
            NSString *reduced=readFile(path);
            check([reduced containsString:@"| `Data/Preferences` | `Library/Preferences` | 未建立映射"],
                  @"README refreshes when verified scope set changes");
            PDReadmeUpdate(@[@"Application Support",@"WebKit",@"Cookies",@"Preferences"]);
            NSString *extended=readFile(path);
            check([extended containsString:@"| `Data/Preferences` | `Library/Preferences` | 已建立映射"],
                  @"README restores mapping table after scope update");
            NSString *custom=[extended stringByAppendingString:@"\n## My Personal Notes\n"];
            check([custom writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil],
                  @"user customizes README");
            PDReadmeUpdate(@[@"Application Support"]);
            check([readFile(path) isEqualToString:custom],
                  @"README customization is never overwritten");
            NSLog(@"All automatic README generation/update/preservation checks passed.");
        } else if(strcmp(argv[1],"prepare-fresh")==0) {
            check(PDStorageBootstrap()==PDStorageStateRecovered,@"brand new app initializes all scopes automatically");
            struct stat st={0};
            NSString *sourceWeb=[home stringByAppendingPathComponent:@"Library/WebKit"];
            NSString *sourceCookies=[home stringByAppendingPathComponent:@"Library/Cookies"];
            check(lstat(sourceWeb.fileSystemRepresentation,&st)==0 && S_ISLNK(st.st_mode),
                  @"fresh install auto-mounts WebKit without opt-in");
            check(lstat(sourceCookies.fileSystemRepresentation,&st)==0 && S_ISLNK(st.st_mode),
                  @"fresh install auto-mounts Cookies without opt-in");
            NSString *sourcePrefs=[home stringByAppendingPathComponent:@"Library/Preferences"];
            check(lstat(sourcePrefs.fileSystemRepresentation,&st)==0 && S_ISLNK(st.st_mode),
                  @"fresh install auto-mounts Preferences without opt-in");
            NSString *readme=readFile([root stringByAppendingPathComponent:@"README.md"]);
            check([readme containsString:@"RavelloH"] &&
                  [readme containsString:@"github.com/RavelloH/SideloadPersist"] &&
                  [readme containsString:@"Data/Preferences"] &&
                  [readme containsString:@"Library/Preferences"],@"README automatically documents all mappings and project metadata");
            NSString *zip=[home stringByAppendingPathComponent:@"multi.zip"];
            makeArchive(zip,NO,NO);
            NSError *error=nil;
            NSString *id=PDArchiveStageZIP([NSURL fileURLWithPath:zip],&error);
            check(id.length==36,[NSString stringWithFormat:@"fresh app accepts v2 ZIP without markers: %@",error]);
            check([fm fileExistsAtPath:pending],@"fresh installation has scheduled v2 restoration");
            NSLog(@"Fresh install initialized and staged v2 recovery.");
        } else if(strcmp(argv[1],"apply-fresh")==0) {
            check(PDStorageBootstrap()==PDStorageStateReady,@"fresh install applies v2 backup after restart");
            check(![fm fileExistsAtPath:pending],@"fresh recovery pending cleared");
            check([readFile([app stringByAppendingPathComponent:@"test.sqlite"]) isEqualToString:@"APP_RESTORED"],@"AppSupport restored after reinstall");
            check([readFile([web stringByAppendingPathComponent:@"localstorage.db"]) isEqualToString:@"WEB_RESTORED"],@"WebKit restored after reinstall");
            check([readFile([cookie stringByAppendingPathComponent:@"Cookies.binarycookies"]) isEqualToString:@"COOKIE_RESTORED"],@"Cookies restored after reinstall");
            NSLog(@"Fresh-install v2 recovery passed.");
        } else if(strcmp(argv[1],"prepare")==0 ||
           strcmp(argv[1],"prepare-interruption")==0 ||
           strcmp(argv[1],"prepare-rollback")==0) {
            check(PDStorageBootstrap()==PDStorageStateRecovered,@"bootstrap new sandbox for v2");
            put([home stringByAppendingPathComponent:@"Library/WebKit/localstorage.db"],@"WEB_OLD");
            put([home stringByAppendingPathComponent:@"Library/Cookies/Cookies.binarycookies"],@"COOKIE_OLD");
            put([home stringByAppendingPathComponent:@"Library/Preferences/testprefs.plist"],@"PREF_OLD");
            check(PDRelocateExtendedScopes(home,root),@"repeat extended scope mounting is idempotent");
            put([app stringByAppendingPathComponent:@"test.sqlite"],@"APP_OLD");
            NSString *unsupported=[home stringByAppendingPathComponent:@"unsupported.zip"];
            makeUnsupportedArchive(unsupported);
            NSError *unsupportedError=nil;
            check(!PDArchiveStageZIP([NSURL fileURLWithPath:unsupported],&unsupportedError),
                  @"unrecognized Data/Unsupported scope rejected instead of silently lost");
            check(![fm fileExistsAtPath:pending],@"reject does not create pending restore");
            NSString *incomplete=[home stringByAppendingPathComponent:@"incomplete.zip"];
            makeArchive(incomplete,YES,YES);
            NSError *incompleteError=nil;
            check(!PDArchiveStageZIP([NSURL fileURLWithPath:incomplete],&incompleteError),
                  @"missing declared Cookie scope rejected before staging");
            check(![fm fileExistsAtPath:pending],@"incomplete backup did not arm restore");
            NSString *zip=[home stringByAppendingPathComponent:@"multi.zip"];
            makeArchive(zip,NO,YES);
            check(PDV2ZIPHasExtraScopes([NSURL fileURLWithPath:zip]),@"v2 ZIP auto-detected");
            NSError *error=nil;
            NSString *identifier=PDArchiveStageZIP([NSURL fileURLWithPath:zip],&error);
            check(identifier.length==36,[NSString stringWithFormat:@"v2 archive staged: %@",error]);
            NSString *stage=[root stringByAppendingPathComponent:[NSString stringWithFormat:@"Incoming/%@/Data",identifier]];
            check([fm fileExistsAtPath:[stage stringByAppendingPathComponent:@"Application Support/test.sqlite"]],
                 @"staged archive data exists");
            check([readFile([app stringByAppendingPathComponent:@"test.sqlite"]) isEqualToString:@"APP_OLD"],
                 @"existing app data still authoritative before cold restart");
            check([readFile([web stringByAppendingPathComponent:@"localstorage.db"]) isEqualToString:@"WEB_OLD"],
                 @"existing WebKit data still authoritative before cold restart");
            check([readFile([cookie stringByAppendingPathComponent:@"Cookies.binarycookies"]) isEqualToString:@"COOKIE_OLD"],
                 @"existing Cookie data still authoritative before cold restart");
            check([readFile([prefsDir stringByAppendingPathComponent:@"testprefs.plist"]) isEqualToString:@"PREF_OLD"],
                 @"existing Preferences data still authoritative before cold restart");
            NSString *userReadme=[root stringByAppendingPathComponent:@"README.md"];
            NSString *contents=readFile(userReadme);
            check([contents containsString:@"Data/Preferences"],@"v3 README lists Preferences mapping");
            put(userReadme,[contents stringByAppendingString:@"\nCUSTOM README NOTE FROM USER\n"]);
            check(![fm fileExistsAtPath:[stage stringByAppendingPathComponent:@"WebKit/._localstorage.db"]],
                 @"AppleDouble metadata excluded from v2 stage");
            check(![fm fileExistsAtPath:[stage stringByAppendingPathComponent:@"Backups"]],
                 @"unrelated backup scope excluded");
            if(strcmp(argv[1],"prepare-interruption")==0) {
                NSString *backup=[root stringByAppendingPathComponent:
                    [NSString stringWithFormat:@"Backups/%@/Data/Application Support",identifier]];
                check([fm createDirectoryAtPath:[backup stringByDeletingLastPathComponent]
                     withIntermediateDirectories:YES attributes:nil error:&error],@"create crash-test backup parent");
                check(rename(app.fileSystemRepresentation,backup.fileSystemRepresentation)==0,
                     @"simulate crash after parking original AppSupport");
            }
            NSLog(@"All v2 staging tests passed.");
        } else if(strcmp(argv[1],"apply")==0) {
            check(PDStorageBootstrap()==PDStorageStateReady,@"v2 cold-start restore committed");
            check(![fm fileExistsAtPath:pending],@"v2 pending flag cleared");
            NSData *receiptData=[NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:@"restore-last.json"]];
            NSDictionary *receipt=receiptData ? [NSJSONSerialization JSONObjectWithData:receiptData options:0 error:nil] : nil;
            check([receipt[@"result"] isEqualToString:@"committed"],@"v2 restore receipt marked committed");
            check([receipt[@"scopes"] count]==4,@"v3 receipt records all four restored scopes");
            NSData *manifestBytes=[NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:@"manifest.json"]];
            NSDictionary *manifest=manifestBytes ? [NSJSONSerialization JSONObjectWithData:manifestBytes options:0 error:nil] : nil;
            check([manifest[@"format"] isEqualToString:@"SideloadPersist.Directory.V3"],@"manifest auto-upgrades to V3 when Preferences link verified");
            check([manifest[@"scopes"] count]==4,@"manifest enumerates all four verified scopes");
            check([readFile([app stringByAppendingPathComponent:@"test.sqlite"]) isEqualToString:@"APP_RESTORED"],
                @"Application Support replaced with v2 copy");
            check([readFile([web stringByAppendingPathComponent:@"localstorage.db"]) isEqualToString:@"WEB_RESTORED"],
                @"WebKit replaced with v2 copy");
            check([readFile([cookie stringByAppendingPathComponent:@"Cookies.binarycookies"]) isEqualToString:@"COOKIE_RESTORED"],
                @"Cookies replaced with v3 copy");
            check([readFile([prefsDir stringByAppendingPathComponent:@"testprefs.plist"]) isEqualToString:@"PREF_RESTORED"],
                @"Preferences replaced with v3 copy");
            check([readFile([root stringByAppendingPathComponent:@"README.md"]) containsString:@"CUSTOM README NOTE FROM USER"],
                @"user-edited README preserved across bootstrap and restore");
            NSArray *ids=[fm contentsOfDirectoryAtPath:[root stringByAppendingPathComponent:@"Backups"] error:nil];
            check(ids.count==1,@"v2 backup retained");
            NSString *backup=[root stringByAppendingPathComponent:
                [NSString stringWithFormat:@"Backups/%@/Data",ids.firstObject]];
            check([readFile([backup stringByAppendingPathComponent:@"Application Support/test.sqlite"]) isEqualToString:@"APP_OLD"],
                @"backup preserves prior AppSupport");
            check([readFile([backup stringByAppendingPathComponent:@"WebKit/localstorage.db"]) isEqualToString:@"WEB_OLD"],
                @"backup preserves prior WebKit");
            check([readFile([backup stringByAppendingPathComponent:@"Cookies/Cookies.binarycookies"]) isEqualToString:@"COOKIE_OLD"],
                @"backup preserves prior Cookies");
            check([readFile([backup stringByAppendingPathComponent:@"Preferences/testprefs.plist"]) isEqualToString:@"PREF_OLD"],
                @"backup preserves prior Preferences");
            NSLog(@"All v2 restore tests passed.");
        } else if(strcmp(argv[1],"apply-rollback")==0) {
            // The test-specific failure gate in PDV2Restore fails after parking
            // the WebKit directory, so the restoring process must roll back
            // Application Support and WebKit without destroying staged files.
            check(PDStorageBootstrap()==PDStorageStateConflict,@"injected restore error stopped app bootstrap");
            check([fm fileExistsAtPath:pending],@"pending retained after rollback");
            check([readFile([app stringByAppendingPathComponent:@"test.sqlite"]) isEqualToString:@"APP_OLD"],
                @"AppSupport rolled back");
            check([readFile([web stringByAppendingPathComponent:@"localstorage.db"]) isEqualToString:@"WEB_OLD"],
                @"WebKit rolled back");
            check([readFile([cookie stringByAppendingPathComponent:@"Cookies.binarycookies"]) isEqualToString:@"COOKIE_OLD"],
                @"Cookies not altered after failure");
            check([readFile([prefsDir stringByAppendingPathComponent:@"testprefs.plist"]) isEqualToString:@"PREF_OLD"],
                @"Preferences not altered after failure");
            NSLog(@"All v2 rollback tests passed.");
        } else {
            check(NO,@"unknown mode");
        }
        return 0;
    }
}
