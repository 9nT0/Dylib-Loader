# DylibLoader

**Faster, stronger LiveContainer tweak loader** — built to beat stock TweakLoader on guest-app timing.

## Why it’s better

| | Stock TweakLoader | DylibLoader |
|--|-------------------|-------------|
| Path discovery | Basic folder | Multi-root LC paths + env override |
| Order | Directory order | Priority: Substrate → early → normal → late |
| Double load | Possible | Path set dedupes |
| Init symbols | Rely on constructors only | Explicit `GlassLoaderEntry` / `glossyglass_init` / … |
| Late UI | Often misses | Long re-kick burst 0.3s–45s + scene observers |
| Disk I/O | Often on load path | Background queue, kicks on main |
| Frameworks | Limited | Loads `.framework` binaries |

## Use with LiveContainer

1. Build `DylibLoader.dylib`
2. Put in the **app-specific Tweaks** folder as `0_DylibLoader.dylib` (loads first)
3. Add `GlossyGlass.dylib` (and any other tweaks) in the same folder
4. Enable TweakLoader for the guest **or** replace LC’s TweakLoader symlink with this build
5. Open guest app — wait a few seconds on first launch (up to ~15–30s for IG guest UI)

Env overrides:

```text
DYLIBLOADER_TWEAKS=/full/path/to/Tweaks
DYLIBLOADER_MAX_KICKS=16
```

## Priority rules (filename)

1. **Substrate / Ellekit / libhooker**
2. Names starting with `0_` / `00` / containing `dylibloader`
3. `glossyglass`, `injector`, `hook`, `1_`
4. Everything else

## Exports

- `DylibLoaderDidLoad()` — force bootstrap again  
- `DylibLoaderRescan()` — rescan folders + re-kick  

## Build

```bash
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun -sdk iphoneos clang -arch arm64 -dynamiclib \
  -isysroot "$SDK" -miphoneos-version-min=15.0 \
  -o DylibLoader.dylib src/DylibLoader.m \
  -framework Foundation -framework UIKit \
  -install_name @rpath/DylibLoader.dylib
```

Or use the included GitHub Action.

## Pair with GlossyGlass v3.6.1+

GlossyGlass exports the symbols this loader re-kicks. Together they handle LC’s “constructor before UI” problem.

**Outside LiveContainer:** do **not** inject DylibLoader. GlossyGlass loads via its own constructors / `+load` and does not depend on this loader.
