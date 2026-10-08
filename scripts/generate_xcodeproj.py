#!/usr/bin/env python3
"""Generates Worklog.xcodeproj (project.pbxproj + shared scheme) from the files on disk.

You don't need this when working in Xcode — just open Worklog.xcodeproj and add files there as usual.
It exists so the project can be regenerated without a Mac (e.g. by tooling on Linux) after files are
added or removed:   python3 scripts/generate_xcodeproj.py

The committed Worklog.xcodeproj is exactly this script's output. Build settings live HERE: a setting changed
in Xcode's editor (version, bundle id, entitlements, signing) is lost the next time the project is
regenerated unless it is mirrored in this file.

Object IDs are derived from stable keys, so regenerating an unchanged tree produces an identical file.
"""
import hashlib
import os
import string
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJECT = "Worklog"
APP_DIR = "Worklog"
TEST_DIR = "WorklogTests"
DEVELOPMENT_TEAM = "6W4ZKDHBVD"  # requires a paid Apple Developer Program team (iCloud + Sign in with Apple)
BUNDLE_ID = "app.dabora.worktracker"  # Release; Debug appends ".debug" (also AppConstants.bundleID)
DEBUG_BUNDLE_ID = f"{BUNDLE_ID}.debug"  # own sandbox container, store, backups, defaults and keychain items
MARKETING_VERSION = "1.0.1"  # CFBundleShortVersionString (Info.plist uses $(MARKETING_VERSION))
CURRENT_PROJECT_VERSION = "1"  # CFBundleVersion
DEPLOYMENT_TARGET = "14.0"

# Files that live in the source tree but must not be compiled or copied as resources.
NOT_IN_BUILD_PHASES = {"Info.plist"}


def oid(key):
    return hashlib.md5(key.encode()).hexdigest()[:24].upper()


def q(value):
    """Quote a pbxproj string when needed."""
    s = str(value)
    if s and all(c in string.ascii_letters + string.digits + "._/" for c in s) and not s.startswith("//"):
        return s
    s = s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
    return f'"{s}"'


def file_type(name):
    ext = os.path.splitext(name)[1]
    return {
        ".swift": "sourcecode.swift",
        ".xcassets": "folder.assetcatalog",
        ".plist": "text.plist.xml",
        ".entitlements": "text.plist.entitlements",
        ".xcconfig": "text.xcconfig",
        ".json": "text.json",
        ".md": "net.daringfireball.markdown",
    }.get(ext, "text")


class Builder:
    def __init__(self):
        self.objects = {}  # id -> (isa, dict)

    def add(self, key, isa, fields):
        i = oid(key)
        self.objects[i] = (isa, fields)
        return i

    def render(self, root_id):
        out = ["// !$*UTF8*$!", "{", "\tarchiveVersion = 1;", "\tclasses = {", "\t};", "\tobjectVersion = 56;", "\tobjects = {"]
        by_isa = {}
        for i, (isa, fields) in self.objects.items():
            by_isa.setdefault(isa, []).append((i, fields))
        for isa in sorted(by_isa):
            out.append("")
            out.append(f"/* Begin {isa} section */")
            for i, fields in sorted(by_isa[isa], key=lambda t: t[0]):
                out.append(f"\t\t{i} = {{")
                out.append(f"\t\t\tisa = {isa};")
                for k in sorted(fields):
                    out.extend(self._field(k, fields[k], 3))
                out.append("\t\t};")
            out.append(f"/* End {isa} section */")
        out.append("\t};")
        out.append(f"\trootObject = {root_id};")
        out.append("}")
        return "\n".join(out) + "\n"

    def _field(self, key, value, depth):
        tab = "\t" * depth
        if isinstance(value, dict):
            lines = [f"{tab}{q(key)} = {{"]
            for k in sorted(value):
                lines.extend(self._field(k, value[k], depth + 1))
            lines.append(f"{tab}}};")
            return lines
        if isinstance(value, list):
            lines = [f"{tab}{q(key)} = ("]
            for v in value:
                lines.append(f"{tab}\t{q(v)},")
            lines.append(f"{tab});")
            return lines
        return [f"{tab}{q(key)} = {q(value)};"]


def walk(rel_dir):
    """Returns (subdirs, files) of rel_dir, treating *.xcassets as files. Sorted, hidden entries skipped."""
    full = os.path.join(ROOT, rel_dir)
    dirs, files = [], []
    for name in sorted(os.listdir(full)):
        if name.startswith("."):
            continue
        path = os.path.join(full, name)
        if os.path.isdir(path) and not name.endswith((".xcassets", ".xcdatamodeld", ".bundle")):
            dirs.append(name)
        else:
            files.append(name)
    return dirs, files


def main():
    b = Builder()
    app_sources, app_resources, test_sources = [], [], []

    def make_group(rel_dir, target):
        """Creates a group mirroring rel_dir; returns its id. Collects build files for `target`."""
        dirs, files = walk(rel_dir)
        children = []
        for d in dirs:
            children.append(make_group(os.path.join(rel_dir, d), target))
        for f in files:
            rel = os.path.join(rel_dir, f)
            ref = b.add(f"ref:{rel}", "PBXFileReference", {
                "lastKnownFileType": file_type(f), "path": f, "sourceTree": "<group>",
            })
            children.append(ref)
            if f in NOT_IN_BUILD_PHASES:
                continue
            if f.endswith(".swift"):
                bf = b.add(f"build:{rel}", "PBXBuildFile", {"fileRef": ref})
                (app_sources if target == "app" else test_sources).append(bf)
            elif target == "app" and not f.endswith(".entitlements"):
                # Asset catalogs, string catalogs, JSON etc. are bundled as resources.
                app_resources.append(b.add(f"build:{rel}", "PBXBuildFile", {"fileRef": ref}))
        return b.add(f"group:{rel_dir}", "PBXGroup", {
            "children": children, "path": os.path.basename(rel_dir), "sourceTree": "<group>",
        })

    app_group = make_group(APP_DIR, "app")
    test_group = make_group(TEST_DIR, "test")

    docs = [f for f in ["README.md"] if os.path.exists(os.path.join(ROOT, f))]
    doc_refs = [b.add(f"ref:{f}", "PBXFileReference", {
        "lastKnownFileType": file_type(f), "path": f, "sourceTree": "<group>",
    }) for f in docs]

    app_product = b.add("product:app", "PBXFileReference", {
        "explicitFileType": "wrapper.application", "includeInIndex": "0",
        "path": f"{PROJECT}.app", "sourceTree": "BUILT_PRODUCTS_DIR",
    })
    test_product = b.add("product:tests", "PBXFileReference", {
        "explicitFileType": "wrapper.cfbundle", "includeInIndex": "0",
        "path": f"{TEST_DIR}.xctest", "sourceTree": "BUILT_PRODUCTS_DIR",
    })
    products_group = b.add("group:Products", "PBXGroup", {
        "children": [app_product, test_product], "name": "Products", "sourceTree": "<group>",
    })
    main_group = b.add("group:main", "PBXGroup", {
        "children": doc_refs + [app_group, test_group, products_group], "sourceTree": "<group>",
    })

    # Build phases
    app_src_phase = b.add("phase:app:sources", "PBXSourcesBuildPhase", {
        "buildActionMask": "2147483647", "files": app_sources, "runOnlyForDeploymentPostprocessing": "0"})
    app_fw_phase = b.add("phase:app:frameworks", "PBXFrameworksBuildPhase", {
        "buildActionMask": "2147483647", "files": [], "runOnlyForDeploymentPostprocessing": "0"})
    app_res_phase = b.add("phase:app:resources", "PBXResourcesBuildPhase", {
        "buildActionMask": "2147483647", "files": app_resources, "runOnlyForDeploymentPostprocessing": "0"})
    test_src_phase = b.add("phase:test:sources", "PBXSourcesBuildPhase", {
        "buildActionMask": "2147483647", "files": test_sources, "runOnlyForDeploymentPostprocessing": "0"})
    test_fw_phase = b.add("phase:test:frameworks", "PBXFrameworksBuildPhase", {
        "buildActionMask": "2147483647", "files": [], "runOnlyForDeploymentPostprocessing": "0"})
    test_res_phase = b.add("phase:test:resources", "PBXResourcesBuildPhase", {
        "buildActionMask": "2147483647", "files": [], "runOnlyForDeploymentPostprocessing": "0"})

    # Build settings
    project_common = {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS": "YES",
        "CLANG_ANALYZER_NONNULL": "YES",
        "CLANG_CXX_LANGUAGE_STANDARD": "gnu++20",
        "CLANG_ENABLE_MODULES": "YES",
        "CLANG_ENABLE_OBJC_ARC": "YES",
        "CLANG_ENABLE_OBJC_WEAK": "YES",
        "CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING": "YES",
        "CLANG_WARN_BOOL_CONVERSION": "YES",
        "CLANG_WARN_COMMA": "YES",
        "CLANG_WARN_CONSTANT_CONVERSION": "YES",
        "CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS": "YES",
        "CLANG_WARN_DIRECT_OBJC_ISA_USAGE": "YES_ERROR",
        "CLANG_WARN_DOCUMENTATION_COMMENTS": "YES",
        "CLANG_WARN_EMPTY_BODY": "YES",
        "CLANG_WARN_ENUM_CONVERSION": "YES",
        "CLANG_WARN_INFINITE_RECURSION": "YES",
        "CLANG_WARN_INT_CONVERSION": "YES",
        "CLANG_WARN_NON_LITERAL_NULL_CONVERSION": "YES",
        "CLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF": "YES",
        "CLANG_WARN_OBJC_LITERAL_CONVERSION": "YES",
        "CLANG_WARN_OBJC_ROOT_CLASS": "YES_ERROR",
        "CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER": "YES",
        "CLANG_WARN_RANGE_LOOP_ANALYSIS": "YES",
        "CLANG_WARN_STRICT_PROTOTYPES": "YES",
        "CLANG_WARN_SUSPICIOUS_MOVE": "YES",
        "CLANG_WARN_UNGUARDED_AVAILABILITY": "YES_AGGRESSIVE",
        "CLANG_WARN_UNREACHABLE_CODE": "YES",
        "CLANG_WARN__DUPLICATE_METHOD": "YES",
        "COPY_PHASE_STRIP": "NO",
        "DEAD_CODE_STRIPPING": "YES",
        "ENABLE_STRICT_OBJC_MSGSEND": "YES",
        "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
        "GCC_C_LANGUAGE_STANDARD": "gnu17",
        "GCC_NO_COMMON_BLOCKS": "YES",
        "GCC_WARN_64_TO_32_BIT_CONVERSION": "YES",
        "GCC_WARN_ABOUT_RETURN_TYPE": "YES_ERROR",
        "GCC_WARN_UNDECLARED_SELECTOR": "YES",
        "GCC_WARN_UNINITIALIZED_AUTOS": "YES_AGGRESSIVE",
        "GCC_WARN_UNUSED_FUNCTION": "YES",
        "GCC_WARN_UNUSED_VARIABLE": "YES",
        "LOCALIZATION_PREFERS_STRING_CATALOGS": "YES",
        "MACOSX_DEPLOYMENT_TARGET": DEPLOYMENT_TARGET,
        "MTL_FAST_MATH": "YES",
        "SDKROOT": "macosx",
        "SWIFT_STRICT_CONCURRENCY": "minimal",
        "SWIFT_VERSION": "5.0",
    }
    project_debug = dict(project_common, **{
        "DEBUG_INFORMATION_FORMAT": "dwarf",
        "ENABLE_TESTABILITY": "YES",
        "GCC_DYNAMIC_NO_PIC": "NO",
        "GCC_OPTIMIZATION_LEVEL": "0",
        "GCC_PREPROCESSOR_DEFINITIONS": ["DEBUG=1", "$(inherited)"],
        "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
        "ONLY_ACTIVE_ARCH": "YES",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG $(inherited)",
        "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
    })
    project_release = dict(project_common, **{
        "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
        "ENABLE_NS_ASSERTIONS": "NO",
        "MTL_ENABLE_DEBUG_INFO": "NO",
        "SWIFT_COMPILATION_MODE": "wholemodule",
    })
    app_settings = {
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
        # Literal values (not variables) so Xcode's Signing & Capabilities editor can read the entitlements.
        "CODE_SIGN_ENTITLEMENTS": f"{APP_DIR}/Resources/Worklog.entitlements",
        "CODE_SIGN_IDENTITY": "Apple Development",
        "CODE_SIGN_STYLE": "Automatic",
        "COMBINE_HIDPI_IMAGES": "YES",
        "CURRENT_PROJECT_VERSION": CURRENT_PROJECT_VERSION,
        "DEVELOPMENT_TEAM": DEVELOPMENT_TEAM,
        "ENABLE_PREVIEWS": "YES",
        "GENERATE_INFOPLIST_FILE": "NO",
        "INFOPLIST_FILE": f"{APP_DIR}/Resources/Info.plist",
        "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/../Frameworks"],
        "MARKETING_VERSION": MARKETING_VERSION,
        "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID,
        "PRODUCT_NAME": "$(TARGET_NAME)",
        "SWIFT_EMIT_LOC_STRINGS": "YES",
    }
    test_settings = {
        "BUNDLE_LOADER": "$(TEST_HOST)",
        "CODE_SIGN_IDENTITY": "Apple Development",
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": CURRENT_PROJECT_VERSION,
        "DEVELOPMENT_TEAM": DEVELOPMENT_TEAM,
        "GENERATE_INFOPLIST_FILE": "YES",
        "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/../Frameworks", "@loader_path/../Frameworks"],
        "MARKETING_VERSION": MARKETING_VERSION,
        "PRODUCT_BUNDLE_IDENTIFIER": f"{BUNDLE_ID}.tests",
        "PRODUCT_NAME": "$(TARGET_NAME)",
        "SWIFT_EMIT_LOC_STRINGS": "NO",
        "TEST_HOST": f"$(BUILT_PRODUCTS_DIR)/{PROJECT}.app/Contents/MacOS/{PROJECT}",
    }

    def config_list(key, settings_by_config, base_ref=None):
        ids = []
        for name, settings in settings_by_config:
            fields = {"buildSettings": settings, "name": name}
            if base_ref:
                fields["baseConfigurationReference"] = base_ref
            ids.append(b.add(f"config:{key}:{name}", "XCBuildConfiguration", fields))
        return b.add(f"configlist:{key}", "XCConfigurationList", {
            "buildConfigurations": ids, "defaultConfigurationIsVisible": "0", "defaultConfigurationName": "Release",
        })

    project_configs = config_list("project", [("Debug", project_debug), ("Release", project_release)])
    # Hardened runtime is for distribution; Debug leaves it off so the test bundle always loads into the host app.
    # Debug: its own bundle id (never opens the real store) and Worklog.entitlements (CloudKit Development).
    # Release: WorklogRelease.entitlements (CloudKit Production; aps-environment is set to production by the Developer ID export) for Developer ID distribution.
    app_debug = dict(app_settings, ENABLE_HARDENED_RUNTIME="NO", PRODUCT_BUNDLE_IDENTIFIER=DEBUG_BUNDLE_ID)
    app_release = dict(app_settings, ENABLE_HARDENED_RUNTIME="YES",
                       CODE_SIGN_ENTITLEMENTS=f"{APP_DIR}/Resources/WorklogRelease.entitlements")
    app_configs = config_list("app", [("Debug", app_debug), ("Release", app_release)])
    test_configs = config_list("tests", [("Debug", test_settings), ("Release", test_settings)])

    project_id = oid("project")
    app_target = b.add("target:app", "PBXNativeTarget", {
        "buildConfigurationList": app_configs,
        "buildPhases": [app_src_phase, app_fw_phase, app_res_phase],
        "buildRules": [], "dependencies": [], "name": PROJECT,
        "productName": PROJECT, "productReference": app_product,
        "productType": "com.apple.product-type.application",
    })
    proxy = b.add("proxy:app", "PBXContainerItemProxy", {
        "containerPortal": project_id, "proxyType": "1",
        "remoteGlobalIDString": app_target, "remoteInfo": PROJECT,
    })
    dependency = b.add("dependency:tests->app", "PBXTargetDependency", {"target": app_target, "targetProxy": proxy})
    test_target = b.add("target:tests", "PBXNativeTarget", {
        "buildConfigurationList": test_configs,
        "buildPhases": [test_src_phase, test_fw_phase, test_res_phase],
        "buildRules": [], "dependencies": [dependency], "name": TEST_DIR,
        "productName": TEST_DIR, "productReference": test_product,
        "productType": "com.apple.product-type.bundle.unit-test",
    })
    b.objects[project_id] = ("PBXProject", {
        "attributes": {
            "BuildIndependentTargetsInParallel": "1",
            "LastSwiftUpdateCheck": "1600",
            "LastUpgradeCheck": "1600",
            "TargetAttributes": {
                app_target: {"CreatedOnToolsVersion": "16.0"},
                test_target: {"CreatedOnToolsVersion": "16.0", "TestTargetID": app_target},
            },
        },
        "buildConfigurationList": project_configs,
        "compatibilityVersion": "Xcode 14.0",
        "developmentRegion": "en",
        "hasScannedForEncodings": "0",
        "knownRegions": ["en", "Base"],
        "mainGroup": main_group,
        "productRefGroup": products_group,
        "projectDirPath": "",
        "projectRoot": "",
        "targets": [app_target, test_target],
    })

    proj_dir = os.path.join(ROOT, f"{PROJECT}.xcodeproj")
    os.makedirs(os.path.join(proj_dir, "project.xcworkspace", "xcshareddata"), exist_ok=True)
    os.makedirs(os.path.join(proj_dir, "xcshareddata", "xcschemes"), exist_ok=True)
    with open(os.path.join(proj_dir, "project.pbxproj"), "w") as fh:
        fh.write(b.render(project_id))
    with open(os.path.join(proj_dir, "project.xcworkspace", "contents.xcworkspacedata"), "w") as fh:
        fh.write('<?xml version="1.0" encoding="UTF-8"?>\n<Workspace\n   version = "1.0">\n'
                 '   <FileRef\n      location = "self:">\n   </FileRef>\n</Workspace>\n')
    with open(os.path.join(proj_dir, "project.xcworkspace", "xcshareddata", "IDEWorkspaceChecks.plist"), "w") as fh:
        fh.write('<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
                 '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n'
                 '\t<key>IDEDidComputeMac32BitWarning</key>\n\t<true/>\n</dict>\n</plist>\n')
    with open(os.path.join(proj_dir, "xcshareddata", "xcschemes", f"{PROJECT}.xcscheme"), "w") as fh:
        fh.write(scheme(app_target, test_target))
    print(f"Wrote {PROJECT}.xcodeproj: {len(app_sources)} app sources, {len(test_sources)} test sources, "
          f"{len(app_resources)} resources")


def scheme(app_id, test_id):
    def ref(target_id, product, name):
        return (f'            <BuildableReference\n               BuildableIdentifier = "primary"\n'
                f'               BlueprintIdentifier = "{target_id}"\n               BuildableName = "{product}"\n'
                f'               BlueprintName = "{name}"\n               ReferencedContainer = "container:{PROJECT}.xcodeproj">\n'
                f'            </BuildableReference>\n')
    app_ref = ref(app_id, f"{PROJECT}.app", PROJECT)
    test_ref = ref(test_id, f"{TEST_DIR}.xctest", TEST_DIR)
    runnable_ref = "".join(line[3:] + "\n" for line in app_ref.splitlines())
    return f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1600"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
{app_ref}         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES"
      codeCoverageEnabled = "YES">
      <Testables>
         <TestableReference
            skipped = "NO"
            parallelizable = "YES">
{test_ref}         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
{runnable_ref}      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
{runnable_ref}      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
'''


if __name__ == "__main__":
    main()
