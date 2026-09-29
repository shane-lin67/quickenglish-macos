#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#import <Carbon/Carbon.h>
#import <Security/Security.h>

static OSType const QEHotKeySignature = 'QENG';
static NSString *const QELegacyKeychainService = @"com.linyan.quickenglish";
static NSString *const QELegacyKeychainAccount = @"translation-api-key";
static NSError *QEError(NSString *message);

static NSString *QEShortcutLabel(NSString *identifier) {
    if ([identifier isEqualToString:@"commandShiftE"]) return @"Command + Shift + E";
    if ([identifier isEqualToString:@"controlOptionReturn"]) return @"Control + Option + Return";
    return @"Control + Option + E";
}

static void QEShortcutDefinition(NSString *identifier, UInt32 *keyCode, UInt32 *modifiers) {
    if ([identifier isEqualToString:@"commandShiftE"]) {
        *keyCode = kVK_ANSI_E;
        *modifiers = cmdKey | shiftKey;
    } else if ([identifier isEqualToString:@"controlOptionReturn"]) {
        *keyCode = kVK_Return;
        *modifiers = controlKey | optionKey;
    } else {
        *keyCode = kVK_ANSI_E;
        *modifiers = controlKey | optionKey;
    }
}

static NSURL *QELaunchAgentURL(void) {
    NSURL *library = [NSFileManager.defaultManager URLsForDirectory:NSLibraryDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *directory = [library URLByAppendingPathComponent:@"LaunchAgents" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];
    return [directory URLByAppendingPathComponent:@"com.linyan.quickenglish.plist" isDirectory:NO];
}

static BOOL QEIsLaunchAtLoginEnabled(void) {
    return [NSFileManager.defaultManager fileExistsAtPath:QELaunchAgentURL().path];
}

static BOOL QESetLaunchAtLoginEnabled(BOOL enabled, NSError **error) {
    NSURL *url = QELaunchAgentURL();
    if (!enabled) {
        if (![NSFileManager.defaultManager fileExistsAtPath:url.path]) return YES;
        return [NSFileManager.defaultManager removeItemAtURL:url error:error];
    }

    NSString *executable = NSBundle.mainBundle.executablePath;
    if (executable.length == 0) {
        if (error) *error = QEError(@"无法确定应用路径");
        return NO;
    }
    NSDictionary *plist = @{
        @"Label": @"com.linyan.quickenglish",
        @"ProgramArguments": @[executable],
        @"RunAtLoad": @YES,
        @"KeepAlive": @NO,
        @"ProcessType": @"Interactive"
    };
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:plist format:NSPropertyListXMLFormat_v1_0 options:0 error:error];
    if (!data || ![data writeToURL:url options:NSDataWritingAtomic error:error]) return NO;
    [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions: @0644} ofItemAtPath:url.path error:nil];
    return YES;
}

static NSError *QEError(NSString *message) {
    return [NSError errorWithDomain:@"com.linyan.quickenglish" code:1 userInfo:@{NSLocalizedDescriptionKey: message ?: @"未知错误"}];
}

static NSURL *QEAPIKeyFileURL(void) {
    NSURL *base = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *directory = [base URLByAppendingPathComponent:@"QuickEnglish" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:directory
                           withIntermediateDirectories:YES
                                            attributes:@{NSFilePosixPermissions: @0700}
                                                 error:nil];
    [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions: @0700}
                                   ofItemAtPath:directory.path
                                          error:nil];
    return [directory URLByAppendingPathComponent:@"api-key" isDirectory:NO];
}

static NSString *QEReadAPIKey(void) {
    NSData *data = [NSData dataWithContentsOfURL:QEAPIKeyFileURL()];
    return data ? ([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"") : @"";
}

static void QESaveAPIKey(NSString *value) {
    NSURL *fileURL = QEAPIKeyFileURL();
    NSString *key = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (key.length == 0) {
        [NSFileManager.defaultManager removeItemAtURL:fileURL error:nil];
        return;
    }
    NSData *data = [key dataUsingEncoding:NSUTF8StringEncoding];
    [data writeToURL:fileURL options:NSDataWritingAtomic error:nil];
    [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions: @0600}
                                   ofItemAtPath:fileURL.path
                                          error:nil];
}

static NSString *QEReadLegacyKeychainAPIKey(OSStatus *statusOut) {
    NSDictionary *query = @{
        (__bridge NSString *)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge NSString *)kSecAttrService: QELegacyKeychainService,
        (__bridge NSString *)kSecAttrAccount: QELegacyKeychainAccount,
        (__bridge NSString *)kSecReturnData: @YES,
        (__bridge NSString *)kSecMatchLimit: (__bridge id)kSecMatchLimitOne
    };
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (statusOut) *statusOut = status;
    if (status != errSecSuccess || !result) return nil;
    NSData *data = CFBridgingRelease(result);
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

@interface QETranslationRequest : NSObject <NSURLSessionDataDelegate>
- (instancetype)initWithChinese:(NSString *)chinese
                         context:(NSString *)context
                            mode:(NSString *)mode
                        settings:(NSDictionary *)settings
                         onToken:(void (^)(NSString *token))onToken
                      completion:(void (^)(NSString *result, NSError *error))completion;
- (void)start;
- (void)cancel;
@end

@interface QETranslationRequest ()
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSURLSessionDataTask *task;
@property(nonatomic, strong) NSMutableData *lineBuffer;
@property(nonatomic, strong) NSMutableData *allData;
@property(nonatomic, strong) NSMutableString *assembledText;
@property(nonatomic, assign) NSInteger responseStatus;
@property(nonatomic, assign) BOOL completed;
@property(nonatomic, copy) void (^onToken)(NSString *token);
@property(nonatomic, copy) void (^completionBlock)(NSString *result, NSError *error);
@end

@implementation QETranslationRequest

- (instancetype)initWithChinese:(NSString *)chinese
                         context:(NSString *)context
                            mode:(NSString *)mode
                        settings:(NSDictionary *)settings
                         onToken:(void (^)(NSString *))onToken
                      completion:(void (^)(NSString *, NSError *))completion {
    self = [super init];
    if (!self) return nil;

    _lineBuffer = [NSMutableData data];
    _allData = [NSMutableData data];
    _assembledText = [NSMutableString string];
    _onToken = [onToken copy];
    _completionBlock = [completion copy];

    NSString *endpoint = settings[@"endpoint"];
    NSURL *url = [NSURL URLWithString:endpoint];
    if (!url) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, QEError(@"接口地址无效")); });
        return self;
    }

    NSDictionary *instructions = @{
        @"naturalPost": @"Rewrite the Chinese as natural, idiomatic English for a social media post. Keep the original meaning and personality, but improve flow and phrasing.",
        @"shortComment": @"Turn the Chinese into a concise, conversational English comment. Sound like a real person online; avoid corporate or overly formal wording.",
        @"faithful": @"Translate the Chinese accurately into clear, idiomatic English. Preserve all meaning and details without adding new information."
    };
    NSString *instruction = instructions[mode] ?: instructions[@"naturalPost"];
    NSString *cleanContext = [context stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (cleanContext.length == 0) cleanContext = @"None provided.";

    NSString *systemPrompt = @"You are a bilingual English editor for social media posts and online comments. Produce only the final English text, with no preface, notes, quotation marks, or alternatives. Preserve names, @mentions, hashtags, URLs, emoji, and intentional line breaks. Never add facts that are not present in the source or context. Use natural contemporary English and contractions where appropriate.";
    NSString *userPrompt = [NSString stringWithFormat:@"TASK:\n%@\n\nOPTIONAL CONTEXT:\n%@\n\nCHINESE SOURCE:\n<source>\n%@\n</source>", instruction, cleanContext, chinese];
    NSDictionary *body = @{
        @"model": settings[@"model"] ?: @"",
        @"messages": @[
            @{@"role": @"system", @"content": systemPrompt},
            @{@"role": @"user", @"content": userPrompt}
        ],
        @"temperature": @0.35,
        @"stream": @YES
    };
    NSError *jsonError = nil;
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:0 error:&jsonError];
    if (!bodyData) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, jsonError); });
        return self;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:45];
    request.HTTPMethod = @"POST";
    request.HTTPBody = bodyData;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"text/event-stream" forHTTPHeaderField:@"Accept"];
    NSString *apiKey = settings[@"apiKey"];
    if (apiKey.length > 0) [request setValue:[@"Bearer " stringByAppendingString:apiKey] forHTTPHeaderField:@"Authorization"];

    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.timeoutIntervalForRequest = 45;
    configuration.timeoutIntervalForResource = 60;
    _session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:nil];
    _task = [_session dataTaskWithRequest:request];
    return self;
}

- (void)start { [self.task resume]; }

- (void)cancel {
    [self.task cancel];
    [self finishWithResult:nil error:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:@{NSLocalizedDescriptionKey: @"已取消"}]];
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    self.responseStatus = [(NSHTTPURLResponse *)response statusCode];
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    [self.allData appendData:data];
    if (self.responseStatus < 200 || self.responseStatus >= 300) return;
    [self.lineBuffer appendData:data];
    NSData *newline = [@"\n" dataUsingEncoding:NSUTF8StringEncoding];
    while (self.lineBuffer.length > 0) {
        NSRange range = [self.lineBuffer rangeOfData:newline options:0 range:NSMakeRange(0, self.lineBuffer.length)];
        if (range.location == NSNotFound) break;
        NSData *line = [self.lineBuffer subdataWithRange:NSMakeRange(0, range.location)];
        [self.lineBuffer replaceBytesInRange:NSMakeRange(0, NSMaxRange(range)) withBytes:NULL length:0];
        [self processSSELine:line];
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (self.completed) return;
    if (error) {
        [self finishWithResult:nil error:error];
        return;
    }
    if (self.responseStatus < 200 || self.responseStatus >= 300) {
        [self finishWithResult:nil error:[self APIError]];
        return;
    }
    if (self.lineBuffer.length > 0) [self processSSELine:self.lineBuffer];

    if (self.assembledText.length == 0) {
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:self.allData options:0 error:nil];
        NSArray *choices = [json[@"choices"] isKindOfClass:NSArray.class] ? json[@"choices"] : nil;
        NSDictionary *firstChoice = [choices.firstObject isKindOfClass:NSDictionary.class] ? choices.firstObject : nil;
        NSDictionary *message = [firstChoice[@"message"] isKindOfClass:NSDictionary.class] ? firstChoice[@"message"] : nil;
        id content = message[@"content"];
        if ([content isKindOfClass:NSString.class]) [self.assembledText appendString:content];
    }
    NSString *result = [self cleanText:self.assembledText];
    if (result.length == 0) {
        [self finishWithResult:nil error:QEError(@"模型返回了空内容")];
    } else {
        [self finishWithResult:result error:nil];
    }
}

- (void)processSSELine:(NSData *)lineData {
    NSString *line = [[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding];
    line = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (![line hasPrefix:@"data:"]) return;
    NSString *payload = [[line substringFromIndex:5] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if ([payload isEqualToString:@"[DONE]"] || payload.length == 0) return;
    NSData *data = [payload dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSArray *choices = [json[@"choices"] isKindOfClass:NSArray.class] ? json[@"choices"] : nil;
    NSDictionary *firstChoice = [choices.firstObject isKindOfClass:NSDictionary.class] ? choices.firstObject : nil;
    NSDictionary *delta = [firstChoice[@"delta"] isKindOfClass:NSDictionary.class] ? firstChoice[@"delta"] : nil;
    id token = delta[@"content"];
    if (![token isKindOfClass:NSString.class] || [token length] == 0) return;
    [self.assembledText appendString:token];
    if (self.onToken) dispatch_async(dispatch_get_main_queue(), ^{ self.onToken(token); });
}

- (NSError *)APIError {
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:self.allData options:0 error:nil];
    id message = [json valueForKeyPath:@"error.message"];
    if (![message isKindOfClass:NSString.class]) {
        message = [[NSString alloc] initWithData:self.allData encoding:NSUTF8StringEncoding];
    }
    if (![message isKindOfClass:NSString.class] || [message length] == 0) message = @"服务器没有返回详细信息";
    if ([message length] > 300) message = [message substringToIndex:300];
    return QEError([NSString stringWithFormat:@"接口错误 %ld：%@", (long)self.responseStatus, message]);
}

- (NSString *)cleanText:(NSString *)text {
    NSString *value = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([value hasPrefix:@"```"] && [value hasSuffix:@"```"]) {
        NSRegularExpression *opening = [NSRegularExpression regularExpressionWithPattern:@"^```(?:english)?\\s*" options:NSRegularExpressionCaseInsensitive error:nil];
        value = [opening stringByReplacingMatchesInString:value options:0 range:NSMakeRange(0, value.length) withTemplate:@""];
        NSRegularExpression *closing = [NSRegularExpression regularExpressionWithPattern:@"\\s*```$" options:0 error:nil];
        value = [closing stringByReplacingMatchesInString:value options:0 range:NSMakeRange(0, value.length) withTemplate:@""];
    }
    return [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

- (void)finishWithResult:(NSString *)result error:(NSError *)error {
    if (self.completed) return;
    self.completed = YES;
    [self.session finishTasksAndInvalidate];
    void (^completion)(NSString *, NSError *) = self.completionBlock;
    if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(result, error); });
}

@end

@class QEAppDelegate;
static OSStatus QEHotKeyHandler(EventHandlerCallRef nextHandler, EventRef event, void *userData);

@interface QEAppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate, WKScriptMessageHandler>
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) NSPanel *panel;
@property(nonatomic, strong) WKWebView *webView;
@property(nonatomic, strong) QETranslationRequest *translationRequest;
@property(nonatomic, assign) EventHotKeyRef hotKeyRef;
@property(nonatomic, assign) EventHandlerRef hotKeyHandlerRef;
@property(nonatomic, assign) BOOL recoveringLegacyKey;
@property(nonatomic, strong) NSMenuItem *shortcutMenuItem;
@property(nonatomic, strong) NSMenuItem *launchAtLoginMenuItem;
- (void)togglePanel;
@end

@implementation QEAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    [NSUserDefaults.standardUserDefaults registerDefaults:@{
        @"apiEndpoint": @"https://api.openai.com/v1/chat/completions",
        @"modelName": @"gpt-4.1-mini",
        @"autoCopy": @YES,
        @"hotkeyShortcut": @"controlOptionE"
    }];
    if (QEIsLaunchAtLoginEnabled()) QESetLaunchAtLoginEnabled(YES, nil);
    [self migrateDeepSeekModelNameIfNeeded];
    [self setupMainMenu];
    [self setupStatusItem];
    [self setupPanel];
    [self registerHotKey];
    [self showPanel];
}

- (void)migrateDeepSeekModelNameIfNeeded {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *endpoint = [defaults stringForKey:@"apiEndpoint"].lowercaseString;
    if (![endpoint containsString:@"api.deepseek.com"]) return;

    NSString *model = [defaults stringForKey:@"modelName"] ?: @"";
    NSString *normalized = model.lowercaseString;
    if ([normalized isEqualToString:@"deepseek-v4-flash"] || [normalized isEqualToString:@"deepseek-chat"]) {
        [defaults setObject:@"deepseek-v4-flash" forKey:@"modelName"];
    } else if ([normalized isEqualToString:@"deepseek-v4-pro"] || [normalized isEqualToString:@"deepseek-reasoner"]) {
        [defaults setObject:@"deepseek-v4-pro" forKey:@"modelName"];
    }
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    if (self.hotKeyRef) UnregisterEventHotKey(self.hotKeyRef);
    if (self.hotKeyHandlerRef) RemoveEventHandler(self.hotKeyHandlerRef);
    [self.webView.configuration.userContentController removeScriptMessageHandlerForName:@"app"];
}

- (void)setupMainMenu {
    NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:@""];

    NSMenuItem *appMenuItem = [[NSMenuItem alloc] initWithTitle:@"快译浮窗" action:nil keyEquivalent:@""];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"快译浮窗"];
    NSMenuItem *hide = [[NSMenuItem alloc] initWithTitle:@"隐藏快译浮窗" action:@selector(hide:) keyEquivalent:@"h"];
    hide.target = NSApp;
    [appMenu addItem:hide];
    [appMenu addItem:NSMenuItem.separatorItem];
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"退出快译浮窗" action:@selector(terminate:) keyEquivalent:@"q"];
    quit.target = NSApp;
    [appMenu addItem:quit];
    appMenuItem.submenu = appMenu;
    [mainMenu addItem:appMenuItem];

    NSMenuItem *editMenuItem = [[NSMenuItem alloc] initWithTitle:@"编辑" action:nil keyEquivalent:@""];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"编辑"];
    [editMenu addItem:[[NSMenuItem alloc] initWithTitle:@"撤销" action:@selector(undo:) keyEquivalent:@"z"]];
    NSMenuItem *redo = [[NSMenuItem alloc] initWithTitle:@"重做" action:@selector(redo:) keyEquivalent:@"z"];
    redo.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    [editMenu addItem:redo];
    [editMenu addItem:NSMenuItem.separatorItem];
    [editMenu addItem:[[NSMenuItem alloc] initWithTitle:@"剪切" action:@selector(cut:) keyEquivalent:@"x"]];
    [editMenu addItem:[[NSMenuItem alloc] initWithTitle:@"复制" action:@selector(copy:) keyEquivalent:@"c"]];
    [editMenu addItem:[[NSMenuItem alloc] initWithTitle:@"粘贴" action:@selector(paste:) keyEquivalent:@"v"]];
    [editMenu addItem:[[NSMenuItem alloc] initWithTitle:@"全选" action:@selector(selectAll:) keyEquivalent:@"a"]];
    editMenuItem.submenu = editMenu;
    [mainMenu addItem:editMenuItem];

    NSApp.mainMenu = mainMenu;
}

- (void)setupStatusItem {
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.title = @"译";
    self.statusItem.button.toolTip = @"快译浮窗";
    NSMenu *menu = [[NSMenu alloc] init];
    NSMenuItem *open = [[NSMenuItem alloc] initWithTitle:@"打开写作浮窗" action:@selector(showPanelAction:) keyEquivalent:@""];
    open.target = self;
    [menu addItem:open];
    NSString *shortcutLabel = QEShortcutLabel([NSUserDefaults.standardUserDefaults stringForKey:@"hotkeyShortcut"]);
    self.shortcutMenuItem = [[NSMenuItem alloc] initWithTitle:[@"快捷键：" stringByAppendingString:shortcutLabel] action:nil keyEquivalent:@""];
    self.shortcutMenuItem.enabled = NO;
    [menu addItem:self.shortcutMenuItem];
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *settings = [[NSMenuItem alloc] initWithTitle:@"模型接口设置…" action:@selector(showSettingsAction:) keyEquivalent:@","];
    settings.target = self;
    [menu addItem:settings];
    self.launchAtLoginMenuItem = [[NSMenuItem alloc] initWithTitle:@"开机自动启动" action:@selector(toggleLaunchAtLoginAction:) keyEquivalent:@""];
    self.launchAtLoginMenuItem.target = self;
    self.launchAtLoginMenuItem.state = QEIsLaunchAtLoginEnabled() ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:self.launchAtLoginMenuItem];
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"退出快译浮窗" action:@selector(quitAction:) keyEquivalent:@"q"];
    quit.target = self;
    [menu addItem:quit];
    self.statusItem.menu = menu;
}

- (void)setupPanel {
    self.panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 410, 460)
                                            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskUtilityWindow
                                              backing:NSBackingStoreBuffered
                                                defer:NO];
    self.panel.title = @"快译浮窗";
    self.panel.floatingPanel = YES;
    self.panel.level = NSFloatingWindowLevel;
    self.panel.hidesOnDeactivate = NO;
    self.panel.releasedWhenClosed = NO;
    self.panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
    self.panel.minSize = NSMakeSize(360, 400);
    self.panel.delegate = self;
    [self.panel center];

    WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
    [configuration.userContentController addScriptMessageHandler:self name:@"app"];
    self.webView = [[WKWebView alloc] initWithFrame:self.panel.contentView.bounds configuration:configuration];
    self.webView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.webView.navigationDelegate = nil;
    [self.panel.contentView addSubview:self.webView];

    NSURL *htmlURL = [NSBundle.mainBundle URLForResource:@"index" withExtension:@"html"];
    [self.webView loadFileURL:htmlURL allowingReadAccessToURL:htmlURL.URLByDeletingLastPathComponent];
}

- (BOOL)windowShouldClose:(NSWindow *)sender {
    [sender orderOut:nil];
    return NO;
}

- (OSStatus)registerHotKey {
    if (self.hotKeyRef) {
        UnregisterEventHotKey(self.hotKeyRef);
        self.hotKeyRef = NULL;
    }
    EventHotKeyID hotKeyID = { QEHotKeySignature, 1 };
    NSString *shortcut = [NSUserDefaults.standardUserDefaults stringForKey:@"hotkeyShortcut"] ?: @"controlOptionE";
    UInt32 keyCode = 0;
    UInt32 modifiers = 0;
    QEShortcutDefinition(shortcut, &keyCode, &modifiers);
    OSStatus status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &_hotKeyRef);
    if (!self.hotKeyHandlerRef) {
        EventTypeSpec eventType = { kEventClassKeyboard, kEventHotKeyPressed };
        InstallEventHandler(GetApplicationEventTarget(), QEHotKeyHandler, 1, &eventType, (__bridge void *)self, &_hotKeyHandlerRef);
    }
    self.shortcutMenuItem.title = [@"快捷键：" stringByAppendingString:QEShortcutLabel(shortcut)];
    return status;
}

- (void)showPanel {
    [NSApp activateIgnoringOtherApps:YES];
    [self.panel makeKeyAndOrderFront:nil];
    [self callJavaScript:@"focusInput" payload:@{}];
}

- (void)togglePanel {
    if (self.panel.visible) [self.panel orderOut:nil];
    else [self showPanel];
}

- (NSDictionary *)settings {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    return @{
        @"endpoint": [defaults stringForKey:@"apiEndpoint"] ?: @"",
        @"model": [defaults stringForKey:@"modelName"] ?: @"",
        @"apiKey": QEReadAPIKey(),
        @"autoCopy": @([defaults boolForKey:@"autoCopy"]),
        @"shortcut": [defaults stringForKey:@"hotkeyShortcut"] ?: @"controlOptionE"
    };
}

- (NSDictionary *)publicSettingsFromSettings:(NSDictionary *)settings {
    NSString *apiKey = settings[@"apiKey"] ?: @"";
    return @{
        @"endpoint": settings[@"endpoint"] ?: @"",
        @"model": settings[@"model"] ?: @"",
        @"autoCopy": @([settings[@"autoCopy"] boolValue]),
        @"apiKeyConfigured": @(apiKey.length > 0),
        @"shortcut": settings[@"shortcut"] ?: @"controlOptionE",
        @"launchAtLogin": @(QEIsLaunchAtLoginEnabled())
    };
}

- (NSString *)validationMessageForSettings:(NSDictionary *)settings {
    NSString *endpoint = [settings[@"endpoint"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSURL *url = [NSURL URLWithString:endpoint];
    if (!url || (![[url.scheme lowercaseString] isEqualToString:@"https"] && ![[url.scheme lowercaseString] isEqualToString:@"http"])) return @"请输入有效的接口地址";
    NSString *model = [settings[@"model"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (model.length == 0) return @"请填写模型名称";
    NSString *host = url.host.lowercaseString;
    BOOL local = [host isEqualToString:@"localhost"] || [host isEqualToString:@"127.0.0.1"] || [host isEqualToString:@"::1"];
    NSString *apiKey = [settings[@"apiKey"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (apiKey.length == 0 && !local) return @"请填写 API Key；本机 Ollama 则可留空";
    if ([[url.scheme lowercaseString] isEqualToString:@"http"] && !local) return @"非本机接口请使用 HTTPS，避免泄露 API Key";
    return nil;
}

- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.body isKindOfClass:NSDictionary.class]) return;
    NSDictionary *body = message.body;
    NSString *command = body[@"command"];

    if ([command isEqualToString:@"ready"]) {
        NSDictionary *settings = [self settings];
        [self callJavaScript:@"onSettings" payload:[self publicSettingsFromSettings:settings]];
        NSString *validation = [self validationMessageForSettings:settings];
        if (validation) [self callJavaScript:@"openSettings" payload:@{@"message": validation}];
    } else if ([command isEqualToString:@"hide"]) {
        [self.panel orderOut:nil];
    } else if ([command isEqualToString:@"copy"]) {
        [self copyText:body[@"text"] ?: @""];
        [self callJavaScript:@"onCopied" payload:@{}];
    } else if ([command isEqualToString:@"openExternal"]) {
        NSURL *url = [NSURL URLWithString:body[@"url"] ?: @""];
        if (url && [url.scheme.lowercaseString isEqualToString:@"https"]) [NSWorkspace.sharedWorkspace openURL:url];
    } else if ([command isEqualToString:@"recoverLegacyKey"]) {
        [self recoverLegacyAPIKey];
    } else if ([command isEqualToString:@"cancel"]) {
        [self.translationRequest cancel];
    } else if ([command isEqualToString:@"saveSettings"]) {
        [self saveSettings:body];
    } else if ([command isEqualToString:@"translate"]) {
        [self translate:body];
    }
}

- (void)saveSettings:(NSDictionary *)body {
    NSString *submittedKey = [body[@"apiKey"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *effectiveKey = submittedKey.length > 0 ? submittedKey : QEReadAPIKey();
    NSDictionary *candidate = @{
        @"endpoint": body[@"endpoint"] ?: @"",
        @"model": body[@"model"] ?: @"",
        @"apiKey": effectiveKey ?: @"",
        @"autoCopy": @([body[@"autoCopy"] boolValue])
    };
    NSString *validation = [self validationMessageForSettings:candidate];
    if (validation) {
        [self callJavaScript:@"onSettingsError" payload:@{@"message": validation}];
        return;
    }
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *oldShortcut = [defaults stringForKey:@"hotkeyShortcut"] ?: @"controlOptionE";
    NSString *newShortcut = [body[@"shortcut"] isKindOfClass:NSString.class] ? body[@"shortcut"] : @"controlOptionE";
    [defaults setObject:newShortcut forKey:@"hotkeyShortcut"];
    OSStatus hotKeyStatus = [self registerHotKey];
    if (hotKeyStatus != noErr) {
        [defaults setObject:oldShortcut forKey:@"hotkeyShortcut"];
        [self registerHotKey];
        [self callJavaScript:@"onSettingsError" payload:@{@"message": @"这个快捷键已被其他应用占用，请换一个"}];
        return;
    }

    BOOL launchAtLogin = [body[@"launchAtLogin"] boolValue];
    NSError *launchError = nil;
    if (!QESetLaunchAtLoginEnabled(launchAtLogin, &launchError)) {
        [self callJavaScript:@"onSettingsError" payload:@{@"message": launchError.localizedDescription ?: @"无法修改开机启动设置"}];
        return;
    }
    self.launchAtLoginMenuItem.state = launchAtLogin ? NSControlStateValueOn : NSControlStateValueOff;

    [defaults setObject:[candidate[@"endpoint"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] forKey:@"apiEndpoint"];
    [defaults setObject:[candidate[@"model"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] forKey:@"modelName"];
    [defaults setBool:[candidate[@"autoCopy"] boolValue] forKey:@"autoCopy"];
    if (submittedKey.length > 0) QESaveAPIKey(submittedKey);
    [self callJavaScript:@"onSettingsSaved" payload:@{
        @"apiKeyConfigured": @(effectiveKey.length > 0),
        @"shortcut": newShortcut,
        @"launchAtLogin": @(launchAtLogin)
    }];
}

- (void)recoverLegacyAPIKey {
    if (self.recoveringLegacyKey) return;
    self.recoveringLegacyKey = YES;
    [self callJavaScript:@"onLegacyKeyRecoveryStarted" payload:@{}];

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        OSStatus status = errSecItemNotFound;
        NSString *key = QEReadLegacyKeychainAPIKey(&status);
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) selfRef = weakSelf;
            selfRef.recoveringLegacyKey = NO;
            if (status == errSecSuccess && key.length > 0) {
                QESaveAPIKey(key);
                [selfRef callJavaScript:@"onLegacyKeyRecovered" payload:@{}];
                return;
            }
            NSString *message = nil;
            if (status == errSecUserCanceled || status == errSecAuthFailed) {
                message = @"未完成授权，旧 API Key 仍在钥匙串中";
            } else if (status == errSecItemNotFound) {
                message = @"没有找到旧钥匙串条目";
            } else {
                CFStringRef detail = SecCopyErrorMessageString(status, NULL);
                message = [NSString stringWithFormat:@"恢复失败：%@", detail ? (__bridge NSString *)detail : @"未知错误"];
                if (detail) CFRelease(detail);
            }
            [selfRef callJavaScript:@"onLegacyKeyRecoveryError" payload:@{@"message": message}];
        });
    });
}

- (void)translate:(NSDictionary *)body {
    if (self.translationRequest) {
        [self.translationRequest cancel];
        self.translationRequest = nil;
    }
    NSString *chinese = [body[@"chinese"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (chinese.length == 0) {
        [self callJavaScript:@"onError" payload:@{@"message": @"先写一段中文"}];
        return;
    }
    NSDictionary *settings = [self settings];
    NSString *validation = [self validationMessageForSettings:settings];
    if (validation) {
        [self callJavaScript:@"onError" payload:@{@"message": validation}];
        [self callJavaScript:@"openSettings" payload:@{@"message": validation}];
        return;
    }

    [self callJavaScript:@"onStart" payload:@{}];
    __weak typeof(self) weakSelf = self;
    self.translationRequest = [[QETranslationRequest alloc]
        initWithChinese:chinese
        context:body[@"context"] ?: @""
        mode:body[@"mode"] ?: @"naturalPost"
        settings:settings
        onToken:^(NSString *token) {
            [weakSelf callJavaScript:@"onToken" payload:@{@"token": token}];
        }
        completion:^(NSString *result, NSError *error) {
            typeof(self) selfRef = weakSelf;
            selfRef.translationRequest = nil;
            if (error) {
                if ([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled) {
                    [selfRef callJavaScript:@"onCancelled" payload:@{}];
                } else {
                    [selfRef callJavaScript:@"onError" payload:@{@"message": error.localizedDescription ?: @"翻译失败"}];
                }
                return;
            }
            BOOL autoCopy = [settings[@"autoCopy"] boolValue];
            if (autoCopy) [selfRef copyText:result];
            [selfRef callJavaScript:@"onResult" payload:@{@"text": result ?: @"", @"copied": @(autoCopy)}];
        }];
    [self.translationRequest start];
}

- (void)copyText:(NSString *)text {
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:text forType:NSPasteboardTypeString];
}

- (void)callJavaScript:(NSString *)method payload:(id)payload {
    if (!method.length) return;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:payload ?: @{} options:0 error:nil];
    NSString *json = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding] ?: @"{}";
    NSString *script = [NSString stringWithFormat:@"window.quickEnglish && window.quickEnglish.%@(%@);", method, json];
    dispatch_async(dispatch_get_main_queue(), ^{ [self.webView evaluateJavaScript:script completionHandler:nil]; });
}

- (void)showPanelAction:(id)sender { [self showPanel]; }
- (void)showSettingsAction:(id)sender {
    [self showPanel];
    [self callJavaScript:@"openSettings" payload:@{}];
}
- (void)quitAction:(id)sender { [NSApp terminate:nil]; }

- (void)toggleLaunchAtLoginAction:(id)sender {
    BOOL enabled = !QEIsLaunchAtLoginEnabled();
    NSError *error = nil;
    if (QESetLaunchAtLoginEnabled(enabled, &error)) {
        self.launchAtLoginMenuItem.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
        [self callJavaScript:@"onLaunchAtLoginChanged" payload:@{@"enabled": @(enabled)}];
    } else {
        [self showPanel];
        [self callJavaScript:@"onError" payload:@{@"message": error.localizedDescription ?: @"无法修改开机启动设置"}];
    }
}

@end

static OSStatus QEHotKeyHandler(EventHandlerCallRef nextHandler, EventRef event, void *userData) {
    EventHotKeyID hotKeyID = {0};
    GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID, NULL, sizeof(hotKeyID), NULL, &hotKeyID);
    if (hotKeyID.signature == QEHotKeySignature && hotKeyID.id == 1) {
        QEAppDelegate *delegate = (__bridge QEAppDelegate *)userData;
        dispatch_async(dispatch_get_main_queue(), ^{ [delegate togglePanel]; });
    }
    return noErr;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *application = NSApplication.sharedApplication;
        QEAppDelegate *delegate = [[QEAppDelegate alloc] init];
        application.delegate = delegate;
        [application run];
    }
    return 0;
}
