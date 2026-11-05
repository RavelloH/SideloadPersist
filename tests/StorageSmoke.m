#import <Foundation/Foundation.h>
#import <sys/stat.h>
#import <unistd.h>
#import <stdlib.h>
#import "PDStorage.h"
#import "PDExperimentalScope.h"
#import "PDArchive.h"
#import "miniz.h"

static void fail(NSString *message) { NSLog(@"FAIL %@",message); exit(1); }
static void check(BOOL good, NSString *message) {
    if (!good) fail(message);
    NSLog(@"PASS %@",message);
}
static void makeZipWithAppleDouble(NSString *path) {
    mz_zip_archive zip={0};
    if (!mz_zip_writer_init_file(&zip,path.fileSystemRepresentation,0)) fail(@"start metadata ZIP writer");
    check(mz_zip_writer_add_mem(&zip,"SideloadPersist/Data/Application Support/restored.json",
                                "RESTORED",strlen("RESTORED"),MZ_BEST_SPEED),@"add primary data entry");
    check(mz_zip_writer_add_mem(&zip,"__MACOSX/SideloadPersist/Data/Application Support/._restored.json",
                                "APPLEDATA",strlen("APPLEDATA"),MZ_BEST_SPEED),@"add AppleDouble ZIP entry");
    check(mz_zip_writer_add_mem(&zip,"SideloadPersist/Data/Application Support/.DS_Store",
                                "METADATA",strlen("METADATA"),MZ_BEST_SPEED),@"add Finder metadata entry");
    check(mz_zip_writer_finalize_archive(&zip),@"metadata ZIP finalize");
    mz_zip_writer_end(&zip);
}
static void makeZip(NSString *path, const char *entryName, const char *contents) {
    mz_zip_archive zip={0};
    if (!mz_zip_writer_init_file(&zip,path.fileSystemRepresentation,0)) fail(@"start zip writer");
    if (!mz_zip_writer_add_mem(&zip,entryName,contents,strlen(contents),MZ_BEST_SPEED)) fail(@"add ZIP entry");
    if (!mz_zip_writer_finalize_archive(&zip)) fail(@"ZIP finalize");
    mz_zip_writer_end(&zip);
}
int main(int argc,char **argv) {
    @autoreleasepool {
        if (argc!=2) fail(@"Missing mode");
        NSString *home=[NSString stringWithUTF8String:getenv("HOME")];
        check(home.length>5,@"isolated HOME set");
        NSString *source=[home stringByAppendingPathComponent:@"Library/Application Support"];
        NSString *target=[home stringByAppendingPathComponent:@"Documents/SideloadPersist/Data/Application Support"];
        NSFileManager *fm=NSFileManager.defaultManager;
        NSString *seed=[source stringByAppendingPathComponent:@"seed.txt"];
        if(strcmp(argv[1],"prepare")==0) {
            check([fm createDirectoryAtPath:source withIntermediateDirectories:YES attributes:nil error:nil],
                @"create legacy AppSupport");
            check([@"ORIGINAL" writeToFile:seed atomically:YES encoding:NSUTF8StringEncoding error:nil],
                @"seed legacy file");
            check(PDStorageBootstrap()==PDStorageStateRecovered,@"directory migrated");
            check(PDStorageIsLinked(),@"symlink points to persistent folder");
            NSString *oldContent=[NSString stringWithContentsOfFile:seed encoding:NSUTF8StringEncoding error:nil];
            check([oldContent isEqualToString:@"ORIGINAL"],@"old path retains data");
            NSString *newPath=[target stringByAppendingPathComponent:@"seed.txt"];
            check([fm fileExistsAtPath:newPath],@"Documents contains original file");
            NSString *nested=[source stringByAppendingPathComponent:@"new/nested"];
            check([fm createDirectoryAtPath:nested withIntermediateDirectories:YES attributes:nil error:nil],
                  @"Foundation mkdir through symlink");
            check([@"NEW" writeToFile:[nested stringByAppendingPathComponent:@"new.txt"]
                              atomically:YES encoding:NSUTF8StringEncoding error:nil],
                  @"write through symlink");
            check([fm fileExistsAtPath:[target stringByAppendingPathComponent:@"new/nested/new.txt"]],
                  @"new file physically in Documents");
            NSString *evil=[home stringByAppendingPathComponent:@"evil.zip"];
            makeZip(evil,"../ESCAPE.txt","MALICIOUS");
            NSError *err=nil;
            check(!PDArchiveStageZIP([NSURL fileURLWithPath:evil],&err),@"ZIP traversal rejected");
            NSString *valid=[home stringByAppendingPathComponent:@"valid.zip"];
            makeZipWithAppleDouble(valid);
            NSString *id=PDArchiveStageZIP([NSURL fileURLWithPath:valid],&err);
            check(id.length==36,@"archive staged");
            check([fm fileExistsAtPath:seed],@"import has not altered active original data");
            NSLog(@"All preparation smoke tests passed.");
        } else if(strcmp(argv[1],"apply")==0) {
            check(PDStorageBootstrap()==PDStorageStateReady,@"cold boot restored and mounted");
            check(PDStorageIsLinked(),@"symlink valid after restore");
            check([[NSString stringWithContentsOfFile:[source stringByAppendingPathComponent:@"restored.json"]
                                              encoding:NSUTF8StringEncoding error:nil]
                       isEqualToString:@"RESTORED"],@"restored bytes visible through old path");
            check(![fm fileExistsAtPath:seed],@"new content replaced original atomically");
            check(![fm fileExistsAtPath:[source stringByAppendingPathComponent:@"._restored.json"]],
                  @"AppleDouble metadata not restored");
            check(![fm fileExistsAtPath:[source stringByAppendingPathComponent:@".DS_Store"]],
                  @"Finder metadata not restored");
            NSArray *backups=[fm contentsOfDirectoryAtPath:[[home stringByAppendingPathComponent:
                @"Documents/SideloadPersist"] stringByAppendingPathComponent:@"Backups"] error:nil];
            check(backups.count==1,@"previous data preserved as backup");
            NSLog(@"All restore smoke tests passed.");
        } else if (strcmp(argv[1],"experiment")==0) {
            NSString *root=[home stringByAppendingPathComponent:@"Documents/SideloadPersist"];
            NSString *web=[home stringByAppendingPathComponent:@"Library/WebKit"];
            NSString *cookies=[home stringByAppendingPathComponent:@"Library/Cookies"];
            check([fm createDirectoryAtPath:web withIntermediateDirectories:YES attributes:nil error:nil],@"create simulated WebKit directory");
            check([fm createDirectoryAtPath:cookies withIntermediateDirectories:YES attributes:nil error:nil],@"create simulated Cookies directory");
            check([@"WEB_DATA" writeToFile:[web stringByAppendingPathComponent:@"data.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil],@"seed simulated WebKit data");
            check([@"COOKIE_DATA" writeToFile:[cookies stringByAppendingPathComponent:@"data.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil],@"seed simulated Cookies data");
            check(PDRelocateWebKitAndCookies(home,root),@"experimental two-directory relocation");
            struct stat st={0};
            check(lstat(web.fileSystemRepresentation,&st)==0 && S_ISLNK(st.st_mode),@"WebKit symlink present");
            check(lstat(cookies.fileSystemRepresentation,&st)==0 && S_ISLNK(st.st_mode),@"Cookies symlink present");
            check([[NSString stringWithContentsOfFile:[web stringByAppendingPathComponent:@"data.txt"] encoding:NSUTF8StringEncoding error:nil] isEqualToString:@"WEB_DATA"],@"WebKit original path still works");
            check([[NSString stringWithContentsOfFile:[cookies stringByAppendingPathComponent:@"data.txt"] encoding:NSUTF8StringEncoding error:nil] isEqualToString:@"COOKIE_DATA"],@"Cookies original path still works");
            check(PDRelocateWebKitAndCookies(home,root),@"repeat relocation idempotent");
            NSString *third=[home stringByAppendingPathComponent:@"conflict-test"];
            check([fm createDirectoryAtPath:[third stringByAppendingPathComponent:@"Library/WebKit"] withIntermediateDirectories:YES attributes:nil error:nil],@"prepare conflict source");
            check([fm createDirectoryAtPath:[third stringByAppendingPathComponent:@"Documents/SideloadPersist/Data/WebKit"] withIntermediateDirectories:YES attributes:nil error:nil],@"prepare conflict target");
            check([@"A" writeToFile:[third stringByAppendingPathComponent:@"Library/WebKit/a.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil],@"seed conflicting source");
            check([@"B" writeToFile:[third stringByAppendingPathComponent:@"Documents/SideloadPersist/Data/WebKit/b.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil],@"seed conflicting target");
            check(!PDRelocateWebKitAndCookies(third,[third stringByAppendingPathComponent:@"Documents/SideloadPersist"]),@"conflicting source/target rejected");
            check([fm fileExistsAtPath:[third stringByAppendingPathComponent:@"Library/WebKit/a.txt"]],@"source retained after conflict");
            check([fm fileExistsAtPath:[third stringByAppendingPathComponent:@"Documents/SideloadPersist/Data/WebKit/b.txt"]],@"target retained after conflict");
            NSLog(@"All WebKit/Cookies test-only relocation checks passed.");
        } else if (strcmp(argv[1],"prepare-bare")==0) {
            check(PDStorageBootstrap()==PDStorageStateRecovered,@"new sandbox initialized");
            NSString *zipPath=[home stringByAppendingPathComponent:@"bare.zip"];
            makeZip(zipPath,"only.txt","BARE_PAYLOAD");
            NSError *error=nil;
            check(PDArchiveStageZIP([NSURL fileURLWithPath:zipPath],&error).length==36,
                  [NSString stringWithFormat:@"bare-root ZIP import staged: %@",error ?: @"ok"]);
            NSLog(@"All bare ZIP preparation tests passed.");
        } else if (strcmp(argv[1],"apply-bare")==0) {
            check(PDStorageBootstrap()==PDStorageStateReady,@"bare ZIP applied on cold boot");
            NSString *result=[NSString stringWithContentsOfFile:[source stringByAppendingPathComponent:@"only.txt"]
                                                      encoding:NSUTF8StringEncoding error:nil];
            check([result isEqualToString:@"BARE_PAYLOAD"],@"single-file root ZIP retained its filename");
            NSLog(@"All bare ZIP restore tests passed.");
        } else fail(@"invalid mode");
        return 0;
    }
}
