/*
 * DylibLoader v1.1.0 — LiveContainer loader (crash-safe)
 *
 * v1.0 froze/crashed because:
 *  - KickAllInits + LoadAllCollected ran in a tight delayed loop
 *  - That re-entered tweak constructors forever
 *
 * v1.1.0:
 *  - Load each dylib at most once
 *  - Init symbols called at most a few times (budget)
 *  - No periodic full rescans after first success
 *  - Short, capped re-kick schedule
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <os/lock.h>
#import <string.h>

static NSString * const kTag = @"[DylibLoader]";
static void DLLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
static void DLLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *m = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"%@ %@", kTag, m);
}

static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;
static NSMutableSet<NSString *> *gLoaded;
static BOOL gStarted = NO;
static int gKickCount = 0;
static const int kMaxKicks = 6;           // hard cap
static BOOL gLoadPassDone = NO;

static NSMutableSet<NSString *> *LoadedSet(void) {
    if (!gLoaded) gLoaded = [NSMutableSet new];
    return gLoaded;
}

#pragma mark - Init symbols (capped)

static const char *kInits[] = {
    "GlassLoaderEntry",
    "glossyglass_init",
    "TweakInitialize",
    "Initialize",
    NULL
};

static void InvokeInits(void *handle, const char *path) {
    if (!handle) return;
    for (const char **s = kInits; *s; s++) {
        dlerror();
        void *sym = dlsym(handle, *s);
        if (!sym) continue;
        DLLog(@"init %s (%s)", *s, path ? path : "?");
        @try { ((void (*)(void))sym)(); }
        @catch (NSException *ex) { DLLog(@"init exception: %@", ex); }
    }
}

static void KickAllInitsCapped(void) {
    os_unfair_lock_lock(&gLock);
    if (gKickCount >= kMaxKicks) {
        os_unfair_lock_unlock(&gLock);
        return;
    }
    gKickCount += 1;
    int n = gKickCount;
    os_unfair_lock_unlock(&gLock);

    DLLog(@"kick %d/%d", n, kMaxKicks);
    for (const char **s = kInits; *s; s++) {
        void *sym = dlsym(RTLD_DEFAULT, *s);
        if (!sym) continue;
        @try { ((void (*)(void))sym)(); }
        @catch (NSException *ex) { DLLog(@"kick exception: %@", ex); }
    }
}

#pragma mark - Paths

static void AddUnique(NSMutableArray *arr, NSString *p) {
    if (!p.length) return;
    p = p.stringByStandardizingPath;
    if (![arr containsObject:p]) [arr addObject:p];
}

static NSArray<NSString *> *TweakRoots(void) {
    NSMutableArray *roots = [NSMutableArray array];
    NSFileManager *fm = NSFileManager.defaultManager;

    const char *env = getenv("DYLIBLOADER_TWEAKS");
    if (env && *env) AddUnique(roots, [NSString stringWithUTF8String:env]);

    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (docs) {
        AddUnique(roots, [docs stringByAppendingPathComponent:@"Tweaks"]);
        NSString *apps = [docs stringByAppendingPathComponent:@"Applications"];
        for (NSString *name in [fm contentsOfDirectoryAtPath:apps error:nil] ?: @[]) {
            NSString *cand = [[apps stringByAppendingPathComponent:name] stringByAppendingPathComponent:@"Tweaks"];
            BOOL isDir = NO;
            if ([fm fileExistsAtPath:cand isDirectory:&isDir] && isDir) AddUnique(roots, cand);
        }
    }

    NSString *lib = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES).firstObject;
    if (lib) {
        AddUnique(roots, [lib stringByAppendingPathComponent:@"Tweaks"]);
        AddUnique(roots, [lib stringByAppendingPathComponent:@"LiveContainer/Tweaks"]);
    }

    NSString *bundle = NSBundle.mainBundle.bundlePath;
    if (bundle.length) {
        AddUnique(roots, [bundle stringByAppendingPathComponent:@"Tweaks"]);
        AddUnique(roots, [[bundle stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"Tweaks"]);
    }

    NSMutableArray *exist = [NSMutableArray array];
    for (NSString *r in roots) {
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:r isDirectory:&isDir] && isDir) [exist addObject:r];
    }
    return exist;
}

#pragma mark - Priority collect

static int Priority(NSString *name) {
    NSString *l = name.lowercaseString;
    if ([l containsString:@"cydiasubstrate"] || [l containsString:@"ellekit"] ||
        [l containsString:@"libsubstrate"]) return 0;
    if ([l hasPrefix:@"0_"] || [l hasPrefix:@"00"] || [l containsString:@"dylibloader"]) return 1;
    if ([l containsString:@"glossyglass"]) return 2;
    return 3;
}

static void Collect(NSString *dir, NSMutableArray *out, int depth) {
    if (depth > 6) return;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray *items = [[fm contentsOfDirectoryAtPath:dir error:nil]
                      sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];
    for (NSString *item in items) {
        if ([item hasPrefix:@"."]) continue;
        NSString *full = [dir stringByAppendingPathComponent:item];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:full isDirectory:&isDir]) continue;
        if (isDir) {
            if ([item.pathExtension.lowercaseString isEqualToString:@"framework"]) {
                NSString *bin = [full stringByAppendingPathComponent:item.stringByDeletingPathExtension];
                if ([fm fileExistsAtPath:bin]) {
                    [out addObject:@{ @"path": bin, @"pri": @(Priority(item)) }];
                }
            } else {
                Collect(full, out, depth + 1);
            }
            continue;
        }
        if (![item.pathExtension.lowercaseString isEqualToString:@"dylib"]) continue;
        // Never load ourselves again
        if ([item.lowercaseString containsString:@"dylibloader"]) continue;
        [out addObject:@{ @"path": full, @"pri": @(Priority(item)) }];
    }
}

static BOOL LoadOne(NSString *path) {
    os_unfair_lock_lock(&gLock);
    if ([LoadedSet() containsObject:path]) {
        os_unfair_lock_unlock(&gLock);
        return NO;
    }
    [LoadedSet() addObject:path];
    os_unfair_lock_unlock(&gLock);

    dlerror();
    void *h = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
    if (!h) {
        DLLog(@"dlopen fail %@: %s", path, dlerror());
        os_unfair_lock_lock(&gLock);
        [LoadedSet() removeObject:path];
        os_unfair_lock_unlock(&gLock);
        return NO;
    }
    DLLog(@"loaded %@", path.lastPathComponent);
    InvokeInits(h, path.fileSystemRepresentation);
    return YES;
}

static void LoadPass(void) {
    // Only one full load pass
    os_unfair_lock_lock(&gLock);
    if (gLoadPassDone) {
        os_unfair_lock_unlock(&gLock);
        return;
    }
    gLoadPassDone = YES;
    os_unfair_lock_unlock(&gLock);

    NSArray *roots = TweakRoots();
    NSMutableArray *all = [NSMutableArray array];
    for (NSString *r in roots) {
        DLLog(@"scan %@", r);
        Collect(r, all, 0);
    }
    [all sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        int pa = [a[@"pri"] intValue], pb = [b[@"pri"] intValue];
        if (pa != pb) return pa < pb ? NSOrderedAscending : NSOrderedDescending;
        return [a[@"path"] caseInsensitiveCompare:b[@"path"]];
    }];

    NSUInteger ok = 0;
    for (NSDictionary *it in all) {
        if (LoadOne(it[@"path"])) ok++;
    }
    DLLog(@"load pass done %lu/%lu", (unsigned long)ok, (unsigned long)all.count);
}

#pragma mark - Bootstrap

static void ArmObserversOnce(void) {
    static BOOL armed = NO;
    if (armed) return;
    armed = YES;

    void (^kick)(NSNotification *) = ^(NSNotification *n) {
        // Only kick if under budget — no rescan
        KickAllInitsCapped();
    };
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:kick];
    if (@available(iOS 13.0, *)) {
        [nc addObserverForName:UISceneDidActivateNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:kick];
    }
}

static void ScheduleLimitedKicks(void) {
    // Short, capped — does NOT rescan folders
    double delays[] = { 0.5, 1.5, 3.0, 6.0, 12.0 };
    for (size_t i = 0; i < sizeof(delays)/sizeof(delays[0]); i++) {
        double d = delays[i];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            KickAllInitsCapped();
        });
    }
}

static void Bootstrap(void) {
    if (gStarted) return;
    gStarted = YES;
    DLLog(@"v1.1.0 bootstrap");

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        LoadPass();
        dispatch_async(dispatch_get_main_queue(), ^{
            KickAllInitsCapped();
            ArmObserversOnce();
            ScheduleLimitedKicks();
        });
    });
}

__attribute__((constructor))
static void DylibLoaderConstructor(void) {
    Bootstrap();
}

void DylibLoaderDidLoad(void) {
    // Manual: allow one more kick only, not full reload storm
    KickAllInitsCapped();
}

void DylibLoaderRescan(void) {
    os_unfair_lock_lock(&gLock);
    gLoadPassDone = NO;
    os_unfair_lock_unlock(&gLock);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        LoadPass();
        dispatch_async(dispatch_get_main_queue(), ^{ KickAllInitsCapped(); });
    });
}
