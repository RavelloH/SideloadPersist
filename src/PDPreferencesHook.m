#import "PDPreferencesHook.h"
#import "PDPreferencesBackend.h"
#import <objc/runtime.h>
#import "fishhook.h"
#import <CoreFoundation/CFPreferences.h>

static NSUserDefaults *s_standard;
static NSMutableSet<NSString *> *s_domains;
static BOOL s_active=NO;
static const void *PDPreferenceSuiteKey=&PDPreferenceSuiteKey;
static NSString *s_status=@"未安装";
static id (*originalInitSuite)(id,SEL,NSString *);
static id (*originalObject)(id,SEL,NSString *);
static void (*originalSetObject)(id,SEL,id,NSString *);
static void (*originalRemoveObject)(id,SEL,NSString *);
static BOOL (*originalSynchronize)(id,SEL);
static NSDictionary *(*originalPersistentDomain)(id,SEL,NSString *);
static void (*originalSetPersistentDomain)(id,SEL,NSDictionary *,NSString *);
static void (*originalRemovePersistentDomain)(id,SEL,NSString *);
static NSDictionary *(*originalDictionaryRepresentation)(id,SEL);

static NSString *PDAppDomain(void) {
    NSString *bundle=NSBundle.mainBundle.bundleIdentifier;
    return bundle.length ? bundle : @"SideloadPersist.StandaloneTest";
}
static NSString *PDDomainForDefaults(id defaults) {
    if(defaults==s_standard) return PDAppDomain();
    return objc_getAssociatedObject(defaults,PDPreferenceSuiteKey);
}
static BOOL PDManagedDomain(NSString *domain) {
    if(![domain isKindOfClass:NSString.class] || !domain.length) return NO;
    @synchronized(s_domains) {return [s_domains containsObject:domain];}
}
static void PDLogPreferenceError(NSString *action, NSString *domain, NSError *error) {
    NSLog(@"[SideloadPersist Preferences] %@ %@: %@",action,domain,error.localizedDescription);
}
static BOOL PDSetupDomain(NSString *domain, NSDictionary *initial) {
    NSError *error=nil;
    BOOL okay=PDPreferencesEnsureDomain(domain,initial,&error);
    if(!okay) {PDLogPreferenceError(@"初始化失败",domain,error);
        PDPreferencesMarkIntegrityFailure(@"initialize-domain");}
    else @synchronized(s_domains) {[s_domains addObject:domain];}
    return okay;
}
static id PDNewSuite(id self,SEL selector,NSString *suite) {
    id result=originalInitSuite(self,selector,suite);
    if(!result || !PDPreferencesShouldManageDomain(suite)) return result;
    NSDictionary *initial=originalPersistentDomain(result,@selector(persistentDomainForName:),suite);
    if(PDSetupDomain(suite,initial ?: @{}))
        objc_setAssociatedObject(result,PDPreferenceSuiteKey,suite,OBJC_ASSOCIATION_COPY_NONATOMIC);
    return result;
}
static id PDObject(id self,SEL selector,NSString *key) {
    NSString *domain=PDDomainForDefaults(self);
    if(!domain.length || !key.length) return originalObject(self,selector,key);
    BOOL present=NO,removed=NO;
    id value=PDPreferencesValue(domain,key,&present,&removed);
    if(present) return value;
    if(removed) return nil;
    // Preserve system global defaults, registration defaults and legacy
    // domain reads for keys that have never been written to the live store.
    return originalObject(self,selector,key);
}
static void PDSet(id self,SEL selector,id value,NSString *key) {
    NSString *domain=PDDomainForDefaults(self);
    if(!domain.length || !key.length) {originalSetObject(self,selector,value,key);return;}
    NSError *error=nil;
    if(!PDPreferencesWriteValue(domain,key,value,&error)) {
        PDLogPreferenceError(@"写入失败，回退原生 API",domain,error);
        PDPreferencesMarkIntegrityFailure(@"set-value");
        originalSetObject(self,selector,value,key);
        return;
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:NSUserDefaultsDidChangeNotification object:self];
}
static void PDRemove(id self,SEL selector,NSString *key) {
    NSString *domain=PDDomainForDefaults(self);
    if(!domain.length || !key.length) {originalRemoveObject(self,selector,key);return;}
    NSError *error=nil;
    if(!PDPreferencesWriteValue(domain,key,nil,&error)) {
        PDLogPreferenceError(@"删除失败，回退原生 API",domain,error);
        PDPreferencesMarkIntegrityFailure(@"remove-value");
        originalRemoveObject(self,selector,key);
        return;
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:NSUserDefaultsDidChangeNotification object:self];
}
static BOOL PDSynchronize(id self,SEL selector) {
    // Live files are committed during every successful mutation.
    return originalSynchronize(self,selector);
}
static NSDictionary *PDPersistentDomain(id self,SEL selector,NSString *name) {
    if(PDManagedDomain(name)) return PDPreferencesValues(name);
    return originalPersistentDomain(self,selector,name);
}
static void PDSetPersistentDomain(id self,SEL selector,NSDictionary *values,NSString *name) {
    if(!PDManagedDomain(name)) {originalSetPersistentDomain(self,selector,values,name);return;}
    NSError *error=nil;
    if(!PDPreferencesReplaceDomain(name,values,&error)) {
        PDLogPreferenceError(@"批量替换失败，回退原生 API",name,error);
        PDPreferencesMarkIntegrityFailure(@"replace-domain");
        originalSetPersistentDomain(self,selector,values,name);
    }
}
static void PDRemovePersistentDomain(id self,SEL selector,NSString *name) {
    if(!PDManagedDomain(name)) {originalRemovePersistentDomain(self,selector,name);return;}
    NSError *error=nil;
    if(!PDPreferencesRemoveDomain(name,&error)) {
        PDLogPreferenceError(@"移除偏好域失败，回退原生 API",name,error);
        PDPreferencesMarkIntegrityFailure(@"remove-domain");
        originalRemovePersistentDomain(self,selector,name);
    }
}
static NSDictionary *PDDictionaryRepresentation(id self,SEL selector) {
    NSDictionary *original=originalDictionaryRepresentation(self,selector);
    NSString *domain=PDDomainForDefaults(self);
    if(!domain.length) return original;
    NSMutableDictionary *result=[original mutableCopy] ?: [NSMutableDictionary dictionary];
    for(NSString *key in PDPreferencesRemovedKeys(domain)) [result removeObjectForKey:key];
    [result addEntriesFromDictionary:PDPreferencesValues(domain)];
    return result;
}
// Explicit typed methods: Foundation implementations need not delegate to
// objectForKey:, depending on the OS and their private concrete classes.
static BOOL (*origBool)(id,SEL,NSString *);
static NSInteger (*origInteger)(id,SEL,NSString *);
static float (*origFloat)(id,SEL,NSString *);
static double (*origDouble)(id,SEL,NSString *);
static NSString *(*origString)(id,SEL,NSString *);
static NSData *(*origData)(id,SEL,NSString *);
static NSArray *(*origArray)(id,SEL,NSString *);
static NSDictionary *(*origDictionary)(id,SEL,NSString *);
static NSArray *(*origStringArray)(id,SEL,NSString *);
static BOOL PDBool(id self,SEL cmd,NSString *key) {id v=PDObject(self,@selector(objectForKey:),key);return [v respondsToSelector:@selector(boolValue)]?[v boolValue]:NO;}
static NSInteger PDInteger(id self,SEL cmd,NSString *key) {id v=PDObject(self,@selector(objectForKey:),key);return [v respondsToSelector:@selector(integerValue)]?[v integerValue]:0;}
static float PDFloat(id self,SEL cmd,NSString *key) {id v=PDObject(self,@selector(objectForKey:),key);return [v respondsToSelector:@selector(floatValue)]?[v floatValue]:0;}
static double PDDouble(id self,SEL cmd,NSString *key) {id v=PDObject(self,@selector(objectForKey:),key);return [v respondsToSelector:@selector(doubleValue)]?[v doubleValue]:0;}
static NSString *PDString(id self,SEL cmd,NSString *key) {id v=PDObject(self,@selector(objectForKey:),key);return [v isKindOfClass:NSString.class]?v:nil;}
static NSData *PDData(id self,SEL cmd,NSString *key) {id v=PDObject(self,@selector(objectForKey:),key);return [v isKindOfClass:NSData.class]?v:nil;}
static NSArray *PDArray(id self,SEL cmd,NSString *key) {id v=PDObject(self,@selector(objectForKey:),key);return [v isKindOfClass:NSArray.class]?v:nil;}
static NSDictionary *PDDictionary(id self,SEL cmd,NSString *key) {id v=PDObject(self,@selector(objectForKey:),key);return [v isKindOfClass:NSDictionary.class]?v:nil;}
static NSArray *PDStringArray(id self,SEL cmd,NSString *key) {
    NSArray *values=PDArray(self,cmd,key);
    for(id v in values) if(![v isKindOfClass:NSString.class]) return nil;
    return values;
}
static void (*origSetBool)(id,SEL,BOOL,NSString *);
static void (*origSetInteger)(id,SEL,NSInteger,NSString *);
static void (*origSetDouble)(id,SEL,double,NSString *);
static void (*origSetFloat)(id,SEL,float,NSString *);
static void PDSetBool(id self,SEL cmd,BOOL value,NSString *key) {PDSet(self,@selector(setObject:forKey:),@(value),key);}
static void PDSetInteger(id self,SEL cmd,NSInteger value,NSString *key) {PDSet(self,@selector(setObject:forKey:),@(value),key);}
static void PDSetDouble(id self,SEL cmd,double value,NSString *key) {PDSet(self,@selector(setObject:forKey:),@(value),key);}
static void PDSetFloat(id self,SEL cmd,float value,NSString *key) {PDSet(self,@selector(setObject:forKey:),@(value),key);}

static void PDSwap(SEL selector,IMP replacement,IMP *original) {
    Method method=class_getInstanceMethod(NSUserDefaults.class,selector);
    if(method) *original=method_setImplementation(method,replacement);
}

// CoreFoundation is not toll-free bridged with NSUserDefaults. Rebind the
// application-imported CFPreferences functions in addition to ObjC methods.
// Covers app-level calls and current-user / any-host explicit-domain calls.
// CFPreferences batch/host-specific/other-user domains remain native until
// their behaviors have been tested independently on iOS.
static CFPropertyListRef (*origCFCopyApp)(CFStringRef,CFStringRef);
static void (*origCFSetApp)(CFStringRef,CFPropertyListRef,CFStringRef);
static Boolean (*origCFSyncApp)(CFStringRef);
static CFPropertyListRef (*origCFCopyValue)(CFStringRef,CFStringRef,CFStringRef,CFStringRef);
static void (*origCFSetValue)(CFStringRef,CFPropertyListRef,CFStringRef,CFStringRef,CFStringRef);
static Boolean (*origCFSynchronize)(CFStringRef,CFStringRef,CFStringRef);
static BOOL PDCFApp( CFStringRef identifier) {
    if(!identifier) return NO;
    if(identifier==kCFPreferencesCurrentApplication) return YES;
    NSString *value=(__bridge NSString *)identifier;
    return [value isEqualToString:PDAppDomain()];
}
static CFPropertyListRef PDCFCopyApp(CFStringRef key,CFStringRef app) {
    if(!PDCFApp(app) || !key) return origCFCopyApp ? origCFCopyApp(key,app) : NULL;
    BOOL present=NO,removed=NO;
    id result=PDPreferencesValue(PDAppDomain(),(__bridge NSString *)key,&present,&removed);
    if(present) return CFBridgingRetain(result);
    if(removed) return NULL;
    return origCFCopyApp?origCFCopyApp(key,app):NULL;
}
static void PDCFSetApp(CFStringRef key,CFPropertyListRef value,CFStringRef app) {
    if(!PDCFApp(app) || !key) {if(origCFSetApp)origCFSetApp(key,value,app);return;}
    NSError *error=nil;
    if(!PDPreferencesWriteValue(PDAppDomain(),(__bridge NSString *)key,
                (__bridge id)value,&error)) {
        PDLogPreferenceError(@"CFPreferencesSetAppValue failed",PDAppDomain(),error);
        PDPreferencesMarkIntegrityFailure(@"cf-set-app");
        if(origCFSetApp)origCFSetApp(key,value,app);
    }
}
static Boolean PDCFSyncApp(CFStringRef app) {
    if(PDCFApp(app) && PDPreferencesDomainExists(PDAppDomain())) return true;
    return origCFSyncApp ? origCFSyncApp(app) : false;
}
static BOOL PDCFExplicitAppDomain(CFStringRef app,CFStringRef user,CFStringRef host) {
    return PDCFApp(app) && user==kCFPreferencesCurrentUser && host==kCFPreferencesAnyHost;
}
static CFPropertyListRef PDCFCopyValue(CFStringRef key,CFStringRef app,
                                       CFStringRef user,CFStringRef host) {
    if(!key || !PDCFExplicitAppDomain(app,user,host))
        return origCFCopyValue ? origCFCopyValue(key,app,user,host) : NULL;
    BOOL present=NO,removed=NO;
    id value=PDPreferencesValue(PDAppDomain(),(__bridge NSString *)key,&present,&removed);
    if(present) return CFBridgingRetain(value);
    if(removed) return NULL;
    return origCFCopyValue ? origCFCopyValue(key,app,user,host) : NULL;
}
static void PDCFSetValue(CFStringRef key,CFPropertyListRef value,CFStringRef app,
                          CFStringRef user,CFStringRef host) {
    if(!key || !PDCFExplicitAppDomain(app,user,host)) {
        if(origCFSetValue) origCFSetValue(key,value,app,user,host);
        return;
    }
    NSError *error=nil;
    if(!PDPreferencesWriteValue(PDAppDomain(),(__bridge NSString *)key,(__bridge id)value,&error)) {
        PDLogPreferenceError(@"CFPreferencesSetValue failed",PDAppDomain(),error);
        PDPreferencesMarkIntegrityFailure(@"cf-set-domain");
        if(origCFSetValue) origCFSetValue(key,value,app,user,host);
    }
}
static Boolean PDCFSynchronize(CFStringRef app,CFStringRef user,CFStringRef host) {
    if(PDCFExplicitAppDomain(app,user,host) && PDPreferencesDomainExists(PDAppDomain())) return true;
    return origCFSynchronize ? origCFSynchronize(app,user,host) : false;
}
BOOL PDPreferencesHookActive(void) {return s_active;}
NSString *PDPreferencesHookStatus(void) {return s_status;}
BOOL PDPreferencesInstallHook(void) {
    if(s_active) return YES;
    // Old experimental builds unintentionally captured Apple framework suites.
    // Keep their copies for recovery in native Caches, never in exported ZIPs.
    NSUInteger excluded=0;
    NSError *quarantineError=nil;
    if(!PDPreferencesQuarantineUnmanagedDomains(&excluded,&quarantineError)) {
        s_status=@"隔离旧版系统偏好文件失败；未安装 Preferences Hook";
        PDPreferencesMarkIntegrityFailure(@"quarantine-legacy-domain");
        NSLog(@"[SideloadPersist Preferences] %@: %@",s_status,quarantineError);
        return NO;
    }
    if(excluded)
        NSLog(@"[SideloadPersist Preferences] 隔离了 %lu 个非应用偏好域文件（保留于 Library/Caches）",
              (unsigned long)excluded);
    s_domains=[NSMutableSet set];
    s_standard=[NSUserDefaults standardUserDefaults];
    NSString *domain=PDAppDomain();
    NSDictionary *initial=[s_standard persistentDomainForName:domain] ?: @{};
    if(!PDSetupDomain(domain,initial)) {
        s_status=@"初始化偏好数据失败；未安装 Hook";
        return NO;
    }
    // Store the original implementations before installing the hooks.
    PDSwap(@selector(initWithSuiteName:),(IMP)PDNewSuite,(IMP *)&originalInitSuite);
    PDSwap(@selector(objectForKey:),(IMP)PDObject,(IMP *)&originalObject);
    PDSwap(@selector(setObject:forKey:),(IMP)PDSet,(IMP *)&originalSetObject);
    PDSwap(@selector(removeObjectForKey:),(IMP)PDRemove,(IMP *)&originalRemoveObject);
    PDSwap(@selector(synchronize),(IMP)PDSynchronize,(IMP *)&originalSynchronize);
    PDSwap(@selector(persistentDomainForName:),(IMP)PDPersistentDomain,(IMP *)&originalPersistentDomain);
    PDSwap(@selector(setPersistentDomain:forName:),(IMP)PDSetPersistentDomain,(IMP *)&originalSetPersistentDomain);
    PDSwap(@selector(removePersistentDomainForName:),(IMP)PDRemovePersistentDomain,(IMP *)&originalRemovePersistentDomain);
    PDSwap(@selector(dictionaryRepresentation),(IMP)PDDictionaryRepresentation,(IMP *)&originalDictionaryRepresentation);
    PDSwap(@selector(boolForKey:),(IMP)PDBool,(IMP *)&origBool);
    PDSwap(@selector(integerForKey:),(IMP)PDInteger,(IMP *)&origInteger);
    PDSwap(@selector(floatForKey:),(IMP)PDFloat,(IMP *)&origFloat);
    PDSwap(@selector(doubleForKey:),(IMP)PDDouble,(IMP *)&origDouble);
    PDSwap(@selector(stringForKey:),(IMP)PDString,(IMP *)&origString);
    PDSwap(@selector(dataForKey:),(IMP)PDData,(IMP *)&origData);
    PDSwap(@selector(arrayForKey:),(IMP)PDArray,(IMP *)&origArray);
    PDSwap(@selector(dictionaryForKey:),(IMP)PDDictionary,(IMP *)&origDictionary);
    PDSwap(@selector(stringArrayForKey:),(IMP)PDStringArray,(IMP *)&origStringArray);
    PDSwap(@selector(setBool:forKey:),(IMP)PDSetBool,(IMP *)&origSetBool);
    PDSwap(@selector(setInteger:forKey:),(IMP)PDSetInteger,(IMP *)&origSetInteger);
    PDSwap(@selector(setFloat:forKey:),(IMP)PDSetFloat,(IMP *)&origSetFloat);
    PDSwap(@selector(setDouble:forKey:),(IMP)PDSetDouble,(IMP *)&origSetDouble);
#if TARGET_OS_IPHONE
    struct rebinding bindings[]={
        {"CFPreferencesCopyAppValue",(void *)PDCFCopyApp,(void **)&origCFCopyApp},
        {"CFPreferencesSetAppValue",(void *)PDCFSetApp,(void **)&origCFSetApp},
        {"CFPreferencesAppSynchronize",(void *)PDCFSyncApp,(void **)&origCFSyncApp},
        {"CFPreferencesCopyValue",(void *)PDCFCopyValue,(void **)&origCFCopyValue},
        {"CFPreferencesSetValue",(void *)PDCFSetValue,(void **)&origCFSetValue},
        {"CFPreferencesSynchronize",(void *)PDCFSynchronize,(void **)&origCFSynchronize}
    };
    int result=rebind_symbols(bindings,sizeof(bindings)/sizeof(bindings[0]));
    s_status=result==0?@"NSUserDefaults + CFPreferences app-level hook installed":
                       @"NSUserDefaults hooked; CFPreferences fishhook failed";
#else
    s_status=@"NSUserDefaults Hook (macOS smoke; CFPreferences rebinding on iOS only)";
#endif
    s_active=YES;
    NSLog(@"[SideloadPersist Preferences] %@ %@",s_status,PDPreferencesHealth());
    return YES;
}
