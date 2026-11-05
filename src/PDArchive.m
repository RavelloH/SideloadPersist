#import "PDArchive.h"
#import "PDStorage.h"
#import "PDV2Archive.h"
#import "miniz.h"
#import <sys/stat.h>

static NSString *const PDArchiveDomain=@"SideloadPersist.Import";
static BOOL PDImportError(NSError **error, NSInteger code, NSString *msg) {
    if (error) *error=[NSError errorWithDomain:PDArchiveDomain code:code
                                     userInfo:@{NSLocalizedDescriptionKey:msg ?: @"导入失败"}];
    PDStorageTrace(@"Import rejected: %@",msg);
    return NO;
}
static NSString *PDSafeArchivePath(NSString *path) {
    if (!path.length || [path hasPrefix:@"/"] || [path hasPrefix:@"~"] ||
        [path containsString:@"\\"] || [path containsString:@":"]) return nil;
    NSMutableArray *parts=[NSMutableArray array];
    for (NSString *part in [path componentsSeparatedByString:@"/"]) {
        if (!part.length) continue;
        if ([part isEqualToString:@"."] || [part isEqualToString:@".."]) return nil;
        for (NSUInteger i=0;i<part.length;i++) {
            unichar c=[part characterAtIndex:i];
            if (c < 0x20 || c==0x7f) return nil;
        }
        [parts addObject:part];
    }
    if (!parts.count) return nil;
    return [parts componentsJoinedByString:@"/"];
}
static NSArray<NSString *> *PDComponents(NSString *path) {
    return [path componentsSeparatedByString:@"/"];
}
static NSString *PDKnownRelativePath(NSString *path) {
    NSArray *parts=PDComponents(path);
    NSUInteger n=parts.count;
    // Accept the plugin folder itself, Data/, or Library/Application Support
    // as an archive root. An arbitrary single wrapper folder is handled later.
    for (NSUInteger start=0;start<n;start++) {
        if ([parts[start] isEqualToString:@"SideloadPersist"] &&
            start+2<n && [parts[start+1] isEqualToString:@"Data"] &&
            [parts[start+2] isEqualToString:@"Application Support"]) {
            return start+3<n ? [[parts subarrayWithRange:NSMakeRange(start+3,n-start-3)]
                                  componentsJoinedByString:@"/"] : @"";
        }
        if ([parts[start] isEqualToString:@"Data"] &&
            start+1<n && [parts[start+1] isEqualToString:@"Application Support"]) {
            return start+2<n ? [[parts subarrayWithRange:NSMakeRange(start+2,n-start-2)]
                                  componentsJoinedByString:@"/"] : @"";
        }
        if ([parts[start] isEqualToString:@"Library"] &&
            start+1<n && [parts[start+1] isEqualToString:@"Application Support"]) {
            return start+2<n ? [[parts subarrayWithRange:NSMakeRange(start+2,n-start-2)]
                                  componentsJoinedByString:@"/"] : @"";
        }
        if ([parts[start] isEqualToString:@"Application Support"]) {
            return start+1<n ? [[parts subarrayWithRange:NSMakeRange(start+1,n-start-1)]
                                  componentsJoinedByString:@"/"] : @"";
        }
    }
    return nil;
}
static NSString *PDArchiveFilename(mz_zip_archive *zip, mz_uint idx) {
    mz_uint32 len=mz_zip_reader_get_filename(zip,idx,NULL,0);
    if (!len || len>4096) return nil;
    char *buffer=calloc((size_t)len+2,1);
    if (!buffer) return nil;
    mz_zip_reader_get_filename(zip,idx,buffer,len+1);
    size_t realLen=strlen(buffer);
    // miniz_get_filename() returns filename length INCLUDING the final NUL.
    // Reject embedded NULs instead of silently truncating to a benign prefix.
    NSString *result=(realLen+1==len) ? [[NSString alloc] initWithBytes:buffer length:realLen encoding:NSUTF8StringEncoding] : nil;
    free(buffer);
    return result;
}
NSString *PDArchivePendingID(void) {
    NSString *path=[PDStorageRoot() stringByAppendingPathComponent:@"restore-pending.txt"];
    return [[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil]
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}
NSString *PDArchiveStageZIP(NSURL *zipURL, NSError **error) {
    if (!zipURL.isFileURL || ![[zipURL.pathExtension lowercaseString] isEqualToString:@"zip"]) {
        PDImportError(error,1,@"仅支持 ZIP 格式备份包");
        return nil;
    }
    if (PDArchivePendingID().length) {
        PDImportError(error,2,@"已有等待恢复的数据包，请先完全退出并重新启动 App");
        return nil;
    }
    // Never silently drop WebKit/Cookies from a user archive. Either stage
    // every supported scope through the v2 path, or reject the whole import.
    if (PDV2ZIPHasExtraScopes(zipURL)) return PDV2StageZIP(zipURL,error);
    BOOL access=[zipURL startAccessingSecurityScopedResource];
    mz_zip_archive zip={0};
    if (!mz_zip_reader_init_file(&zip,zipURL.fileSystemRepresentation,0)) {
        if(access) [zipURL stopAccessingSecurityScopedResource];
        PDImportError(error,3,@"无法读取 ZIP 文件，或 ZIP 已损坏");
        return nil;
    }
    mz_uint count=mz_zip_reader_get_num_files(&zip);
    if (!count || count>100000) {
        mz_zip_reader_end(&zip);
        if(access) [zipURL stopAccessingSecurityScopedResource];
        PDImportError(error,4,@"ZIP 文件数超出限制");
        return nil;
    }
    NSMutableArray<NSDictionary *> *entries=[NSMutableArray array];
    unsigned long long total=0;
    BOOL knownRoot=NO;
    NSMutableSet *firstParts=[NSMutableSet set];
    NSString *commonRoot=nil;
    NSString *identifier=nil;
    NSString *stage=nil;
    NSUInteger extracted=0;
    NSMutableSet<NSString *> *extractedPaths=[NSMutableSet set];
    for (mz_uint i=0;i<count;i++) {
        mz_zip_archive_file_stat stat={0};
        NSString *raw=PDArchiveFilename(&zip,i);
        NSString *safe=PDSafeArchivePath(raw);
        if (!safe || !mz_zip_reader_file_stat(&zip,i,&stat) ||
            mz_zip_reader_is_file_encrypted(&zip,i)) {
            PDImportError(error,5,@"ZIP 包含无效路径、加密文件或不支持的项目");
            goto failure;
        }
        // Reject Unix symlinks and any nonregular special entries.
        mz_uint32 unixMode=(stat.m_external_attr>>16)&0170000;
        if (unixMode && unixMode!=0100000 && unixMode!=0040000) {
            PDImportError(error,6,@"ZIP 包含符号链接或特殊文件，已拒绝导入");
            goto failure;
        }
        // Files.app and Finder may add AppleDouble metadata when archiving.
        // These are not part of the application's authoritative data and must
        // not be restored as dot-underscore files in Application Support.
        NSString *firstComponent=PDComponents(safe).firstObject;
        NSString *lastComponent=PDComponents(safe).lastObject;
        if ([firstComponent isEqualToString:@"__MACOSX"] ||
            [lastComponent hasPrefix:@"._"] ||
            [lastComponent isEqualToString:@".DS_Store"]) {
            PDStorageTrace(@"Skipping ZIP metadata entry: %@",safe);
            continue;
        }
        BOOL directory=mz_zip_reader_is_file_a_directory(&zip,i);
        if (!directory) {
            total += stat.m_uncomp_size;
            if (total>12ULL*1024*1024*1024) {
                PDImportError(error,7,@"解压后数据超过 12 GiB 安全限制");
                goto failure;
            }
        }
        [firstParts addObject:PDComponents(safe).firstObject];
        if (PDKnownRelativePath(safe)) knownRoot=YES;
        [entries addObject:@{@"index":@(i),@"path":safe,@"dir":@(directory)}];
    }
    commonRoot=(!knownRoot && firstParts.count==1) ? firstParts.anyObject : nil;
    if (commonRoot) {
        BOOL hasChild=NO;
        NSString *prefix=[commonRoot stringByAppendingString:@"/"];
        for (NSDictionary *entry in entries) {
            if ([entry[@"path"] hasPrefix:prefix]) {hasChild=YES;break;}
        }
        if (!hasChild) commonRoot=nil; // a single file is not an enclosing folder
    }
    identifier=NSUUID.UUID.UUIDString;
    stage=[[[PDStorageRoot() stringByAppendingPathComponent:@"Incoming"]
                         stringByAppendingPathComponent:identifier]
                         stringByAppendingPathComponent:@"Application Support"];
    if (![[NSFileManager defaultManager] createDirectoryAtPath:stage
             withIntermediateDirectories:YES attributes:nil error:error]) goto failure;
    for (NSDictionary *entry in entries) {
        NSString *original=entry[@"path"];
        NSString *relative=PDKnownRelativePath(original);
        if (knownRoot && relative==nil) continue; // ignore unrelated metadata in full SideloadPersist archives
        if (!knownRoot) {
            if (commonRoot && [original hasPrefix:[commonRoot stringByAppendingString:@"/"]])
                relative=[original substringFromIndex:commonRoot.length+1];
            else if (commonRoot && [original isEqualToString:commonRoot])
                relative=@"";
            else relative=original;
        }
        if (!relative.length) continue;
        NSString *key=relative.lowercaseString;
        if ([extractedPaths containsObject:key]) {
            PDImportError(error,10,@"ZIP 包含重复或大小写冲突的路径，已拒绝导入");
            goto failureStage;
        }
        [extractedPaths addObject:key];
        NSString *destination=[stage stringByAppendingPathComponent:relative];
        if ([entry[@"dir"] boolValue]) {
            if (![[NSFileManager defaultManager] createDirectoryAtPath:destination
                     withIntermediateDirectories:YES attributes:nil error:error]) goto failureStage;
        } else {
            NSString *parent=[destination stringByDeletingLastPathComponent];
            if (![[NSFileManager defaultManager] createDirectoryAtPath:parent
                     withIntermediateDirectories:YES attributes:nil error:error]) goto failureStage;
            // The staging directory is freshly created, and zip paths were
            // checked against traversal, absolute paths and symlink entries.
            if (!mz_zip_reader_extract_to_file(&zip,[entry[@"index"] unsignedIntValue],
                                                destination.fileSystemRepresentation,0)) {
                PDImportError(error,8,@"ZIP 解压失败或文件校验错误");
                goto failureStage;
            }
            extracted++;
        }
    }
    if (!extracted) {
        PDImportError(error,9,@"ZIP 中没有可导入的 Application Support 数据");
        goto failureStage;
    }
    {
        NSString *pending=[PDStorageRoot() stringByAppendingPathComponent:@"restore-pending.txt"];
        if (![identifier writeToFile:pending atomically:YES encoding:NSUTF8StringEncoding error:error])
            goto failureStage;
    }
    mz_zip_reader_end(&zip);
    if (access) [zipURL stopAccessingSecurityScopedResource];
    PDStorageTrace(@"Import staged: id=%@, files=%lu, unpackedBytes=%llu; apply on NEXT cold start",
                   identifier,(unsigned long)extracted,total);
    return identifier;
failureStage:
    [[NSFileManager defaultManager] removeItemAtPath:
        [[stage stringByDeletingLastPathComponent] stringByStandardizingPath] error:nil];
failure:
    mz_zip_reader_end(&zip);
    if (access) [zipURL stopAccessingSecurityScopedResource];
    return nil;
}
