#import <Foundation/Foundation.h>
#import <sys/stat.h>
#import <unistd.h>
#import <stdlib.h>
#import <string.h>
#import "PDStorage.h"
#import "PDArchive.h"
#import "PDExperimentalScope.h"
#import "PDV2Archive.h"
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
                           @"SideloadPersist/Data/Preferences/config.plist"]) {
        check(mz_zip_writer_add_mem(&zip,name.UTF8String,"X",1,MZ_BEST_SPEED),@"add unsupported scope fixture");
    }
    check(mz_zip_writer_finalize_archive(&zip),@"finalize unsupported ZIP");
    mz_zip_writer_end(&zip);
}
static void makeArchive(NSString *path,BOOL omitCookies) {
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
        NSString *pending=[root stringByAppendingPathComponent:@"restore-pending.txt"];
        NSFileManager *fm=NSFileManager.defaultManager;
        if(strcmp(argv[1],"prepare")==0 ||
           strcmp(argv[1],"prepare-interruption")==0 ||
           strcmp(argv[1],"prepare-rollback")==0) {
            check(PDStorageBootstrap()==PDStorageStateRecovered,@"bootstrap new sandbox for v2");
            put([home stringByAppendingPathComponent:@"Library/WebKit/localstorage.db"],@"WEB_OLD");
            put([home stringByAppendingPathComponent:@"Library/Cookies/Cookies.binarycookies"],@"COOKIE_OLD");
            check(PDExperimentalRelocateWebKitAndCookies(home,root),@"mount two experimental scope links");
            put([app stringByAppendingPathComponent:@"test.sqlite"],@"APP_OLD");
            NSString *unsupported=[home stringByAppendingPathComponent:@"unsupported.zip"];
            makeUnsupportedArchive(unsupported);
            NSError *unsupportedError=nil;
            check(!PDArchiveStageZIP([NSURL fileURLWithPath:unsupported],&unsupportedError),
                  @"unrecognized Data/Preferences scope rejected instead of silently lost");
            check(![fm fileExistsAtPath:pending],@"reject does not create pending restore");
            NSString *incomplete=[home stringByAppendingPathComponent:@"incomplete.zip"];
            makeArchive(incomplete,YES);
            NSError *incompleteError=nil;
            check(!PDArchiveStageZIP([NSURL fileURLWithPath:incomplete],&incompleteError),
                  @"missing declared Cookie scope rejected before staging");
            check(![fm fileExistsAtPath:pending],@"incomplete backup did not arm restore");
            NSString *zip=[home stringByAppendingPathComponent:@"multi.zip"];
            makeArchive(zip,NO);
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
            NSData *manifestBytes=[NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:@"manifest.json"]];
            NSDictionary *manifest=manifestBytes ? [NSJSONSerialization JSONObjectWithData:manifestBytes options:0 error:nil] : nil;
            check([manifest[@"format"] isEqualToString:@"SideloadPersist.Directory.V2"],@"manifest auto-upgrades to V2 when links verified");
            check([manifest[@"scopes"] count]==3,@"manifest enumerates all three verified scopes");
            check([readFile([app stringByAppendingPathComponent:@"test.sqlite"]) isEqualToString:@"APP_RESTORED"],
                @"Application Support replaced with v2 copy");
            check([readFile([web stringByAppendingPathComponent:@"localstorage.db"]) isEqualToString:@"WEB_RESTORED"],
                @"WebKit replaced with v2 copy");
            check([readFile([cookie stringByAppendingPathComponent:@"Cookies.binarycookies"]) isEqualToString:@"COOKIE_RESTORED"],
                @"Cookies replaced with v2 copy");
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
            NSLog(@"All v2 rollback tests passed.");
        } else {
            check(NO,@"unknown mode");
        }
        return 0;
    }
}
