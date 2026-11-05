#import <Foundation/Foundation.h>
#import "../src/PDRedirect.h"
#import <stdlib.h>
#import <string.h>

static void assertEqual(NSString *actual, NSString *expected, NSString *description) {
    if (![actual isEqualToString:expected]) {
        NSLog(@"FAIL %@: actual=%@ expected=%@", description, actual, expected);
        exit(1);
    }
    NSLog(@"PASS %@", description);
}
int main(void) {
    @autoreleasepool {
        const char *home = getenv("HOME");
        if (!home) exit(2);
        NSString *documents = [[NSString stringWithUTF8String:home] stringByAppendingPathComponent:@"Documents"];
        NSString *target = @"/tmp/sideloadpersist-test/Documents";
        assertEqual(PDTranslatedPath([documents stringByAppendingPathComponent:@"hello.txt"]),
            [documents stringByAppendingPathComponent:@"hello.txt"], @"disabled pass-through");
        PDSetExternalDocumentsPath(target);
        assertEqual(PDTranslatedPath(documents), target, @"Documents root");
        assertEqual(PDTranslatedPath([documents stringByAppendingPathComponent:@"nested/example.json"]),
            [target stringByAppendingPathComponent:@"nested/example.json"], @"nested Documents");
        assertEqual(PDTranslatedPath([documents stringByAppendingString:@"-other/file"]),
            [documents stringByAppendingString:@"-other/file"], @"prefix boundary");
        assertEqual(PDTranslatedPath([[NSString stringWithUTF8String:home] stringByAppendingPathComponent:@"Library/Preferences/test.plist"]),
            [[NSString stringWithUTF8String:home] stringByAppendingPathComponent:@"Library/Preferences/test.plist"], @"Library unchanged");
        char *converted = PDTranslatedCString(documents.fileSystemRepresentation);
        if (!converted || strcmp(converted, target.fileSystemRepresentation)) exit(3);
        free(converted);
        NSLog(@"All smoke tests passed.");
    }
    return 0;
}
