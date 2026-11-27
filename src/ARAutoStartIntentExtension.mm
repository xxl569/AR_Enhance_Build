//
// ARAutoStartIntentExtension.mm
// AudioRecorder TS 6.0.3 独立 SiriKit Intents Extension (PlugIns/ARAutoStartIntents.appex)
// 在后台零闪屏检测并拉起 root 守护进程 (AudioRecorder daemon)，完全不唤醒主 App 界面
//

#import <Foundation/Foundation.h>
#import <Intents/Intents.h>
#import <mach-o/dyld.h>
#import <sys/sysctl.h>
#import <sys/stat.h>
#import <spawn.h>
#import <unistd.h>
#import <signal.h>
#import <errno.h>
#import <stdlib.h>
#import <notify.h>
#import <string.h>

#import "EnsureDaemonIntent.h"

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

static NSString *const kARExtSuiteName       = @"net.limneos.audiorecorder";
static NSString *const kARExtDefaultsTmpPath = @"/tmp/.audioRecDefaults";
static NSString *const kARExtBootAlivePath   = @"/tmp/.ar_enhance_boot_alive";
static NSString *const kARExtDaemonPidPath   = @"/tmp/.ar_daemon_pid";
static NSString *const kARExtMainExecPath    = @"/tmp/.ar_main_exec_path";
static NSString *const kARExtLogPath         = @"/tmp/ar_enhance.log";
static NSString *const kARExtQQBundleID      = @"com.tencent.mqq";
static const char *const kARExtNotifyPrefs   = "net.limneos.audiorecorder.prefsChangedInternal";

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

static BOOL ARExtProcessHasDaemonArg(pid_t pid) {
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
        while (p < end && *p != '\0') p++;
        while (p < end && *p == '\0') p++;
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

// 三级守护进程存活检测：绕开 uid=501 调用 KERN_PROCARGS2 查询 uid=0 进程被 EPERM 拒绝的问题
static pid_t ARExtFindRunningDaemonPID(NSString *__autoreleasing *outSource) {
    pid_t selfPid = getpid();
    int64_t bootTime = ARExtGetSystemBootTimeSeconds();

    // 一级：读取 /tmp/.ar_daemon_pid + kill(0) + KERN_PROC_PID 校验 p_comm
    NSString *pidInfo = [NSString stringWithContentsOfFile:kARExtDaemonPidPath
                                                  encoding:NSUTF8StringEncoding
                                                     error:nil];
    if (pidInfo.length > 0) {
        NSArray<NSString *> *parts = [[pidInfo stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
                                      componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (parts.count >= 2) {
            pid_t recPid = (pid_t)[parts[0] intValue];
            int64_t recBoot = [parts[1] longLongValue];
            if (recPid > 1 && recPid != selfPid && recBoot == bootTime) {
                errno = 0;
                if (kill(recPid, 0) == 0 || errno == EPERM) {
                    struct kinfo_proc kp;
                    memset(&kp, 0, sizeof(kp));
                    size_t klen = sizeof(kp);
                    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, recPid};
                    if (sysctl(mib, 4, &kp, &klen, NULL, 0) == 0 && klen >= sizeof(kp)) {
                        if (strncmp(kp.kp_proc.p_comm, "AudioRecorder", 13) == 0) {
                            if (outSource) *outSource = @"pidfile";
                            return recPid;
                        }
                    }
                }
            }
        }
    }

    // 二级：KERN_PROC_ALL 全局扫描 p_comm == "AudioRecorder" 且 e_ucred.cr_uid == 0
    int mibAll[3] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL};
    size_t ksize = 0;
    if (sysctl(mibAll, 3, NULL, &ksize, NULL, 0) == 0 && ksize > 0) {
        size_t allocSize = ksize + sizeof(struct kinfo_proc) * 16;
        struct kinfo_proc *klist = (struct kinfo_proc *)malloc(allocSize);
        if (klist) {
            size_t actualSize = allocSize;
            if (sysctl(mibAll, 3, klist, &actualSize, NULL, 0) == 0 && actualSize >= sizeof(struct kinfo_proc)) {
                size_t n = actualSize / sizeof(struct kinfo_proc);
                for (size_t i = 0; i < n; i++) {
                    pid_t pid = klist[i].kp_proc.p_pid;
                    if (pid <= 1 || pid == selfPid) continue;
                    if (strncmp(klist[i].kp_proc.p_comm, "AudioRecorder", 13) == 0 &&
                        klist[i].kp_eproc.e_ucred.cr_uid == 0) {
                        free(klist);
                        if (outSource) *outSource = @"kinfo_root";
                        return pid;
                    }
                }
            }
            free(klist);
        }
    }

    // 三级：原有 proc_listpids + proc_pidpath + KERN_PROCARGS2 兜底
    int byteCount = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (byteCount <= 0) return -1;
    int cap = (byteCount / (int)sizeof(pid_t)) + 64;
    pid_t *pids = (pid_t *)calloc((size_t)cap, sizeof(pid_t));
    if (!pids) return -1;

    int actualBytes = proc_listpids(PROC_ALL_PIDS, 0, pids, cap * (int)sizeof(pid_t));
    int count = actualBytes / (int)sizeof(pid_t);
    pid_t result = -1;

    char pathBuf[PROC_PIDPATHINFO_MAXSIZE];
    for (int i = 0; i < count; i++) {
        pid_t pid = pids[i];
        if (pid <= 1 || pid == selfPid) continue;
        memset(pathBuf, 0, sizeof(pathBuf));
        if (proc_pidpath(pid, pathBuf, sizeof(pathBuf)) > 0) {
            if (strstr(pathBuf, "/AudioRecorder.app/AudioRecorder") != NULL) {
                if (ARExtProcessHasDaemonArg(pid)) {
                    result = pid;
                    if (outSource) *outSource = @"procargs";
                    break;
                }
            }
        }
    }
    free(pids);
    return result;
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

@interface ARAutoStartIntentExtensionHandler : INExtension <EnsureDaemonIntentHandling>
@end

static NSString *ARExtMainExecutablePath(void) {
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];

    // 候选 1：_NSGetExecutablePath + realpath，往上 3 级得到 AudioRecorder.app/AudioRecorder
    uint32_t bufSize = 4096;
    char rawExec[4096];
    memset(rawExec, 0, sizeof(rawExec));
    if (_NSGetExecutablePath(rawExec, &bufSize) == 0) {
        char resolvedExec[4096];
        const char *usedPath = realpath(rawExec, resolvedExec) ? resolvedExec : rawExec;
        NSString *nsExec = [NSString stringWithUTF8String:usedPath];
        if (nsExec.length > 0) {
            NSString *appDir = [[[nsExec stringByDeletingLastPathComponent]
                                 stringByDeletingLastPathComponent]
                                stringByDeletingLastPathComponent];
            NSString *p1 = [appDir stringByAppendingPathComponent:@"AudioRecorder"];
            if (p1.length > 0) [candidates addObject:p1];
        }
    }

    // 候选 2：bundleForClass 往上 2 级
    NSString *clsBundle = [[NSBundle bundleForClass:[ARAutoStartIntentExtensionHandler class]] bundlePath];
    if (clsBundle.length > 0) {
        NSString *appDir = [[clsBundle stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
        NSString *p2 = [appDir stringByAppendingPathComponent:@"AudioRecorder"];
        if (p2.length > 0 && ![candidates containsObject:p2]) [candidates addObject:p2];
    }

    // 候选 3：mainBundle 往上 2 级
    NSString *mainBundle = [[NSBundle mainBundle] bundlePath];
    if (mainBundle.length > 0) {
        NSString *appDir = [[mainBundle stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
        NSString *p3 = [appDir stringByAppendingPathComponent:@"AudioRecorder"];
        if (p3.length > 0 && ![candidates containsObject:p3]) [candidates addObject:p3];
    }

    // 候选 4：主 App 写入的 /tmp/.ar_main_exec_path
    NSString *savedPath = [NSString stringWithContentsOfFile:kARExtMainExecPath
                                                    encoding:NSUTF8StringEncoding
                                                       error:nil];
    if (savedPath.length > 0) {
        NSString *p4 = [savedPath stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (p4.length > 0 && ![candidates containsObject:p4]) [candidates addObject:p4];
    }

    NSString *firstNonEmpty = nil;
    for (NSString *cand in candidates) {
        if (![cand hasSuffix:@"/AudioRecorder"]) continue;
        if (!firstNonEmpty) firstNonEmpty = cand;

        errno = 0;
        int acc = access(cand.UTF8String, X_OK);
        int accErr = errno;
        struct stat st;
        errno = 0;
        int stRc = stat(cand.UTF8String, &st);
        int stErr = errno;
        ARExtLog(@"主程序候选路径: %@ | access(X_OK)=%d(err=%d) stat=%d(err=%d)",
                 cand, acc, accErr, stRc, stErr);
        if (acc == 0 || stRc == 0) {
            return cand;
        }
    }

    if (firstNonEmpty) {
        ARExtLog(@"所有候选 access/stat 未直接通过，保留首个有效拼接路径继续尝试 spawn: %@", firstNonEmpty);
    }
    return firstNonEmpty;
}

static BOOL ARExtSpawnDaemonAsRoot(NSString *execPath, int *outRc, pid_t *outPid) {
    if (outRc) *outRc = -1;
    if (outPid) *outPid = -1;
    if (!execPath || execPath.length == 0) {
        ARExtLog(@"拉起守护进程失败：未找到主程序可执行文件");
        if (outRc) *outRc = ENOENT;
        return NO;
    }

    posix_spawnattr_t attr;
    if (posix_spawnattr_init(&attr) != 0) {
        int err = errno;
        if (outRc) *outRc = err;
        return NO;
    }

    // 完全对齐原版 0x10008820c 的属性设置顺序与 envp=NULL
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);
    posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    posix_spawnattr_set_persona_uid_np(&attr, 0);
    posix_spawnattr_set_persona_gid_np(&attr, 0);
    posix_spawnattr_setpgroup(&attr, 0);

    const char *cPath = execPath.UTF8String;
    char *argv[] = {(char *)cPath, (char *)"daemon", NULL};
    pid_t childPid = -1;
    int rc = posix_spawn(&childPid, cPath, NULL, &attr, argv, NULL);
    posix_spawnattr_destroy(&attr);

    if (rc == 0 && childPid > 0) {
        if (outRc) *outRc = 0;
        if (outPid) *outPid = childPid;
        ARExtLog(@"成功以 root persona 拉起守护进程 pid=%d path=%@", childPid, execPath);
        return YES;
    }

    ARExtLog(@"root persona 拉起失败 rc=%d (%s)，尝试普通 posix_spawn 兜底", rc, strerror(rc));
    int rc2 = posix_spawn(&childPid, cPath, NULL, NULL, argv, NULL);
    ARExtLog(@"普通 posix_spawn 结果 rc=%d (%s) pid=%d", rc2, strerror(rc2), childPid);
    if (rc2 == 0 && childPid > 0) {
        if (outRc) *outRc = 0;
        if (outPid) *outPid = childPid;
        return YES;
    }

    if (outRc) *outRc = (rc != 0 ? rc : rc2);
    return NO;
}

static BOOL ARExtEnsureDaemonRunning(NSString *__autoreleasing *outMsg) {
    int64_t bootTime = ARExtGetSystemBootTimeSeconds();
    NSString *source = nil;
    pid_t existingPid = ARExtFindRunningDaemonPID(&source);

    if (existingPid > 0) {
        if (![[NSFileManager defaultManager] fileExistsAtPath:kARExtDefaultsTmpPath]) {
            ARExtSyncPreferencesToTmp();
        }
        if (outMsg) {
            *outMsg = [NSString stringWithFormat:@"通话录音守护进程已在运行中 (PID %d)", existingPid];
        }
        ARExtLog(@"跳过拉起：守护进程已存活 pid=%d source=%@ bootTime=%lld", existingPid, source, bootTime);
        return YES;
    }

    NSString *execPath = ARExtMainExecutablePath();
    ARExtLog(@"检测到守护进程未运行（bootTime=%lld），正在后台拉起 path=%@", bootTime, execPath);
    ARExtSyncPreferencesToTmp();
    int spawnRc = 0;
    pid_t childPid = -1;
    BOOL spawned = ARExtSpawnDaemonAsRoot(execPath, &spawnRc, &childPid);
    if (spawned) {
        NSString *marker = [NSString stringWithFormat:@"%lld\n", bootTime];
        [marker writeToFile:kARExtBootAlivePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        chmod(kARExtBootAlivePath.UTF8String, 0666);

        if (childPid > 0) {
            NSString *pidStr = [NSString stringWithFormat:@"%d %lld\n", childPid, bootTime];
            [pidStr writeToFile:kARExtDaemonPidPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
            chmod(kARExtDaemonPidPath.UTF8String, 0666);
        }

        if (outMsg) {
            *outMsg = @"检测到重启后守护进程未启动，已在后台静默恢复通话录音";
        }
        return YES;
    }

    if (outMsg) {
        *outMsg = [NSString stringWithFormat:@"后台拉起失败(rc=%d)，请查看 /tmp/ar_enhance.log", spawnRc];
    }
    return NO;
}

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
    resp.statusMessage = statusMsg ?: (ok ? @"已生效" : @"拉起失败");
    ARExtLog(@"handleEnsureDaemon 完成 ok=%d msg=%@", ok, resp.statusMessage);

    if (completion) {
        completion(resp);
    }
}

@end
