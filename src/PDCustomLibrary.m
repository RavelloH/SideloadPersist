#import "PDCustomLibrary.h"
#import "PDStorage.h"
#import "PDExperimentalScope.h"
#import <sys/stat.h>
#import <unistd.h>
#import <limits.h>

static NSString *PDExtraRoot(void) {
    // Application Support is already a verified, versioned ZIP scope.
    // Nesting here means V1/V2/V3 restores inherit the extra directories
    // without introducing a new unchecked Data/<scope> ZIP namespace.
    return [PDStorageTarget() stringByAppendingPathComponent:@"SideloadPersist.Library"];
}
static NSString *PDExtraHome(void) {
    return [PDStorageDocuments() stringByDeletingLastPathComponent];
}
static NSString *PDExtraLibrary(void) {
    return [PDExtraHome() stringByAppendingPathComponent:@"Library"];
}
static NSString *PDAppIdentifier(void) {
    NSString *identifier=NSBundle.mainBundle.bundleIdentifier;
    return identifier.length ? identifier : @"SideloadPersist.StandaloneTest";
}
static BOOL PDSystemOwnedName(NSString *name) {
    static NSSet<NSString *> *reserved=nil;
    static dispatch_once_t once;
    dispatch_once(&once,^{
        reserved=[NSSet setWithArray:@[
            @"application support", @"webkit", @"cookies", @"preferences",
            @"caches", @"saved application state", @"splashboard", @"snapshots",
            @"keyboard", @"keyboards", @"logs", @"crashes", @"group containers",
            @"syncedpreferences", @"com.apple", @"coreduet", @"accounts",
            @"tcc", @"httpstorages", @"sideloadpersist", @"sideloadpersist.library"
        ]];
    });
    NSString *lower=name.lowercaseString;
    return [reserved containsObject:lower] ||
        [lower hasPrefix:@"com.apple."] || [lower hasPrefix:@"apple."] ||
        [lower hasPrefix:@"group."] || [lower hasPrefix:@"system."] ||
        [lower hasPrefix:@"com.apple-"];
}
BOOL PDCustomLibrarySafeName(NSString *name) {
    if(![name isKindOfClass:NSString.class] || !name.length || name.length>80 ||
       [name hasPrefix:@"."] || [name hasPrefix:@"~"] || [name hasPrefix:@" "] ||
       [name hasSuffix:@" "] || [name containsString:@"/"] ||
       [name containsString:@"\\"] || [name containsString:@":"] ||
       [name isEqualToString:@"."] || [name isEqualToString:@".."] ||
       PDSystemOwnedName(name)) return NO;
    for(NSUInteger i=0;i<name.length;i++) {
        unichar c=[name characterAtIndex:i];
        if(c<0x20 || c==0x7f) return NO;
    }
    return YES;
}
static BOOL PDAppNamedDirectory(NSString *name) {
    if(!PDCustomLibrarySafeName(name)) return NO;
    NSString *app=PDAppIdentifier();
    if([name isEqualToString:app]) return YES;
    NSString *display=NSBundle.mainBundle.infoDictionary[@"CFBundleDisplayName"];
    if(![display isKindOfClass:NSString.class] || display.length<5)
        display=NSBundle.mainBundle.infoDictionary[@"CFBundleName"];
    if(![display isKindOfClass:NSString.class] || display.length<5) return NO;
    // The app's own name followed by a distinct suffix is high confidence.
    // Unknown framework/system directory names are only reported, not moved.
    return [name hasPrefix:display] || [name isEqualToString:display];
}
static NSSet<NSString *> *PDExplicitScopes(void) {
    id input=NSBundle.mainBundle.infoDictionary[@"SideloadPersistAdditionalLibraryScopes"];
    if(![input isKindOfClass:NSArray.class]) return [NSSet set];
    NSMutableSet *result=[NSMutableSet set];
    for(id item in input) {
        if([item isKindOfClass:NSString.class] && PDCustomLibrarySafeName(item))
            [result addObject:item];
    }
    return result;
}
static BOOL PDIsOurExtraLink(NSString *name) {
    NSString *source=[PDExtraLibrary() stringByAppendingPathComponent:name];
    NSString *target=[PDExtraRoot() stringByAppendingPathComponent:name];
    struct stat st={0};
    if(lstat(source.fileSystemRepresentation,&st)!=0 || !S_ISLNK(st.st_mode)) return NO;
    if(lstat(target.fileSystemRepresentation,&st)!=0 || !S_ISDIR(st.st_mode)) return NO;
    char value[PATH_MAX]={0};
    ssize_t len=readlink(source.fileSystemRepresentation,value,sizeof(value)-1);
    if(len<=0 || len>=(ssize_t)sizeof(value)) return NO;
    value[len]=0;
    return [target isEqualToString:[NSString stringWithUTF8String:value]];
}
NSArray<NSString *> *PDCustomLibraryVerified(void) {
    if(!PDStorageIsLinked()) return @[];
    NSArray *names=[NSFileManager.defaultManager contentsOfDirectoryAtPath:PDExtraRoot() error:nil];
    if(!names.count) return @[];
    NSMutableArray *verified=[NSMutableArray array];
    for(id name in names) {
        if(PDCustomLibrarySafeName(name) && PDIsOurExtraLink(name))
            [verified addObject:name];
    }
    return [verified sortedArrayUsingSelector:@selector(compare:)];
}
void PDCustomLibraryMount(void) {
    if(!PDStorageIsLinked()) return;
    NSFileManager *fm=NSFileManager.defaultManager;
    NSArray<NSString *> *libraryNames=[fm contentsOfDirectoryAtPath:PDExtraLibrary() error:nil] ?: @[];
    NSArray<NSString *> *savedNames=[fm contentsOfDirectoryAtPath:PDExtraRoot() error:nil] ?: @[];
    NSSet *explicitNames=PDExplicitScopes();
    NSMutableSet<NSString *> *chosen=[NSMutableSet set];
    NSMutableArray<NSDictionary *> *report=[NSMutableArray array];
    NSUInteger unselected=0,failures=0;
    if(libraryNames.count>256 || savedNames.count>64) {
        PDStorageTrace(@"Extra Library discovery limit exceeded; refusing any new mounts");
        NSDictionary *info=@{@"format":@"SideloadPersist.LibraryDiscovery.V1",
                             @"error":@"directory-count-exceeded",
                             @"sourceEntries":@(libraryNames.count),@"savedEntries":@(savedNames.count)};
        NSData *bytes=[NSJSONSerialization dataWithJSONObject:info options:NSJSONWritingPrettyPrinted error:nil];
        [bytes writeToFile:[PDStorageRoot() stringByAppendingPathComponent:@"library-discovery.json"]
                   options:NSDataWritingAtomic error:nil];
        return;
    }
    // Candidate path is always one top-level Library directory, never an
    // arbitrary nested filesystem path. System-managed names are vetoed even
    // when explicitly listed in Info.plist or found in an old backup.
    for(id name in libraryNames) {
        if(!PDCustomLibrarySafeName(name)) {unselected++;continue;}
        if([explicitNames containsObject:name] || PDAppNamedDirectory(name))
            [chosen addObject:name];
        else unselected++;
    }
    for(id name in savedNames)
        if(PDCustomLibrarySafeName(name)) [chosen addObject:name];
    // Only auto-create configured paths if their existing data or a saved
    // target exists. No need to add empty directories for hypothetical scopes.
    for(NSString *name in explicitNames) {
        NSString *source=[PDExtraLibrary() stringByAppendingPathComponent:name];
        NSString *target=[PDExtraRoot() stringByAppendingPathComponent:name];
        if([fm fileExistsAtPath:source] || [fm fileExistsAtPath:target])
            [chosen addObject:name];
    }
    for(NSString *name in [[chosen allObjects] sortedArrayUsingSelector:@selector(compare:)]) {
        NSString *target=[PDExtraRoot() stringByAppendingPathComponent:name];
        NSString *reason=nil;
        BOOL mapped=PDRelocateLibraryDirectory(name,PDExtraHome(),target,&reason);
        if(!mapped) failures++;
        [report addObject:@{
            @"name":name,
            @"mapped":@(mapped),
            @"reason":reason ?: @"unknown",
            @"path":[@"Library" stringByAppendingPathComponent:name],
            @"backupPath":[@"Data/Application Support/SideloadPersist.Library"
                             stringByAppendingPathComponent:name]
        }];
        PDStorageTrace(@"Extra Library %@ mapped=%@ reason=%@",
                       name,mapped?@"yes":@"no",reason);
    }
    NSDictionary *info=@{
        @"format":@"SideloadPersist.LibraryDiscovery.V1",
        @"mapped":PDCustomLibraryVerified(),
        @"candidates":report,
        @"unselectedLibraryEntries":@(unselected),
        @"conflicts":@(failures),
        @"generatedAt":@([[NSDate date] timeIntervalSince1970])
    };
    NSData *bytes=[NSJSONSerialization dataWithJSONObject:info options:NSJSONWritingPrettyPrinted error:nil];
    if(bytes && ![bytes writeToFile:[PDStorageRoot() stringByAppendingPathComponent:@"library-discovery.json"]
                  options:NSDataWritingAtomic error:nil])
        PDStorageTrace(@"Could not save private Library discovery report");
}
