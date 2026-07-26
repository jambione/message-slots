#!/usr/bin/env python3
"""Generate MessageSlots.xcodeproj for the iOS prototype app.

The Swift package (`Package.swift`) stays the source of truth for the engine and
its tests — `swift test` works with no Xcode at all. This script produces an
equivalent three-target Xcode project so the same sources build, run and *test*
from the IDE:

    GameCore.framework   Sources/GameCore  + the compiled word-pool JSON
    MessageSlots.app     App/              links and embeds GameCore
    GameCoreTests.xctest Tests/            links GameCore, `@testable` imports it

GameCore is a real framework target rather than sources compiled straight into
the app, because a module is what `@testable import GameCore` needs to attach
to. Without it the XCTest suite can only run under SwiftPM — which is how a
1%-of-spins dead-end bug survived in the engine while the project looked green.

Regenerate after adding or renaming source files:

    python3 tools/generate_xcodeproj.py
"""

from __future__ import annotations

import hashlib
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
PROJECT = ROOT / "MessageSlots.xcodeproj"

APP_NAME = "MessageSlots"
FRAMEWORK_NAME = "GameCore"
TEST_NAME = "GameCoreTests"
BUNDLE_ID = "com.messageslots.prototype"
DEPLOYMENT_TARGET = "17.0"
SWIFT_VERSION = "5.0"

FRAMEWORK_DIR = ROOT / "Sources" / "GameCore"
APP_DIR = ROOT / "App"
TEST_DIR = ROOT / "Tests" / "GameCoreTests"
RESOURCE_DIR = FRAMEWORK_DIR / "Resources"

TAB = "\t"


def oid(*parts: str) -> str:
    """Stable 24-hex-character object id, so regeneration produces a clean diff."""
    return hashlib.sha1("::".join(parts).encode()).hexdigest()[:24].upper()


def swift_in(directory: pathlib.Path) -> list[pathlib.Path]:
    return sorted(p for p in directory.rglob("*.swift"))


def resources() -> list[pathlib.Path]:
    return sorted(RESOURCE_DIR.glob("*.json"))


class Project:
    """Accumulates pbxproj sections for the three targets."""

    def __init__(self) -> None:
        self.build_files: list[str] = []
        self.file_refs: list[str] = []
        self.seen_refs: set[str] = set()

    def file_ref(self, path: pathlib.Path) -> str:
        rel = path.relative_to(ROOT).as_posix()
        ref = oid("ref", rel)
        if ref not in self.seen_refs:
            self.seen_refs.add(ref)
            ftype = "sourcecode.swift" if path.suffix == ".swift" else "text.json"
            self.file_refs.append(
                f'{TAB}{TAB}{ref} /* {path.name} */ = {{isa = PBXFileReference; '
                f'lastKnownFileType = {ftype}; name = "{path.name}"; path = "{rel}"; '
                f'sourceTree = "<group>"; }};'
            )
        return ref

    def build_file(self, path: pathlib.Path, target: str, attributes: str = "") -> str:
        """A file can build into several targets, so ids are keyed by target too."""
        rel = path.relative_to(ROOT).as_posix()
        ref = self.file_ref(path)
        build = oid("build", target, rel)
        self.build_files.append(
            f"{TAB}{TAB}{build} /* {path.name} */ = {{isa = PBXBuildFile; "
            f"fileRef = {ref} /* {path.name} */;{attributes} }};"
        )
        return build

    def product_build_file(self, product_ref: str, name: str, target: str, attributes: str = "") -> str:
        build = oid("build", target, name)
        self.build_files.append(
            f"{TAB}{TAB}{build} /* {name} */ = {{isa = PBXBuildFile; "
            f"fileRef = {product_ref} /* {name} */;{attributes} }};"
        )
        return build


def listing(entries: list[str], indent: int = 4) -> str:
    pad = TAB * indent
    return "\n".join(f"{pad}{e}," for e in entries)


def build_settings(pairs: dict[str, str]) -> str:
    return "\n".join(f"{TAB * 5}{k} = {v};" for k, v in pairs.items())


def generate() -> str:
    p = Project()

    fw_sources = swift_in(FRAMEWORK_DIR)
    app_sources = swift_in(APP_DIR)
    test_sources = swift_in(TEST_DIR)
    res = resources()
    if not fw_sources or not app_sources:
        raise SystemExit("no Swift sources found")
    if not test_sources:
        raise SystemExit(f"no test sources found in {TEST_DIR}")

    ids = {
        key: oid("obj", key)
        for key in [
            "project", "group_root", "group_gamecore", "group_app", "group_tests",
            "group_products", "cfg_list_project", "cfg_proj_debug", "cfg_proj_release",
            "target_app", "product_app", "phase_app_sources", "phase_app_frameworks",
            "phase_app_resources", "phase_app_embed", "cfg_list_app",
            "cfg_app_debug", "cfg_app_release",
            "target_fw", "product_fw", "phase_fw_sources", "phase_fw_frameworks",
            "phase_fw_resources", "cfg_list_fw", "cfg_fw_debug", "cfg_fw_release",
            "target_test", "product_test", "phase_test_sources", "phase_test_frameworks",
            "phase_test_embed", "cfg_list_test", "cfg_test_debug", "cfg_test_release",
            "dep_app_fw", "dep_test_fw", "proxy_app_fw", "proxy_test_fw",
        ]
    }

    # --- product references -------------------------------------------------
    products = [
        (ids["product_app"], f"{APP_NAME}.app", "wrapper.application"),
        (ids["product_fw"], f"{FRAMEWORK_NAME}.framework", "wrapper.framework"),
        (ids["product_test"], f"{TEST_NAME}.xctest", "wrapper.cfbundle"),
    ]
    product_refs = [
        f"{TAB}{TAB}{ref} /* {name} */ = {{isa = PBXFileReference; explicitFileType = {ftype}; "
        f"includeInIndex = 0; path = {name}; sourceTree = BUILT_PRODUCTS_DIR; }};"
        for ref, name, ftype in products
    ]

    # --- build files per target ---------------------------------------------
    fw_source_phase = [p.build_file(f, "fw") for f in fw_sources]
    fw_resource_phase = [p.build_file(f, "fw") for f in res]
    app_source_phase = [p.build_file(f, "app") for f in app_sources]
    test_source_phase = [p.build_file(f, "test") for f in test_sources]

    # The app links the framework and embeds it; the test bundle does the same so
    # it can run without a host application.
    embed_attrs = " settings = {ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy, ); };"
    app_link = p.product_build_file(ids["product_fw"], f"{FRAMEWORK_NAME}.framework", "app_link")
    app_embed = p.product_build_file(ids["product_fw"], f"{FRAMEWORK_NAME}.framework", "app_embed", embed_attrs)
    test_link = p.product_build_file(ids["product_fw"], f"{FRAMEWORK_NAME}.framework", "test_link")
    test_embed = p.product_build_file(ids["product_fw"], f"{FRAMEWORK_NAME}.framework", "test_embed", embed_attrs)

    def refs_of(paths: list[pathlib.Path]) -> list[str]:
        return [f"{p.file_ref(f)} /* {f.name} */" for f in paths]

    common = {
        "IPHONEOS_DEPLOYMENT_TARGET": DEPLOYMENT_TARGET,
        "SWIFT_VERSION": SWIFT_VERSION,
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": "1",
        "MARKETING_VERSION": "0.1",
        "GENERATE_INFOPLIST_FILE": "YES",
        "TARGETED_DEVICE_FAMILY": '"1,2"',
    }
    fw_settings = common | {
        "DEFINES_MODULE": "YES",
        "DYLIB_COMPATIBILITY_VERSION": "1",
        "DYLIB_CURRENT_VERSION": "1",
        "DYLIB_INSTALL_NAME_BASE": '"@rpath"',
        "INSTALL_PATH": '"$(LOCAL_LIBRARY_DIR)/Frameworks"',
        "LD_RUNPATH_SEARCH_PATHS": '(\n\t\t\t\t\t\t"$(inherited)",\n\t\t\t\t\t\t"@executable_path/Frameworks",\n\t\t\t\t\t\t"@loader_path/Frameworks",\n\t\t\t\t\t)',
        "PRODUCT_BUNDLE_IDENTIFIER": f"com.messageslots.{FRAMEWORK_NAME}",
        "PRODUCT_NAME": '"$(TARGET_NAME:c99extidentifier)"',
        "SKIP_INSTALL": "YES",
        "VERSIONING_SYSTEM": '"apple-generic"',
    }
    app_settings = common | {
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "ENABLE_PREVIEWS": "YES",
        "INFOPLIST_KEY_UILaunchScreen_Generation": "YES",
        "INFOPLIST_KEY_UISupportedInterfaceOrientations": "UIInterfaceOrientationPortrait",
        "LD_RUNPATH_SEARCH_PATHS": '(\n\t\t\t\t\t\t"$(inherited)",\n\t\t\t\t\t\t"@executable_path/Frameworks",\n\t\t\t\t\t)',
        "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID,
        "PRODUCT_NAME": '"$(TARGET_NAME)"',
        "SWIFT_EMIT_LOC_STRINGS": "YES",
    }
    # No TEST_HOST: these are pure logic tests over a framework, so they run
    # without launching the app — faster, and they cannot be broken by UI work.
    test_settings = common | {
        "LD_RUNPATH_SEARCH_PATHS": '(\n\t\t\t\t\t\t"$(inherited)",\n\t\t\t\t\t\t"@executable_path/Frameworks",\n\t\t\t\t\t\t"@loader_path/Frameworks",\n\t\t\t\t\t)',
        "PRODUCT_BUNDLE_IDENTIFIER": f"com.messageslots.{TEST_NAME}",
        "PRODUCT_NAME": '"$(TARGET_NAME)"',
    }

    nl = "\n"
    return f"""// !$*UTF8*$!
{{
{TAB}archiveVersion = 1;
{TAB}classes = {{
{TAB}}};
{TAB}objectVersion = 56;
{TAB}objects = {{

/* Begin PBXBuildFile section */
{nl.join(p.build_files)}
/* End PBXBuildFile section */

/* Begin PBXContainerItemProxy section */
{TAB}{TAB}{ids['proxy_app_fw']} /* PBXContainerItemProxy */ = {{
{TAB}{TAB}{TAB}isa = PBXContainerItemProxy;
{TAB}{TAB}{TAB}containerPortal = {ids['project']} /* Project object */;
{TAB}{TAB}{TAB}proxyType = 1;
{TAB}{TAB}{TAB}remoteGlobalIDString = {ids['target_fw']};
{TAB}{TAB}{TAB}remoteInfo = {FRAMEWORK_NAME};
{TAB}{TAB}}};
{TAB}{TAB}{ids['proxy_test_fw']} /* PBXContainerItemProxy */ = {{
{TAB}{TAB}{TAB}isa = PBXContainerItemProxy;
{TAB}{TAB}{TAB}containerPortal = {ids['project']} /* Project object */;
{TAB}{TAB}{TAB}proxyType = 1;
{TAB}{TAB}{TAB}remoteGlobalIDString = {ids['target_fw']};
{TAB}{TAB}{TAB}remoteInfo = {FRAMEWORK_NAME};
{TAB}{TAB}}};
/* End PBXContainerItemProxy section */

/* Begin PBXCopyFilesBuildPhase section */
{TAB}{TAB}{ids['phase_app_embed']} /* Embed Frameworks */ = {{
{TAB}{TAB}{TAB}isa = PBXCopyFilesBuildPhase;
{TAB}{TAB}{TAB}buildActionMask = 2147483647;
{TAB}{TAB}{TAB}dstPath = "";
{TAB}{TAB}{TAB}dstSubfolderSpec = 10;
{TAB}{TAB}{TAB}files = (
{TAB}{TAB}{TAB}{TAB}{app_embed} /* {FRAMEWORK_NAME}.framework in Embed Frameworks */,
{TAB}{TAB}{TAB});
{TAB}{TAB}{TAB}name = "Embed Frameworks";
{TAB}{TAB}{TAB}runOnlyForDeploymentPostprocessing = 0;
{TAB}{TAB}}};
{TAB}{TAB}{ids['phase_test_embed']} /* Embed Frameworks */ = {{
{TAB}{TAB}{TAB}isa = PBXCopyFilesBuildPhase;
{TAB}{TAB}{TAB}buildActionMask = 2147483647;
{TAB}{TAB}{TAB}dstPath = "";
{TAB}{TAB}{TAB}dstSubfolderSpec = 10;
{TAB}{TAB}{TAB}files = (
{TAB}{TAB}{TAB}{TAB}{test_embed} /* {FRAMEWORK_NAME}.framework in Embed Frameworks */,
{TAB}{TAB}{TAB});
{TAB}{TAB}{TAB}name = "Embed Frameworks";
{TAB}{TAB}{TAB}runOnlyForDeploymentPostprocessing = 0;
{TAB}{TAB}}};
/* End PBXCopyFilesBuildPhase section */

/* Begin PBXFileReference section */
{nl.join(p.file_refs)}
{nl.join(product_refs)}
/* End PBXFileReference section */

/* Begin PBXFrameworksBuildPhase section */
{TAB}{TAB}{ids['phase_fw_frameworks']} = {{
{TAB}{TAB}{TAB}isa = PBXFrameworksBuildPhase;
{TAB}{TAB}{TAB}buildActionMask = 2147483647;
{TAB}{TAB}{TAB}files = (
{TAB}{TAB}{TAB});
{TAB}{TAB}{TAB}runOnlyForDeploymentPostprocessing = 0;
{TAB}{TAB}}};
{TAB}{TAB}{ids['phase_app_frameworks']} = {{
{TAB}{TAB}{TAB}isa = PBXFrameworksBuildPhase;
{TAB}{TAB}{TAB}buildActionMask = 2147483647;
{TAB}{TAB}{TAB}files = (
{TAB}{TAB}{TAB}{TAB}{app_link} /* {FRAMEWORK_NAME}.framework in Frameworks */,
{TAB}{TAB}{TAB});
{TAB}{TAB}{TAB}runOnlyForDeploymentPostprocessing = 0;
{TAB}{TAB}}};
{TAB}{TAB}{ids['phase_test_frameworks']} = {{
{TAB}{TAB}{TAB}isa = PBXFrameworksBuildPhase;
{TAB}{TAB}{TAB}buildActionMask = 2147483647;
{TAB}{TAB}{TAB}files = (
{TAB}{TAB}{TAB}{TAB}{test_link} /* {FRAMEWORK_NAME}.framework in Frameworks */,
{TAB}{TAB}{TAB});
{TAB}{TAB}{TAB}runOnlyForDeploymentPostprocessing = 0;
{TAB}{TAB}}};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
{TAB}{TAB}{ids['group_root']} = {{
{TAB}{TAB}{TAB}isa = PBXGroup;
{TAB}{TAB}{TAB}children = (
{TAB}{TAB}{TAB}{TAB}{ids['group_gamecore']} /* GameCore */,
{TAB}{TAB}{TAB}{TAB}{ids['group_app']} /* App */,
{TAB}{TAB}{TAB}{TAB}{ids['group_tests']} /* Tests */,
{TAB}{TAB}{TAB}{TAB}{ids['group_products']} /* Products */,
{TAB}{TAB}{TAB});
{TAB}{TAB}{TAB}sourceTree = "<group>";
{TAB}{TAB}}};
{TAB}{TAB}{ids['group_gamecore']} /* GameCore */ = {{
{TAB}{TAB}{TAB}isa = PBXGroup;
{TAB}{TAB}{TAB}children = (
{listing(refs_of(fw_sources + res))}
{TAB}{TAB}{TAB});
{TAB}{TAB}{TAB}name = GameCore;
{TAB}{TAB}{TAB}sourceTree = "<group>";
{TAB}{TAB}}};
{TAB}{TAB}{ids['group_app']} /* App */ = {{
{TAB}{TAB}{TAB}isa = PBXGroup;
{TAB}{TAB}{TAB}children = (
{listing(refs_of(app_sources))}
{TAB}{TAB}{TAB});
{TAB}{TAB}{TAB}name = App;
{TAB}{TAB}{TAB}sourceTree = "<group>";
{TAB}{TAB}}};
{TAB}{TAB}{ids['group_tests']} /* Tests */ = {{
{TAB}{TAB}{TAB}isa = PBXGroup;
{TAB}{TAB}{TAB}children = (
{listing(refs_of(test_sources))}
{TAB}{TAB}{TAB});
{TAB}{TAB}{TAB}name = Tests;
{TAB}{TAB}{TAB}sourceTree = "<group>";
{TAB}{TAB}}};
{TAB}{TAB}{ids['group_products']} /* Products */ = {{
{TAB}{TAB}{TAB}isa = PBXGroup;
{TAB}{TAB}{TAB}children = (
{TAB}{TAB}{TAB}{TAB}{ids['product_app']} /* {APP_NAME}.app */,
{TAB}{TAB}{TAB}{TAB}{ids['product_fw']} /* {FRAMEWORK_NAME}.framework */,
{TAB}{TAB}{TAB}{TAB}{ids['product_test']} /* {TEST_NAME}.xctest */,
{TAB}{TAB}{TAB});
{TAB}{TAB}{TAB}name = Products;
{TAB}{TAB}{TAB}sourceTree = "<group>";
{TAB}{TAB}}};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
{TAB}{TAB}{ids['target_fw']} /* {FRAMEWORK_NAME} */ = {{
{TAB}{TAB}{TAB}isa = PBXNativeTarget;
{TAB}{TAB}{TAB}buildConfigurationList = {ids['cfg_list_fw']};
{TAB}{TAB}{TAB}buildPhases = (
{TAB}{TAB}{TAB}{TAB}{ids['phase_fw_sources']},
{TAB}{TAB}{TAB}{TAB}{ids['phase_fw_frameworks']},
{TAB}{TAB}{TAB}{TAB}{ids['phase_fw_resources']},
{TAB}{TAB}{TAB});
{TAB}{TAB}{TAB}buildRules = (
{TAB}{TAB}{TAB});
{TAB}{TAB}{TAB}dependencies = (
{TAB}{TAB}{TAB});
{TAB}{TAB}{TAB}name = {FRAMEWORK_NAME};
{TAB}{TAB}{TAB}productName = {FRAMEWORK_NAME};
{TAB}{TAB}{TAB}productReference = {ids['product_fw']} /* {FRAMEWORK_NAME}.framework */;
{TAB}{TAB}{TAB}productType = "com.apple.product-type.framework";
{TAB}{TAB}}};
{TAB}{TAB}{ids['target_app']} /* {APP_NAME} */ = {{
{TAB}{TAB}{TAB}isa = PBXNativeTarget;
{TAB}{TAB}{TAB}buildConfigurationList = {ids['cfg_list_app']};
{TAB}{TAB}{TAB}buildPhases = (
{TAB}{TAB}{TAB}{TAB}{ids['phase_app_sources']},
{TAB}{TAB}{TAB}{TAB}{ids['phase_app_frameworks']},
{TAB}{TAB}{TAB}{TAB}{ids['phase_app_resources']},
{TAB}{TAB}{TAB}{TAB}{ids['phase_app_embed']},
{TAB}{TAB}{TAB});
{TAB}{TAB}{TAB}buildRules = (
{TAB}{TAB}{TAB});
{TAB}{TAB}{TAB}dependencies = (
{TAB}{TAB}{TAB}{TAB}{ids['dep_app_fw']} /* PBXTargetDependency */,
{TAB}{TAB}{TAB});
{TAB}{TAB}{TAB}name = {APP_NAME};
{TAB}{TAB}{TAB}productName = {APP_NAME};
{TAB}{TAB}{TAB}productReference = {ids['product_app']} /* {APP_NAME}.app */;
{TAB}{TAB}{TAB}productType = "com.apple.product-type.application";
{TAB}{TAB}}};
{TAB}{TAB}{ids['target_test']} /* {TEST_NAME} */ = {{
{TAB}{TAB}{TAB}isa = PBXNativeTarget;
{TAB}{TAB}{TAB}buildConfigurationList = {ids['cfg_list_test']};
{TAB}{TAB}{TAB}buildPhases = (
{TAB}{TAB}{TAB}{TAB}{ids['phase_test_sources']},
{TAB}{TAB}{TAB}{TAB}{ids['phase_test_frameworks']},
{TAB}{TAB}{TAB}{TAB}{ids['phase_test_embed']},
{TAB}{TAB}{TAB});
{TAB}{TAB}{TAB}buildRules = (
{TAB}{TAB}{TAB});
{TAB}{TAB}{TAB}dependencies = (
{TAB}{TAB}{TAB}{TAB}{ids['dep_test_fw']} /* PBXTargetDependency */,
{TAB}{TAB}{TAB});
{TAB}{TAB}{TAB}name = {TEST_NAME};
{TAB}{TAB}{TAB}productName = {TEST_NAME};
{TAB}{TAB}{TAB}productReference = {ids['product_test']} /* {TEST_NAME}.xctest */;
{TAB}{TAB}{TAB}productType = "com.apple.product-type.bundle.unit-test";
{TAB}{TAB}}};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
{TAB}{TAB}{ids['project']} /* Project object */ = {{
{TAB}{TAB}{TAB}isa = PBXProject;
{TAB}{TAB}{TAB}attributes = {{
{TAB}{TAB}{TAB}{TAB}BuildIndependentTargetsInParallel = 1;
{TAB}{TAB}{TAB}{TAB}LastSwiftUpdateCheck = 1520;
{TAB}{TAB}{TAB}{TAB}LastUpgradeCheck = 1520;
{TAB}{TAB}{TAB}{TAB}TargetAttributes = {{
{TAB}{TAB}{TAB}{TAB}{TAB}{ids['target_app']} = {{
{TAB}{TAB}{TAB}{TAB}{TAB}{TAB}CreatedOnToolsVersion = 15.2;
{TAB}{TAB}{TAB}{TAB}{TAB}}};
{TAB}{TAB}{TAB}{TAB}{TAB}{ids['target_fw']} = {{
{TAB}{TAB}{TAB}{TAB}{TAB}{TAB}CreatedOnToolsVersion = 15.2;
{TAB}{TAB}{TAB}{TAB}{TAB}}};
{TAB}{TAB}{TAB}{TAB}{TAB}{ids['target_test']} = {{
{TAB}{TAB}{TAB}{TAB}{TAB}{TAB}CreatedOnToolsVersion = 15.2;
{TAB}{TAB}{TAB}{TAB}{TAB}}};
{TAB}{TAB}{TAB}{TAB}}};
{TAB}{TAB}{TAB}}};
{TAB}{TAB}{TAB}buildConfigurationList = {ids['cfg_list_project']};
{TAB}{TAB}{TAB}compatibilityVersion = "Xcode 14.0";
{TAB}{TAB}{TAB}developmentRegion = en;
{TAB}{TAB}{TAB}hasScannedForEncodings = 0;
{TAB}{TAB}{TAB}knownRegions = (
{TAB}{TAB}{TAB}{TAB}en,
{TAB}{TAB}{TAB}{TAB}Base,
{TAB}{TAB}{TAB});
{TAB}{TAB}{TAB}mainGroup = {ids['group_root']};
{TAB}{TAB}{TAB}productRefGroup = {ids['group_products']} /* Products */;
{TAB}{TAB}{TAB}projectDirPath = "";
{TAB}{TAB}{TAB}projectRoot = "";
{TAB}{TAB}{TAB}targets = (
{TAB}{TAB}{TAB}{TAB}{ids['target_fw']} /* {FRAMEWORK_NAME} */,
{TAB}{TAB}{TAB}{TAB}{ids['target_app']} /* {APP_NAME} */,
{TAB}{TAB}{TAB}{TAB}{ids['target_test']} /* {TEST_NAME} */,
{TAB}{TAB}{TAB});
{TAB}{TAB}}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
{TAB}{TAB}{ids['phase_fw_resources']} = {{
{TAB}{TAB}{TAB}isa = PBXResourcesBuildPhase;
{TAB}{TAB}{TAB}buildActionMask = 2147483647;
{TAB}{TAB}{TAB}files = (
{listing(fw_resource_phase)}
{TAB}{TAB}{TAB});
{TAB}{TAB}{TAB}runOnlyForDeploymentPostprocessing = 0;
{TAB}{TAB}}};
{TAB}{TAB}{ids['phase_app_resources']} = {{
{TAB}{TAB}{TAB}isa = PBXResourcesBuildPhase;
{TAB}{TAB}{TAB}buildActionMask = 2147483647;
{TAB}{TAB}{TAB}files = (
{TAB}{TAB}{TAB});
{TAB}{TAB}{TAB}runOnlyForDeploymentPostprocessing = 0;
{TAB}{TAB}}};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
{TAB}{TAB}{ids['phase_fw_sources']} = {{
{TAB}{TAB}{TAB}isa = PBXSourcesBuildPhase;
{TAB}{TAB}{TAB}buildActionMask = 2147483647;
{TAB}{TAB}{TAB}files = (
{listing(fw_source_phase)}
{TAB}{TAB}{TAB});
{TAB}{TAB}{TAB}runOnlyForDeploymentPostprocessing = 0;
{TAB}{TAB}}};
{TAB}{TAB}{ids['phase_app_sources']} = {{
{TAB}{TAB}{TAB}isa = PBXSourcesBuildPhase;
{TAB}{TAB}{TAB}buildActionMask = 2147483647;
{TAB}{TAB}{TAB}files = (
{listing(app_source_phase)}
{TAB}{TAB}{TAB});
{TAB}{TAB}{TAB}runOnlyForDeploymentPostprocessing = 0;
{TAB}{TAB}}};
{TAB}{TAB}{ids['phase_test_sources']} = {{
{TAB}{TAB}{TAB}isa = PBXSourcesBuildPhase;
{TAB}{TAB}{TAB}buildActionMask = 2147483647;
{TAB}{TAB}{TAB}files = (
{listing(test_source_phase)}
{TAB}{TAB}{TAB});
{TAB}{TAB}{TAB}runOnlyForDeploymentPostprocessing = 0;
{TAB}{TAB}}};
/* End PBXSourcesBuildPhase section */

/* Begin PBXTargetDependency section */
{TAB}{TAB}{ids['dep_app_fw']} /* PBXTargetDependency */ = {{
{TAB}{TAB}{TAB}isa = PBXTargetDependency;
{TAB}{TAB}{TAB}target = {ids['target_fw']} /* {FRAMEWORK_NAME} */;
{TAB}{TAB}{TAB}targetProxy = {ids['proxy_app_fw']} /* PBXContainerItemProxy */;
{TAB}{TAB}}};
{TAB}{TAB}{ids['dep_test_fw']} /* PBXTargetDependency */ = {{
{TAB}{TAB}{TAB}isa = PBXTargetDependency;
{TAB}{TAB}{TAB}target = {ids['target_fw']} /* {FRAMEWORK_NAME} */;
{TAB}{TAB}{TAB}targetProxy = {ids['proxy_test_fw']} /* PBXContainerItemProxy */;
{TAB}{TAB}}};
/* End PBXTargetDependency section */

/* Begin XCBuildConfiguration section */
{TAB}{TAB}{ids['cfg_proj_debug']} /* Debug */ = {{
{TAB}{TAB}{TAB}isa = XCBuildConfiguration;
{TAB}{TAB}{TAB}buildSettings = {{
{TAB}{TAB}{TAB}{TAB}ALWAYS_SEARCH_USER_PATHS = NO;
{TAB}{TAB}{TAB}{TAB}CLANG_ENABLE_MODULES = YES;
{TAB}{TAB}{TAB}{TAB}CLANG_ENABLE_OBJC_ARC = YES;
{TAB}{TAB}{TAB}{TAB}COPY_PHASE_STRIP = NO;
{TAB}{TAB}{TAB}{TAB}DEBUG_INFORMATION_FORMAT = dwarf;
{TAB}{TAB}{TAB}{TAB}ENABLE_STRICT_OBJC_MSGSEND = YES;
{TAB}{TAB}{TAB}{TAB}ENABLE_TESTABILITY = YES;
{TAB}{TAB}{TAB}{TAB}GCC_OPTIMIZATION_LEVEL = 0;
{TAB}{TAB}{TAB}{TAB}GCC_PREPROCESSOR_DEFINITIONS = (
{TAB}{TAB}{TAB}{TAB}{TAB}"DEBUG=1",
{TAB}{TAB}{TAB}{TAB}{TAB}"$(inherited)",
{TAB}{TAB}{TAB}{TAB});
{TAB}{TAB}{TAB}{TAB}IPHONEOS_DEPLOYMENT_TARGET = {DEPLOYMENT_TARGET};
{TAB}{TAB}{TAB}{TAB}MTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;
{TAB}{TAB}{TAB}{TAB}ONLY_ACTIVE_ARCH = YES;
{TAB}{TAB}{TAB}{TAB}SDKROOT = iphoneos;
{TAB}{TAB}{TAB}{TAB}SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;
{TAB}{TAB}{TAB}{TAB}SWIFT_OPTIMIZATION_LEVEL = "-Onone";
{TAB}{TAB}{TAB}{TAB}SWIFT_VERSION = {SWIFT_VERSION};
{TAB}{TAB}{TAB}}};
{TAB}{TAB}{TAB}name = Debug;
{TAB}{TAB}}};
{TAB}{TAB}{ids['cfg_proj_release']} /* Release */ = {{
{TAB}{TAB}{TAB}isa = XCBuildConfiguration;
{TAB}{TAB}{TAB}buildSettings = {{
{TAB}{TAB}{TAB}{TAB}ALWAYS_SEARCH_USER_PATHS = NO;
{TAB}{TAB}{TAB}{TAB}CLANG_ENABLE_MODULES = YES;
{TAB}{TAB}{TAB}{TAB}CLANG_ENABLE_OBJC_ARC = YES;
{TAB}{TAB}{TAB}{TAB}COPY_PHASE_STRIP = NO;
{TAB}{TAB}{TAB}{TAB}DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
{TAB}{TAB}{TAB}{TAB}ENABLE_NS_ASSERTIONS = NO;
{TAB}{TAB}{TAB}{TAB}ENABLE_STRICT_OBJC_MSGSEND = YES;
{TAB}{TAB}{TAB}{TAB}ENABLE_TESTABILITY = YES;
{TAB}{TAB}{TAB}{TAB}IPHONEOS_DEPLOYMENT_TARGET = {DEPLOYMENT_TARGET};
{TAB}{TAB}{TAB}{TAB}MTL_ENABLE_DEBUG_INFO = NO;
{TAB}{TAB}{TAB}{TAB}SDKROOT = iphoneos;
{TAB}{TAB}{TAB}{TAB}SWIFT_COMPILATION_MODE = wholemodule;
{TAB}{TAB}{TAB}{TAB}SWIFT_OPTIMIZATION_LEVEL = "-O";
{TAB}{TAB}{TAB}{TAB}SWIFT_VERSION = {SWIFT_VERSION};
{TAB}{TAB}{TAB}{TAB}VALIDATE_PRODUCT = YES;
{TAB}{TAB}{TAB}}};
{TAB}{TAB}{TAB}name = Release;
{TAB}{TAB}}};
{TAB}{TAB}{ids['cfg_fw_debug']} /* Debug */ = {{
{TAB}{TAB}{TAB}isa = XCBuildConfiguration;
{TAB}{TAB}{TAB}buildSettings = {{
{build_settings(fw_settings)}
{TAB}{TAB}{TAB}}};
{TAB}{TAB}{TAB}name = Debug;
{TAB}{TAB}}};
{TAB}{TAB}{ids['cfg_fw_release']} /* Release */ = {{
{TAB}{TAB}{TAB}isa = XCBuildConfiguration;
{TAB}{TAB}{TAB}buildSettings = {{
{build_settings(fw_settings)}
{TAB}{TAB}{TAB}}};
{TAB}{TAB}{TAB}name = Release;
{TAB}{TAB}}};
{TAB}{TAB}{ids['cfg_app_debug']} /* Debug */ = {{
{TAB}{TAB}{TAB}isa = XCBuildConfiguration;
{TAB}{TAB}{TAB}buildSettings = {{
{build_settings(app_settings)}
{TAB}{TAB}{TAB}}};
{TAB}{TAB}{TAB}name = Debug;
{TAB}{TAB}}};
{TAB}{TAB}{ids['cfg_app_release']} /* Release */ = {{
{TAB}{TAB}{TAB}isa = XCBuildConfiguration;
{TAB}{TAB}{TAB}buildSettings = {{
{build_settings(app_settings)}
{TAB}{TAB}{TAB}}};
{TAB}{TAB}{TAB}name = Release;
{TAB}{TAB}}};
{TAB}{TAB}{ids['cfg_test_debug']} /* Debug */ = {{
{TAB}{TAB}{TAB}isa = XCBuildConfiguration;
{TAB}{TAB}{TAB}buildSettings = {{
{build_settings(test_settings)}
{TAB}{TAB}{TAB}}};
{TAB}{TAB}{TAB}name = Debug;
{TAB}{TAB}}};
{TAB}{TAB}{ids['cfg_test_release']} /* Release */ = {{
{TAB}{TAB}{TAB}isa = XCBuildConfiguration;
{TAB}{TAB}{TAB}buildSettings = {{
{build_settings(test_settings)}
{TAB}{TAB}{TAB}}};
{TAB}{TAB}{TAB}name = Release;
{TAB}{TAB}}};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
{TAB}{TAB}{ids['cfg_list_project']} = {{
{TAB}{TAB}{TAB}isa = XCConfigurationList;
{TAB}{TAB}{TAB}buildConfigurations = (
{TAB}{TAB}{TAB}{TAB}{ids['cfg_proj_debug']} /* Debug */,
{TAB}{TAB}{TAB}{TAB}{ids['cfg_proj_release']} /* Release */,
{TAB}{TAB}{TAB});
{TAB}{TAB}{TAB}defaultConfigurationIsVisible = 0;
{TAB}{TAB}{TAB}defaultConfigurationName = Release;
{TAB}{TAB}}};
{TAB}{TAB}{ids['cfg_list_fw']} = {{
{TAB}{TAB}{TAB}isa = XCConfigurationList;
{TAB}{TAB}{TAB}buildConfigurations = (
{TAB}{TAB}{TAB}{TAB}{ids['cfg_fw_debug']} /* Debug */,
{TAB}{TAB}{TAB}{TAB}{ids['cfg_fw_release']} /* Release */,
{TAB}{TAB}{TAB});
{TAB}{TAB}{TAB}defaultConfigurationIsVisible = 0;
{TAB}{TAB}{TAB}defaultConfigurationName = Release;
{TAB}{TAB}}};
{TAB}{TAB}{ids['cfg_list_app']} = {{
{TAB}{TAB}{TAB}isa = XCConfigurationList;
{TAB}{TAB}{TAB}buildConfigurations = (
{TAB}{TAB}{TAB}{TAB}{ids['cfg_app_debug']} /* Debug */,
{TAB}{TAB}{TAB}{TAB}{ids['cfg_app_release']} /* Release */,
{TAB}{TAB}{TAB});
{TAB}{TAB}{TAB}defaultConfigurationIsVisible = 0;
{TAB}{TAB}{TAB}defaultConfigurationName = Release;
{TAB}{TAB}}};
{TAB}{TAB}{ids['cfg_list_test']} = {{
{TAB}{TAB}{TAB}isa = XCConfigurationList;
{TAB}{TAB}{TAB}buildConfigurations = (
{TAB}{TAB}{TAB}{TAB}{ids['cfg_test_debug']} /* Debug */,
{TAB}{TAB}{TAB}{TAB}{ids['cfg_test_release']} /* Release */,
{TAB}{TAB}{TAB});
{TAB}{TAB}{TAB}defaultConfigurationIsVisible = 0;
{TAB}{TAB}{TAB}defaultConfigurationName = Release;
{TAB}{TAB}}};
/* End XCConfigurationList section */
{TAB}}};
{TAB}rootObject = {ids['project']} /* Project object */;
}}
"""


def scheme() -> str:
    app_id = oid("obj", "target_app")
    test_id = oid("obj", "target_test")
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "1520" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{app_id}"
               BuildableName = "{APP_NAME}.app"
               BlueprintName = "{APP_NAME}"
               ReferencedContainer = "container:{APP_NAME}.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
         <TestableReference skipped = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{test_id}"
               BuildableName = "{TEST_NAME}.xctest"
               BlueprintName = "{TEST_NAME}"
               ReferencedContainer = "container:{APP_NAME}.xcodeproj">
            </BuildableReference>
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{app_id}"
            BuildableName = "{APP_NAME}.app"
            BlueprintName = "{APP_NAME}"
            ReferencedContainer = "container:{APP_NAME}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{app_id}"
            BuildableName = "{APP_NAME}.app"
            BlueprintName = "{APP_NAME}"
            ReferencedContainer = "container:{APP_NAME}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug"></AnalyzeAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES"></ArchiveAction>
</Scheme>
"""


def main() -> int:
    # Overwrite in place rather than rmtree + recreate: Xcode holds the project
    # open (workspace state, xcuserdata) with permissions this script can't
    # always touch, and it doesn't need to — only project.pbxproj and the
    # shared scheme are generated content.
    PROJECT.mkdir(parents=True, exist_ok=True)
    (PROJECT / "project.pbxproj").write_text(generate(), encoding="utf-8")

    shared = PROJECT / "xcshareddata" / "xcschemes"
    shared.mkdir(parents=True, exist_ok=True)
    (shared / f"{APP_NAME}.xcscheme").write_text(scheme(), encoding="utf-8")

    print(f"wrote {PROJECT.relative_to(ROOT)}")
    print(f"  {FRAMEWORK_NAME}: {len(swift_in(FRAMEWORK_DIR))} Swift files, {len(resources())} resources")
    print(f"  {APP_NAME}: {len(swift_in(APP_DIR))} Swift files")
    print(f"  {TEST_NAME}: {len(swift_in(TEST_DIR))} Swift files")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
