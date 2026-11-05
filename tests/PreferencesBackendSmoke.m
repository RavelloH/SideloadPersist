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
            verify(PDPreferencesDomainExists(domain),@"hook-backed live domain exists");
            verify([PDPreferencesValues(domain)[@"StorageProbe.HookCounter"] integerValue]==8,
                @"native hook wrote live backing file");
            NSLog(@"Hook verified: %@",PDPreferencesHookStatus());
        } else verify(NO,@"unknown test mode");
    }
    return 0;
}
