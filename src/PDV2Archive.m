#import "PDV2Archive.h"
#import "PDStorage.h"
#import "miniz.h"
#import <sys/stat.h>
#import <TargetConditionals.h>

static NSArray<NSString *> *PDV2Scopes(void) {
    return @[@"Application Support", @"WebKit", @"Cookies"];
}
static NSString *PDV2ErrorDomain=@"SideloadPersist.MultiRestore";
static NSString *PDV2Name(mz_zip_archive *zip,mz_uint index) {
    mz_uint32 n=mz_zip_reader_get_filename(zip,index,NULL,0);
    if(n<2 || n>4096) return nil;
    char *buffer=calloc(n+1,1);
    if(!buffer) return nil;
    mz_zip_reader_get_filename(zip,index,buffer,n+1);
    size_t actual=strlen(buffer);
    NSString *name=(actual+1==n) ? [[NSString alloc] initWithBytes:buffer length:actual encoding:NSUTF8StringEncoding] : nil;
    free(buffer);
    return name;
}
static NSString *PDV2SafePath(NSString *path) {
    if (!path.length || [path hasPrefix:@"/"] || [path hasPrefix:@"~"] ||
        [path containsString:@"\\"] || [path containsString:@":"]) return nil;
    NSMutableArray<NSString *> *parts=[NSMutableArray array];
    for(NSString *part in [path componentsSeparatedByString:@"/"]) {
        if(!part.length) continue;
        if([part isEqualToString:@"."] || [part isEqualToString:@".."]) return nil;
        for(NSUInteger i=0;i<part.length;i++) {
            unichar c=[part characterAtIndex:i];
            if(c<0x20 || c==0x7f) return nil;
        }
        [parts addObject:part];
    }
    return parts.count ? [parts componentsJoinedByString:@"/"] : nil;
}
static BOOL PDV2IsMetadata(NSString *path) {
    NSArray *parts=[path componentsSeparatedByString:@"/"];
    if([parts containsObject:@"__MACOSX"]) return YES;
    for(NSString *part in parts)
        if([part hasPrefix:@"._"] || [part isEqualToString:@".DS_Store"]) return YES;
    return NO;
}
// Full plugin-folder ZIP; one-folder wrapper; or direct Data/Library/<scope>.
// Never use a substring match on an arbitrary nested data path.
static NSString *PDV2Relative(NSString *path,NSString **scopeOut) {
    NSArray<NSString *> *parts=[path componentsSeparatedByString:@"/"];
    NSArray<NSString *> *scopes=PDV2Scopes();
    for(NSUInteger i=0;i<parts.count;i++) {
        BOOL base=NO;
        if([parts[i] isEqualToString:@"SideloadPersist"] &&
           i+2<parts.count && [parts[i+1] isEqualToString:@"Data"]) {
            i+=2; base=YES;
        } else if([parts[i] isEqualToString:@"Data"] && i+1<parts.count) {
            i+=1; base=YES;
        } else if([parts[i] isEqualToString:@"Library"] && i+1<parts.count) {
            i+=1; base=YES;
        } else if([scopes containsObject:parts[i]] && i<=1) {
            base=YES;
        }
        if(!base) continue;
        if(![scopes containsObject:parts[i]]) return nil;
        if(scopeOut) *scopeOut=parts[i];
        return i+1<parts.count ?
            [[parts subarrayWithRange:NSMakeRange(i+1,parts.count-i-1)] componentsJoinedByString:@"/"] : @"";
    }
    return nil;
}
BOOL PDV2AllowsExtraScopes(void) {
#if TARGET_OS_OSX
    if(strcmp(getenv("PD_STORAGE_SMOKE_ALLOW_V2") ?: "", "1")==0) return YES;
#endif
    if(![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.ravelloh.storageprobe"]) return NO;
    if(![NSBundle.mainBundle.infoDictionary[@"SideloadPersistExperimentalWebKitRelocation"] boolValue]) return NO;
    return [[NSFileManager defaultManager] fileExistsAtPath:
            [PDStorageRoot() stringByAppendingPathComponent:@"enable-webkit-experiment.flag"]];
}
BOOL PDV2ZIPHasExtraScopes(NSURL *url) {
    if(!url.isFileURL) return NO;
    BOOL access=[url startAccessingSecurityScopedResource];
    mz_zip_archive zip={0};
    BOOL found=NO;
    if(mz_zip_reader_init_file(&zip,url.fileSystemRepresentation,0)) {
        for(mz_uint i=0;i<mz_zip_reader_get_num_files(&zip);i++) {
            NSString *name=PDV2Name(&zip,i);
            NSString *scope=nil;
            if(name && PDV2Relative(name,&scope) &&
               ([scope isEqualToString:@"WebKit"] || [scope isEqualToString:@"Cookies"])) {
                found=YES; break;
            }
        }
    }
    mz_zip_reader_end(&zip);
    if(access) [url stopAccessingSecurityScopedResource];
    return found;
}
static void PDV2Fail(NSError **error,NSInteger code,NSString *message) {
    if(error) *error=[NSError errorWithDomain:PDV2ErrorDomain code:code
        userInfo:@{NSLocalizedDescriptionKey:message}];
    PDStorageTrace(@"V2 ZIP refused: %@",message);
}
NSString *PDV2StageZIP(NSURL *url,NSError **error) {
    if(!PDV2AllowsExtraScopes()) {
        PDV2Fail(error,1,@"当前 App 未启用多目录实验。为避免丢失 WebKit/Cookies 数据，已拒绝此备份。");
        return nil;
    }
    BOOL access=[url startAccessingSecurityScopedResource];
    mz_zip_archive zip={0};
    if(!mz_zip_reader_init_file(&zip,url.fileSystemRepresentation,0)) {
        if(access) [url stopAccessingSecurityScopedResource];
        PDV2Fail(error,2,@"ZIP 损坏或无法读取");
        return nil;
    }
    mz_uint count=mz_zip_reader_get_num_files(&zip);
    NSString *identifier=NSUUID.UUID.UUIDString;
    NSString *directory=[[[PDStorageRoot() stringByAppendingPathComponent:@"Incoming"]
                          stringByAppendingPathComponent:identifier] stringByStandardizingPath];
    NSMutableArray<NSDictionary *> *entries=[NSMutableArray array];
    NSMutableSet<NSString *> *paths=[NSMutableSet set];
    NSMutableSet<NSString *> *scopes=[NSMutableSet set];
    unsigned long long total=0;
    NSUInteger files=0;
    if(count==0 || count>100000) {PDV2Fail(error,3,@"ZIP 条目数超出限制");goto invalid;}
    for(mz_uint i=0;i<count;i++) {
        mz_zip_archive_file_stat st={0};
        NSString *name=PDV2SafePath(PDV2Name(&zip,i));
        if(!name || !mz_zip_reader_file_stat(&zip,i,&st) || mz_zip_reader_is_file_encrypted(&zip,i)) {
            PDV2Fail(error,4,@"ZIP 包含无效路径或加密项目");
            goto invalid;
        }
        mz_uint32 unixMode=(st.m_external_attr>>16)&0170000;
        if(unixMode && unixMode!=0100000 && unixMode!=0040000) {
            PDV2Fail(error,5,@"ZIP 包含符号链接或特殊文件");
            goto invalid;
        }
        if(PDV2IsMetadata(name)) continue;
        NSString *scope=nil;
        NSString *relative=PDV2Relative(name,&scope);
        if(!scope) continue; // Ignore Inbox/Backups/plugin metadata.
        if(!relative) continue;
        NSString *canonical=[NSString stringWithFormat:@"%@/%@",scope,relative];
        if([paths containsObject:canonical.lowercaseString]) {
            PDV2Fail(error,6,@"ZIP 存在重复路径或大小写冲突");
            goto invalid;
        }
        [paths addObject:canonical.lowercaseString];
        BOOL isDirectory=mz_zip_reader_is_file_a_directory(&zip,i);
        if(!isDirectory) {
            if(st.m_uncomp_size>12ULL*1024*1024*1024-total) {
                PDV2Fail(error,7,@"解压数据超过 12 GiB 上限"); goto invalid;
            }
            total+=st.m_uncomp_size;
            files++;
        }
        [scopes addObject:scope];
        [entries addObject:@{@"index":@(i),@"scope":scope,@"relative":relative,
                              @"directory":@(isDirectory)}];
    }
    if(![scopes containsObject:@"Application Support"] ||
       !([scopes containsObject:@"WebKit"] || [scopes containsObject:@"Cookies"]) || !files) {
        PDV2Fail(error,8,@"v2 备份必须包含 Application Support 和至少一个扩展目录的实际文件");goto invalid;
    }
    if(![NSFileManager.defaultManager createDirectoryAtPath:
           [directory stringByAppendingPathComponent:@"Data"] withIntermediateDirectories:YES
           attributes:nil error:error]) goto invalid;
    // Precreate only those scopes explicitly present in the ZIP.
    for(NSString *scope in scopes) {
        if(![NSFileManager.defaultManager createDirectoryAtPath:
             [[directory stringByAppendingPathComponent:@"Data"] stringByAppendingPathComponent:scope]
             withIntermediateDirectories:YES attributes:nil error:error]) goto invalid;
    }
    for(NSDictionary *entry in entries) {
        NSString *relative=entry[@"relative"];
        if(!relative.length) continue;
        NSString *destination=[[[directory stringByAppendingPathComponent:@"Data"]
                                 stringByAppendingPathComponent:entry[@"scope"]]
                                 stringByAppendingPathComponent:relative];
        if([entry[@"directory"] boolValue]) {
            if(![NSFileManager.defaultManager createDirectoryAtPath:destination
                withIntermediateDirectories:YES attributes:nil error:error]) goto invalid;
        } else {
            if(![NSFileManager.defaultManager createDirectoryAtPath:[destination stringByDeletingLastPathComponent]
                withIntermediateDirectories:YES attributes:nil error:error]) goto invalid;
            if(!mz_zip_reader_extract_to_file(&zip,[entry[@"index"] unsignedIntValue],
                                               destination.fileSystemRepresentation,0)) {
                PDV2Fail(error,9,@"ZIP 内容解压或 CRC 校验失败");goto invalid;
            }
        }
    }
    {
        NSMutableArray<NSString *> *ordered=[NSMutableArray array];
        for(NSString *scope in PDV2Scopes()) if([scopes containsObject:scope]) [ordered addObject:scope];
        NSDictionary *plan=@{@"format":@"SideloadPersist.Restore.V2",
                              @"id":identifier, @"scopes":ordered, @"unpackedBytes":@(total),
                              @"fileCount":@(files)};
        NSData *json=[NSJSONSerialization dataWithJSONObject:plan options:NSJSONWritingPrettyPrinted error:error];
        if(!json || ![json writeToFile:[directory stringByAppendingPathComponent:@"restore-plan.json"]
                             options:NSDataWritingAtomic error:error]) goto invalid;
        NSString *pending=[PDStorageRoot() stringByAppendingPathComponent:@"restore-pending.txt"];
        if(![identifier writeToFile:pending atomically:YES encoding:NSUTF8StringEncoding error:error]) goto invalid;
    }
    mz_zip_reader_end(&zip);
    if(access) [url stopAccessingSecurityScopedResource];
    PDStorageTrace(@"V2 staged %@ (%lu files, %llu bytes)",identifier,(unsigned long)files,total);
    return identifier;
invalid:
    mz_zip_reader_end(&zip);
    if(access) [url stopAccessingSecurityScopedResource];
    [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
    return nil;
}
