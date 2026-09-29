#import <Foundation/Foundation.h>
#import <Security/Security.h>

static void Probe(BOOL dataProtection) {
    NSMutableDictionary *query = [@{
        (__bridge NSString *)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge NSString *)kSecMatchLimit: (__bridge id)kSecMatchLimitAll,
        (__bridge NSString *)kSecReturnAttributes: @YES
    } mutableCopy];
    if (dataProtection) query[(__bridge NSString *)kSecUseDataProtectionKeychain] = @YES;

    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    NSArray *items = status == errSecSuccess ? CFBridgingRelease(result) : @[];
    for (NSDictionary *item in items) {
        NSString *service = item[(__bridge NSString *)kSecAttrService] ?: @"";
        NSString *account = item[(__bridge NSString *)kSecAttrAccount] ?: @"";
        NSString *label = item[(__bridge NSString *)kSecAttrLabel] ?: @"";
        NSString *combined = [NSString stringWithFormat:@"%@ %@ %@", service, account, label].lowercaseString;
        if ([combined containsString:@"quickenglish"] || [combined containsString:@"linyan.quickenglish"]) {
            printf("store=%s service=%s account=%s label=%s\n",
                   dataProtection ? "data-protection" : "default",
                   service.UTF8String, account.UTF8String, label.UTF8String);
        }
    }
    if (status != errSecSuccess && status != errSecItemNotFound) {
        printf("store=%s status=%d\n", dataProtection ? "data-protection" : "default", (int)status);
    }
}

int main(void) {
    @autoreleasepool {
        Probe(NO);
        Probe(YES);
    }
    return 0;
}
