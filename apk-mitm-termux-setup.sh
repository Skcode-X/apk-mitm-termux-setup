#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
#  apk-mitm - Termux Auto Installer (aarch64/ARM64 patched build)
#  ---------------------------------------------------------------------------
#   This script prepares apk-mitm to run on Termux:
#     - apktool/aapt2  -> uses the Termux-native aapt2 package
#     - zipalign        -> aarch64 zipalign from the rendiix repo
#     - $ resource sanitizer (fixes App Bundle base-split APKs)
#     - App Bundle split flags strip (isSplitRequired) -> standalone install
#     - Correct APK signing (uber-apk-signer v1.3.0 fix)
#   Usage:  bash apk-mitm-termux-setup.sh
#
#   Required:  Termux + internet
# =============================================================================

set -uo pipefail

BOLD='\e[1m'
DIM='\e[2m'
GREEN='\e[32m'
YELLOW='\e[33m'
RED='\e[31m'
RESET='\e[0m'

info()  { printf "${BOLD}[*]${RESET} %s\n" "$1"; }
ok()    { printf "${GREEN}  [OK]${RESET} %s\n" "$1"; }
warn()  { printf "${YELLOW}  [!]${RESET} %s\n" "$1"; }
die()   { printf "${RED}  [X]${RESET} %s\n" "$1" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 0. Only run inside Termux
# ---------------------------------------------------------------------------
if [ -z "${TERMUX_VERSION:-}" ] && [ ! -d /data/data/com.termux ]; then
    die "This installer can only be run inside Termux."
fi
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"

echo
printf "${BOLD}╔══════════════════════════════════════════════════════╗${RESET}\n"
printf "${BOLD}║      apk-mitm - Termux Auto Installer (aarch64)      ║${RESET}\n"
printf "${BOLD}╚══════════════════════════════════════════════════════╝${RESET}\n"
echo

# ---------------------------------------------------------------------------
# 1. Install base dependencies from Termux main repo
# ---------------------------------------------------------------------------
info "Updating and installing Termux packages (this may take ~5-10 min on first run)..."
pkg update -y > /dev/null 2>&1 || true
pkg install -y nodejs-lts openjdk-17 git aapt aapt2 > /dev/null 2>&1 || \
    pkg install -y nodejs-lts openjdk-17 git aapt aapt2 || true

command -v node    > /dev/null 2>&1 && ok "node     : $(node --version)"  || warn "node was not installed"
command -v java    > /dev/null 2>&1 && ok "java     : $(java -version 2>&1 | head -1)" || warn "java was not installed"
command -v aapt2   > /dev/null 2>&1 && ok "aapt2    : present (Termux-native)" || warn "aapt2 (Termux) was not installed"

# ---------------------------------------------------------------------------
# 2. rendiix repo (aarch64 zipalign) + install zipalign
# ---------------------------------------------------------------------------
REPO_FILE="$PREFIX/etc/apt/sources.list.d/rendiix.list"
if [ ! -f "$REPO_FILE" ]; then
    info "Adding the rendiix repo (for aarch64 zipalign)..."
    echo "deb https://rendiix.github.io android-tools termux" > "$REPO_FILE"
    pkg update -y > /dev/null 2>&1 || true
fi

if ! command -v zipalign > /dev/null 2>&1; then
    pkg install -y zipalign > /dev/null 2>&1 || true
fi
if command -v zipalign > /dev/null 2>&1; then
    ok "zipalign : present ($(command -v zipalign))"
else
    warn "zipalign was not installed — the APK will still be signed, but alignment will be skipped."
fi

# ---------------------------------------------------------------------------
# 3. Install apk-mitm via npm (skip re-download if 1.3.0 is already present)
# ---------------------------------------------------------------------------
NPM_ROOT="$(npm root -g 2>/dev/null || true)"
APK_MITM_DIR="$NPM_ROOT/apk-mitm"
INSTALLED_VER=""
if [ -f "$APK_MITM_DIR/package.json" ]; then
    INSTALLED_VER="$(node -e "console.log(require('$APK_MITM_DIR/package.json').version)" 2>/dev/null || true)"
fi
if [ "$INSTALLED_VER" = "1.3.0" ]; then
    ok "apk-mitm is already installed (v1.3.0) — reinstall skip."
else
    info "Installing apk-mitm (npm)..."
    LOG_FILE="${TMPDIR:-$PREFIX/tmp}/apkmitm-npm.log"
    npm install -g apk-mitm@1.3.0 > "$LOG_FILE" 2>&1 \
        || { tail -20 "$LOG_FILE"; die "apk-mitm npm install failed (log: $LOG_FILE)."; }
    ok "apk-mitm npm package installed"
fi

DIST_DIR="$APK_MITM_DIR/dist"
[ -d "$DIST_DIR" ] || die "apk-mitm dist folder not found: $DIST_DIR"

# ---------------------------------------------------------------------------
# 4. Apply Termux patches
# ---------------------------------------------------------------------------
info "Applying Termux patches..."

# 4.a  NEW  tasks/sanitize-resources.js (renames legacy "$..." resources
#       so that aapt2 does not crash on App Bundle APKs)
cat > "$DIST_DIR/tasks/sanitize-resources.js" <<'PATCH_EOF'
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
const path = require("path");
const globby = require("globby");
const fs = require("../utils/fs");
const observe_async_1 = require("../utils/observe-async");
const build_glob_1 = require("../utils/build-glob");

function sanitizeResources(decodeDir) {
    return observe_async_1.default(async (log) => {
        const resDir = path.join(decodeDir, 'res');
        if (!await fs.exists(resDir)) {
            log('No res/ directory found, skipping.');
            return;
        }

        const dollarFilesGlob = build_glob_1.default(decodeDir, 'res/**/$*');
        const dollarFiles = [];
        for await (const filePathChunk of globby.stream(dollarFilesGlob)) {
            dollarFiles.push(filePathChunk);
        }

        if (dollarFiles.length === 0) {
            log('No legacy $-prefixed resources found.');
            return;
        }

        log(`Found ${dollarFiles.length} legacy $-prefixed resource(s), renaming...`);

        const renameMap = {};

        for (const filePath of dollarFiles) {
            const dir = path.dirname(filePath);
            const base = path.basename(filePath);
            const newBase = 'z' + base.substring(1);
            const newPath = path.join(dir, newBase);

            if (await fs.exists(newPath)) {
                log(`Warning: ${newBase} already exists, skipping ${base}`);
                continue;
            }

            await fs.rename(filePath, newPath);

            const baseNoExt = base.replace(/\.xml$/i, '');
            const newBaseNoExt = newBase.replace(/\.xml$/i, '');
            renameMap[baseNoExt] = newBaseNoExt;
        }

        log(`Renamed ${Object.keys(renameMap).length} file(s).`);

        if (Object.keys(renameMap).length === 0) return;

        const xmlGlob = build_glob_1.default(decodeDir, 'res/**/*.xml');
        const xmlFiles = [];
        for await (const filePathChunk of globby.stream(xmlGlob)) {
            xmlFiles.push(filePathChunk);
        }

        let updatedCount = 0;
        for (const xmlFile of xmlFiles) {
            let content = await fs.readFile(xmlFile, 'utf-8');
            let modified = false;

            for (const [oldName, newName] of Object.entries(renameMap)) {
                if (content.includes(oldName)) {
                    content = content.split(oldName).join(newName);
                    modified = true;
                }
            }

            if (modified) {
                await fs.writeFile(xmlFile, content, 'utf-8');
                updatedCount++;
            }
        }

        log(`Updated references in ${updatedCount} XML file(s).`);
    });
}

exports.default = sanitizeResources;
PATCH_EOF
ok "patched: tasks/sanitize-resources.js (new)"

# 4.b  tasks/modify-manifest.js — App Bundle split flags strip
cat > "$DIST_DIR/tasks/modify-manifest.js" <<'PATCH_EOF'
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
const fs = require("../utils/fs");
const xml = require("xml-js");
async function modifyManifest(path, debuggable = false, mapsApiKey = '') {
    var _a, _b, _c, _d, _e;
    const document = xml.xml2js(await fs.readFile(path, 'utf-8'));
    const manifest = (_a = document.elements) === null || _a === void 0 ? void 0 : _a.find(el => el.name === 'manifest');
    const application = (_b = manifest.elements) === null || _b === void 0 ? void 0 : _b.find(el => el.name === 'application');
    application.attributes = {
        ...application.attributes,
        'android:networkSecurityConfig': '@xml/nsc_mitm',
        ...(debuggable && { 'android:debuggable': 'true' }),
    };
    delete application.attributes['android:isSplitRequired'];
    if (Array.isArray(application.elements)) {
        application.elements = application.elements.filter(el => {
            const name = el.name === 'meta-data' && el.attributes ? el.attributes['android:name'] : undefined;
            return !(name === 'com.android.vending.splits' ||
                name === 'com.android.vending.splits.required' ||
                name === 'com.android.vending.derived.apk.id');
        });
    }
    const usesAppBundle = (_d = (_c = application.elements) === null || _c === void 0 ? void 0 : _c.some(el => {
        var _a;
        return el.name === 'meta-data' &&
            ((_a = el.attributes) === null || _a === void 0 ? void 0 : _a['android:name']) === 'com.android.vending.splits';
    })) !== null && _d !== void 0 ? _d : false;
    if (mapsApiKey) {
        (_e = application.elements) === null || _e === void 0 ? void 0 : _e.forEach(el => {
            var _a;
            if (el.name === 'meta-data') {
                const name = ((_a = el.attributes) === null || _a === void 0 ? void 0 : _a['android:name']) + '';
                const mapsApiName = [
                    'com.google.android.maps.v2.API_KEY',
                    'com.google.android.geo.API_KEY',
                ];
                if (mapsApiName.includes(name)) {
                    el.attributes['android:value'] = mapsApiKey;
                }
            }
        });
    }
    await fs.writeFile(path, xml.js2xml(document, { spaces: 4 }));
    return { usesAppBundle };
}
exports.default = modifyManifest;
PATCH_EOF
ok "patched: tasks/modify-manifest.js (split-flags strip)"

# 4.c  tools/apktool.js — Termux-native aapt2 auto-detect
cat > "$DIST_DIR/tools/apktool.js" <<'PATCH_EOF'
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
const fs = require("fs");
const operators_1 = require("rxjs/operators");
const chalk = require("chalk");
const execute_jar_1 = require("../utils/execute-jar");
const observe_process_1 = require("../utils/observe-process");
const tool_1 = require("./tool");

function isTermux() {
    return process.env.TERMUX_VERSION !== undefined ||
        process.env.PREFIX?.includes('com.termux') ||
        fs.existsSync('/data/data/com.termux/files/usr/bin/aapt2');
}

function findAapt2() {
    if (isTermux()) {
        const paths = [
            '/data/data/com.termux/files/usr/bin/aapt2',
            '/data/data/com.termux/files/usr/opt/android-sdk/build-tools/36.1.0/aapt2',
            '/data/data/com.termux/files/usr/opt/android-sdk/build-tools/35.0.0/aapt2',
        ];
        for (const p of paths) {
            if (fs.existsSync(p)) return p;
        }
    }
    return undefined;
}

class Apktool extends tool_1.default {
    constructor(options) {
        super();
        this.options = options;
        this.name = 'apktool';
    }
    decode(inputPath, outputPath) {
        return this.run([
            'decode',
            inputPath,
            '--output',
            outputPath,
            '--frame-path',
            this.options.frameworkPath,
        ], 'decoding');
    }
    encode(inputPath, outputPath, useAapt2) {
        const args = [
            'build',
            inputPath,
            '--output',
            outputPath,
            '--frame-path',
            this.options.frameworkPath,
        ];
        if (useAapt2 && isTermux()) {
            const aapt2Path = findAapt2();
            if (aapt2Path) {
                args.push('--aapt', aapt2Path);
            }
        }
        return this.run(args, `encoding-${useAapt2 ? 'aapt2' : 'aapt'}`);
    }
    run(args, logName) {
        return operators_1.map((line) => line.replace(/I: /g, ''))(observe_process_1.default(execute_jar_1.executeJar(this.path, args), logName));
    }
    get path() {
        return this.options.customPath || this.jarPath;
    }
    get version() {
        if (this.options.customPath)
            return { name: chalk.italic('custom version') };
        const versionNumber = '2.9.3';
        return {
            name: `v${versionNumber}`,
            downloadUrl: 'https://github.com/iBotPeaches/Apktool/releases/download' +
                `/v${versionNumber}/apktool_${versionNumber}.jar`,
        };
    }
}
exports.default = Apktool;
PATCH_EOF
ok "patched: tools/apktool.js (aapt2 auto-detect)"

# 4.d  tools/uber-apk-signer.js — correct signing + zipalign auto-detect
cat > "$DIST_DIR/tools/uber-apk-signer.js" <<'PATCH_EOF'
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
const fs = require("fs");
const { execSync } = require("child_process");
const execute_jar_1 = require("../utils/execute-jar");
const observe_process_1 = require("../utils/observe-process");
const tool_1 = require("./tool");

function isTermux() {
    return process.env.TERMUX_VERSION !== undefined ||
        process.env.PREFIX?.includes('com.termux') ||
        fs.existsSync('/data/data/com.termux/files/usr/bin/aapt2');
}

function findZipAlign() {
    const candidates = [
        '/data/data/com.termux/files/usr/opt/android-sdk/build-tools/36.1.0/zipalign',
        '/data/data/com.termux/files/usr/opt/android-sdk/build-tools/35.0.0/zipalign',
        '/data/data/com.termux/files/usr/bin/zipalign',
    ];
    for (const p of candidates) {
        if (fs.existsSync(p)) return p;
    }
    try {
        const p = execSync('command -v zipalign 2>/dev/null', { encoding: 'utf-8' }).trim();
        if (p && fs.existsSync(p)) return p;
    } catch (_) {}
    return undefined;
}

class UberApkSigner extends tool_1.default {
    constructor() {
        super(...arguments);
        this.name = 'uber-apk-signer';
    }
    sign(inputPaths, { zipalign = false } = {}) {
        const pathArgs = [];
        for (const path of inputPaths) {
            pathArgs.push('--apks', path);
        }
        const args = [
            '--allowResign',
            '--overwrite',
            ...(zipalign ? [] : ['--skipZipAlign']),
            ...pathArgs,
        ];
        if (zipalign) {
            const zipAlignBin = findZipAlign();
            if (zipAlignBin) {
                args.push('--zipAlignPath', zipAlignBin);
            }
        }
        return observe_process_1.default(execute_jar_1.executeJar(this.jarPath, args), 'signing');
    }
    get version() {
        const versionNumber = '1.3.0';
        return {
            name: `v${versionNumber}`,
            downloadUrl: 'https://github.com/patrickfav/uber-apk-signer/releases/download' +
                `/v${versionNumber}/uber-apk-signer-${versionNumber}.jar`,
        };
    }
}
exports.default = UberApkSigner;
PATCH_EOF
ok "patched: tools/uber-apk-signer.js (signing fix + zipalign auto-detect)"

# 4.e  patch-apk.js — inserts the sanitize step (between patches and encoding)
cat > "$DIST_DIR/patch-apk.js" <<'PATCH_EOF'
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.showAppBundleWarning = void 0;
const path = require("path");
const events_1 = require("events");
const fs = require("./utils/fs");
const Listr = require("listr");
const chalk = require("chalk");
const observe_async_1 = require("./utils/observe-async");
const apply_patches_1 = require("./tasks/apply-patches");
const sanitize_resources_1 = require("./tasks/sanitize-resources");
const check_prerequisites_1 = require("./tasks/check-prerequisites");
function patchApk(options) {
    const { apktool, uberApkSigner } = options;
    const decodeDir = options.skipDecode
        ? options.inputPath
        : path.join(options.tmpDir, 'decode');
    const tmpApkPath = path.join(options.tmpDir, 'tmp.apk');
    let fallBackToAapt = false;
    return new Listr([
        {
            title: 'Checking prerequisities',
            task: () => check_prerequisites_1.default(options),
        },
        {
            title: 'Decoding APK file',
            skip: () => options.skipDecode,
            task: () => apktool.decode(options.inputPath, decodeDir),
        },
        {
            title: 'Applying patches',
            skip: () => options.skipPatches,
            task: () => apply_patches_1.default(decodeDir, {
                debuggable: options.debuggable,
                certificatePath: options.certificatePath,
                mapsApiKey: options.mapsApiKey,
            }),
        },
        {
            title: 'Sanitizing legacy resource names',
            skip: () => options.skipPatches,
            task: () => sanitize_resources_1.default(decodeDir),
        },
        {
            title: 'Waiting for you to make changes',
            enabled: () => options.wait,
            task: () => observe_async_1.default(async (log) => {
                process.stdin.setEncoding('utf-8');
                process.stdin.setRawMode(true);
                log('Press any key to continue.');
                await events_1.once(process.stdin, 'data');
                process.stdin.setRawMode(false);
                process.stdin.pause();
            }),
        },
        {
            title: 'Encoding patched APK file',
            task: () => new Listr([
                {
                    title: 'Encoding using AAPT2',
                    task: (_, task) => observe_async_1.default(async (next) => {
                        try {
                            await apktool
                                .encode(decodeDir, tmpApkPath, true)
                                .forEach(next);
                        }
                        catch (_a) {
                            task.skip('Failed, falling back to AAPT...');
                            fallBackToAapt = true;
                        }
                    }),
                },
                {
                    title: chalk `Encoding using AAPT {dim [fallback]}`,
                    skip: () => !fallBackToAapt,
                    task: () => apktool.encode(decodeDir, tmpApkPath, false),
                },
            ]),
        },
        {
            title: 'Signing patched APK file',
            task: () => observe_async_1.default(async (log) => {
                await uberApkSigner
                    .sign([tmpApkPath], { zipalign: true })
                    .forEach(line => log(line));
                await fs.copyFile(tmpApkPath, options.outputPath);
            }),
        },
    ]);
}
exports.default = patchApk;
function showAppBundleWarning() {
    console.log(chalk `{yellow
  {inverse.bold  WARNING }

  This app seems to be using {bold Android App Bundle} which means that you
  will likely run into problems installing it. That's because this app
  is made out of {bold multiple APK files} and you've only got one of them.

  If you want to patch an app like this with {bold apk-mitm}, you'll have to
  supply it with all the APKs. You have two options for doing this:

  – download a {bold *.xapk} file {dim (for example from https://apkpure.com​)}
  – export a {bold *.apks} file {dim (using https://github.com/Aefyr/SAI​)}

  You can then run {bold apk-mitm} again with that file to patch the bundle.}`);
}
exports.showAppBundleWarning = showAppBundleWarning;
PATCH_EOF
ok "patched: patch-apk.js (sanitize step)"

# ---------------------------------------------------------------------------
# 5. Verify patches load correctly
# ---------------------------------------------------------------------------
info "Verifying patches..."
node -e "
const t1=require('$DIST_DIR/tasks/sanitize-resources.js');
const t2=require('$DIST_DIR/tasks/modify-manifest.js');
const t3=require('$DIST_DIR/tools/apktool.js');
const t4=require('$DIST_DIR/tools/uber-apk-signer.js');
const t5=require('$DIST_DIR/patch-apk.js');
const all=[t1,t2,t3,t4,t5].every(m=>typeof m.default==='function');
process.exit(all?0:1);
" && ok "All 5 modules loaded successfully" || die "Failed to load patched modules."

# ---------------------------------------------------------------------------
# 6. Done
# ---------------------------------------------------------------------------
echo
printf "${GREEN}${BOLD}══════════════════════════════════════════════════════${RESET}\n"
printf "${GREEN}${BOLD}  Setup complete! Now patch an APK:${RESET}\n"
printf "${BOLD}      apk-mitm app.apk${RESET}\n"
printf "${GREEN}${BOLD}  Output:  ./app-patched.apk${RESET}\n"
printf "${GREEN}${BOLD}══════════════════════════════════════════════════════${RESET}\n"
echo