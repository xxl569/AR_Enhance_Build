//
// ARAutoStartIntentExtension.mm
// AudioRecorder TS 6.0.3 独立 SiriKit Intents Extension (PlugIns/ARAutoStartIntents.appex)
// v7：沙盒穿透 Darwin Ping-Pong 验活 + FrontBoardServices 后台挂起唤醒无沙盒主 App 拉起 root 守护进程
//

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <Intents/Intents.h>
#import <objc/message.h>
#import <sys/sysctl.h>
#import <sys/stat.h>
#import <dlfcn.h>
#import <unistd.h>
#import <errno.h>
#import <notify.h>
#import <string.h>

#import "EnsureDaemonIntent.h"

static NSString *const kARExtBundleID        = @"net.limneos.AudioRecorder";
static NSString *const kARExtSuiteName       = @"net.limneos.audiorecorder";
static NSString *const kARExtDefaultsTmpPath = @"/tmp/.audioRecDefaults";
static NSString *const kARExtDaemonPongPath  = @"/tmp/.ar_daemon_pong";
static NSString *const kARExtWantRecoverPath = @"/tmp/.ar_want_bg_recover";
static NSString *const kARExtLogPath         = @"/tmp/ar_enhance.log";
static NSString *const kARExtQQBundleID      = @"com.tencent.mqq";
static const char *const kARExtNotifyPrefs   = "net.limneos.audiorecorder.prefsChangedInternal";
static const char *const kARExtNotifyPing    = "net.limneos.audiorecorder.arenhance.ping";

// 同步写入日志，避免短生命周期扩展退出时异步日志丢失
static void ARExtLog(NSString *fmt, ...) {
    @autoreleasepool {
        va_list args;
        va_start(args, fmt);
        NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
        va_end(args);

        static NSDateFormatter *df = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            df = [[NSDateFormatter alloc] init];
            df.dateFormat = @"MM-dd HH:mm:ss.SSS";
        });
        NSString *line = [NSString stringWithFormat:@"[%@] [EXT pid:%d] %@\n",
                          [df stringFromDate:[NSDate date]], getpid(), msg];

        const char *path = kARExtLogPath.UTF8String;
        struct stat st;
        if (stat(path, &st) == 0 && st.st_size > 65536) {
            unlink(path);
        }
        FILE *fp = fopen(path, "a");
        if (fp) {
            const char *utf8 = line.UTF8String;
            if (utf8) fwrite(utf8, 1, strlen(utf8), fp);
            fclose(fp);
            chmod(path, 0666);
        }
    }
}

static int64_t ARExtGetSystemBootTimeSeconds(void) {
    struct timeval boottime = {0};
    size_t len = sizeof(boottime);
    int mib[2] = {CTL_KERN, KERN_BOOTTIME};
    if (sysctl(mib, 2, &boottime, &len, NULL, 0) == 0) {
        return (int64_t)boottime.tv_sec;
    }
    return 0;
}

static void ARExtSyncPreferencesToTmp(void) {
    @autoreleasepool {
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kARExtSuiteName];
        [defaults synchronize];
        NSMutableDictionary *dict = [[defaults dictionaryRepresentation] mutableCopy];
        if (!dict) dict = [NSMutableDictionary dictionary];

        NSString *prefPlistPath = @"/var/mobile/Library/Preferences/net.limneos.audiorecorder.plist";
        NSDictionary *diskPrefs = [NSDictionary dictionaryWithContentsOfFile:prefPlistPath];
        if ([diskPrefs isKindOfClass:[NSDictionary class]]) {
            [dict addEntriesFromDictionary:diskPrefs];
        }

        if (!dict[kARExtQQBundleID]) {
            dict[kARExtQQBundleID] = @(1);
        }
        if (!dict[@"localization"]) {
            NSString *lang = [[NSLocale currentLocale] objectForKey:NSLocaleLanguageCode] ?: @"zh";
            dict[@"localization"] = lang;
        }

        NSMutableDictionary *cleanDict = [NSMutableDictionary dictionaryWithCapacity:dict.count];
        for (id key in dict) {
            id val = dict[key];
            if ([key isKindOfClass:[NSString class]] &&
                ([val isKindOfClass:[NSString class]] ||
                 [val isKindOfClass:[NSNumber class]] ||
                 [val isKindOfClass:[NSArray class]] ||
                 [val isKindOfClass:[NSDictionary class]] ||
                 [val isKindOfClass:[NSData class]] ||
                 [val isKindOfClass:[NSDate class]])) {
                cleanDict[key] = val;
            }
        }

        BOOL ok = [cleanDict writeToFile:kARExtDefaultsTmpPath atomically:YES];
        if (ok) {
            chown(kARExtDefaultsTmpPath.UTF8String, 501, 501);
            chmod(kARExtDefaultsTmpPath.UTF8String, 0666);
            notify_post(kARExtNotifyPrefs);
        }
        ARExtLog(@"同步配置到 %@ 结果=%d, enabled=%@, qqMode=%@",
                 kARExtDefaultsTmpPath, ok, cleanDict[@"enabled"], cleanDict[kARExtQQBundleID]);
    }
}

// 沙盒穿透 Ping-Pong 验活：不依赖被 Seatbelt 封锁的 sysctl(KERN_PROC_*) / posix_spawn
static BOOL ARExtPingDaemon(int timeoutMs, pid_t *outPid) {
    if (outPid) *outPid = -1;
    int64_t curBoot = ARExtGetSystemBootTimeSeconds();
    unlink(kARExtDaemonPongPath.UTF8String);
    notify_post(kARExtNotifyPing);

    int elapsed = 0;
    const int stepMs = 20;
    while (elapsed <= timeoutMs) {
        NSString *pong = [NSString stringWithContentsOfFile:kARExtDaemonPongPath
                                                   encoding:NSUTF8StringEncoding
                                                      error:nil];
        if (pong.length > 0) {
            NSArray<NSString *> *parts = [[pong stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
                                          componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (parts.count >= 2) {
                pid_t pid = (pid_t)[parts[0] intValue];
                int64_t recBoot = [parts[1] longLongValue];
                if (pid > 1 && recBoot == curBoot) {
                    if (outPid) *outPid = pid;
                    return YES;
                }
            }
        }
        usleep(stepMs * 1000);
        elapsed += stepMs;
    }
    return NO;
}

// 后台挂起唤醒无沙盒主 App，由主 App constructor 同步完成 root daemon 拉起（零闪屏）
static BOOL ARExtWakeMainAppInBackground(NSString *__autoreleasing *outDiag) {
    int64_t curBoot = ARExtGetSystemBootTimeSeconds();
    NSString *reqContent = [NSString stringWithFormat:@"%lld\n", curBoot];
    [reqContent writeToFile:kARExtWantRecoverPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    chmod(kARExtWantRecoverPath.UTF8String, 0666);
    ARExtSyncPreferencesToTmp();

    NSMutableArray<NSString *> *diagParts = [NSMutableArray array];

    // 通道 A：FrontBoardServices (__ActivateSuspended = YES, __UnlockDevice = NO)
    void *fbsHandle = dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_NOW);
    Class svcCls = NSClassFromString(@"FBSOpenApplicationService");
    Class optCls = NSClassFromString(@"FBSOpenApplicationOptions");
    if (svcCls && optCls) {
        id svc = ((id (*)(id, SEL))objc_msgSend)(svcCls, NSSelectorFromString(@"serviceWithDefaultShellEndpoint"));
        NSDictionary *optDict = @{
            @"__ActivateSuspended": @YES,
            @"__UnlockDevice": @NO
        };
        id opts = ((id (*)(id, SEL, id))objc_msgSend)(optCls, NSSelectorFromString(@"optionsWithDictionary:"), optDict);
        SEL openSel = NSSelectorFromString(@"openApplication:withOptions:completion:");
        if (svc && opts && [svc respondsToSelector:openSel]) {
            __block BOOL fbsDone = NO;
            __block BOOL fbsSuccess = NO;
            __block NSString *fbsErrStr = nil;
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);

            void (^comp)(id, NSError *) = ^(id process, NSError *error) {
                if (error) {
                    fbsSuccess = NO;
                    fbsErrStr = [NSString stringWithFormat:@"FBS:%@(%ld)", error.domain, (long)error.code];
                    ARExtLog(@"FBSOpenApplication 失败: %@", error);
                } else {
                    fbsSuccess = YES;
                    ARExtLog(@"FBSOpenApplication 成功触发后台挂起唤醒 process=%@", process);
                }
                fbsDone = YES;
                dispatch_semaphore_signal(sem);
            };

            ((void (*)(id, SEL, id, id, id))objc_msgSend)(svc, openSel, kARExtBundleID, opts, comp);
            dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)));

            if (fbsDone && fbsSuccess) {
                if (outDiag) *outDiag = @"FBS_OK";
                return YES;
            }
            [diagParts addObject:(fbsErrStr ?: @"FBS_TIMEOUT")];
        } else {
            [diagParts addObject:[NSString stringWithFormat:@"FBS_NO_SVC(svc=%d,opts=%d)", svc != nil, opts != nil]];
        }
    } else {
        [diagParts addObject:[NSString stringWithFormat:@"FBS_NO_CLS(h=%d)", fbsHandle != NULL]];
    }

    // 通道 B：SpringBoardServices SBSLaunchApplicationWithIdentifier(..., suspended=true)
    void *sbsHandle = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW);
    if (sbsHandle) {
        typedef int (*SBSLaunchFn)(CFStringRef, Boolean);
        SBSLaunchFn sbsLaunch = (SBSLaunchFn)dlsym(sbsHandle, "SBSLaunchApplicationWithIdentifier");
        if (sbsLaunch) {
            int sbsRc = sbsLaunch((__bridge CFStringRef)kARExtBundleID, true);
            ARExtLog(@"SBSLaunchApplicationWithIdentifier(suspended=true) rc=%d", sbsRc);
            if (sbsRc == 0) {
                if (outDiag) *outDiag = [NSString stringWithFormat:@"%@,SBS_OK", [diagParts componentsJoinedByString:@";"]];
                return YES;
            }
            [diagParts addObject:[NSString stringWithFormat:@"SBS:%d", sbsRc]];
        } else {
            [diagParts addObject:@"SBS_NO_SYM"];
        }
    } else {
        [diagParts addObject:@"SBS_NO_DL"];
    }

    if (outDiag) *outDiag = [diagParts componentsJoinedByString:@";"];
    return NO;
}

static BOOL ARExtEnsureDaemonRunning(NSString *__autoreleasing *outMsg) {
    pid_t alivePid = -1;
    if (ARExtPingDaemon(260, &alivePid)) {
        if (![[NSFileManager defaultManager] fileExistsAtPath:kARExtDefaultsTmpPath]) {
            ARExtSyncPreferencesToTmp();
        }
        if (outMsg) {
            *outMsg = [NSString stringWithFormat:@"通话录音守护进程已在运行中 (PID %d)", alivePid];
        }
        ARExtLog(@"Ping-Pong 确认守护进程存活 pid=%d", alivePid);
        return YES;
    }

    ARExtLog(@"Ping-Pong 未收到响应，准备通过 FrontBoard 后台唤醒无沙盒主 App 拉起守护进程...");
    NSString *wakeDiag = nil;
    BOOL wakeCalled = ARExtWakeMainAppInBackground(&wakeDiag);
    ARExtLog(@"后台唤醒主 App 调用完成 wakeCalled=%d diag=%@", wakeCalled, wakeDiag);

    // 轮询等待最多 3.5 秒，直到新拉起的守护进程返回 Pong
    pid_t newPid = -1;
    for (int i = 0; i < 14; i++) {
        if (ARExtPingDaemon(220, &newPid)) {
            ARExtLog(@"后台唤醒成功，守护进程已恢复 pid=%d (尝试轮次=%d)", newPid, i + 1);
            if (outMsg) {
                *outMsg = [NSString stringWithFormat:@"检测到重启后守护进程未启动，已在后台静默恢复通话录音 (PID %d)", newPid];
            }
            return YES;
        }
        usleep(30 * 1000);
    }

    ARExtLog(@"后台恢复超时 wakeDiag=%@", wakeDiag);
    if (outMsg) {
        *outMsg = [NSString stringWithFormat:@"后台恢复超时(%@)，请查看 /tmp/ar_enhance.log", wakeDiag ?: @"未知"];
    }
    return NO;
}

@interface ARAutoStartIntentExtensionHandler : INExtension <EnsureDaemonIntentHandling>
@end

@implementation ARAutoStartIntentExtensionHandler

- (id)handlerForIntent:(INIntent *)intent {
    ARExtLog(@"收到 handlerForIntent：%@", NSStringFromClass([intent class]));
    return self;
}

- (void)confirmEnsureDaemon:(EnsureDaemonIntent *)intent
                completion:(void (^)(EnsureDaemonIntentResponse *response))completion {
    ARExtLog(@"confirmEnsureDaemon 就绪");
    if (completion) {
        EnsureDaemonIntentResponse *resp =
            [[EnsureDaemonIntentResponse alloc] initWithCode:EnsureDaemonIntentResponseCodeReady userActivity:nil];
        completion(resp);
    }
}

- (void)handleEnsureDaemon:(EnsureDaemonIntent *)intent
               completion:(void (^)(EnsureDaemonIntentResponse *response))completion {
    ARExtLog(@"开始处理 EnsureDaemonIntent");
    NSString *statusMsg = nil;
    BOOL ok = NO;
    @try {
        ok = ARExtEnsureDaemonRunning(&statusMsg);
    } @catch (NSException *ex) {
        ARExtLog(@"handleEnsureDaemon 异常：%@", ex);
        ok = NO;
        statusMsg = [NSString stringWithFormat:@"执行异常：%@", ex.reason ?: @"未知错误"];
    }

    EnsureDaemonIntentResponseCode code = ok ? EnsureDaemonIntentResponseCodeSuccess : EnsureDaemonIntentResponseCodeFailure;
    EnsureDaemonIntentResponse *resp = [[EnsureDaemonIntentResponse alloc] initWithCode:code userActivity:nil];
    resp.statusMessage = statusMsg ?: (ok ? @"已生效" : @"恢复失败");
    ARExtLog(@"handleEnsureDaemon 完成 ok=%d msg=%@", ok, resp.statusMessage);

    if (completion) {
        completion(resp);
    }
}

@end
