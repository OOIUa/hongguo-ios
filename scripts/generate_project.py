#!/usr/bin/env python3
"""Generate the dependency-free Xcode project from checked-in source files."""
import hashlib
import json
import xml.etree.ElementTree as ET
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

# QA uses exactly the same app objects, source list and Release.json settings.
# Generate it here so new production files cannot silently disappear from UI test builds.
qa_project = root / 'Hongguo-QA.xcodeproj'
qa_project.mkdir(exist_ok=True)
qa = dict(objects)
qa_target, qa_product, qa_file, qa_build, qa_sources, qa_frameworks, qa_resources, qa_configs, dependency, proxy = [
    uid('qa:' + name) for name in ('target', 'product', 'file', 'build', 'sources', 'frameworks', 'resources', 'configs', 'dependency', 'proxy')]
qa[qa_product] = '{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = HongguoQATests.xctest; sourceTree = BUILT_PRODUCTS_DIR; }'
qa[qa_file] = '{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Tests/UIQATests.swift; sourceTree = "<group>"; }'
qa[qa_build] = f'{{isa = PBXBuildFile; fileRef = {qa_file}; }}'
qa[qa_sources] = f'{{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({qa_build},); runOnlyForDeploymentPostprocessing = 0; }}'
for phase, kind in [(qa_frameworks, 'PBXFrameworksBuildPhase'), (qa_resources, 'PBXResourcesBuildPhase')]:
    qa[phase] = f'{{isa = {kind}; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }}'
qa[products] = qa[products].replace(f'({product},)', f'({product},{qa_product},)')
qa[group] = qa[group].replace(f'{products},)', f'{qa_file},{products},)')
qa[proxy] = f'{{isa = PBXContainerItemProxy; containerPortal = {proj}; proxyType = 1; remoteGlobalIDString = {target}; remoteInfo = Hongguo; }}'
qa[dependency] = f'{{isa = PBXTargetDependency; target = {target}; targetProxy = {proxy}; }}'
qa_config_ids = []
for config in ('Debug', 'Release'):
    config_id = uid('qa:config:' + config)
    qa_config_ids.append(config_id)
    test_settings = {
        'PRODUCT_NAME': 'HongguoQATests', 'PRODUCT_BUNDLE_IDENTIFIER': 'com.ooiua.hongguo.qa',
        'GENERATE_INFOPLIST_FILE': 'YES', 'TEST_TARGET_NAME': 'Hongguo',
        'CODE_SIGNING_ALLOWED': 'NO', 'CODE_SIGNING_REQUIRED': 'NO', 'CODE_SIGN_IDENTITY': '',
        'SWIFT_VERSION': '5.0', 'IPHONEOS_DEPLOYMENT_TARGET': release['minimumOSVersion'],
        'TARGETED_DEVICE_FAMILY': '1', 'SUPPORTED_PLATFORMS': 'iphoneos iphonesimulator',
        'LD_RUNPATH_SEARCH_PATHS': '$(inherited) @executable_path/Frameworks @loader_path/Frameworks',
    }
    qa[config_id] = '{isa = XCBuildConfiguration; buildSettings = {' + ''.join(f'{k} = {quote(v)};' for k, v in test_settings.items()) + '}; name = ' + config + '; }'
qa[qa_configs] = f'{{isa = XCConfigurationList; buildConfigurations = ({",".join(qa_config_ids)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }}'
qa[qa_target] = f'{{isa = PBXNativeTarget; buildConfigurationList = {qa_configs}; buildPhases = ({qa_sources},{qa_frameworks},{qa_resources},); buildRules = (); dependencies = ({dependency},); name = HongguoQATests; productName = HongguoQATests; productReference = {qa_product}; productType = "com.apple.product-type.bundle.ui-testing"; }}'
qa[proj] = qa[proj].replace(f'targets = ({target},)', f'targets = ({target},{qa_target},)')
qa_body = '\n'.join(f'{key} = {value};' for key, value in sorted(qa.items()))
(qa_project / 'project.pbxproj').write_text('// !$*UTF8*$!\n{archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n' + qa_body + '\n}; rootObject = ' + proj + '; }\n')
qa_scheme = ET.parse(schemes / 'Hongguo.xcscheme')
for reference in qa_scheme.iter('BuildableReference'):
    reference.set('ReferencedContainer', 'container:Hongguo-QA.xcodeproj')
def test_reference(parent):
    ET.SubElement(parent, 'BuildableReference', BuildableIdentifier='primary', BlueprintIdentifier=qa_target,
                  BuildableName='HongguoQATests.xctest', BlueprintName='HongguoQATests', ReferencedContainer='container:Hongguo-QA.xcodeproj')
build_entry = ET.SubElement(qa_scheme.find('BuildAction/BuildActionEntries'), 'BuildActionEntry',
                           buildForTesting='YES', buildForRunning='NO', buildForProfiling='NO', buildForArchiving='NO', buildForAnalyzing='YES')
test_reference(build_entry)
test_action = ET.Element('TestAction', buildConfiguration='Debug', selectedDebuggerIdentifier='Xcode.DebuggerFoundation.Debugger.LLDB',
                        selectedLauncherIdentifier='Xcode.IDEFoundation.Launcher.LLDB', shouldUseLaunchSchemeArgsEnv='YES')
test_reference(ET.SubElement(ET.SubElement(test_action, 'Testables'), 'TestableReference', skipped='NO'))
qa_scheme.getroot().insert(1, test_action)
qa_scheme_dir = qa_project / 'xcshareddata' / 'xcschemes'
qa_scheme_dir.mkdir(parents=True, exist_ok=True)
qa_scheme.write(qa_scheme_dir / 'HongguoQA.xcscheme', encoding='utf-8', xml_declaration=True)
print('Generated Hongguo-QA.xcodeproj with the same app sources and version')
