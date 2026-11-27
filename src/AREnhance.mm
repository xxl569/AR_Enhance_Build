//
// AREnhance.mm
// AudioRecorder TS 6.0.3 功能增强动态库：
// 1. 需求一：开机特征检测 (KERN_BOOTTIME) + 偏好同步 (/tmp/.audioRecDefaults)
//           + 守护进程存活检测与 root 拉起 + SiriKit 后台零闪屏 INIntent + 静默 URL 路由
// 2. 需求二：QQ (com.tencent.mqq) 设置页原生融合 + 守护进程 QQ 语音/视频通话智能监听与双向录音接入
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Intents/Intents.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <sys/sysctl.h>
#import <sys/stat.h>
#import <dlfcn.h>
#import <notify.h>
#import <spawn.h>
#import <unistd.h>
#import <signal.h>
#import <string.h>

#import "EnsureDaemonIntent.h"

// ============================================================================
// 私有系统 C API 声明（仅依赖标准 libSystem，无第三方头文件依赖）
// ============================================================================

extern "C" {
    extern char **environ;
    int proc_listpids(uint32_t type, uint32_t typeinfo, void *buffer, int buffersize);
    int proc_pidpath(int pid, void *buffer, uint32_t buffersize);
    int posix_spawnattr_set_persona_np(const posix_spawnattr_t *__restrict, uid_t, uint32_t);
    int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t *__restrict, uid_t);
    int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t *__restrict, gid_t);
}

#ifndef PROC_ALL_PIDS
#define PROC_ALL_PIDS 1
#endif
#ifndef PROC_PIDPATHINFO_MAXSIZE
#define PROC_PIDPATHINFO_MAXSIZE 4096
#endif
#ifndef POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE
#define POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 1
#endif

// ============================================================================
// 常量定义（均由 AudioRecorder TS 6.0.3 ARM64 二进制反汇编实证确认）
// ============================================================================

static NSString *const kARSuiteName            = @"net.limneos.audiorecorder";
static NSString *const kARDefaultsTmpPath      = @"/tmp/.audioRecDefaults";
static NSString *const kARBootAlivePath        = @"/tmp/.ar_enhance_boot_alive";
static NSString *const kARLogPath              = @"/tmp/ar_enhance.log";
static NSString *const kARQQProbeLogPath       = @"/tmp/ar_qq_probe.log";
static NSString *const kQQBundleID             = @"com.tencent.mqq";
static NSString *const kQQDisplayName          = @"QQ";

static const char *const kARNotifyStatus       = "net.limneos.audiorecorder.status";
static const char *const kARNotifyPrefsInt     = "net.limneos.audiorecorder.prefsChangedInternal";

// AudioRecorder 6.0.3 (arm64 slice) 全局变量相对 0x100000000 静态地址偏移
static const uintptr_t kARAddrCallStatusDict   = 0x100179618ULL;
static const uintptr_t kARAddrCallStartTime    = 0x100179638ULL;
static const uintptr_t kARAddrCallEndTime      = 0x100179640ULL;

// ============================================================================
// 轻量滚动日志（上限 64KB，方便真机排查）
// ============================================================================

static void ARLog(NSString *fmt, ...) {
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
        NSString *line = [NSString stringWithFormat:@"[%@] [pid:%d] %@\n", [df stringFromDate:[NSDate date]], getpid(), msg];

        static dispatch_queue_t logQ = nil;
        static dispatch_once_t qOnce;
        dispatch_once(&qOnce, ^{
            logQ = dispatch_queue_create("com.arenhance.log", DISPATCH_QUEUE_SERIAL);
        });
        dispatch_async(logQ, ^{
            const char *path = kARLogPath.UTF8String;
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
        });
    }
}

// ============================================================================
// 通用工具：主镜像 ASLR slide 与安全全局指针读取
// ============================================================================

static uintptr_t ARMainImageSlide(void) {
    static uintptr_t cachedSlide = 0;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cachedSlide = (uintptr_t)_dyld_get_image_vmaddr_slide(0);
    });
    return cachedSlide;
}

static BOOL ARIsAddressInMainDataSegment(uintptr_t addr) {
    const struct mach_header_64 *hdr = (const struct mach_header_64 *)_dyld_get_image_header(0);
    if (!hdr || hdr->magic != MH_MAGIC_64) return NO;
    uintptr_t slide = ARMainImageSlide();
    const uint8_t *cmdPtr = (const uint8_t *)(hdr + 1);
    for (uint32_t i = 0; i < hdr->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cmdPtr;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            if (strcmp(seg->segname, "__DATA") == 0) {
                uintptr_t start = seg->vmaddr + slide;
                uintptr_t end = start + seg->vmsize;
                return (addr >= start && addr + sizeof(void *) <= end);
            }
        }
        cmdPtr += lc->cmdsize;
    }
    return NO;
}

static void **ARGetGlobalCallStatusDictSlot(void) {
    uintptr_t addr = ARMainImageSlide() + kARAddrCallStatusDict;
    if (!ARIsAddressInMainDataSegment(addr)) {
        ARLog(@"警告：全局状态字典地址 0x%lx 不在主镜像 __DATA 段内，已跳过", (unsigned long)addr);
        return NULL;
    }
    return (void **)addr;
}

static double *ARGetGlobalTimeSlot(uintptr_t staticAddr) {
    uintptr_t addr = ARMainImageSlide() + staticAddr;
    if (!ARIsAddressInMainDataSegment(addr)) return NULL;
    return (double *)addr;
}

// ============================================================================
// 模块 1：系统开机特征检测、偏好同步与守护进程自动复活
// ============================================================================

static int64_t ARGetSystemBootTimeSeconds(void) {
    struct timeval boottime = {0};
    size_t len = sizeof(boottime);
    int mib[2] = {CTL_KERN, KERN_BOOTTIME};
    if (sysctl(mib, 2, &boottime, &len, NULL, 0) == 0) {
        return (int64_t)boottime.tv_sec;
    }
    return 0;
}

static BOOL ARProcessHasDaemonArg(pid_t pid) {
    int mib[3] = {CTL_KERN, KERN_PROCARGS2, pid};
    size_t size = 0;
    if (sysctl(mib, 3, NULL, &size, NULL, 0) != 0 || size == 0 || size > 65536) {
        return NO;
    }
    char *buf = (char *)malloc(size);
    if (!buf) return NO;
    BOOL found = NO;
    if (sysctl(mib, 3, buf, &size, NULL, 0) == 0 && size > sizeof(int)) {
        int argc = 0;
        memcpy(&argc, buf, sizeof(int));
        char *p = buf + sizeof(int);
        char *end = buf + size;
        // 跳过 exec_path 及其后的空字符填充
        while (p < end && *p != '\0') p++;
        while (p < end && *p == '\0') p++;
        // 遍历 argv[0..argc-1]
        for (int i = 0; i < argc && p < end; i++) {
            size_t slen = strnlen(p, (size_t)(end - p));
            if (i > 0 && slen == 6 && strncmp(p, "daemon", 6) == 0) {
                found = YES;
                break;
            }
            p += slen + 1;
        }
    }
    free(buf);
    return found;
}

static pid_t ARFindRunningDaemonPID(void) {
    int byteCount = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (byteCount <= 0) return -1;
    int cap = (byteCount / (int)sizeof(pid_t)) + 64;
    pid_t *pids = (pid_t *)calloc((size_t)cap, sizeof(pid_t));
    if (!pids) return -1;

    int actualBytes = proc_listpids(PROC_ALL_PIDS, 0, pids, cap * (int)sizeof(pid_t));
    int count = actualBytes / (int)sizeof(pid_t);
    pid_t selfPid = getpid();
    pid_t result = -1;

    char pathBuf[PROC_PIDPATHINFO_MAXSIZE];
    for (int i = 0; i < count; i++) {
        pid_t pid = pids[i];
        if (pid <= 1 || pid == selfPid) continue;
        memset(pathBuf, 0, sizeof(pathBuf));
        if (proc_pidpath(pid, pathBuf, sizeof(pathBuf)) > 0) {
            if (strstr(pathBuf, "/AudioRecorder.app/AudioRecorder") != NULL) {
                if (ARProcessHasDaemonArg(pid)) {
                    result = pid;
                    break;
                }
            }
        }
    }
    free(pids);
    return result;
}

// 同步 net.limneos.audiorecorder 偏好到 /tmp/.audioRecDefaults（解决重启后 /tmp 清空问题）
static void ARSyncPreferencesToTmp(void) {
    @autoreleasepool {
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kARSuiteName];
        [defaults synchronize];
        NSMutableDictionary *dict = [[defaults dictionaryRepresentation] mutableCopy];
        if (!dict) dict = [NSMutableDictionary dictionary];

        // 兜底直接读偏好 plist，避免后台冷启动时 NSUserDefaults 缓存为空
        NSString *prefPlistPath = @"/var/mobile/Library/Preferences/net.limneos.audiorecorder.plist";
        NSDictionary *diskPrefs = [NSDictionary dictionaryWithContentsOfFile:prefPlistPath];
        if ([diskPrefs isKindOfClass:[NSDictionary class]]) {
            [dict addEntriesFromDictionary:diskPrefs];
        }

        // 若用户未显式关闭 QQ，默认开启自动录制全部 QQ 通话 (1 = Automatically)
        if (!dict[kQQBundleID]) {
            dict[kQQBundleID] = @(1);
        }
        // 确保 localization 字段存在（原版守护进程依赖）
        if (!dict[@"localization"]) {
            NSString *lang = [[NSLocale currentLocale] objectForKey:NSLocaleLanguageCode] ?: @"zh";
            dict[@"localization"] = lang;
        }
        // 清理不可序列化对象，防止 writeToFile 失败
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

        BOOL ok = [cleanDict writeToFile:kARDefaultsTmpPath atomically:YES];
        if (ok) {
            chown(kARDefaultsTmpPath.UTF8String, 501, 501);
            chmod(kARDefaultsTmpPath.UTF8String, 0666);
            notify_post(kARNotifyPrefsInt);
        }
        ARLog(@"同步配置到 %@ 结果=%d, enabled=%@, qqMode=%@",
              kARDefaultsTmpPath, ok, cleanDict[@"enabled"], cleanDict[kQQBundleID]);
    }
}

static BOOL ARSpawnDaemonAsRoot(void) {
    NSString *execPath = [[NSBundle mainBundle] executablePath];
    if (!execPath || execPath.length == 0) {
        ARLog(@"拉起守护进程失败：executablePath 为空");
        return NO;
    }

    posix_spawnattr_t attr;
    if (posix_spawnattr_init(&attr) != 0) {
        return NO;
    }

    // 赋予 root persona（依赖 TrollStore 保留的 com.apple.private.persona-mgmt 与 spawn-subsystem-root）
    posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    posix_spawnattr_set_persona_uid_np(&attr, 0);
    posix_spawnattr_set_persona_gid_np(&attr, 0);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);
    posix_spawnattr_setpgroup(&attr, 0);

    const char *cPath = execPath.UTF8String;
    char *argv[] = {(char *)cPath, (char *)"daemon", NULL};
    pid_t childPid = -1;
    int rc = posix_spawn(&childPid, cPath, NULL, &attr, argv, environ);
    posix_spawnattr_destroy(&attr);

    if (rc == 0 && childPid > 0) {
        ARLog(@"成功拉起守护进程 pid=%d path=%@", childPid, execPath);
        return YES;
    }

    // 若 persona 失败，尝试普通 posix_spawn 兜底
    ARLog(@"root persona 拉起失败 rc=%d，尝试普通 posix_spawn 兜底", rc);
    rc = posix_spawn(&childPid, cPath, NULL, NULL, argv, environ);
    ARLog(@"普通 posix_spawn 结果 rc=%d pid=%d", rc, childPid);
    return (rc == 0 && childPid > 0);
}

// 核心入口：开机周期内检测守护进程状态，未运行则同步配置并静默拉起
static BOOL AREnsureDaemonRunning(NSString *__autoreleasing *outMessage) {
    static NSObject *lockObj = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        lockObj = [[NSObject alloc] init];
    });

    @synchronized (lockObj) {
        int64_t bootTime = ARGetSystemBootTimeSeconds();
        pid_t existingPid = ARFindRunningDaemonPID();

        if (existingPid > 0) {
            // 顺手确保 /tmp/.audioRecDefaults 存在
            if (![[NSFileManager defaultManager] fileExistsAtPath:kARDefaultsTmpPath]) {
                ARSyncPreferencesToTmp();
            }
            if (outMessage) {
                *outMessage = [NSString stringWithFormat:@"通话录音守护进程已在运行中 (PID %d)", existingPid];
            }
            ARLog(@"跳过拉起：守护进程已存活 pid=%d bootTime=%lld", existingPid, bootTime);
            return YES;
        }

        ARLog(@"检测到守护进程未运行（可能刚重启，bootTime=%lld），正在静默恢复...", bootTime);
        ARSyncPreferencesToTmp();
        BOOL spawned = ARSpawnDaemonAsRoot();
        if (spawned) {
            // 写本开机周期标记文件
            NSString *marker = [NSString stringWithFormat:@"%lld\n", bootTime];
            [marker writeToFile:kARBootAlivePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
            chmod(kARBootAlivePath.UTF8String, 0666);

            if (outMessage) {
                *outMessage = @"检测到重启后守护进程未启动，已在后台静默恢复通话录音";
            }
            return YES;
        } else {
            if (outMessage) {
                *outMessage = @"后台拉起守护进程失败，请手动打开一次通话录音";
            }
            return NO;
        }
    }
}

// ============================================================================
// 模块 2：SiriKit In-App Intent 后台处理器（零闪屏）+ 静默 URL 保底
// ============================================================================

@interface AREnsureDaemonIntentHandler : NSObject <EnsureDaemonIntentHandling>
@end

@implementation AREnsureDaemonIntentHandler

- (void)handleEnsureDaemon:(EnsureDaemonIntent *)intent
                completion:(void (^)(EnsureDaemonIntentResponse *response))completion {
    ARLog(@"收到 SiriKit 后台 Intent 调用：EnsureDaemonIntent");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *statusMsg = nil;
        BOOL ok = AREnsureDaemonRunning(&statusMsg);
        EnsureDaemonIntentResponseCode code = ok ? EnsureDaemonIntentResponseCodeSuccess : EnsureDaemonIntentResponseCodeFailure;
        EnsureDaemonIntentResponse *resp = [[EnsureDaemonIntentResponse alloc] initWithCode:code userActivity:nil];
        resp.statusMessage = statusMsg ?: (ok ? @"已生效" : @"拉起失败");
        if (completion) {
            completion(resp);
        }
    });
}

@end

// 主 App 启动后主动向系统 siriactionsd 捐赠快捷指令动作，确保在“快捷指令”App 中立即可搜到
static void ARDonateEnsureDaemonShortcut(void) {
    @autoreleasepool {
        @try {
            EnsureDaemonIntent *intent = [[EnsureDaemonIntent alloc] init];
            intent.suggestedInvocationPhrase = @"检查并恢复通话录音";
            INInteraction *interaction = [[INInteraction alloc] initWithIntent:intent response:nil];
            [interaction donateInteractionWithCompletion:^(NSError * _Nullable error) {
                if (error) {
                    ARLog(@"捐赠 EnsureDaemonIntent 失败：%@", error);
                } else {
                    ARLog(@"已向系统成功捐赠 EnsureDaemonIntent");
                }
            }];
            INShortcut *shortcut = [[INShortcut alloc] initWithIntent:intent];
            if (shortcut) {
                [[INVoiceShortcutCenter sharedCenter] setShortcutSuggestions:@[shortcut]];
                ARLog(@"已向 INVoiceShortcutCenter 注册 EnsureDaemonIntent 建议动作");
            }
        } @catch (NSException *ex) {
            ARLog(@"捐赠快捷指令异常：%@", ex);
        }
    }
}

// 动态挂到 AudioRecorderApplication 的 handlerForIntent:
static id AR_application_handlerForIntent(id self, SEL _cmd, UIApplication *application, INIntent *intent) {
    if ([intent isKindOfClass:[EnsureDaemonIntent class]]) {
        static AREnsureDaemonIntentHandler *handler = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            handler = [[AREnsureDaemonIntentHandler alloc] init];
        });
        return handler;
    }
    return nil;
}

static BOOL (*orig_openURL_legacy)(id, SEL, UIApplication *, NSURL *, NSString *, id) = NULL;
static void (*orig_app_recStart)(id, SEL) = NULL;

static void hook_app_recStart(id self, SEL _cmd) {
    // 后台快捷指令冷启动主 App 时，若守护进程已在运行，严禁执行原版 recStart 里的 endrecording/die 误杀正在进行的通话录音
    UIApplicationState state = [UIApplication sharedApplication].applicationState;
    pid_t existingPid = ARFindRunningDaemonPID();
    if (state == UIApplicationStateBackground && existingPid > 0) {
        ARLog(@"后台唤醒保护：守护进程已存活 (pid=%d)，拦截原版 recStart 避免中断录音", existingPid);
        return;
    }
    ARSyncPreferencesToTmp();
    if (orig_app_recStart) {
        orig_app_recStart(self, _cmd);
    }
}

static void ARHandleAutoStartURL(UIApplication *app) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *msg = nil;
        AREnsureDaemonRunning(&msg);
        ARLog(@"URL 静默唤醒完成：%@", msg);
        // 若被拉到了前台，极速退回后台减少打扰
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.18 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIApplication *shared = app ?: [UIApplication sharedApplication];
            if (shared.applicationState == UIApplicationStateActive) {
                SEL suspendSel = NSSelectorFromString(@"suspend");
                if ([shared respondsToSelector:suspendSel]) {
                    ((void (*)(id, SEL))objc_msgSend)(shared, suspendSel);
                }
            }
        });
    });
}

static BOOL hook_openURL_legacy(id self, SEL _cmd, UIApplication *app, NSURL *url, NSString *sourceApp, id annotation) {
    if (url && [[url.absoluteString lowercaseString] hasPrefix:@"audiorecorder://autostart"]) {
        ARLog(@"收到 URL 静默唤醒：%@", url.absoluteString);
        ARHandleAutoStartURL(app);
        return YES;
    }
    if (orig_openURL_legacy) {
        return orig_openURL_legacy(self, _cmd, app, url, sourceApp, annotation);
    }
    return NO;
}

static BOOL hook_openURL_options(id self, SEL _cmd, UIApplication *app, NSURL *url, NSDictionary *options) {
    if (url && [[url.absoluteString lowercaseString] hasPrefix:@"audiorecorder://autostart"]) {
        ARLog(@"收到 URL(options) 静默唤醒：%@", url.absoluteString);
        ARHandleAutoStartURL(app);
        return YES;
    }
    if (orig_openURL_legacy) {
        return orig_openURL_legacy(self, @selector(application:openURL:sourceApplication:annotation:), app, url, options[UIApplicationOpenURLOptionsSourceApplicationKey], options[UIApplicationOpenURLOptionsAnnotationKey]);
    }
    return NO;
}

// ============================================================================
// 模块 3：设置页原生融合 QQ（样式、图标、自动/手动开关 100% 与微信一致）
// ============================================================================

static id (*orig_prefs_specifiers)(id, SEL) = NULL;
static void (*orig_prefs_setPrefVal)(id, SEL, id, id) = NULL;
static void (*orig_appOpt_setAutoRecord)(id, SEL, id, id) = NULL;

static id hook_prefs_specifiers(id self, SEL _cmd) {
    id res = orig_prefs_specifiers ? orig_prefs_specifiers(self, _cmd) : nil;
    if (![res isKindOfClass:[NSArray class]]) return res;

    NSMutableArray *list = [res isKindOfClass:[NSMutableArray class]] ? (NSMutableArray *)res : [res mutableCopy];

    // 检查是否已存在 com.tencent.mqq
    BOOL hasQQ = NO;
    NSInteger insertIdx = -1;
    for (NSInteger i = 0; i < (NSInteger)list.count; i++) {
        id spec = list[i];
        SEL propSel = @selector(propertyForKey:);
        if (![spec respondsToSelector:propSel]) continue;
        NSString *appID = ((id (*)(id, SEL, id))objc_msgSend)(spec, propSel, @"appID");
        NSString *key   = ((id (*)(id, SEL, id))objc_msgSend)(spec, propSel, @"key");
        NSString *sid   = ((id (*)(id, SEL, id))objc_msgSend)(spec, propSel, @"id");
        if ([appID isEqualToString:kQQBundleID] || [key isEqualToString:kQQBundleID]) {
            hasQQ = YES;
            break;
        }
        // 紧跟在“系统音频 (SYSTEM_AUDIO)”或“微信 (com.tencent.xin)”后面插入，视觉最自然
        if ([appID isEqualToString:@"com.tencent.xin"] || [key isEqualToString:@"com.tencent.xin"]) {
            insertIdx = i + 1;
        } else if (insertIdx < 0 && ([sid isEqualToString:@"SYSTEM_AUDIO"] || [key isEqualToString:@"SystemAudio"])) {
            insertIdx = i + 1;
        }
    }

    if (!hasQQ) {
        Class psSpecCls = NSClassFromString(@"PSSpecifier");
        Class appOptCls = NSClassFromString(@"AudioRecorderAppOptionsController");
        if (psSpecCls && appOptCls) {
            // PSSpecifier preferenceSpecifierNamed:target:set:get:detail:cell:edit: (PSLinkListCell = 2)
            SEL createSel = NSSelectorFromString(@"preferenceSpecifierNamed:target:set:get:detail:cell:edit:");
            if ([psSpecCls respondsToSelector:createSel]) {
                id qqSpec = ((id (*)(id, SEL, NSString *, id, SEL, SEL, Class, NSInteger, Class))objc_msgSend)(
                    psSpecCls,
                    createSel,
                    kQQDisplayName,
                    self,
                    NSSelectorFromString(@"setPreferenceValue:specifier:"),
                    NSSelectorFromString(@"readPreferenceValue:"),
                    appOptCls,
                    2, // PSLinkListCell
                    Nil
                );
                if (qqSpec) {
                    SEL setPropSel = @selector(setProperty:forKey:);
                    void (*setProp)(id, SEL, id, id) = (void (*)(id, SEL, id, id))objc_msgSend;
                    setProp(qqSpec, setPropSel, kQQBundleID, @"id");
                    setProp(qqSpec, setPropSel, kQQBundleID, @"key");
                    setProp(qqSpec, setPropSel, kQQBundleID, @"appID");
                    setProp(qqSpec, setPropSel, kQQBundleID, @"appIDForLazyIcon");
                    setProp(qqSpec, setPropSel, @YES, @"useLazyIcons");
                    setProp(qqSpec, setPropSel, kARSuiteName, @"defaults");
                    setProp(qqSpec, setPropSel, @(1), @"default"); // 默认 Automatically，与微信体验一致
                    setProp(qqSpec, setPropSel, @"itemsTitles:", @"titlesDataSource");
                    setProp(qqSpec, setPropSel, @"itemsValues:", @"valuesDataSource");
                    setProp(qqSpec, setPropSel, @"itemsShortTitles:", @"shortTitlesDataSource");

                    if (insertIdx >= 0 && insertIdx <= (NSInteger)list.count) {
                        [list insertObject:qqSpec atIndex:(NSUInteger)insertIdx];
                    } else {
                        [list addObject:qqSpec];
                    }

                    // 如果 PreferencesController 缓存了 _specifiers ivar，同步更新
                    Ivar iv = class_getInstanceVariable([self class], "_specifiers");
                    if (iv) {
                        object_setIvar(self, iv, list);
                    }
                    ARLog(@"已在录音设置列表中原生注入 QQ 条目（索引=%ld）", (long)insertIdx);
                }
            }
        }
    }
    return list;
}

static void hook_prefs_setPrefVal(id self, SEL _cmd, id value, id specifier) {
    if (orig_prefs_setPrefVal) {
        orig_prefs_setPrefVal(self, _cmd, value, specifier);
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        ARSyncPreferencesToTmp();
    });
}

static void hook_appOpt_setAutoRecord(id self, SEL _cmd, id value, id specifier) {
    if (orig_appOpt_setAutoRecord) {
        orig_appOpt_setAutoRecord(self, _cmd, value, specifier);
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        ARSyncPreferencesToTmp();
    });
}

// ============================================================================
// 模块 3.5：首页录音列表补齐 QQ 应用小图标（AudioRecorderTableController）
// ============================================================================

static void (*orig_table_generateAppIcons)(id, SEL) = NULL;

static void hook_table_generateAppIcons(id self, SEL _cmd) {
    if (orig_table_generateAppIcons) {
        orig_table_generateAppIcons(self, _cmd);
    }
    @try {
        Ivar dictIv = class_getInstanceVariable([self class], "imageDict");
        if (!dictIv) return;
        id imgDictObj = object_getIvar(self, dictIv);
        if (![imgDictObj isKindOfClass:[NSMutableDictionary class]]) return;
        NSMutableDictionary *imgDict = (NSMutableDictionary *)imgDictObj;

        int iconFmt = 0;
        Ivar fmtIv = class_getInstanceVariable([self class], "appIconFormat");
        if (fmtIv) {
            ptrdiff_t offset = ivar_getOffset(fmtIv);
            iconFmt = *(int *)((uint8_t *)(__bridge void *)self + offset);
        }

        SEL iconSel = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:");
        UIImage *qqIcon = nil;
        if ([UIImage respondsToSelector:iconSel]) {
            qqIcon = ((UIImage *(*)(id, SEL, NSString *, int))objc_msgSend)([UIImage class], iconSel, kQQBundleID, iconFmt);
            if (!qqIcon && iconFmt != 0) {
                qqIcon = ((UIImage *(*)(id, SEL, NSString *, int))objc_msgSend)([UIImage class], iconSel, kQQBundleID, 0);
            }
        }
        if (qqIcon) {
            imgDict[kQQDisplayName] = qqIcon;
            imgDict[@"QQAudio"] = qqIcon;
            imgDict[@"QQVideo"] = qqIcon;
            imgDict[kQQBundleID] = qqIcon;
            ARLog(@"已向首页录音列表 imageDict 注入 QQ 小图标 (format=%d)", iconFmt);
        }
    } @catch (NSException *ex) {
        ARLog(@"注入 QQ 小图标异常：%@", ex);
    }
}

// ============================================================================
// 模块 3.8：多源 QQ 对方号码提取器 + 本地只读诊断探针 (/tmp/ar_qq_probe.log)
// ============================================================================

static BOOL ARIsLikelyTimestampOrInvalidUin(NSString *numStr, time_t nowSec) {
    if (numStr.length < 5 || numStr.length > 11) return YES;
    long long v = [numStr longLongValue];
    if (v < 10000LL) return YES;
    // 排除当前秒级/毫秒级 Unix 时间戳（误差 7 天内）
    if (numStr.length == 10 && llabs(v - (long long)nowSec) < 86400LL * 30LL) return YES;
    // 排除 YYYYMMDD / YYYYMMDDHH 日期串（如 20261127）
    if (numStr.length >= 8 && ([numStr hasPrefix:@"202"] || [numStr hasPrefix:@"201"] || [numStr hasPrefix:@"197"])) {
        if (numStr.length == 8 || numStr.length == 10) return YES;
    }
    return NO;
}

static void ARCollectQQContainers(NSString *__autoreleasing *outDataPath, NSArray<NSString *> *__autoreleasing *outGroupPaths) {
    dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_NOW);
    dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_NOW);
    Class proxyCls = NSClassFromString(@"LSApplicationProxy");
    if (!proxyCls) return;
    SEL sel = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (![proxyCls respondsToSelector:sel]) return;
    id proxy = ((id (*)(id, SEL, id))objc_msgSend)(proxyCls, sel, kQQBundleID);
    if (!proxy) return;

    SEL dataUrlSel = NSSelectorFromString(@"dataContainerURL");
    if ([proxy respondsToSelector:dataUrlSel]) {
        NSURL *u = ((NSURL *(*)(id, SEL))objc_msgSend)(proxy, dataUrlSel);
        if (u.path.length > 0 && outDataPath) *outDataPath = u.path;
    }

    SEL grpUrlSel = NSSelectorFromString(@"groupContainerURLs");
    if ([proxy respondsToSelector:grpUrlSel]) {
        NSDictionary *grps = ((NSDictionary *(*)(id, SEL))objc_msgSend)(proxy, grpUrlSel);
        if ([grps isKindOfClass:[NSDictionary class]] && outGroupPaths) {
            NSMutableArray<NSString *> *paths = [NSMutableArray array];
            for (id val in grps.allValues) {
                if ([val isKindOfClass:[NSURL class]] && [(NSURL *)val path].length > 0) {
                    [paths addObject:[(NSURL *)val path]];
                }
            }
            *outGroupPaths = paths;
        }
    }
}

// 精准判定唯一“当前正在登录的自己 QQ 号”（避免把历史曾登录过的小号误判为自己而排除）
static NSString *ARDetectCurrentSelfQQUin(NSString *qqDataPath) {
    if (qqDataPath.length == 0) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];

    auto isValidUin = ^BOOL(NSString *s) {
        return (s.length >= 5 && s.length <= 11 &&
                ![s hasPrefix:@"0"] &&
                [s rangeOfCharacterFromSet:nonDigits].location == NSNotFound);
    };

    // 1. 优先从 LYStorage 命名空间子目录与 MiniAppNotify 中找 mtime 最新的 <selfUin>（QQ 9.x 实测最准）
    NSString *bestUin = nil;
    time_t bestMtime = 0;

    NSString *miniNotifyDir = [qqDataPath stringByAppendingPathComponent:@"Library/Caches/MiniAppNotify"];
    for (NSString *name in ([fm contentsOfDirectoryAtPath:miniNotifyDir error:nil] ?: @[])) {
        if (!isValidUin(name)) continue;
        struct stat st;
        NSString *full = [miniNotifyDir stringByAppendingPathComponent:name];
        if (lstat(full.UTF8String, &st) == 0 && st.st_mtime > bestMtime) {
            bestMtime = st.st_mtime;
            bestUin = name;
        }
    }

    NSString *lyRoot = [qqDataPath stringByAppendingPathComponent:@"Library/Caches/LYStorage"];
    for (NSString *ns in ([fm contentsOfDirectoryAtPath:lyRoot error:nil] ?: @[])) {
        NSString *nsPath = [lyRoot stringByAppendingPathComponent:ns];
        for (NSString *sub in ([fm contentsOfDirectoryAtPath:nsPath error:nil] ?: @[])) {
            if (!isValidUin(sub)) continue;
            struct stat st;
            NSString *full = [nsPath stringByAppendingPathComponent:sub];
            if (lstat(full.UTF8String, &st) == 0 && S_ISDIR(st.st_mode) && st.st_mtime > bestMtime) {
                bestMtime = st.st_mtime;
                bestUin = sub;
            }
        }
    }
    if (bestUin.length > 0) return bestUin;

    // 2. 兜底读 com.tencent.mqq.plist
    NSString *plistPath = [qqDataPath stringByAppendingPathComponent:@"Library/Preferences/com.tencent.mqq.plist"];
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:plistPath];
    if ([prefs isKindOfClass:[NSDictionary class]]) {
        for (NSString *k in @[@"lastLoginUin", @"kCurrentUin", @"CurrentUin", @"selfUin", @"uin"]) {
            id v = prefs[k];
            NSString *sv = [v isKindOfClass:[NSNumber class]] ? [v stringValue] : ([v isKindOfClass:[NSString class]] ? v : nil);
            if (sv && isValidUin(sv)) return sv;
        }
    }

    // 3. 最后兜底：Documents/contents 下 mtime 最新的单个账号目录
    NSString *contentsDir = [qqDataPath stringByAppendingPathComponent:@"Documents/contents"];
    for (NSString *name in ([fm contentsOfDirectoryAtPath:contentsDir error:nil] ?: @[])) {
        if (!isValidUin(name)) continue;
        struct stat st;
        NSString *full = [contentsDir stringByAppendingPathComponent:name];
        if (lstat(full.UTF8String, &st) == 0 && st.st_mtime > bestMtime) {
            bestMtime = st.st_mtime;
            bestUin = name;
        }
    }
    return bestUin;
}

static NSString *ARExtractPeerUinFromText(NSString *text, NSSet<NSString *> *selfUins, time_t nowSec) {
    if (text.length == 0) return nil;
    static NSRegularExpression *explicitRegex = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        explicitRegex = [NSRegularExpression regularExpressionWithPattern:
            @"(?:peer[_\\s]?uin|friend[_\\s]?uin|from[_\\s]?uin|to[_\\s]?uin|remote[_\\s]?uin|target[_\\s]?uin|caller[_\\s]?uin|call[_\\s]?uin|dst[_\\s]?uin|src[_\\s]?uin|peerId|peer_id|friUin|chatUin)[\"']?\\s*[:=]\\s*[\"']?([1-9][0-9]{4,10})(?![0-9])"
            options:NSRegularExpressionCaseInsensitive
            error:nil];
    });
    if (!explicitRegex) return nil;

    NSArray<NSTextCheckingResult *> *matches = [explicitRegex matchesInString:text options:0 range:NSMakeRange(0, text.length)];
    for (NSInteger i = (NSInteger)matches.count - 1; i >= 0; i--) {
        NSTextCheckingResult *m = matches[(NSUInteger)i];
        if (m.numberOfRanges >= 2) {
            NSString *cand = [text substringWithRange:[m rangeAtIndex:1]];
            if (![selfUins containsObject:cand] && !ARIsLikelyTimestampOrInvalidUin(cand, nowSec)) {
                return cand;
            }
        }
    }
    return nil;
}

static NSString *ARExtractPeerUinFromFilename(NSString *relPath, NSSet<NSString *> *selfUins, time_t nowSec) {
    NSString *fname = [relPath lastPathComponent];
    static NSRegularExpression *fnRegex = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        fnRegex = [NSRegularExpression regularExpressionWithPattern:
            @"(?:^|[_\\-/])(?:uin|peer|fri|friend|head|avatar|c2c|av|call|chat|user)?[_\\-]?([1-9][0-9]{4,10})(?:[_\\.\\-]|$)"
            options:NSRegularExpressionCaseInsensitive
            error:nil];
    });
    if (!fnRegex) return nil;

    NSString *low = [relPath lowercaseString];
    BOOL relevant = ([low containsString:@"user_summary"] || [low containsString:@"lystorage"] ||
                     [low containsString:@"head"] || [low containsString:@"avatar"] ||
                     [low containsString:@"face"] || [low containsString:@"av"] ||
                     [low containsString:@"voip"] || [low containsString:@"call"] ||
                     [low containsString:@"c2c"]  || [low containsString:@"friend"] ||
                     [low containsString:@"uin"]  || [low containsString:@"peer"]);
    if (!relevant) return nil;

    NSArray<NSTextCheckingResult *> *matches = [fnRegex matchesInString:fname options:0 range:NSMakeRange(0, fname.length)];
    for (NSTextCheckingResult *m in matches) {
        if (m.numberOfRanges >= 2) {
            NSString *cand = [fname substringWithRange:[m rangeAtIndex:1]];
            if (![selfUins containsObject:cand] && !ARIsLikelyTimestampOrInvalidUin(cand, nowSec)) {
                return cand;
            }
        }
    }
    return nil;
}

static NSString *ARResolveQQPeerUinAndWriteProbe(void) {
    @autoreleasepool {
        time_t nowSec = time(NULL);
        NSString *qqDataPath = nil;
        NSArray<NSString *> *groupPaths = nil;
        ARCollectQQContainers(&qqDataPath, &groupPaths);

        NSString *currentSelfUin = ARDetectCurrentSelfQQUin(qqDataPath);
        NSSet<NSString *> *selfUins = currentSelfUin ? [NSSet setWithObject:currentSelfUin] : [NSSet set];

        NSFileManager *fm = [NSFileManager defaultManager];
        NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
        NSMutableArray<NSDictionary *> *lyCandidates = [NSMutableArray array];
        NSMutableArray<NSDictionary *> *recentFiles = [NSMutableArray array];

        // ====================================================================
        // 定点靶心 1（极速 <5ms，QQ 9.x 实机探针实证命中）：
        // DATA/Library/Caches/LYStorage/<namespace>/<currentSelfUin>/<peerUin>
        // 典型路径：USER_SUMMARY_PRIVAC_ENGINE_NAMESPACE/<selfUin>/<peerUin>
        // ====================================================================
        if (qqDataPath.length > 0) {
            NSString *lyRoot = [qqDataPath stringByAppendingPathComponent:@"Library/Caches/LYStorage"];
            NSArray<NSString *> *namespaces = [fm contentsOfDirectoryAtPath:lyRoot error:nil] ?: @[];
            for (NSString *ns in namespaces) {
                NSString *nsPath = [lyRoot stringByAppendingPathComponent:ns];
                NSArray<NSString *> *subEntries = [fm contentsOfDirectoryAtPath:nsPath error:nil] ?: @[];
                for (NSString *sub in subEntries) {
                    // 若已确定 currentSelfUin，只看当前登录账号名下的子目录；否则检查全部数字目录
                    if (currentSelfUin && ![sub isEqualToString:currentSelfUin]) continue;
                    NSString *selfDir = [nsPath stringByAppendingPathComponent:sub];
                    NSArray<NSString *> *peerFiles = [fm contentsOfDirectoryAtPath:selfDir error:nil] ?: @[];
                    for (NSString *pf in peerFiles) {
                        // 提取纯数字文件名（或前缀数字）作为候选对方 QQ 号
                        NSString *baseName = [pf stringByDeletingPathExtension];
                        if (baseName.length < 5 || baseName.length > 11 || [baseName hasPrefix:@"0"]) continue;
                        if ([baseName rangeOfCharacterFromSet:nonDigits].location != NSNotFound) continue;
                        if ([selfUins containsObject:baseName] || ARIsLikelyTimestampOrInvalidUin(baseName, nowSec)) continue;

                        NSString *full = [selfDir stringByAppendingPathComponent:pf];
                        struct stat st;
                        if (lstat(full.UTF8String, &st) != 0 || S_ISDIR(st.st_mode)) continue;
                        time_t age = nowSec - st.st_mtime;
                        if (age >= -5 && age <= 120) {
                            int prio = ([[ns uppercaseString] containsString:@"USER_SUMMARY"]) ? 0 : 1;
                            [lyCandidates addObject:@{
                                @"uin": baseName,
                                @"age": @(age),
                                @"prio": @(prio),
                                @"rel": [NSString stringWithFormat:@"LYStorage/%@/%@/%@", ns, sub, pf],
                                @"size": @((long long)st.st_size)
                            }];
                        }
                    }
                }
            }
            [lyCandidates sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                // 优先取 20 秒内最新修改；同区间优先 USER_SUMMARY 命名空间
                NSInteger ageA = [a[@"age"] integerValue];
                NSInteger ageB = [b[@"age"] integerValue];
                BOOL freshA = (ageA <= 20);
                BOOL freshB = (ageB <= 20);
                if (freshA != freshB) return freshA ? NSOrderedAscending : NSOrderedDescending;
                NSComparisonResult pr = [a[@"prio"] compare:b[@"prio"]];
                if (pr != NSOrderedSame) return pr;
                return [a[@"age"] compare:b[@"age"]];
            }];
        }

        NSString *resolvedUin = nil;
        NSString *resolvedSource = @"none";
        if (lyCandidates.count > 0) {
            NSDictionary *top = lyCandidates.firstObject;
            resolvedUin = top[@"uin"];
            resolvedSource = [NSString stringWithFormat:@"lystorage(%lds):%@",
                              (long)[top[@"age"] integerValue], top[@"rel"]];
        }

        // ====================================================================
        // 定点靶心 2（各目录独立配额，不再被 Library/Caches 6000 文件截断）：
        // 若靶心 1 未命中，快速扫描 QQXLog / Documents / tmp / AppGroup
        // ====================================================================
        if (!resolvedUin) {
            NSMutableArray<NSString *> *rootsToScan = [NSMutableArray array];
            if (qqDataPath.length > 0) {
                for (NSString *sub in @[@"Library/Caches/QQINI/QQXLog", @"Documents", @"tmp", @"Library/Application Support"]) {
                    NSString *full = [qqDataPath stringByAppendingPathComponent:sub];
                    if ([fm fileExistsAtPath:full]) [rootsToScan addObject:full];
                }
            }
            for (NSString *gp in groupPaths) {
                if ([fm fileExistsAtPath:gp]) [rootsToScan addObject:gp];
            }

            for (NSString *scanRoot in rootsToScan) {
                NSInteger scannedInRoot = 0;
                const NSInteger kMaxPerRoot = 1500;
                NSUInteger rootDepth = [[scanRoot pathComponents] count];
                NSDirectoryEnumerator *en = [fm enumeratorAtPath:scanRoot];
                NSString *rel = nil;
                while ((rel = [en nextObject]) != nil) {
                    if (++scannedInRoot > kMaxPerRoot) break;
                    NSString *full = [scanRoot stringByAppendingPathComponent:rel];
                    NSUInteger depth = [[full pathComponents] count] - rootDepth;
                    if (depth > 4) {
                        [en skipDescendants];
                        continue;
                    }
                    struct stat st;
                    if (lstat(full.UTF8String, &st) != 0) continue;
                    if (S_ISDIR(st.st_mode)) {
                        NSString *lowName = [rel.lastPathComponent lowercaseString];
                        if ([lowName isEqualToString:@"webview"] || [lowName isEqualToString:@"miniapp"] ||
                            [lowName isEqualToString:@"qzone"] || [lowName isEqualToString:@"shortvideo"] ||
                            [lowName isEqualToString:@"ark"] || [lowName isEqualToString:@"hippy"]) {
                            [en skipDescendants];
                        }
                        continue;
                    }
                    time_t age = nowSec - st.st_mtime;
                    if (age >= -5 && age <= 45) {
                        NSString *shortRel = qqDataPath.length > 0 && [full hasPrefix:qqDataPath]
                            ? [@"DATA" stringByAppendingString:[full substringFromIndex:qqDataPath.length]]
                            : [@"GRP/" stringByAppendingString:rel];
                        [recentFiles addObject:@{
                            @"full": full,
                            @"rel": shortRel,
                            @"age": @(age),
                            @"size": @((long long)st.st_size)
                        }];
                    }
                }
            }

            [recentFiles sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                return [a[@"age"] compare:b[@"age"]];
            }];

            NSInteger logChecked = 0;
            for (NSDictionary *item in recentFiles) {
                if (logChecked >= 12) break;
                NSString *full = item[@"full"];
                NSString *low = [full lowercaseString];
                long long fsize = [item[@"size"] longLongValue];
                if (fsize <= 0 || fsize > 64 * 1024 * 1024) continue;
                BOOL isTextLike = ([low hasSuffix:@".log"] || [low hasSuffix:@".txt"] ||
                                   [low hasSuffix:@".plist"] || [low hasSuffix:@".json"] ||
                                   [low containsString:@"av"] || [low containsString:@"qav"] ||
                                   [low containsString:@"rtc"] || [low containsString:@"voip"]);
                if (!isTextLike) continue;
                logChecked++;

                FILE *fp = fopen(full.UTF8String, "rb");
                if (!fp) continue;
                long long readLen = fsize > 32768 ? 32768 : fsize;
                if (fsize > readLen) fseeko(fp, fsize - readLen, SEEK_SET);
                char *buf = (char *)malloc((size_t)readLen + 1);
                if (buf) {
                    size_t nr = fread(buf, 1, (size_t)readLen, fp);
                    buf[nr] = '\0';
                    for (size_t k = 0; k < nr; k++) {
                        if (buf[k] == '\0') buf[k] = ' ';
                    }
                    NSString *tailText = [[NSString alloc] initWithBytes:buf length:nr encoding:NSISOLatin1StringEncoding];
                    free(buf);
                    NSString *cand = ARExtractPeerUinFromText(tailText, selfUins, nowSec);
                    if (cand) {
                        resolvedUin = cand;
                        resolvedSource = [NSString stringWithFormat:@"log:%@", item[@"rel"]];
                        fclose(fp);
                        break;
                    }
                }
                fclose(fp);
            }

            if (!resolvedUin) {
                for (NSDictionary *item in recentFiles) {
                    if ([item[@"age"] integerValue] > 30) break;
                    NSString *cand = ARExtractPeerUinFromFilename(item[@"rel"], selfUins, nowSec);
                    if (cand) {
                        resolvedUin = cand;
                        resolvedSource = [NSString stringWithFormat:@"filename:%@", item[@"rel"]];
                        break;
                    }
                }
            }
        }

        // 写入只读诊断探针 /tmp/ar_qq_probe.log
        NSMutableString *probe = [NSMutableString string];
        [probe appendFormat:@"=== QQ Peer Probe v3 @ %ld ===\n", (long)nowSec];
        [probe appendFormat:@"qqDataPath: %@\n", qqDataPath ?: @"(nil)"];
        [probe appendFormat:@"currentSelfUin: %@\n", currentSelfUin ?: @"(nil)"];
        [probe appendFormat:@"resolvedUin: %@ (source=%@)\n", resolvedUin ?: @"(not found)", resolvedSource];
        [probe appendFormat:@"lyCandidates(<=120s, count=%lu):\n", (unsigned long)lyCandidates.count];
        for (NSUInteger i = 0; i < MIN(lyCandidates.count, (NSUInteger)15); i++) {
            NSDictionary *it = lyCandidates[i];
            [probe appendFormat:@"  [%3lds ago | p=%d | %6lldB] uin=%@ (%@)\n",
             (long)[it[@"age"] integerValue], [it[@"prio"] intValue], [it[@"size"] longLongValue], it[@"uin"], it[@"rel"]];
        }
        if (recentFiles.count > 0) {
            [probe appendFormat:@"fallbackRecentFiles(count=%lu):\n", (unsigned long)recentFiles.count];
            for (NSUInteger i = 0; i < MIN(recentFiles.count, (NSUInteger)25); i++) {
                NSDictionary *it = recentFiles[i];
                [probe appendFormat:@"  [%2lds ago | %8lldB] %@\n",
                 (long)[it[@"age"] integerValue], [it[@"size"] longLongValue], it[@"rel"]];
            }
        }
        [probe writeToFile:kARQQProbeLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        chmod(kARQQProbeLogPath.UTF8String, 0666);

        ARLog(@"QQ 对方号码探测 v3 完成：self=%@ peer=%@ source=%@",
              currentSelfUin ?: @"?", resolvedUin ?: @"QQCall", resolvedSource);
        return resolvedUin;
    }
}

// ============================================================================
// 模块 4：守护进程 QQ (com.tencent.mqq) 语音/视频通话智能监听器
// ============================================================================

@interface ARQQCallMonitor : NSObject {
    dispatch_queue_t _queue;
    dispatch_source_t _timer;
    BOOL _inQQCall;
    CFAbsoluteTime _candidateStartTime;
    CFAbsoluteTime _lostSignalTime;
    CFAbsoluteTime _callStartTime;
    BOOL _stMicActiveForQQ;
    id _stMediaDomain;
    BOOL _loggedFirstProbe;
    NSString *_lastDebugSig;
}
+ (instancetype)sharedMonitor;
- (void)start;
@end

@implementation ARQQCallMonitor

+ (instancetype)sharedMonitor {
    static ARQQCallMonitor *inst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        inst = [[ARQQCallMonitor alloc] init];
    });
    return inst;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("com.arenhance.qqmonitor", DISPATCH_QUEUE_SERIAL);
        _inQQCall = NO;
        _candidateStartTime = 0;
        _lostSignalTime = 0;
        _stMicActiveForQQ = NO;
    }
    return self;
}

// 动态加载私有框架，兼容 iOS 15.6.1 与 16.6.1
- (void)loadPrivateFrameworks {
    dlopen("/System/Library/PrivateFrameworks/MediaExperience.framework/MediaExperience", RTLD_NOW);
    dlopen("/System/Library/PrivateFrameworks/Celestial.framework/Celestial", RTLD_NOW);
    dlopen("/System/Library/PrivateFrameworks/SystemStatus.framework/SystemStatus", RTLD_NOW);
    dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_NOW);
}

// 接入 iOS 14+ SystemStatus.framework 的 STMediaStatusDomain（系统状态栏橙点麦克风归属真源）
- (void)setupSystemStatusMediaObserver {
    Class domainCls = NSClassFromString(@"STMediaStatusDomain");
    if (!domainCls) {
        ARLog(@"提示：未找到 STMediaStatusDomain，将仅使用 AVSystemController 监测");
        return;
    }
    @try {
        id domain = [[domainCls alloc] init];
        if (!domain) return;
        _stMediaDomain = domain;

        __weak typeof(self) weakSelf = self;
        SEL observeSel = NSSelectorFromString(@"observeDataWithBlock:");
        if ([domain respondsToSelector:observeSel]) {
            void (^block)(id) = ^(id mediaData) {
                [weakSelf handleSystemStatusMediaData:mediaData];
            };
            ((void (*)(id, SEL, id))objc_msgSend)(domain, observeSel, block);
            ARLog(@"已成功注册 STMediaStatusDomain 麦克风归属监听");
        }
        // 读取初始状态
        SEL dataSel = NSSelectorFromString(@"data");
        if ([domain respondsToSelector:dataSel]) {
            id initData = ((id (*)(id, SEL))objc_msgSend)(domain, dataSel);
            if (initData) [self handleSystemStatusMediaData:initData];
        }
    } @catch (NSException *ex) {
        ARLog(@"注册 STMediaStatusDomain 异常（已自动降级）：%@", ex);
    }
}

- (void)handleSystemStatusMediaData:(id)mediaData {
    if (!mediaData) return;
    @try {
        BOOL qqRecording = NO;
        // 兼容 iOS 15 (audioRecordingAttributions) 与 iOS 16 (audioRecordingAttributions / attributions)
        NSArray *keys = @[@"audioRecordingAttributions", @"mutedAudioRecordingAttributions", @"attributions"];
        for (NSString *k in keys) {
            SEL s = NSSelectorFromString(k);
            if ([mediaData respondsToSelector:s]) {
                id arr = ((id (*)(id, SEL))objc_msgSend)(mediaData, s);
                if ([arr isKindOfClass:[NSArray class]] || [arr isKindOfClass:[NSSet class]]) {
                    for (id item in arr) {
                        NSString *desc = [item description];
                        if (desc && [desc containsString:kQQBundleID]) {
                            qqRecording = YES;
                            break;
                        }
                        // 进一步检查 activityAttribution.executableDisplayName / bundleIdentifier
                        SEL actSel = NSSelectorFromString(@"activityAttribution");
                        if ([item respondsToSelector:actSel]) {
                            id act = ((id (*)(id, SEL))objc_msgSend)(item, actSel);
                            if (act && [[act description] containsString:kQQBundleID]) {
                                qqRecording = YES;
                                break;
                            }
                        }
                    }
                }
            }
            if (qqRecording) break;
        }
        dispatch_async(_queue, ^{
            if (self->_stMicActiveForQQ != qqRecording) {
                ARLog(@"STMediaStatusDomain 变更：QQ 占麦=%d", qqRecording);
                self->_stMicActiveForQQ = qqRecording;
                [self pollTick];
            }
        });
    } @catch (NSException *ex) {
        // 忽略单个字段不兼容
    }
}

// 精确查找官方 QQ 主进程 PID（排除 .appex 扩展）
- (pid_t)findQQMainPID {
    int byteCount = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (byteCount <= 0) return -1;
    int cap = (byteCount / (int)sizeof(pid_t)) + 64;
    pid_t *pids = (pid_t *)calloc((size_t)cap, sizeof(pid_t));
    if (!pids) return -1;

    int actualBytes = proc_listpids(PROC_ALL_PIDS, 0, pids, cap * (int)sizeof(pid_t));
    int count = actualBytes / (int)sizeof(pid_t);
    pid_t found = -1;
    char pathBuf[PROC_PIDPATHINFO_MAXSIZE];
    for (int i = 0; i < count; i++) {
        pid_t pid = pids[i];
        if (pid <= 1) continue;
        memset(pathBuf, 0, sizeof(pathBuf));
        if (proc_pidpath(pid, pathBuf, sizeof(pathBuf)) > 0) {
            if (strstr(pathBuf, "/QQ.app/QQ") != NULL && strstr(pathBuf, ".appex") == NULL) {
                found = pid;
                break;
            }
        }
    }
    free(pids);
    return found;
}

// 安全读取 AVSystemController 属性（先查官方符号名，再查字面量）
- (id)avControllerAttribute:(id)avc symbolName:(const char *)symName fallbackKey:(NSString *)fallback {
    if (!avc) return nil;
    SEL attrSel = NSSelectorFromString(@"attributeForKey:");
    if (![avc respondsToSelector:attrSel]) return nil;

    NSString *key = nil;
    if (symName) {
        NSString *__unsafe_unretained *symPtr = (NSString *__unsafe_unretained *)dlsym(RTLD_DEFAULT, symName);
        if (symPtr && *symPtr) {
            key = *symPtr;
        }
    }
    if (!key) key = fallback;
    if (!key) return nil;

    @try {
        return ((id (*)(id, SEL, id))objc_msgSend)(avc, attrSel, key);
    } @catch (NSException *ex) {
        return nil;
    }
}

// 检查当前是否已有其他 CallKit/系统电话正在进行（避免抢占系统电话或微信通话）
- (BOOL)isOtherCallActive {
    void **slot = ARGetGlobalCallStatusDictSlot();
    if (!slot || !(*slot)) return NO;
    id obj = (__bridge id)(*slot);
    if (![obj isKindOfClass:[NSDictionary class]]) return NO;
    NSDictionary *dict = (NSDictionary *)obj;
    int status = [dict[@"CallStatus"] intValue];
    NSString *appId = dict[@"appIdentifier"];
    NSString *appName = dict[@"Application"];
    if (status == 1) {
        if ([appId isEqualToString:kQQBundleID] || [appName isEqualToString:kQQDisplayName]) {
            return NO;
        }
        return YES;
    }
    return NO;
}

// 向原版 AudioRecorder 引擎发送与微信完全一致的通话开始/结束事件
- (void)postQQCallStatus:(int)callStatus {
    void **dictSlot = ARGetGlobalCallStatusDictSlot();
    if (!dictSlot) {
        ARLog(@"错误：无法获取全局状态字典槽位，无法触发 QQ 录音");
        return;
    }

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();

    if (callStatus == 1) {
        // 确保 /tmp/.audioRecDefaults 已存在且包含 QQ 配置
        if (![[NSFileManager defaultManager] fileExistsAtPath:kARDefaultsTmpPath]) {
            ARSyncPreferencesToTmp();
        }
        double *startSlot = ARGetGlobalTimeSlot(kARAddrCallStartTime);
        if (startSlot) *startSlot = now;

        NSMutableDictionary *info = [NSMutableDictionary dictionary];
        NSString *peerUin = ARResolveQQPeerUinAndWriteProbe();
        NSString *displayPeer = (peerUin.length >= 5) ? peerUin : @"QQCall";
        info[@"CallStatus"] = @(1);
        info[@"Application"] = kQQDisplayName;
        info[@"appIdentifier"] = kQQBundleID;
        info[@"EndpointOnCurrentDevice"] = @YES;
        info[@"Number"] = displayPeer;
        info[@"Name"] = displayPeer;
        info[@"isOutgoing"] = @(NO);
        info[@"StartTime"] = @((int)now);

        // 原版 AudioRecorder 为 MRC，采用手动 Retain 写入全局槽位，避免 ARC 误释放原版对象导致野指针
        *dictSlot = (void *)CFBridgingRetain(info);
        _callStartTime = now;
        ARLog(@">>> 触发 QQ 通话录音开始 (CallStatus=1) info=%@", info);
        notify_post(kARNotifyStatus);
    } else {
        double *endSlot = ARGetGlobalTimeSlot(kARAddrCallEndTime);
        if (endSlot) *endSlot = now;

        id existing = (*dictSlot) ? (__bridge id)(*dictSlot) : nil;
        NSMutableDictionary *info = [existing isKindOfClass:[NSMutableDictionary class]] ? (NSMutableDictionary *)existing : nil;
        if (!info) {
            info = [NSMutableDictionary dictionary];
            info[@"Application"] = kQQDisplayName;
            info[@"appIdentifier"] = kQQBundleID;
            info[@"EndpointOnCurrentDevice"] = @YES;
            info[@"Number"] = @"QQCall";
            info[@"Name"] = kQQDisplayName;
            info[@"StartTime"] = @((int)_callStartTime);
            *dictSlot = (void *)CFBridgingRetain(info);
        }
        info[@"CallStatus"] = @(6); // 原版挂断/结束转码状态码
        info[@"EndTime"] = @((int)now);

        ARLog(@"<<< 触发 QQ 通话录音结束 (CallStatus=6, 时长=%.1fs)", now - _callStartTime);
        notify_post(kARNotifyStatus);
    }
}

- (void)pollTick {
    @autoreleasepool {
        pid_t qqPid = [self findQQMainPID];
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();

        if (qqPid <= 0) {
            if (_inQQCall) {
                _inQQCall = NO;
                _candidateStartTime = 0;
                _lostSignalTime = 0;
                [self postQQCallStatus:6];
            } else {
                _candidateStartTime = 0;
            }
            return;
        }

        // 获取 AVSystemController 实时音频会话特征
        Class avcCls = NSClassFromString(@"AVSystemController");
        id avc = nil;
        if (avcCls) {
            SEL sharedSel = NSSelectorFromString(@"sharedAVSystemController");
            if ([avcCls respondsToSelector:sharedSel]) {
                avc = ((id (*)(id, SEL))objc_msgSend)(avcCls, sharedSel);
            }
        }

        id recPidsObj = [self avControllerAttribute:avc
                                         symbolName:"AVSystemController_RecordingClientPIDsAttribute"
                                        fallbackKey:@"RecordingClientPIDs"];
        id activeCatObj = [self avControllerAttribute:avc
                                           symbolName:"AVSystemController_CurrentlyActiveCategoryAttribute"
                                          fallbackKey:@"CurrentlyActiveCategory"];
        id activeModeObj = [self avControllerAttribute:avc
                                            symbolName:"AVSystemController_CurrentlyActiveModeAttribute"
                                           fallbackKey:@"CurrentlyActiveMode"];
        id activeRouteObj = [self avControllerAttribute:avc
                                             symbolName:"AVSystemController_ActiveAudioRouteAttribute"
                                            fallbackKey:@"ActiveAudioRoute"];

        BOOL qqInRecPids = NO;
        if ([recPidsObj isKindOfClass:[NSArray class]]) {
            for (id item in (NSArray *)recPidsObj) {
                if ([item respondsToSelector:@selector(intValue)] && [item intValue] == qqPid) {
                    qqInRecPids = YES;
                    break;
                }
            }
        }

        NSString *catStr = [activeCatObj isKindOfClass:[NSString class]] ? (NSString *)activeCatObj : @"";
        NSString *modeStr = [activeModeObj isKindOfClass:[NSString class]] ? (NSString *)activeModeObj : @"";
        NSString *routeStr = [activeRouteObj isKindOfClass:[NSString class]] ? (NSString *)activeRouteObj : @"";

        BOOL isQQUsingMic = qqInRecPids || _stMicActiveForQQ;
        BOOL isVoiceOrVideoMode = ([modeStr rangeOfString:@"VoiceChat" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                                   [modeStr rangeOfString:@"VideoChat" options:NSCaseInsensitiveSearch].location != NSNotFound);
        BOOL isPlayAndRecord = ([catStr rangeOfString:@"PlayAndRecord" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                                [catStr rangeOfString:@"Audio/Video" options:NSCaseInsensitiveSearch].location != NSNotFound);

        // 仅在状态变化时记录日志，避免刷屏
        NSString *sig = [NSString stringWithFormat:@"pid=%d recPid=%d stMic=%d cat=%@ mode=%@ route=%@",
                         qqPid, qqInRecPids, _stMicActiveForQQ, catStr, modeStr, routeStr];
        if (!_loggedFirstProbe || ![sig isEqualToString:_lastDebugSig]) {
            _loggedFirstProbe = YES;
            _lastDebugSig = sig;
            if (isQQUsingMic || _inQQCall || isVoiceOrVideoMode) {
                ARLog(@"QQ 音频探针：%@", sig);
            }
        }

        // 判定是否满足 QQ 语音/视频通话信号
        // 强信号：QQ 占麦 + VoiceChat / VideoChat（0.5 秒防抖即刻开录）
        // 兜底信号：QQ 占麦 + PlayAndRecord（2.5 秒防抖，过滤普通按住发语音条）
        BOOL strongCallSignal = (isQQUsingMic && isVoiceOrVideoMode);
        BOOL fallbackCallSignal = (isQQUsingMic && isPlayAndRecord);

        if (!_inQQCall) {
            if ([self isOtherCallActive]) {
                _candidateStartTime = 0;
                return;
            }
            if (strongCallSignal || fallbackCallSignal) {
                if (_candidateStartTime <= 0) {
                    _candidateStartTime = now;
                }
                double threshold = strongCallSignal ? 0.5 : 2.5;
                if ((now - _candidateStartTime) >= threshold) {
                    _inQQCall = YES;
                    _lostSignalTime = 0;
                    [self postQQCallStatus:1];
                }
            } else {
                _candidateStartTime = 0;
            }
        } else {
            // 正在 QQ 通话录音中：持续满足占麦或通话模式即保持
            BOOL stillInCall = isQQUsingMic || (isVoiceOrVideoMode && isPlayAndRecord);
            if (stillInCall) {
                _lostSignalTime = 0;
            } else {
                if (_lostSignalTime <= 0) {
                    _lostSignalTime = now;
                } else if ((now - _lostSignalTime) >= 1.5) {
                    _inQQCall = NO;
                    _candidateStartTime = 0;
                    _lostSignalTime = 0;
                    [self postQQCallStatus:6];
                }
            }
        }
    }
}

- (void)start {
    ARLog(@"ARQQCallMonitor 启动（daemon 进程）");
    [self loadPrivateFrameworks];
    [self setupSystemStatusMediaObserver];

    // 每 0.5 秒轮询一次轻量探针（QQ 未运行时 proc_listpids 开销极低）
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    dispatch_source_set_timer(_timer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                              (uint64_t)(0.5 * NSEC_PER_SEC),
                              (uint64_t)(0.1 * NSEC_PER_SEC));
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_timer, ^{
        [weakSelf pollTick];
    });
    dispatch_resume(_timer);
}

@end

// ============================================================================
// 动态库入口：按进程角色（主 App UI vs 后台 daemon）分别安装 Hook
// ============================================================================

static void ARSwizzleMethod(Class cls, SEL sel, IMP newImp, IMP *origOut, const char *typesIfAdd) {
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (m) {
        if (origOut) *origOut = method_getImplementation(m);
        method_setImplementation(m, newImp);
    } else if (typesIfAdd) {
        class_addMethod(cls, sel, newImp, typesIfAdd);
    }
}

static BOOL ARIsDaemonProcess(void) {
    NSArray<NSString *> *args = [[NSProcessInfo processInfo] arguments];
    for (NSUInteger i = 1; i < args.count; i++) {
        if ([args[i] isEqualToString:@"daemon"]) {
            return YES;
        }
    }
    return NO;
}

static BOOL ARIsChildRecorderHelperProcess(void) {
    NSArray<NSString *> *args = [[NSProcessInfo processInfo] arguments];
    if (args.count >= 2) {
        NSString *arg1 = args[1];
        // 原版双轨抓取音频子进程参数（如 5246 / 5248 / playBeep / playWarning），不要注入任何监控逻辑
        if ([arg1 isEqualToString:@"5246"] ||
            [arg1 isEqualToString:@"5248"] ||
            [arg1 isEqualToString:@"playBeep"] ||
            [arg1 isEqualToString:@"playWarning"]) {
            return YES;
        }
    }
    return NO;
}

__attribute__((constructor))
static void AREnhanceInit(void) {
    @autoreleasepool {
        if (ARIsChildRecorderHelperProcess()) {
            // 音频抓取短生命周期子进程：保持零干扰
            return;
        }

        if (ARIsDaemonProcess()) {
            ARLog(@"AREnhance.dylib 已加载至 daemon 守护进程");
            // 确保守护进程启动时 /tmp/.audioRecDefaults 含 QQ 默认设置
            if (![[NSFileManager defaultManager] fileExistsAtPath:kARDefaultsTmpPath]) {
                ARSyncPreferencesToTmp();
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [[ARQQCallMonitor sharedMonitor] start];
            });
            return;
        }

        // 主 App 进程：安装 SiriKit Intent、静默 URL 路由与 QQ 设置页注入
        ARLog(@"AREnhance.dylib 已加载至主 App 进程");

        Class appCls = NSClassFromString(@"AudioRecorderApplication");
        if (appCls) {
            // 1. 挂载 SiriKit In-App Intent 后台处理入口
            SEL intentSel = @selector(application:handlerForIntent:);
            ARSwizzleMethod(appCls, intentSel, (IMP)AR_application_handlerForIntent, NULL, "@@:@@");

            // 2. 挂载静默 URL Scheme 保底入口 (audiorecorder://autostart)
            SEL legacyUrlSel = @selector(application:openURL:sourceApplication:annotation:);
            ARSwizzleMethod(appCls, legacyUrlSel, (IMP)hook_openURL_legacy, (IMP *)&orig_openURL_legacy, "B@:@@@@");

            SEL modernUrlSel = @selector(application:openURL:options:);
            if (!class_getInstanceMethod(appCls, modernUrlSel)) {
                class_addMethod(appCls, modernUrlSel, (IMP)hook_openURL_options, "B@:@@@");
            }

            // 3. 拦截后台冷启时的 recStart，防止误杀正在通话录音中的守护进程
            ARSwizzleMethod(appCls, NSSelectorFromString(@"recStart"),
                            (IMP)hook_app_recStart, (IMP *)&orig_app_recStart, "v@:");
        }

        // 3. 挂载设置页 QQ 列表项注入与偏好即时同步
        Class prefsCls = NSClassFromString(@"AudioRecorderPreferencesListController");
        if (prefsCls) {
            ARSwizzleMethod(prefsCls, @selector(specifiers), (IMP)hook_prefs_specifiers, (IMP *)&orig_prefs_specifiers, "@@:");
            ARSwizzleMethod(prefsCls, NSSelectorFromString(@"setPreferenceValue:specifier:"),
                            (IMP)hook_prefs_setPrefVal, (IMP *)&orig_prefs_setPrefVal, "v@:@@");
        }

        Class appOptCls = NSClassFromString(@"AudioRecorderAppOptionsController");
        if (appOptCls) {
            ARSwizzleMethod(appOptCls, NSSelectorFromString(@"setAutoRecordAllCalls:specifier:"),
                            (IMP)hook_appOpt_setAutoRecord, (IMP *)&orig_appOpt_setAutoRecord, "v@:@@");
        }

        // 4. 挂载首页录音列表图标补丁，点亮 QQ 小图标
        Class tableCls = NSClassFromString(@"AudioRecorderTableController");
        if (tableCls) {
            ARSwizzleMethod(tableCls, NSSelectorFromString(@"generateAppIcons"),
                            (IMP)hook_table_generateAppIcons, (IMP *)&orig_table_generateAppIcons, "v@:");
        }

        // 5. 延迟主动向系统捐赠后台快捷指令动作，让“快捷指令”App 立即可检索到
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            ARDonateEnsureDaemonShortcut();
        });
    }
}
