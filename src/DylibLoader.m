/*
 * DylibLoader — high-performance LiveContainer tweak loader
 * Designed to outperform stock TweakLoader for guest-app timing.
 *
 * Strengths vs stock TweakLoader:
 *  - Aggressive multi-root path discovery (LC Documents / app folders)
 *  - Priority queue: Substrate → critical inits → user tweaks
 *  - Tracks already-loaded paths (no double dlopen)
 *  - Explicit init symbol invocation + process-wide re-kick
 *  - Fast early re-kick burst (UI often appears 1–8s after constructor)
 *  - Scene / active observers without blocking main thread on disk I/O
 *  - Optional .framework support (loads framework binary)
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <pthread.h>
#import <os/lock.h>
#import <dirent.h>
#import <sys/stat.h>
#import <stdio.h>
#import <string.h>

static NSString * const kTag = @"[DylibLoader]";

static void DLLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
static void DLLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *m = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"%@ %@", kTag, m);
}

#pragma mark - State

static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;
static NSMutableSet<NSString *> *gLoadedPaths;
static NSMutableArray<NSString *> *gLoadedOrder;
static BOOL gBootstrapped = NO;
static BOOL gObservers = NO;

static NSMutableSet<NSString *> *LoadedSet(void) {
    if (!gLoadedPaths) gLoadedPaths = [NSMutableSet new];
    return gLoadedPaths;
}

static NSMutableArray<NSString *> *LoadedOrder(void) {
    if (!gLoadedOrder) gLoadedOrder = [NSMutableArray new];
    return gLoadedOrder;
}

#pragma mark - Init symbols (GlossyGlass + generic)

static const char *kInitSymbols[] = {
    "GlassLoaderEntry",
    "glossyglass_init",
    "TweakInitialize",
    "Initialize",
    "DylibLoaderDidLoad",
    "%ctor",  // not a real symbol; skipped if missing
    NULL
};

static void InvokeInits(void *handle, const char *path) {
    if (!handle) return;
    for (const char **s = kInitSymbols; *s; ++s) {
        if (strcmp(*s, "%ctor") == 0) continue;
        dlerror();
        void *sym = dlsym(handle, *s);
        if (!sym) continue;
        DLLog(@"init %s ← %s", *s, path ? path : "?");
        @try {
            ((void (*)(void))sym)();
        } @catch (NSException *ex) {
            DLLog(@"init crashed %s: %@", *s, ex);
        }
    }
}

static void KickAllInits(void) {
    for (const char **s = kInitSymbols; *s; ++s) {
        if (strcmp(*s, "%ctor") == 0) continue;
        void *sym = dlsym(RTLD_DEFAULT, *s);
        if (!sym) continue;
        @try {
            ((void (*)(void))sym)();
        } @catch (NSException *ex) {
            DLLog(@"re-kick %@ crashed: %@", [NSString stringWithUTF8String:*s], ex);
        }
    }
}

#pragma mark - Path discovery (fast + broad)

static void AddUnique(NSMutableArray<NSString *> *arr, NSString *path) {
    if (!path.length) return;
    NSString *std = path.stringByStandardizingPath;
    if (![arr containsObject:std]) [arr addObject:std];
}

static NSArray<NSString *> *DiscoverTweakRoots(void) {
    NSMutableArray *roots = [NSMutableArray array];
    NSFileManager *fm = NSFileManager.defaultManager;

    // 1) Env override (highest priority)
    const char *env = getenv("DYLIBLOADER_TWEAKS");
    if (env && *env) AddUnique(roots, [NSString stringWithUTF8String:env]);

    // 2) Documents/Tweaks (common LC)
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (docs) {
        AddUnique(roots, [docs stringByAppendingPathComponent:@"Tweaks"]);
        // Walk Applications/*/ for per-app tweak links sometimes mirrored
        NSString *apps = [docs stringByAppendingPathComponent:@"Applications"];
        NSArray *appDirs = [fm contentsOfDirectoryAtPath:apps error:nil];
        for (NSString *name in appDirs) {
            NSString *cand = [[apps stringByAppendingPathComponent:name] stringByAppendingPathComponent:@"Tweaks"];
            BOOL isDir = NO;
            if ([fm fileExistsAtPath:cand isDirectory:&isDir] && isDir) AddUnique(roots, cand);
        }
    }

    // 3) Library / Application Support style
    NSString *lib = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES).firstObject;
    if (lib) {
        AddUnique(roots, [lib stringByAppendingPathComponent:@"Tweaks"]);
        AddUnique(roots, [lib stringByAppendingPathComponent:@"LiveContainer/Tweaks"]);
    }

    // 4) Bundle-adjacent
    NSString *bundle = NSBundle.mainBundle.bundlePath;
    if (bundle.length) {
        AddUnique(roots, [bundle stringByAppendingPathComponent:@"Tweaks"]);
        AddUnique(roots, [[bundle stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"Tweaks"]);
        AddUnique(roots, [[bundle stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"Frameworks"]);
    }

    // 5) Home relative (some LC builds)
    NSString *home = NSHomeDirectory();
    if (home.length) {
        AddUnique(roots, [home stringByAppendingPathComponent:@"Documents/Tweaks"]);
        AddUnique(roots, [home stringByAppendingPathComponent:@"Library/Tweaks"]);
    }

    // Keep only existing directories
    NSMutableArray *existing = [NSMutableArray array];
    for (NSString *r in roots) {
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:r isDirectory:&isDir] && isDir) {
            [existing addObject:r];
        }
    }
    return existing;
}

#pragma mark - Collect files with priority

typedef NS_ENUM(NSInteger, DLPriority) {
    DLPrioritySubstrate = 0,
    DLPriorityCritical  = 1,  // DylibLoader helpers / early hooks
    DLPriorityNormal    = 2,
    DLPriorityLate      = 3,
};

static DLPriority PriorityForName(NSString *name) {
    NSString *l = name.lowercaseString;
    if ([l containsString:@"cydiasubstrate"] || [l containsString:@"ellekit"] ||
        [l containsString:@"libsubstrate"] || [l isEqualToString:@"substrate.dylib"]) {
        return DLPrioritySubstrate;
    }
    if ([l hasPrefix:@"0_"] || [l hasPrefix:@"00"] || [l containsString:@"dylibloader"]) {
        return DLPriorityCritical;
    }
    if ([l containsString:@"glossyglass"] || [l containsString:@"injector"] ||
        [l containsString:@"hook"] || [l hasPrefix:@"1_"]) {
        return DLPriorityNormal;
    }
    return DLPriorityLate;
}

static void CollectDylibs(NSString *dir, NSMutableArray<NSDictionary *> *out, int depth) {
    if (depth > 8) return;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray *items = [[fm contentsOfDirectoryAtPath:dir error:nil]
                      sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];
    for (NSString *item in items) {
        if ([item hasPrefix:@"."]) continue;
        NSString *full = [dir stringByAppendingPathComponent:item];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:full isDirectory:&isDir]) continue;
        if (isDir) {
            // .framework: load binary inside
            if ([item.pathExtension.lowercaseString isEqualToString:@"framework"]) {
                NSString *exec = [full stringByAppendingPathComponent:item.stringByDeletingPathExtension];
                if ([fm fileExistsAtPath:exec]) {
                    [out addObject:@{ @"path": exec, @"pri": @(PriorityForName(item)) }];
                }
            } else {
                CollectDylibs(full, out, depth + 1);
            }
            continue;
        }
        NSString *ext = item.pathExtension.lowercaseString;
        if (![ext isEqualToString:@"dylib"]) continue;
        if ([item.lowercaseString containsString:@"dylibloader"] && depth == 0) {
            // allow loading sibling copies only once via set
        }
        [out addObject:@{ @"path": full, @"pri": @(PriorityForName(item)) }];
    }
}

#pragma mark - Load

static BOOL LoadOne(NSString *path) {
    if (!path.length) return NO;

    os_unfair_lock_lock(&gLock);
    if ([LoadedSet() containsObject:path]) {
        os_unfair_lock_unlock(&gLock);
        return NO;
    }
    [LoadedSet() addObject:path];
    os_unfair_lock_unlock(&gLock);

    const char *cpath = path.fileSystemRepresentation;
    dlerror();
    CFTimeInterval t0 = CACurrentMediaTime();
    void *h = dlopen(cpath, RTLD_NOW | RTLD_GLOBAL);
    CFTimeInterval ms = (CACurrentMediaTime() - t0) * 1000.0;
    if (!h) {
        const char *err = dlerror();
        DLLog(@"FAIL %.1fms %s — %s", ms, cpath, err ? err : "?");
        os_unfair_lock_lock(&gLock);
        [LoadedSet() removeObject:path];
        os_unfair_lock_unlock(&gLock);
        return NO;
    }
    DLLog(@"OK   %.1fms %s", ms, cpath);
    InvokeInits(h, cpath);

    os_unfair_lock_lock(&gLock);
    [LoadedOrder() addObject:path];
    os_unfair_lock_unlock(&gLock);
    return YES;
}

static void LoadAllCollected(void) {
    NSArray *roots = DiscoverTweakRoots();
    if (roots.count == 0) {
        DLLog(@"No Tweaks folders found yet");
        return;
    }

    NSMutableArray<NSDictionary *> *all = [NSMutableArray array];
    for (NSString *root in roots) {
        DLLog(@"Scan %@", root);
        CollectDylibs(root, all, 0);
    }

    [all sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSInteger pa = [a[@"pri"] integerValue];
        NSInteger pb = [b[@"pri"] integerValue];
        if (pa < pb) return NSOrderedAscending;
        if (pa > pb) return NSOrderedDescending;
        return [a[@"path"] caseInsensitiveCompare:b[@"path"]];
    }];

    CFTimeInterval t0 = CACurrentMediaTime();
    NSUInteger ok = 0;
    for (NSDictionary *item in all) {
        if (LoadOne(item[@"path"])) ok++;
    }
    DLLog(@"Loaded %lu/%lu in %.1fms", (unsigned long)ok, (unsigned long)all.count,
          (CACurrentMediaTime() - t0) * 1000.0);
}

#pragma mark - Notifications & schedule

static void ArmObservers(void) {
    if (gObservers) return;
    gObservers = YES;
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    void (^block)(NSNotification *) = ^(NSNotification *n) {
        DLLog(@"%@ → kick", n.name);
        KickAllInits();
        // Light rescan if nothing loaded yet
        os_unfair_lock_lock(&gLock);
        NSUInteger nLoaded = LoadedSet().count;
        os_unfair_lock_unlock(&gLock);
        if (nLoaded == 0) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                LoadAllCollected();
                dispatch_async(dispatch_get_main_queue(), ^{ KickAllInits(); });
            });
        }
    };
    [nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:block];
    [nc addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:block];
    if (@available(iOS 13.0, *)) {
        [nc addObserverForName:UISceneDidActivateNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:block];
        [nc addObserverForName:UISceneWillEnterForegroundNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:block];
    }
}

static void ScheduleBurst(void) {
    // Fast early burst — critical for LC guest UI
    double delays[] = { 0.15, 0.4, 0.8, 1.2, 1.8, 2.5, 3.5, 5.0, 7.5, 10.0, 15.0, 22.0, 30.0, 45.0 };
    size_t n = sizeof(delays) / sizeof(delays[0]);
    for (size_t i = 0; i < n; i++) {
        double d = delays[i];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            KickAllInits();
            if (d <= 3.5 || d == 10.0 || d == 30.0) {
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                    LoadAllCollected();
                    dispatch_async(dispatch_get_main_queue(), ^{ KickAllInits(); });
                });
            }
        });
    }
}

#pragma mark - Entry

static void Bootstrap(void) {
    if (gBootstrapped) return;
    gBootstrapped = YES;
    DLLog(@"Bootstrap (fast LC loader)");

    // Disk scan off main when possible; constructor may be early
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        LoadAllCollected();
        dispatch_async(dispatch_get_main_queue(), ^{
            KickAllInits();
            ArmObservers();
            ScheduleBurst();
        });
    });

    // Also immediate main-queue kick in case something already loaded
    dispatch_async(dispatch_get_main_queue(), ^{
        KickAllInits();
        ArmObservers();
    });
}

__attribute__((constructor))
static void DylibLoaderConstructor(void) {
    Bootstrap();
}

void DylibLoaderDidLoad(void) {
    DLLog(@"DylibLoaderDidLoad()");
    gBootstrapped = NO; // allow forced rescan
    Bootstrap();
}

void DylibLoaderRescan(void) {
    DLLog(@"Rescan requested");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        LoadAllCollected();
        dispatch_async(dispatch_get_main_queue(), ^{ KickAllInits(); });
    });
}
