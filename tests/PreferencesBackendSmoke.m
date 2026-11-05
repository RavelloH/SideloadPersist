#import <Foundation/Foundation.h>
#import <stdlib.h>
#import "PDPreferencesBackend.h"
#import "PDPreferencesHook.h"

NSString *PDStorageRoot(void) {
    NSString *home=[NSString stringWithUTF8String:getenv("HOME") ?: "/tmp"];
    return [home stringByAppendingPathComponent:@"Documents/SideloadPersist"];
}
static void verify(BOOL yes,NSString *reason) {
    if(!yes) {NSLog(@"FAIL %@",reason);exit(2);}
    NSLog(@"PASS %@",reason);
}
int main(int argc,char **argv) {
    @autoreleasepool {
        verify(argc==2,@"test mode specified");
        NSString *domain=NSBundle.mainBundle.bundleIdentifier ?: @"SideloadPersist.StandaloneTest";
        NSString *suite=@"com.ravelloh.preferences.test.suite";
        if(strcmp(argv[1],"prepare")==0) {
            NSError *error=nil;
            verify(PDPreferencesEnsureDomain(domain,@{@"existing":@"seeded"},&error),@"seed live domain");
            verify(PDPreferencesWriteValue(domain,@"count",@7,&error),@"write number");
            verify(PDPreferencesWriteValue(domain,@"example",@[@"A",@"B"],&error),@"write array");
            verify(PDPreferencesWriteValue(domain,@"existing",nil,&error),@"remove key");
            verify(PDPreferencesEnsureDomain(suite,@{},&error),@"create suite domain");
            verify(PDPreferencesWriteValue(suite,@"count",@19,&error),@"isolated suite value");
            verify([[PDPreferencesHealth() objectForKey:@"domainFiles"] integerValue]==2,@"two canonical domain files");
            NSString *path=PDPreferencesDomainFile(domain);
            verify([path hasPrefix:PDPreferencesRoot()],@"safe domain path");
            verify([path hasSuffix:@".plist"],@"single per-domain plist");
            NSLog(@"Backend persisted: %@",PDPreferencesHealth());
        } else if(strcmp(argv[1],"check")==0) {
            verify(PDPreferencesDomainExists(domain),@"domain survives process restart");
            verify([PDPreferencesValues(domain)[@"count"] integerValue]==7,@"counter restored");
            verify([PDPreferencesValues(suite)[@"count"] integerValue]==19,@"suite restored independently");
            BOOL present=YES,removed=NO;
            verify(!PDPreferencesValue(domain,@"existing",&present,&removed) && !present && removed,
                @"removed key tombstone preserved across restart");
            NSError *error=nil;
            verify(PDPreferencesReplaceDomain(domain,@{@"replacement":@"yes"},&error),
                @"replace persistent domain");
            verify(!PDPreferencesValues(domain)[@"count"],@"replaced domain drops old values");
            verify([PDPreferencesRemovedKeys(domain) containsObject:@"count"],@"replaced domain retains tombstone for old key");
            verify(PDPreferencesRemoveDomain(suite,&error),@"suite domain removal");
            verify(!PDPreferencesValues(suite)[@"count"],@"suite domain erased");
            NSLog(@"Backend verified: %@",PDPreferencesHealth());
        } else if(strcmp(argv[1],"hooks")==0) {
            NSString *nativeDomain=@"com.apple.Accessibility";
            NSString *pathDomain=@"/var/mobile/Library/Preferences/com.apple.Accessibility";
            verify(PDPreferencesShouldManageDomain(domain),@"bundle domain allowed");
            verify(PDPreferencesShouldManageDomain(@"com.ravelloh.preferences.hook.suite"),@"app suite allowed");
            verify(!PDPreferencesShouldManageDomain(nativeDomain),@"system framework domain excluded");
            verify(!PDPreferencesShouldManageDomain(pathDomain),@"absolute-path domain excluded");
            verify(!PDPreferencesShouldManageDomain(@"group.example.shared"),@"App Group suite excluded");
            NSError *legacyError=nil;
            verify(PDPreferencesEnsureDomain(nativeDomain,@{@"dummy":@"not real OS data"},&legacyError),
                @"create simulated legacy system suite");
            verify(PDPreferencesEnsureDomain(pathDomain,@{@"dummy":@"not real OS data"},&legacyError),
                @"create simulated legacy path suite");
            verify(PDPreferencesInstallHook(),@"Foundation preferences hook installed");
            verify(!PDPreferencesDomainExists(nativeDomain) && !PDPreferencesDomainExists(pathDomain),
                @"legacy system preference domain copies moved outside exported Data");
            NSString *home=[NSString stringWithUTF8String:getenv("HOME") ?: "/tmp"];
            NSString *excluded=[home stringByAppendingPathComponent:
                @"Library/Caches/SideloadPersist/ExcludedPreferences"];
            NSArray *batches=[NSFileManager.defaultManager contentsOfDirectoryAtPath:excluded error:nil];
            verify(batches.count==1,@"one non-destructive quarantine batch");
            NSString *batch=[excluded stringByAppendingPathComponent:batches.firstObject];
            NSArray *files=[NSFileManager.defaultManager contentsOfDirectoryAtPath:batch error:nil];
            verify(files.count==2,@"both system-domain mock files preserved outside ZIP");
            NSUserDefaults *prefs=NSUserDefaults.standardUserDefaults;
            [prefs setInteger:8 forKey:@"StorageProbe.HookCounter"];
            verify([prefs integerForKey:@"StorageProbe.HookCounter"]==8,@"NSUserDefaults typed integer read/write");
            [prefs setBool:YES forKey:@"StorageProbe.HookBoolean"];
            verify([prefs boolForKey:@"StorageProbe.HookBoolean"],@"NSUserDefaults typed Boolean read/write");
            [prefs setObject:@[@"Chinese",@"English"] forKey:@"StorageProbe.HookArray"];
            verify([prefs arrayForKey:@"StorageProbe.HookArray"].count==2,@"NSUserDefaults array read/write");
            NSUserDefaults *another=[[NSUserDefaults alloc] initWithSuiteName:@"com.ravelloh.preferences.hook.suite"];
            [another setInteger:22 forKey:@"StorageProbe.SuiteCounter"];
            verify([another integerForKey:@"StorageProbe.SuiteCounter"]==22,@"NSUserDefaults suite separation");
            NSUserDefaults *systemSuite=[[NSUserDefaults alloc] initWithSuiteName:nativeDomain];
            verify(systemSuite!=nil,@"native system suite remains available");
            verify(!PDPreferencesDomainExists(nativeDomain),@"opening native system suite does not recreate export");
            verify(![prefs objectForKey:@"StorageProbe.SuiteCounter"],@"standard app domain not contaminated by suite");
            [prefs removeObjectForKey:@"StorageProbe.HookBoolean"];
            verify(![prefs boolForKey:@"StorageProbe.HookBoolean"],@"NSUserDefaults remove masked");
            verify(![[prefs dictionaryRepresentation] objectForKey:@"StorageProbe.HookBoolean"],
                @"NSUserDefaults dictionaryRepresentation also masks removed key");
            // A removed managed key falls back to registered defaults, rather
            // than silently resurfacing stale values from the native plist.
            [prefs registerDefaults:@{@"StorageProbe.Registered":@"registration-value"}];
            [prefs setObject:@"override" forKey:@"StorageProbe.Registered"];
            verify([[prefs stringForKey:@"StorageProbe.Registered"] isEqualToString:@"override"],
                   @"managed value overrides registration default");
            [prefs removeObjectForKey:@"StorageProbe.Registered"];
            verify([[prefs stringForKey:@"StorageProbe.Registered"] isEqualToString:@"registration-value"],
                   @"removed key exposes registered fallback");
            verify([[prefs dictionaryRepresentation][@"StorageProbe.Registered"] isEqualToString:@"registration-value"],
                   @"dictionaryRepresentation preserves registration fallback");
            NSDictionary *previousArguments=[prefs volatileDomainForName:NSArgumentDomain] ?: @{};
            [prefs setVolatileDomain:@{@"StorageProbe.HookCounter":@99} forName:NSArgumentDomain];
            verify([prefs integerForKey:@"StorageProbe.HookCounter"]==99,
                   @"NSArgumentDomain overrides managed app value");
            verify([[prefs dictionaryRepresentation][@"StorageProbe.HookCounter"] integerValue]==99,
                   @"dictionaryRepresentation respects argument precedence");
            [prefs setVolatileDomain:previousArguments forName:NSArgumentDomain];
            NSLog(@"ARGUMENT_RESET nativeDomain=%@ liveValue=%@ observed=%@",
                  [prefs volatileDomainForName:NSArgumentDomain],
                  PDPreferencesValues(domain)[@"StorageProbe.HookCounter"],
                  [prefs objectForKey:@"StorageProbe.HookCounter"]);
            verify(![prefs volatileDomainForName:NSArgumentDomain][@"StorageProbe.HookCounter"],
                   @"temporary argument value removed without removing startup defaults");
            verify([prefs integerForKey:@"StorageProbe.HookCounter"]==8,
                   @"managed value visible after restoring argument domain");
            verify(PDPreferencesDomainExists(domain),@"hook-backed live domain exists");
            verify([PDPreferencesValues(domain)[@"StorageProbe.HookCounter"] integerValue]==8,
                @"native hook wrote live backing file");
            NSLog(@"Hook verified: %@",PDPreferencesHookStatus());
        } else if(strcmp(argv[1],"stress")==0) {
            NSError *error=nil;
            verify(PDPreferencesEnsureDomain(domain,@{},&error),@"initialize concurrent live domain");
            NSMutableArray *failures=[NSMutableArray array];
            CFAbsoluteTime begin=CFAbsoluteTimeGetCurrent();
            dispatch_apply(4,dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^(size_t worker){
                NSString *key=[NSString stringWithFormat:@"Stress.worker%lu",(unsigned long)worker];
                for(NSInteger i=0;i<100;i++) {
                    NSError *writeError=nil;
                    if(!PDPreferencesWriteValue(domain,key,@(i),&writeError)) {
                        @synchronized(failures) { [failures addObject:writeError ?: NSNull.null]; }
                    }
                }
            });
            verify(failures.count==0,@"400 concurrent atomic preference writes without errors");
            NSDictionary *values=PDPreferencesValues(domain);
            for(NSUInteger worker=0;worker<4;worker++) {
                NSString *key=[NSString stringWithFormat:@"Stress.worker%lu",(unsigned long)worker];
                verify([values[key] integerValue]==99,@"each writer's last value preserved");
            }
            verify(PDPreferencesIntegrityOK(),@"concurrent writes did not set integrity marker");
            NSLog(@"PREFERENCES_STRESS 400 writes %.3fs; size %@",CFAbsoluteTimeGetCurrent()-begin,PDPreferencesHealth());
        } else if(strcmp(argv[1],"fault")==0) {
            verify(PDPreferencesInstallHook(),@"hook installed for injected storage failure");
            verify(PDPreferencesIntegrityOK(),@"fresh installation has no integrity warning");
            NSString *file=PDPreferencesDomainFile(domain);
            NSFileManager *fm=NSFileManager.defaultManager;
            verify([fm removeItemAtPath:file error:nil],@"remove managed domain file for fault injection");
            verify([fm createDirectoryAtPath:file withIntermediateDirectories:NO
                  attributes:nil error:nil],@"simulate corrupt domain file path");
            [NSUserDefaults.standardUserDefaults setObject:@"fallback" forKey:@"StorageProbe.Fault"];
            verify(!PDPreferencesIntegrityOK(),@"native fallback marks backup integrity unsafe");
            NSString *warning=[PDStorageRoot() stringByAppendingPathComponent:@"preferences-integrity-warning.json"];
            verify([fm fileExistsAtPath:warning],@"integrity warning saved outside managed domain");
            verify([[PDPreferencesIntegrityWarning() lowercaseString] containsString:@"备份"],
                   @"backup user-facing warning is actionable");
        } else verify(NO,@"unknown test mode");
    }
    return 0;
}
