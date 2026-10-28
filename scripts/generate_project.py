#!/usr/bin/env python3
"""Generate the dependency-free Xcode project from checked-in source files."""
import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parent.parent
release = json.loads((root / 'Configuration/Release.json').read_text())
project = root / 'Hongguo.xcodeproj'
project.mkdir(exist_ok=True)

def uid(value):
    return hashlib.sha1(value.encode()).hexdigest()[:24].upper()

def quote(value):
    return json.dumps(str(value), ensure_ascii=False)

objects = {}
sources = sorted((root / 'Sources').rglob('*.swift'))
resources = sorted((root / 'Sources').rglob('*.js'))
resources += sorted(p for p in (root / 'Resources').glob('*') if p.is_file() or p.suffix == '.xcassets')
source_builds, resource_builds, file_refs = [], [], []
for paths, phase, builds in [(sources, 'source', source_builds), (resources, 'resource', resource_builds)]:
    for path in paths:
        rel = path.relative_to(root).as_posix()
        file_id, build_id = uid('file:' + rel), uid('build:' + rel)
        filetype = 'sourcecode.swift' if phase == 'source' else ('folder.assetcatalog' if path.suffix == '.xcassets' else 'text')
        objects[file_id] = f'{{isa = PBXFileReference; lastKnownFileType = {filetype}; path = {quote(rel)}; sourceTree = "<group>"; }}'
        objects[build_id] = f'{{isa = PBXBuildFile; fileRef = {file_id}; }}'
        file_refs.append(file_id)
        builds.append(build_id)

product, products, group, source_phase, resource_phase, framework_phase, target, proj = [uid(x) for x in
    ('product', 'products', 'group', 'sources', 'resources', 'frameworks', 'target', 'project')]
objects[product] = '{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Hongguo.app; sourceTree = BUILT_PRODUCTS_DIR; }'
objects[products] = f'{{isa = PBXGroup; children = ({product},); name = Products; sourceTree = "<group>"; }}'
objects[group] = f'{{isa = PBXGroup; children = ({",".join(file_refs + [products])},); sourceTree = "<group>"; }}'
objects[source_phase] = f'{{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(source_builds)},); runOnlyForDeploymentPostprocessing = 0; }}'
objects[resource_phase] = f'{{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(resource_builds)},); runOnlyForDeploymentPostprocessing = 0; }}'
objects[framework_phase] = '{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }'

project_configs, target_configs = [], []
for config in ('Debug', 'Release'):
    pc, tc = uid('project:' + config), uid('target:' + config)
    project_configs.append(pc); target_configs.append(tc)
    objects[pc] = '{isa = XCBuildConfiguration; buildSettings = {CLANG_ENABLE_MODULES = YES; SWIFT_VERSION = 5.0; IPHONEOS_DEPLOYMENT_TARGET = ' + release['minimumOSVersion'] + '; SDKROOT = iphoneos; }; name = ' + config + '; }'
    settings = {
        'PRODUCT_NAME': 'Hongguo', 'PRODUCT_BUNDLE_IDENTIFIER': 'com.ooiua.hongguo.ios',
        'INFOPLIST_FILE': 'Configuration/Info.plist', 'GENERATE_INFOPLIST_FILE': 'NO',
        'CURRENT_PROJECT_VERSION': str(release['build']), 'MARKETING_VERSION': release['version'],
        'CODE_SIGNING_ALLOWED': 'NO', 'CODE_SIGNING_REQUIRED': 'NO', 'CODE_SIGN_IDENTITY': '',
        'TARGETED_DEVICE_FAMILY': '1', 'SUPPORTED_PLATFORMS': 'iphoneos iphonesimulator',
        'SUPPORTS_MACCATALYST': 'NO', 'SWIFT_VERSION': '5.0',
        'SWIFT_STRICT_CONCURRENCY': 'targeted', 'ENABLE_USER_SCRIPT_SANDBOXING': 'YES',
        'ASSETCATALOG_COMPILER_APPICON_NAME': 'AppIcon', 'OTHER_LDFLAGS': '-lz',
        'LD_RUNPATH_SEARCH_PATHS': '$(inherited) @executable_path/Frameworks',
        'SWIFT_OPTIMIZATION_LEVEL': '-Onone' if config == 'Debug' else '-O',
        'DEBUG_INFORMATION_FORMAT': 'dwarf' if config == 'Debug' else 'dwarf-with-dsym',
        'SWIFT_ACTIVE_COMPILATION_CONDITIONS': 'DEBUG' if config == 'Debug' else '',
        'ENABLE_TESTABILITY': 'YES' if config == 'Debug' else 'NO',
    }
    objects[tc] = '{isa = XCBuildConfiguration; buildSettings = {' + ''.join(f'{k} = {quote(v)};' for k,v in settings.items()) + '}; name = ' + config + '; }'

pc_list, tc_list = uid('projectConfigs'), uid('targetConfigs')
objects[pc_list] = f'{{isa = XCConfigurationList; buildConfigurations = ({",".join(project_configs)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }}'
objects[tc_list] = f'{{isa = XCConfigurationList; buildConfigurations = ({",".join(target_configs)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }}'
objects[target] = f'{{isa = PBXNativeTarget; buildConfigurationList = {tc_list}; buildPhases = ({source_phase},{framework_phase},{resource_phase},); buildRules = (); dependencies = (); name = Hongguo; productName = Hongguo; productReference = {product}; productType = "com.apple.product-type.application"; }}'
objects[proj] = f'{{isa = PBXProject; attributes = {{BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 2700; }}; buildConfigurationList = {pc_list}; compatibilityVersion = "Xcode 14.0"; developmentRegion = zh-Hans; hasScannedForEncodings = 0; knownRegions = ("zh-Hans",en,Base,); mainGroup = {group}; productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; targets = ({target},); }}'
body = '\n'.join(f'{key} = {value};' for key,value in sorted(objects.items()))
(project / 'project.pbxproj').write_text('// !$*UTF8*$!\n{archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n' + body + '\n}; rootObject = ' + proj + '; }\n')
schemes = project / 'xcshareddata' / 'xcschemes'
schemes.mkdir(parents=True, exist_ok=True)
(schemes / 'Hongguo.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="Hongguo.app" BlueprintName="Hongguo" ReferencedContainer="container:Hongguo.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="Hongguo.app" BlueprintName="Hongguo" ReferencedContainer="container:Hongguo.xcodeproj"/></BuildableProductRunnable></LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"/>
 <AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
print(f'Generated Hongguo.xcodeproj: {len(sources)} Swift sources, {len(resources)} resources')
