#import "PDPreferencesBackend.h"
#import "PDStorage.h"
#import <CommonCrypto/CommonDigest.h>

static NSObject *PDPreferencesGuard(void) {
    static NSObject *guard=nil;
    static dispatch_once_t once;
    dispatch_once(&once,^{guard=[NSObject new];});
    return guard;
}
static NSError *PDPreferencesError(NSInteger code, NSString *detail) {
    return [NSError errorWithDomain:@"SideloadPersist.Preferences" code:code
       userInfo:@{NSLocalizedDescriptionKey:detail ?: @"偏好数据存储失败"}];
}
NSString *PDPreferencesRoot(void) {
    return [[PDStorageRoot() stringByAppendingPathComponent:@"Data"] stringByAppendingPathComponent:@"Preferences"];
}
NSString *PDPreferencesDomainFile(NSString *domain) {
    if(![domain isKindOfClass:NSString.class] || !domain.length) return nil;
    NSData *bytes=[domain dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]={0};
    CC_SHA256(bytes.bytes,(CC_LONG)bytes.length,digest);
    NSMutableString *hash=[NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH*2];
    for(NSUInteger i=0;i<CC_SHA256_DIGEST_LENGTH;i++) [hash appendFormat:@"%02x",digest[i]];
    // No attacker/user-supplied domain can escape Data/Preferences.
    return [PDPreferencesRoot() stringByAppendingPathComponent:
            [hash stringByAppendingPathExtension:@"plist"]];
}
static BOOL PDPreferencesAllowedObject(id value) {
    if(!value) return NO;
    NSData *encoded=[NSPropertyListSerialization dataWithPropertyList:value
         format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    return encoded!=nil;
}
static NSDictionary *PDPreferencesRead(NSString *domain) {
    NSString *path=PDPreferencesDomainFile(domain);
    NSData *data=path ? [NSData dataWithContentsOfFile:path] : nil;
    NSDictionary *result=data ? [NSPropertyListSerialization propertyListWithData:data
         options:NSPropertyListImmutable format:NULL error:nil] : nil;
    if(![result isKindOfClass:NSDictionary.class] ||
       ![result[@"format"] isEqualToString:@"SideloadPersist.LivePreferences.V1"] ||
       ![result[@"domain"] isEqualToString:domain] ||
       ![result[@"values"] isKindOfClass:NSDictionary.class] ||
       ![result[@"removed"] isKindOfClass:NSArray.class]) return nil;
    return result;
}
static BOOL PDPreferencesSave(NSString *domain, NSDictionary *values,
                              NSArray *removed, NSError **error) {
    if(!domain.length || ![values isKindOfClass:NSDictionary.class] ||
       ![removed isKindOfClass:NSArray.class]) {
        if(error) *error=PDPreferencesError(1,@"偏好域或数据类型无效");
        return NO;
    }
    NSString *directory=PDPreferencesRoot();
    if(![NSFileManager.defaultManager createDirectoryAtPath:directory
         withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    NSDictionary *record=@{
        @"format":@"SideloadPersist.LivePreferences.V1",
        @"domain":domain,
        @"values":values,
        @"removed":removed
    };
    NSData *plist=[NSPropertyListSerialization dataWithPropertyList:record
         format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    if(!plist) return NO;
    // Atomic replacement of the sole canonical file; no retained generations.
    return [plist writeToFile:PDPreferencesDomainFile(domain)
                     options:NSDataWritingAtomic error:error];
}
BOOL PDPreferencesDomainExists(NSString *domain) {
    @synchronized(PDPreferencesGuard()) {return PDPreferencesRead(domain)!=nil;}
}
BOOL PDPreferencesEnsureDomain(NSString *domain,NSDictionary *initial,NSError **error) {
    @synchronized(PDPreferencesGuard()) {
        if(PDPreferencesRead(domain)) return YES;
        NSString *file=PDPreferencesDomainFile(domain);
        if(!file) {
            if(error) *error=PDPreferencesError(2,@"偏好域名称无效");
            return NO;
        }
        // Fail closed on a corrupted existing file: never replace it with
        // empty defaults and silently destroy a potentially recoverable domain.
        if([NSFileManager.defaultManager fileExistsAtPath:file]) {
            if(error) *error=PDPreferencesError(3,@"原有持久化偏好文件损坏，拒绝覆盖");
            return NO;
        }
        return PDPreferencesSave(domain,initial ?: @{},@[],error);
    }
}
id PDPreferencesValue(NSString *domain,NSString *key,BOOL *present,BOOL *removed) {
    @synchronized(PDPreferencesGuard()) {
        NSDictionary *record=PDPreferencesRead(domain);
        id value=record[@"values"][key];
        BOOL tombstone=[record[@"removed"] containsObject:key];
        if(present) *present=value!=nil;
        if(removed) *removed=tombstone;
        return value;
    }
}
NSDictionary *PDPreferencesValues(NSString *domain) {
    @synchronized(PDPreferencesGuard()) {return PDPreferencesRead(domain)[@"values"] ?: @{};}
}
BOOL PDPreferencesWriteValue(NSString *domain,NSString *key,id value,NSError **error) {
    @synchronized(PDPreferencesGuard()) {
        NSDictionary *record=PDPreferencesRead(domain);
        if(!record || ![key isKindOfClass:NSString.class] || !key.length ||
           (value && !PDPreferencesAllowedObject(value))) {
            if(error) *error=PDPreferencesError(4,@"未初始化偏好域或无效的键值");
            return NO;
        }
        NSMutableDictionary *values=[record[@"values"] mutableCopy];
        NSMutableSet *removed=[NSMutableSet setWithArray:record[@"removed"]];
        if(value) {
            values[key]=value;
            [removed removeObject:key];
        } else {
            [values removeObjectForKey:key];
            [removed addObject:key];
        }
        return PDPreferencesSave(domain,values,[removed.allObjects sortedArrayUsingSelector:@selector(compare:)],error);
    }
}
BOOL PDPreferencesReplaceDomain(NSString *domain,NSDictionary *values,NSError **error) {
    @synchronized(PDPreferencesGuard()) {
        NSDictionary *record=PDPreferencesRead(domain);
        if(!record || ![values isKindOfClass:NSDictionary.class] ||
           !PDPreferencesAllowedObject(values)) {
            if(error) *error=PDPreferencesError(5,@"偏好域不存在或替换内容无效");
            return NO;
        }
        NSMutableSet *removed=[NSMutableSet setWithArray:record[@"removed"]];
        for(NSString *key in record[@"values"]) if(!values[key]) [removed addObject:key];
        for(NSString *key in values) [removed removeObject:key];
        return PDPreferencesSave(domain,values,[removed.allObjects sortedArrayUsingSelector:@selector(compare:)],error);
    }
}
BOOL PDPreferencesRemoveDomain(NSString *domain,NSError **error) {
    return PDPreferencesReplaceDomain(domain,@{},error);
}
NSDictionary *PDPreferencesHealth(void) {
    NSString *root=PDPreferencesRoot();
    NSArray *files=[NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil] ?: @[];
    NSUInteger count=0,bytes=0;
    for(NSString *name in files) {
        if(![name.pathExtension isEqualToString:@"plist"]) continue;
        NSString *path=[root stringByAppendingPathComponent:name];
        NSDictionary *stat=[NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
        if(stat) {count++;bytes += [stat[NSFileSize] unsignedIntegerValue];}
    }
    return @{@"format":@"SideloadPersist.LivePreferences.V1",
             @"domainFiles":@(count),@"bytes":@(bytes)};
}
