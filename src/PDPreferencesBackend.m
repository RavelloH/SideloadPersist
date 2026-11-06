#import "PDPreferencesBackend.h"
#import "PDStorage.h"
#import <CommonCrypto/CommonDigest.h>
#import <sys/stat.h>

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
BOOL PDPreferencesShouldManageDomain(NSString *domain) {
    if(![domain isKindOfClass:NSString.class] || !domain.length) return NO;
    // The main app domain is legitimate even for an unusual bundle identifier.
    NSString *app=NSBundle.mainBundle.bundleIdentifier ?: @"SideloadPersist.StandaloneTest";
    if([domain isEqualToString:app]) return YES;
    NSString *lower=domain.lowercaseString;
    // UIKit, Accessibility, AVFoundation, etc. routinely instantiate their
    // own suites inside the injected process. They are not application data.
    if([lower isEqualToString:@"com.apple"] || [lower hasPrefix:@"com.apple."] ||
       [lower hasPrefix:@"apple."] || [lower hasPrefix:@"group."] ||
       [@[@"nsglobaldomain",@"nsargumentdomain",@"nsregistrationdomain"]
            containsObject:lower]) return NO;
    // CFPreferences may pass a *filesystem path* as a suite identifier.
    // Never export system paths such as /var/mobile/Library/Preferences/...
    if([domain containsString:@"/"] || [domain containsString:@"\\"] ||
       [domain hasPrefix:@"~"]) return NO;
    return YES;
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
NSArray<NSString *> *PDPreferencesRemovedKeys(NSString *domain) {
    @synchronized(PDPreferencesGuard()) {return PDPreferencesRead(domain)[@"removed"] ?: @[];}
}
BOOL PDPreferencesWriteValue(NSString *domain,NSString *key,id value,NSError **error) {
    @synchronized(PDPreferencesGuard()) {
        NSDictionary *record=PDPreferencesRead(domain);
        if(!record) {
            if(error) *error=PDPreferencesError(4,@"持久化偏好域文件不存在或无法解析");
            return NO;
        }
        if(![key isKindOfClass:NSString.class] || !key.length) {
            if(error) *error=PDPreferencesError(6,@"偏好键名称无效");
            return NO;
        }
        if(value && !PDPreferencesAllowedObject(value)) {
            if(error) *error=PDPreferencesError(7,@"偏好值不能序列化为 Property List");
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

BOOL PDPreferencesValidateDirectory(NSString *directory,NSString **reason) {
    NSFileManager *fm=NSFileManager.defaultManager;
    NSArray *contents=[fm contentsOfDirectoryAtPath:directory error:nil];
    if(!contents || !contents.count || contents.count>128) {
        if(reason) *reason=@"empty-or-oversized-preferences-directory";
        return NO;
    }
    BOOL hasPrimary=NO, hasDomain=NO;
    for(NSString *name in contents) {
        if(![name.pathExtension isEqualToString:@"plist"]) {
            if(reason) *reason=@"unexpected-preferences-file"; return NO;
        }
        NSString *file=[directory stringByAppendingPathComponent:name];
        NSDictionary *stat=[fm attributesOfItemAtPath:file error:nil];
        if(![stat[NSFileType] isEqualToString:NSFileTypeRegular] ||
           [stat[NSFileSize] unsignedLongLongValue] > 32ULL*1024*1024) {
            if(reason) *reason=@"invalid-preferences-file-type-or-size"; return NO;
        }
        NSData *bytes=[NSData dataWithContentsOfFile:file];
        id parsed=bytes ? [NSPropertyListSerialization propertyListWithData:bytes
            options:NSPropertyListImmutable format:NULL error:nil] : nil;
        if(![parsed isKindOfClass:NSDictionary.class]) {
            if(reason) *reason=@"invalid-live-preferences-root";return NO;
        }
        NSDictionary *record=parsed;
        NSString *domain=record[@"domain"];
        if(
           ![record[@"format"] isEqualToString:@"SideloadPersist.LivePreferences.V1"] ||
           ![domain isKindOfClass:NSString.class] ||
           ![record[@"values"] isKindOfClass:NSDictionary.class] ||
           ![record[@"removed"] isKindOfClass:NSArray.class] ||
           ![name isEqualToString:[PDPreferencesDomainFile(domain) lastPathComponent]]) {
            if(reason) *reason=@"invalid-live-preferences-record";return NO;
        }
        hasDomain=YES;
        if([domain isEqualToString:(NSBundle.mainBundle.bundleIdentifier ?: @"SideloadPersist.StandaloneTest")])
            hasPrimary=YES;
    }
    if(!hasDomain || !hasPrimary) {
        if(reason) *reason=@"primary-domain-missing";
        return NO;
    }
    return YES;
}
BOOL PDPreferencesQuarantineUnmanagedDomains(NSUInteger *count,NSError **error) {
    @synchronized(PDPreferencesGuard()) {
        if(count) *count=0;
        NSFileManager *fm=NSFileManager.defaultManager;
        NSString *root=PDPreferencesRoot();
        NSError *listError=nil;
        NSArray<NSString *> *files=[fm contentsOfDirectoryAtPath:root error:&listError];
        if(!files) {
            if(![fm fileExistsAtPath:root]) return YES; // first installation
            if(error) *error=listError ?: PDPreferencesError(7,@"无法读取原有偏好备份");
            return NO;
        }
        if(files.count>4096) {
            if(error) *error=PDPreferencesError(8,@"偏好备份文件数量异常，停止隔离");
            return NO;
        }
        NSString *quarantine=nil;
        for(NSString *name in files) {
            if(![name.pathExtension isEqualToString:@"plist"]) continue;
            NSString *from=[root stringByAppendingPathComponent:name];
            struct stat st={0};
            if(lstat(from.fileSystemRepresentation,&st)!=0 || !S_ISREG(st.st_mode)) continue;
            NSData *bytes=[NSData dataWithContentsOfFile:from];
            id parsed=bytes ? [NSPropertyListSerialization propertyListWithData:bytes
                     options:NSPropertyListImmutable format:NULL error:nil] : nil;
            if(![parsed isKindOfClass:NSDictionary.class]) continue;
            NSDictionary *record=parsed;
            NSString *domain=record[@"domain"];
            if(![record[@"format"] isEqualToString:@"SideloadPersist.LivePreferences.V1"] ||
               ![domain isKindOfClass:NSString.class] ||
               ![name isEqualToString:PDPreferencesDomainFile(domain).lastPathComponent]) continue;
            if(PDPreferencesShouldManageDomain(domain)) continue;
            if(!quarantine) {
                // Caches is deliberately outside the user-exported Data folder.
                // Move, never copy or overwrite: preserve recoverability of
                // older plugin versions without continuing to export OS data.
                NSString *home=[[PDStorageRoot() stringByDeletingLastPathComponent]
                                   stringByDeletingLastPathComponent];
                quarantine=[[[home stringByAppendingPathComponent:@"Library/Caches/SideloadPersist/ExcludedPreferences"]
                             stringByAppendingPathComponent:NSUUID.UUID.UUIDString] copy];
                if(![fm createDirectoryAtPath:quarantine withIntermediateDirectories:YES
                          attributes:nil error:error]) return NO;
            }
            NSString *to=[quarantine stringByAppendingPathComponent:name];
            if(![fm moveItemAtPath:from toPath:to error:error]) return NO;
            if(count) ++*count;
        }
        return YES;
    }
}
static BOOL s_integrityFailure=NO;
static NSString *PDPreferencesIntegrityMarker(void) {
    return [PDStorageRoot() stringByAppendingPathComponent:@"preferences-integrity-warning.json"];
}
static NSString *PDPreferencesErrorCategory(NSError *failure) {
    if(!failure) return @"unknown";
    if([failure.domain isEqualToString:@"SideloadPersist.Preferences"]) {
        switch(failure.code) {
            case 3: case 4: return @"managed-domain-missing-or-corrupt";
            case 6: return @"invalid-preference-key";
            case 7: return @"unsupported-property-list-value";
            case 1: case 2: case 5: return @"invalid-managed-domain-data";
            case 8: return @"unexpected-preferences-file-count";
            default: return @"managed-store-error";
        }
    }
    if([failure.domain isEqualToString:NSCocoaErrorDomain] ||
       [failure.domain isEqualToString:NSPOSIXErrorDomain])
        return @"filesystem-or-permission-error";
    if([failure.domain isEqualToString:@"NSPropertyListErrorDomain"])
        return @"property-list-serialization-error";
    return @"unknown";
}
static NSString *PDPreferencesSafeErrorDomain(NSError *failure) {
    NSString *domain=failure.domain;
    if([domain isEqualToString:@"SideloadPersist.Preferences"] ||
       [domain isEqualToString:NSCocoaErrorDomain] ||
       [domain isEqualToString:NSPOSIXErrorDomain] ||
       [domain isEqualToString:@"NSPropertyListErrorDomain"]) return domain;
    return @"other";
}
void PDPreferencesMarkIntegrityFailureWithError(NSString *operation, NSError *failure) {
    @synchronized(PDPreferencesGuard()) {
        s_integrityFailure=YES;
        NSString *path=PDPreferencesIntegrityMarker();
        NSData *prior=[NSData dataWithContentsOfFile:path];
        id parsed=prior ? [NSJSONSerialization JSONObjectWithData:prior options:0 error:nil] : nil;
        NSDictionary *previous=[parsed isKindOfClass:NSDictionary.class] ? parsed : nil;
        // Preserve the original fault even after many subsequent writes fail.
        // Never write keys, values, descriptions, user paths or raw domain names.
        NSString *category=PDPreferencesErrorCategory(failure);
        NSDictionary *first=[previous[@"firstFailure"] isKindOfClass:NSDictionary.class] ?
            previous[@"firstFailure"] : nil;
        if(!first) {
            first=@{
                @"operation":operation ?: @"unknown",
                @"category":category,
                @"errorDomain":PDPreferencesSafeErrorDomain(failure),
                @"errorCode":@(failure ? failure.code : 0),
                @"at":@([[NSDate date] timeIntervalSince1970])
            };
        }
        NSDictionary *record=@{
            @"format":@"SideloadPersist.IntegrityWarning.V2",
            @"reason":@"managed-preferences-write-failed",
            @"operation":operation ?: @"unknown",
            @"backupSafe":@NO,
            @"firstFailure":first,
            @"lastCategory":category,
            @"lastErrorDomain":PDPreferencesSafeErrorDomain(failure),
            @"lastErrorCode":@(failure ? failure.code : 0),
            @"failureCount":@([previous[@"failureCount"] unsignedIntegerValue]+1),
            @"createdAt":previous[@"createdAt"] ?: first[@"at"]
        };
        NSData *data=[NSJSONSerialization dataWithJSONObject:record
            options:NSJSONWritingPrettyPrinted error:nil];
        NSError *writeError=nil;
        if(!data || ![data writeToFile:path options:NSDataWritingAtomic error:&writeError])
            NSLog(@"[SideloadPersist Preferences] CRITICAL: unable to save integrity diagnostic: %@",
                  writeError);
        NSLog(@"[SideloadPersist Preferences] CRITICAL: %@ failed: category=%@ code=%ld",
              operation ?: @"unknown",category,(long)failure.code);
    }
}
void PDPreferencesMarkIntegrityFailure(NSString *operation) {
    PDPreferencesMarkIntegrityFailureWithError(operation,nil);
}
BOOL PDPreferencesIntegrityOK(void) {
    @synchronized(PDPreferencesGuard()) {
        return !s_integrityFailure &&
           ![NSFileManager.defaultManager fileExistsAtPath:PDPreferencesIntegrityMarker()];
    }
}
NSString *PDPreferencesIntegrityWarning(void) {
    return PDPreferencesIntegrityOK() ? nil :
       @"偏好数据写入曾失败，备份可能不完整；请勿卸载 App。请保存原始数据并检查故障日志。";
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
