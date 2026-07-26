#!/usr/bin/env python3
"""Generate MessageSlots.xcodeproj for the iOS prototype app.

The Swift package (`Package.swift`) stays the source of truth for the engine and
its tests — `swift test` works with no Xcode at all. This script exists only so
the prototype can be run on a simulator: it produces a plain iOS app target that
compiles the GameCore sources *directly*, alongside the App/ sources, plus the
compiled word-pool JSON as a bundle resource.

Compiling the engine into the app rather than linking the package keeps the
project file simple and dependency-free, and `WordPool.bundled` already resolves
its resource from either bundle.

Regenerate after adding or renaming source files:

    python3 tools/generate_xcodeproj.py
"""

from __future__ import annotations

import hashlib
import pathlib
import shutil

ROOT = pathlib.Path(__file__).resolve().parent.parent
PROJECT = ROOT / "MessageSlots.xcodeproj"

APP_NAME = "MessageSlots"
BUNDLE_ID = "com.messageslots.prototype"
DEPLOYMENT_TARGET = "17.0"

SOURCE_DIRS = [ROOT / "Sources" / "GameCore", ROOT / "App"]
RESOURCE_DIR = ROOT / "Sources" / "GameCore" / "Resources"


def oid(*parts: str) -> str:
    """Stable 24-hex-character object id, so regeneration produces a clean diff."""
    return hashlib.sha1("::".join(parts).encode()).hexdigest()[:24].upper()


def swift_sources() -> list[pathlib.Path]:
    files: list[pathlib.Path] = []
    for directory in SOURCE_DIRS:
        files.extend(sorted(p for p in directory.rglob("*.swift")))
    return files


def resources() -> list[pathlib.Path]:
    return sorted(RESOURCE_DIR.glob("*.json"))


def generate() -> str:
    sources = swift_sources()
    res = resources()
    if not sources:
        raise SystemExit("no Swift sources found")

    file_refs, build_files, source_phase, resource_phase, group_children = [], [], [], [], []

    for path in sources + res:
        rel = path.relative_to(ROOT).as_posix()
        ref = oid("ref", rel)
        build = oid("build", rel)
        ftype = "sourcecode.swift" if path.suffix == ".swift" else "text.json"
        file_refs.append(
            f'\t\t{ref} /* {path.name} */ = {{isa = PBXFileReference; lastKnownFileType = {ftype}; '
            f'name = "{path.name}"; path = "{rel}"; sourceTree = "<group>"; }};'
        )
        build_files.append(
            f'\t\t{build} /* {path.name} */ = {{isa = PBXBuildFile; fileRef = {ref} /* {path.name} */; }};'
        )
        group_children.append(f"\t\t\t\t{ref} /* {path.name} */,")
        (source_phase if path.suffix == ".swift" else resource_phase).append(
            f"\t\t\t\t{build} /* {path.name} */,"
        )

    ids = {
        key: oid("obj", key)
        for key in [
            "project", "target", "group_root", "group_src", "group_products",
            "product", "phase_sources", "phase_resources", "phase_frameworks",
            "cfg_list_project", "cfg_list_target",
            "cfg_proj_debug", "cfg_proj_release", "cfg_tgt_debug", "cfg_tgt_release",
        ]
    }

    nl = "\n"
    return f"""// !$*UTF8*$!
{{
	archiveVersion = 1;
	classes = {{
	}};
	objectVersion = 56;
	objects = {{

/* Begin PBXBuildFile section */
{nl.join(build_files)}
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
{nl.join(file_refs)}
		{ids['product']} /* {APP_NAME}.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = {APP_NAME}.app; sourceTree = BUILT_PRODUCTS_DIR; }};
/* End PBXFileReference section */

/* Begin PBXFrameworksBuildPhase section */
		{ids['phase_frameworks']} = {{
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
		{ids['group_root']} = {{
			isa = PBXGroup;
			children = (
				{ids['group_src']} /* Sources */,
				{ids['group_products']} /* Products */,
			);
			sourceTree = "<group>";
		}};
		{ids['group_src']} /* Sources */ = {{
			isa = PBXGroup;
			children = (
{nl.join(group_children)}
			);
			name = Sources;
			sourceTree = "<group>";
		}};
		{ids['group_products']} /* Products */ = {{
			isa = PBXGroup;
			children = (
				{ids['product']} /* {APP_NAME}.app */,
			);
			name = Products;
			sourceTree = "<group>";
		}};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		{ids['target']} /* {APP_NAME} */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {ids['cfg_list_target']};
			buildPhases = (
				{ids['phase_sources']},
				{ids['phase_frameworks']},
				{ids['phase_resources']},
			);
			buildRules = (
			);
			dependencies = (
			);
			name = {APP_NAME};
			productName = {APP_NAME};
			productReference = {ids['product']} /* {APP_NAME}.app */;
			productType = "com.apple.product-type.application";
		}};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		{ids['project']} /* Project object */ = {{
			isa = PBXProject;
			attributes = {{
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 1520;
				LastUpgradeCheck = 1520;
				TargetAttributes = {{
					{ids['target']} = {{
						CreatedOnToolsVersion = 15.2;
					}};
				}};
			}};
			buildConfigurationList = {ids['cfg_list_project']};
			compatibilityVersion = "Xcode 14.0";
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				Base,
			);
			mainGroup = {ids['group_root']};
			productRefGroup = {ids['group_products']} /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				{ids['target']} /* {APP_NAME} */,
			);
		}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
		{ids['phase_resources']} = {{
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
{nl.join(resource_phase)}
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
		{ids['phase_sources']} = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
{nl.join(source_phase)}
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
		{ids['cfg_proj_debug']} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = dwarf;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				ENABLE_TESTABILITY = YES;
				GCC_OPTIMIZATION_LEVEL = 0;
				GCC_PREPROCESSOR_DEFINITIONS = (
					"DEBUG=1",
					"$(inherited)",
				);
				IPHONEOS_DEPLOYMENT_TARGET = {DEPLOYMENT_TARGET};
				MTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;
				ONLY_ACTIVE_ARCH = YES;
				SDKROOT = iphoneos;
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;
				SWIFT_OPTIMIZATION_LEVEL = "-Onone";
				SWIFT_VERSION = 5.0;
			}};
			name = Debug;
		}};
		{ids['cfg_proj_release']} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
				ENABLE_NS_ASSERTIONS = NO;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				IPHONEOS_DEPLOYMENT_TARGET = {DEPLOYMENT_TARGET};
				MTL_ENABLE_DEBUG_INFO = NO;
				SDKROOT = iphoneos;
				SWIFT_COMPILATION_MODE = wholemodule;
				SWIFT_OPTIMIZATION_LEVEL = "-O";
				SWIFT_VERSION = 5.0;
				VALIDATE_PRODUCT = YES;
			}};
			name = Release;
		}};
		{ids['cfg_tgt_debug']} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				DEVELOPMENT_TEAM = "";
				ENABLE_PREVIEWS = YES;
				GENERATE_INFOPLIST_FILE = YES;
				INFOPLIST_KEY_UILaunchScreen_Generation = YES;
				INFOPLIST_KEY_UISupportedInterfaceOrientations = UIInterfaceOrientationPortrait;
				IPHONEOS_DEPLOYMENT_TARGET = {DEPLOYMENT_TARGET};
				MARKETING_VERSION = 0.1;
				PRODUCT_BUNDLE_IDENTIFIER = {BUNDLE_ID};
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_EMIT_LOC_STRINGS = YES;
				SWIFT_VERSION = 5.0;
				TARGETED_DEVICE_FAMILY = "1,2";
			}};
			name = Debug;
		}};
		{ids['cfg_tgt_release']} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				DEVELOPMENT_TEAM = "";
				ENABLE_PREVIEWS = YES;
				GENERATE_INFOPLIST_FILE = YES;
				INFOPLIST_KEY_UILaunchScreen_Generation = YES;
				INFOPLIST_KEY_UISupportedInterfaceOrientations = UIInterfaceOrientationPortrait;
				IPHONEOS_DEPLOYMENT_TARGET = {DEPLOYMENT_TARGET};
				MARKETING_VERSION = 0.1;
				PRODUCT_BUNDLE_IDENTIFIER = {BUNDLE_ID};
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_EMIT_LOC_STRINGS = YES;
				SWIFT_VERSION = 5.0;
				TARGETED_DEVICE_FAMILY = "1,2";
			}};
			name = Release;
		}};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		{ids['cfg_list_project']} = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{ids['cfg_proj_debug']} /* Debug */,
				{ids['cfg_proj_release']} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
		{ids['cfg_list_target']} = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{ids['cfg_tgt_debug']} /* Debug */,
				{ids['cfg_tgt_release']} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
/* End XCConfigurationList section */
	}};
	rootObject = {ids['project']} /* Project object */;
}}
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
    print(f"  {len(swift_sources())} Swift files, {len(resources())} resources")
    return 0


def scheme() -> str:
    target_id = oid("obj", "target")
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "1520" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{target_id}"
               BuildableName = "{APP_NAME}.app"
               BlueprintName = "{APP_NAME}"
               ReferencedContainer = "container:{APP_NAME}.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{target_id}"
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
            BlueprintIdentifier = "{target_id}"
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


if __name__ == "__main__":
    raise SystemExit(main())
