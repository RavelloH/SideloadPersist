#import <Foundation/Foundation.h>
#import <sys/stat.h>
#import <unistd.h>
#import <stdlib.h>
#import <string.h>
#import "PDStorage.h"
#import "PDArchive.h"
#import "PDReadme.h"
#import "PDV2Archive.h"
#import "PDPreferencesBackend.h"
#import "PDPreferencesHook.h"
#import "PDCustomLibrary.h"
#import "miniz.h"

static void check(BOOL good, NSString *name) {
    if(!good){NSLog(@"FAIL %@",name);exit(1);}
    NSLog(@"PASS %@",name);
}
static NSString *home(void){return [NSString stringWithUTF8String:getenv("HOME")];}
static NSString *root(void){return [home() stringByAppendingPathComponent:@"Documents/SideloadPersist"];}
static NSString *data(NSString *scope){return [[root() stringByAppendingPathComponent:@"Data"] stringByAppendingPathComponent:scope];}
static NSString *lib(NSString *scope){return [[home() stringByAppendingPathComponent:@"Library"] stringByAppendingPathComponent:scope];}
static NSString *appID(void){return NSBundle.mainBundle.bundleIdentifier ?: @"SideloadPersist.StandaloneTest";}
static NSString *readFile(NSString *p){return [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];}
static void put(NSString *p,NSString *value){
    check([NSFileManager.defaultManager createDirectoryAtPath:p.stringByDeletingLastPathComponent
          withIntermediateDirectories:YES attributes:nil error:nil],@"mkdir");
    check([value writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil],@"write file");
}
static NSDictionary *json(NSString *p){
    NSData *bytes=[NSData dataWithContentsOfFile:p];
    id parsed=bytes?[NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil]:nil;
    return [parsed isKindOfClass:NSDictionary.class] ? parsed : nil;
}
static BOOL linked(NSString *p){struct stat st={0};return lstat(p.fileSystemRepresentation,&st)==0&&S_ISLNK(st.st_mode);}
static void prefs(NSString *value){
    NSError *err=nil;
    check(PDPreferencesWriteValue(appID(),@"restoreMarker",value,&err),
         [NSString stringWithFormat:@"write live Preferences %@",err]);
}
static NSString *prefValue(void){return PDPreferencesValues(appID())[@"restoreMarker"];}
static void archiveWithIdentity(NSString *p,BOOL withPrefs,BOOL missingCookie,
                                NSString *sourceBundle){
    mz_zip_archive zip={0};
    check(mz_zip_writer_init_file(&zip,p.fileSystemRepresentation,0),@"ZIP initialize");
    NSString *identity=[sourceBundle isEqualToString:@"__legacy__"] ? @"" :
        [NSString stringWithFormat:@",\"originalBundleID\":\"%@\"",sourceBundle ?: appID()];
    NSString *manifest=[NSString stringWithFormat:withPrefs?
        @"{\"format\":\"SideloadPersist.Directory.V3\",\"scopes\":[\"Application Support\",\"WebKit\",\"Cookies\",\"Preferences\"]%@}":
        @"{\"format\":\"SideloadPersist.Directory.V2\",\"scopes\":[\"Application Support\",\"WebKit\",\"Cookies\"]%@}",identity];
    NSDictionary *contents=@{
        @"SideloadPersist/manifest.json":manifest,
        @"SideloadPersist/Data/Application Support/test.sqlite":@"APP_NEW",
        @"SideloadPersist/Data/WebKit/localstorage.db":@"WEB_NEW"
    };
    for(NSString *path in contents) {
        NSData *bytes=[contents[path] dataUsingEncoding:NSUTF8StringEncoding];
        check(mz_zip_writer_add_mem(&zip,path.UTF8String,bytes.bytes,bytes.length,MZ_BEST_SPEED),@"ZIP string");
    }
    if(!missingCookie) {
        NSData *cookie=[@"COOKIE_NEW" dataUsingEncoding:NSUTF8StringEncoding];
        check(mz_zip_writer_add_mem(&zip,"SideloadPersist/Data/Cookies/Cookies.binarycookies",
                                     cookie.bytes,cookie.length,MZ_BEST_SPEED),@"ZIP Cookies");
    }
    if(withPrefs) {
        prefs(@"PREF_NEW");
        NSString *file=PDPreferencesDomainFile(appID());
        NSData *raw=[NSData dataWithContentsOfFile:file];
        NSString *entry=[@"SideloadPersist/Data/Preferences" stringByAppendingPathComponent:file.lastPathComponent];
        check(raw && mz_zip_writer_add_mem(&zip,entry.UTF8String,raw.bytes,raw.length,MZ_BEST_SPEED),
              @"ZIP canonical Preferences plist");
        // Legacy v3 archives may contain accidentally captured UIKit/Apple suites.
        // They must still be importable, but the new Hook must exclude those
        // synthetic system-domain records after a cold-start restore.
        NSString *systemDomain=@"com.apple.Accessibility";
        NSError *systemError=nil;
        check(PDPreferencesEnsureDomain(systemDomain,@{@"synthetic":@"not real OS preferences"},&systemError),
              @"simulate legacy ZIP containing Apple suite");
        NSString *systemPath=PDPreferencesDomainFile(systemDomain);
        NSData *systemRaw=[NSData dataWithContentsOfFile:systemPath];
        NSString *systemEntry=[@"SideloadPersist/Data/Preferences"
                                stringByAppendingPathComponent:systemPath.lastPathComponent];
        check(systemRaw && mz_zip_writer_add_mem(&zip,systemEntry.UTF8String,
                          systemRaw.bytes,systemRaw.length,MZ_BEST_SPEED),
              @"ZIP includes synthetic legacy system preference domain");
    }
    NSString *custom=[[[data(@"Application Support")
                            stringByAppendingPathComponent:@"SideloadPersist.Library"]
                            stringByAppendingPathComponent:appID()]
                            stringByAppendingPathComponent:@"marker.txt"];
    if([NSFileManager.defaultManager fileExistsAtPath:custom]) {
        NSData *value=[@"PRIVATE_NEW" dataUsingEncoding:NSUTF8StringEncoding];
        NSString *zipName=[@"SideloadPersist/Data/Application Support/SideloadPersist.Library"
                            stringByAppendingPathComponent:appID()];
        zipName=[zipName stringByAppendingPathComponent:@"marker.txt"];
        check(mz_zip_writer_add_mem(&zip,zipName.UTF8String,
                          value.bytes,value.length,MZ_BEST_SPEED),
              @"ZIP carries app-owned Library directory inside Application Support");
    }
    check(mz_zip_writer_finalize_archive(&zip),@"ZIP finalize");
    mz_zip_writer_end(&zip);
}
static void archive(NSString *p,BOOL withPrefs,BOOL missingCookie) {
    archiveWithIdentity(p,withPrefs,missingCookie,nil);
}
static void scopeChecks(void){
    check(linked(lib(@"Application Support")) && linked(lib(@"WebKit")) && linked(lib(@"Cookies")),
          @"existing three scope symlinks");
    check(PDPreferencesHookActive(),@"Preferences live Hook installed");
    if(linked(lib(@"Preferences"))) {
        char destination[4096]={0};
        ssize_t count=readlink(lib(@"Preferences").fileSystemRepresentation,destination,sizeof(destination)-1);
        check(count>0 && ![data(@"Preferences") isEqualToString:[NSString stringWithUTF8String:destination]],
              @"preexisting foreign Preferences symlink left unchanged");
    } else check(YES,@"native Preferences does not require a symlink");
    NSDictionary *manifest=json([root() stringByAppendingPathComponent:@"manifest.json"]);
    check([manifest[@"format"] isEqualToString:@"SideloadPersist.Directory.V3"],
          @"V3 manifest after Hook activation");
    check([manifest[@"scopeModes"][@"Preferences"] isEqualToString:@"live-api-hook"],
          @"manifest describes Preferences correctly");
}
int main(int argc,char **argv){
 @autoreleasepool {
    check(argc==2,@"test mode");
    NSString *mode=[NSString stringWithUTF8String:argv[1]];
    NSString *pending=[root() stringByAppendingPathComponent:@"restore-pending.txt"];
    NSFileManager *fm=NSFileManager.defaultManager;
    if([mode isEqualToString:@"identity-mismatch"] ||
       [mode isEqualToString:@"identity-legacy"]) {
        check(PDStorageBootstrap()==PDStorageStateRecovered,@"identity test initializes storage");
        NSString *zip=[home() stringByAppendingPathComponent:@"identity-test.zip"];
        BOOL legacy=[mode isEqualToString:@"identity-legacy"];
        archiveWithIdentity(zip,NO,NO,legacy?@"__legacy__":@"org.other.vendor");
        NSString *seen=nil;
        PDArchiveIdentityState state=PDArchiveInspectIdentity([NSURL fileURLWithPath:zip],&seen);
        check(state==(legacy?PDArchiveIdentityStateLegacyUnknown:
                     PDArchiveIdentityStateDifferentApp),@"backup identity preflight recognized mismatch");
        NSError *error=nil;
        check(!PDArchiveStageZIP([NSURL fileURLWithPath:zip],&error),
              @"unverified identity rejected by default");
        check(![fm fileExistsAtPath:pending],@"identity refusal does not stage restore");
        error=nil;
        check(PDArchiveStageZIPWithIdentityApproval([NSURL fileURLWithPath:zip],YES,&error).length==36,
              @"explicit identity approval permits compatible archive");
    } else if([mode isEqualToString:@"prepare-private-conflict"]) {
        NSString *original=[lib(appID()) stringByAppendingPathComponent:@"marker.txt"];
        NSString *nested=[[[data(@"Application Support")
                             stringByAppendingPathComponent:@"SideloadPersist.Library"]
                             stringByAppendingPathComponent:appID()]
                             stringByAppendingPathComponent:@"marker.txt"];
        put(original,@"ORIGINAL_STAYS");
        put(nested,@"BACKUP_STAYS");
        check(PDStorageBootstrap()==PDStorageStateRecovered,@"core migration unaffected by custom Library conflict");
        scopeChecks();
        check(!linked(lib(appID())),@"conflicting custom source preserved as normal directory");
        check([readFile(original) isEqualToString:@"ORIGINAL_STAYS"],@"original custom data not overwritten");
        check([readFile(nested) isEqualToString:@"BACKUP_STAYS"],@"old custom target not overwritten");
        check(![PDCustomLibraryVerified() containsObject:appID()],@"conflicting custom folder not reported as mapped");
        NSDictionary *diag=json([root() stringByAppendingPathComponent:@"library-discovery.json"]);
        BOOL found=NO;
        for(NSDictionary *candidate in diag[@"candidates"])
            if([candidate[@"name"] isEqualToString:appID()] &&
               [candidate[@"reason"] isEqualToString:@"source-and-target-both-nonempty"])
                found=YES;
        check(found,@"custom scope conflict reason diagnosed");
    } else if([mode isEqualToString:@"prepare-private"]) {
        NSString *custom=[lib(appID()) stringByAppendingPathComponent:@"marker.txt"];
        put(custom,@"PRIVATE_OLD");
        put([lib(@"SplashBoard") stringByAppendingPathComponent:@"system.bin"],@"SYSTEM_UNCHANGED");
        put([lib(@"UnrelatedSDK") stringByAppendingPathComponent:@"unrelated.bin"],@"UNRELATED_UNCHANGED");
        check(!PDCustomLibrarySafeName(@"Preferences") &&
              !PDCustomLibrarySafeName(@"SplashBoard") &&
              !PDCustomLibrarySafeName(@"com.apple.Accessibility") &&
              !PDCustomLibrarySafeName(@"../escape") &&
              PDCustomLibrarySafeName(appID()),@"custom scope names reject system and unsafe entries");
        check(PDStorageBootstrap()==PDStorageStateRecovered,@"first custom Library directory migrated");
        scopeChecks();
        check(linked(lib(appID())),@"app-owned Library directory becomes symlink");
        check([readFile(custom) isEqualToString:@"PRIVATE_OLD"],@"private app data readable via old path");
        check(!linked(lib(@"SplashBoard")) && !linked(lib(@"UnrelatedSDK")),
              @"system and unrelated Library directories never migrated");
        NSArray *verified=PDCustomLibraryVerified();
        check(verified.count==1 && [verified containsObject:appID()],
              @"only verified app-named extra directory selected");
        NSDictionary *manifest=json([root() stringByAppendingPathComponent:@"manifest.json"]);
        check([manifest[@"format"] isEqualToString:@"SideloadPersist.Directory.V3"],
              @"V3 ZIP format remains unchanged with nested custom directory");
        check([manifest[@"additionalLibraryMappings"] count]==1,
              @"manifest records extra Library mapping");
        NSString *readme=readFile([root() stringByAppendingPathComponent:@"README.md"]);
        check([readme containsString:@"Data/Application Support/SideloadPersist.Library/"] &&
              [readme containsString:appID()],@"generated README includes custom directory");
        NSString *zip=[home() stringByAppendingPathComponent:@"private-v3.zip"];
        archive(zip,YES,NO);
        prefs(@"PREF_OLD");
        NSError *error=nil;
        check(PDArchiveStageZIP([NSURL fileURLWithPath:zip],&error).length==36,
              [NSString stringWithFormat:@"V3 archive stages nested custom scope: %@",error]);
        check([readFile(custom) isEqualToString:@"PRIVATE_OLD"],
              @"staged ZIP has not modified active custom directory");
        // Simulate the fact that a *newly reinstalled* App no longer has the
        // original Library/<app-id> link, without deleting the backup contents.
        check(unlink(lib(appID()).fileSystemRepresentation)==0,
              @"simulate disappearance of old custom link after reinstall");
    } else if([mode isEqualToString:@"apply-private"]) {
        check(PDStorageBootstrap()==PDStorageStateReady,@"V3 archive with custom data restored on cold start");
        scopeChecks();
        check(linked(lib(appID())),@"custom source link automatically recreated on new installation");
        check([readFile([lib(appID()) stringByAppendingPathComponent:@"marker.txt"])
                isEqualToString:@"PRIVATE_NEW"],@"restored custom data visible through original Library path");
        check(!linked(lib(@"SplashBoard")) && !linked(lib(@"UnrelatedSDK")),
              @"unrelated system and SDK directories still unmodified");
        NSDictionary *manifest=json([root() stringByAppendingPathComponent:@"manifest.json"]);
        check([manifest[@"additionalLibraryMappings"] count]==1,
              @"restored custom link appears in machine-readable manifest");
        NSArray *versions=[fm contentsOfDirectoryAtPath:[root() stringByAppendingPathComponent:@"Backups"] error:nil];
        check(versions.count==1,@"previous data version preserved");
        NSString *old=[[[[root() stringByAppendingPathComponent:@"Backups"]
                         stringByAppendingPathComponent:versions.firstObject]
                         stringByAppendingPathComponent:@"Data/Application Support/SideloadPersist.Library"]
                         stringByAppendingPathComponent:appID()];
        check([readFile([old stringByAppendingPathComponent:@"marker.txt"])
                isEqualToString:@"PRIVATE_OLD"],@"prior custom Library contents retained in recovery backup");
    } else if([mode isEqualToString:@"readme"]) {
        check(PDStorageBootstrap()==PDStorageStateRecovered,@"initialize for README");
        scopeChecks();
        NSString *path=[root() stringByAppendingPathComponent:@"README.md"];
        check([readFile(path) containsString:@"RavelloH"],@"README with author");
        PDReadmeUpdate(@[@"Application Support"]);
        check([readFile(path) containsString:@"未建立映射"],@"README reflects scope change");
        PDReadmeUpdate(@[@"Application Support",@"WebKit",@"Cookies",@"Preferences"]);
        check([readFile(path) containsString:@"API 实时存储"],@"README documents Hook storage");
        put(path,[readFile(path) stringByAppendingString:@"\nMY OWN NOTES\n"]);
        PDReadmeUpdate(@[@"Application Support"]);
        check([readFile(path) containsString:@"MY OWN NOTES"],@"manual README preserved");
    } else if([mode isEqualToString:@"prepare-empty-target"]) {
        put([lib(@"Preferences") stringByAppendingPathComponent:@"native.plist"],@"NATIVE");
        [fm createDirectoryAtPath:data(@"Preferences") withIntermediateDirectories:YES attributes:nil error:nil];
        check(PDStorageBootstrap()==PDStorageStateRecovered,@"does not rename native Preferences");
        scopeChecks();
        check([readFile([lib(@"Preferences") stringByAppendingPathComponent:@"native.plist"]) isEqualToString:@"NATIVE"],
              @"native Preferences directory unchanged");
    } else if([mode isEqualToString:@"prepare-foreign-link"]) {
        NSString *foreign=[home() stringByAppendingPathComponent:@"Library/ForeignPreferences"];
        put([foreign stringByAppendingPathComponent:@"marker.plist"],@"FOREIGN");
        check(symlink(foreign.fileSystemRepresentation,lib(@"Preferences").fileSystemRepresentation)==0,
              @"create foreign Preferences symlink");
        check(PDStorageBootstrap()==PDStorageStateRecovered,@"ignores foreign Preferences symlink");
        scopeChecks();
        check(linked(lib(@"Preferences")) && [readFile([lib(@"Preferences") stringByAppendingPathComponent:@"marker.plist"])
              isEqualToString:@"FOREIGN"],@"foreign symlink intact");
    } else if([mode isEqualToString:@"prepare-conflict"]) {
        put([lib(@"Preferences") stringByAppendingPathComponent:@"native.plist"],@"NATIVE");
        put([data(@"Preferences") stringByAppendingPathComponent:@"extra.plist"],@"EXTRA");
        check(PDStorageBootstrap()==PDStorageStateRecovered,@"native and target data coexist");
        scopeChecks();
        archive([home() stringByAppendingPathComponent:@"oldv2.zip"],NO,NO);
        NSError *error=nil;
        check(PDArchiveStageZIP([NSURL fileURLWithPath:[home() stringByAppendingPathComponent:@"oldv2.zip"]],&error).length==36,
              @"old V2 backup imports with Hook installed");
    } else if([mode isEqualToString:@"apply-conflict"]) {
        check(PDStorageBootstrap()==PDStorageStateReady,@"old V2 restored");
        check([readFile([data(@"Application Support") stringByAppendingPathComponent:@"test.sqlite"]) isEqualToString:@"APP_NEW"],
              @"V2 restore AppSupport");
        check([readFile([lib(@"Preferences") stringByAppendingPathComponent:@"native.plist"]) isEqualToString:@"NATIVE"],
              @"system Preferences unchanged by old ZIP");
        check([readFile([data(@"Preferences") stringByAppendingPathComponent:@"extra.plist"]) isEqualToString:@"EXTRA"],
              @"existing target file unchanged");
    } else if([mode isEqualToString:@"prepare-fresh"]) {
        check(PDStorageBootstrap()==PDStorageStateRecovered,@"fresh app bootstrap");
        scopeChecks();
        archive([home() stringByAppendingPathComponent:@"v2.zip"],NO,NO);
        NSError *error=nil;
        check(PDArchiveStageZIP([NSURL fileURLWithPath:[home() stringByAppendingPathComponent:@"v2.zip"]],&error).length==36,
              @"fresh V2 stage");
    } else if([mode isEqualToString:@"apply-fresh"]) {
        check(PDStorageBootstrap()==PDStorageStateReady,@"fresh app restored V2");
        scopeChecks();
        check([readFile([data(@"Application Support") stringByAppendingPathComponent:@"test.sqlite"]) isEqualToString:@"APP_NEW"],
              @"fresh V2 restored AppSupport");
    } else if([mode hasPrefix:@"prepare"]) {
        check(PDStorageBootstrap()==PDStorageStateRecovered,@"first V3 bootstrap");
        scopeChecks();
        put([data(@"Application Support") stringByAppendingPathComponent:@"test.sqlite"],@"APP_OLD");
        put([data(@"WebKit") stringByAppendingPathComponent:@"localstorage.db"],@"WEB_OLD");
        put([data(@"Cookies") stringByAppendingPathComponent:@"Cookies.binarycookies"],@"COOKIE_OLD");
        prefs(@"PREF_OLD");
        NSString *bad=[home() stringByAppendingPathComponent:@"incomplete.zip"];
        archive(bad,YES,YES);
        NSError *err=nil;
        check(!PDArchiveStageZIP([NSURL fileURLWithPath:bad],&err),@"incomplete V3 rejected");
        check(![fm fileExistsAtPath:pending],@"no pending after bad V3");
        NSString *zip=[home() stringByAppendingPathComponent:@"fullv3.zip"];
        archive(zip,YES,NO);
        prefs(@"PREF_OLD");
        check(PDArchiveStageZIP([NSURL fileURLWithPath:zip],&err).length==36,@"valid V3 staged");
        check([prefValue() isEqualToString:@"PREF_OLD"],@"active Preferences unchanged before restart");
        if([mode isEqualToString:@"prepare-interruption"]) {
            NSString *identifier=readFile(pending);
            NSString *backup=[root() stringByAppendingPathComponent:
                [NSString stringWithFormat:@"Backups/%@/Data/Application Support",identifier]];
            [fm createDirectoryAtPath:backup.stringByDeletingLastPathComponent
                withIntermediateDirectories:YES attributes:nil error:nil];
            check(rename(data(@"Application Support").fileSystemRepresentation,backup.fileSystemRepresentation)==0,
                  @"simulate crash after parking AppSupport");
        }
    } else if([mode isEqualToString:@"apply"]) {
        check(PDStorageBootstrap()==PDStorageStateReady,@"V3 cold-start restoration completed");
        scopeChecks();
        check([readFile([data(@"Application Support") stringByAppendingPathComponent:@"test.sqlite"]) isEqualToString:@"APP_NEW"],
              @"V3 restored AppSupport");
        check([readFile([data(@"WebKit") stringByAppendingPathComponent:@"localstorage.db"]) isEqualToString:@"WEB_NEW"],
              @"V3 restored WebKit");
        check([readFile([data(@"Cookies") stringByAppendingPathComponent:@"Cookies.binarycookies"]) isEqualToString:@"COOKIE_NEW"],
              @"V3 restored Cookies");
        check([prefValue() isEqualToString:@"PREF_NEW"],@"V3 restored live Preferences");
        check(!PDPreferencesDomainExists(@"com.apple.Accessibility"),
              @"restored legacy system domain moved out of exported Data");
        check([[PDPreferencesHealth() objectForKey:@"domainFiles"] unsignedIntegerValue]==1,
              @"only app-owned Preferences record is in active backup scope");
        check(![fm fileExistsAtPath:pending],@"V3 pending marker removed");
        NSDictionary *receipt=json([root() stringByAppendingPathComponent:@"restore-last.json"]);
        check([receipt[@"scopes"] containsObject:@"Preferences"],@"V3 receipt includes Preferences");
    } else if([mode isEqualToString:@"apply-rollback"]) {
        check(PDStorageBootstrap()==PDStorageStateConflict,@"injected V3 failure returns conflict");
        check([readFile([data(@"Application Support") stringByAppendingPathComponent:@"test.sqlite"]) isEqualToString:@"APP_OLD"],
              @"AppSupport rolled back");
        check([readFile([data(@"WebKit") stringByAppendingPathComponent:@"localstorage.db"]) isEqualToString:@"WEB_OLD"],
              @"WebKit rolled back");
        check([prefValue() isEqualToString:@"PREF_OLD"],@"Preferences preserved after failure");
    } else check(NO,@"unknown scenario");
    NSLog(@"ALL PASSED: %@",mode);
 }
 return 0;
}
