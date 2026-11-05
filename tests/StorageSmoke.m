#import <Foundation/Foundation.h>
#import <sys/stat.h>
#import <unistd.h>
#import <stdlib.h>
#import "PDStorage.h"
#import "PDArchive.h"
#import "miniz.h"

static void fail(NSString *message) { NSLog(@"FAIL %@",message); exit(1); }
static void check(BOOL good, NSString *message) {
    if (!good) fail(message);
    NSLog(@"PASS %@",message);
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
            makeZip(valid,"SideloadPersist/Data/Application Support/restored.json","RESTORED");
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
            NSArray *backups=[fm contentsOfDirectoryAtPath:[[home stringByAppendingPathComponent:
                @"Documents/SideloadPersist"] stringByAppendingPathComponent:@"Backups"] error:nil];
            check(backups.count==1,@"previous data preserved as backup");
            NSLog(@"All restore smoke tests passed.");
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
