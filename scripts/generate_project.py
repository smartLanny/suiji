#!/usr/bin/env python3
"""Generate the Suiji iOS + watchOS Xcode project from the source folders."""

from __future__ import annotations

import argparse
from pathlib import Path
import uuid


ROOT = Path(__file__).resolve().parents[1]
PROJECT_DIR = ROOT / "Suiji.xcodeproj"
SCHEME_DIR = PROJECT_DIR / "xcshareddata" / "xcschemes"
CONFIG_DIR = ROOT / "Config"
PROJECT_FILE = PROJECT_DIR / "project.pbxproj"
IOS_BUNDLE_ID = "com.lann.suiji"
WATCH_BUNDLE_ID = "com.lann.suiji.watchkitapp"
NAMESPACE = uuid.UUID("7d44d0aa-845b-4bfb-a0d4-38c920ab2edc")


def object_id(key: str) -> str:
    return uuid.uuid5(NAMESPACE, key).hex[:24].upper()


def pbx_quote(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def pbx_value(value: object) -> str:
    if isinstance(value, bool):
        return "YES" if value else "NO"
    text = str(value)
    if text and all(char.isalnum() or char in "_./+-" for char in text):
        return text
    return pbx_quote(text)


def write_info_plists() -> None:
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    (CONFIG_DIR / "Info-iOS.plist").write_text(
        """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleExecutable</key><string>$(EXECUTABLE_NAME)</string>
  <key>CFBundleIdentifier</key><string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$(PRODUCT_NAME)</string>
  <key>CFBundleDisplayName</key><string>随记</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$(MARKETING_VERSION)</string>
  <key>CFBundleVersion</key><string>$(CURRENT_PROJECT_VERSION)</string>
  <key>LSRequiresIPhoneOS</key><true/>
  <key>MinimumOSVersion</key><string>$(IPHONEOS_DEPLOYMENT_TARGET)</string>
  <key>NSMicrophoneUsageDescription</key><string>随记使用麦克风记录你主动口述的内容。</string>
  <key>UILaunchScreen</key><dict/>
  <key>UIBackgroundModes</key><array><string>audio</string></array>
</dict>
</plist>
""",
        encoding="utf-8",
    )
    (CONFIG_DIR / "Info-watchOS.plist").write_text(
        """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleExecutable</key><string>$(EXECUTABLE_NAME)</string>
  <key>CFBundleIdentifier</key><string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$(PRODUCT_NAME)</string>
  <key>CFBundleDisplayName</key><string>随记</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$(MARKETING_VERSION)</string>
  <key>CFBundleVersion</key><string>$(CURRENT_PROJECT_VERSION)</string>
  <key>MinimumOSVersion</key><string>$(WATCHOS_DEPLOYMENT_TARGET)</string>
  <key>NSMicrophoneUsageDescription</key><string>随记使用 Apple Watch 麦克风记录你主动口述的内容。</string>
  <key>WKApplication</key><true/>
  <key>WKBackgroundModes</key><array><string>audio</string></array>
  <key>WKCompanionAppBundleIdentifier</key><string>com.lann.suiji</string>
</dict>
</plist>
""",
        encoding="utf-8",
    )


class ProjectFile:
    def __init__(self) -> None:
        self.objects: list[str] = []
        self.ids: dict[str, str] = {}

    def id(self, key: str) -> str:
        if key not in self.ids:
            self.ids[key] = object_id(key)
        return self.ids[key]

    def add(self, key: str, comment: str, body: str) -> str:
        ref = self.id(key)
        self.objects.append(f"\t\t{ref} /* {comment} */ = {{\n{body}\t\t}};")
        return ref

    def list_field(self, name: str, entries: list[tuple[str, str]]) -> str:
        lines = [f"\t\t\t{name} = (\n"]
        for ref, comment in entries:
            lines.append(f"\t\t\t\t{ref} /* {comment} */,\n")
        lines.append("\t\t\t);\n")
        return "".join(lines)

    def build_settings(self, settings: dict[str, object]) -> str:
        lines: list[str] = []
        for key, value in settings.items():
            if isinstance(value, list):
                lines.append(f"\t\t\t\t{key} = (\n")
                for entry in value:
                    lines.append(f"\t\t\t\t\t{pbx_value(entry)},\n")
                lines.append("\t\t\t\t);\n")
            else:
                lines.append(f"\t\t\t\t{key} = {pbx_value(value)};\n")
        return "".join(lines)

    def configuration(self, target: str, name: str, settings: dict[str, object]) -> str:
        body = (
            f"\t\t\tisa = XCBuildConfiguration;\n"
            f"\t\t\tbuildSettings = {{\n{self.build_settings(settings)}\t\t\t}};\n"
            f"\t\t\tname = {name};\n"
        )
        return self.add(f"config:{target}:{name}", f"{name} {target}", body)

    def configuration_list(self, target: str, configs: list[str]) -> str:
        entries = [(ref, "Debug" if index == 0 else "Release") for index, ref in enumerate(configs)]
        body = (
            "\t\t\tisa = XCConfigurationList;\n"
            + self.list_field("buildConfigurations", entries)
            + "\t\t\tdefaultConfigurationIsVisible = 0;\n"
            "\t\t\tdefaultConfigurationName = Release;\n"
        )
        return self.add(f"config-list:{target}", f"Build configuration list for {target}", body)

    def source_reference(self, relative: Path) -> tuple[str, str]:
        key = f"file:{relative.as_posix()}"
        ref = self.add(
            key,
            relative.name,
            "\t\t\tisa = PBXFileReference;\n"
            "\t\t	lastKnownFileType = sourcecode.swift;\n"
            f"\t\t\tpath = {pbx_quote(relative.name)};\n"
            "\t\t\tsourceTree = \"<group>\";\n",
        )
        return ref, relative.name

    def build_file(self, target: str, path: Path, ref: str, comment: str | None = None, attributes: list[str] | None = None) -> tuple[str, str]:
        label = comment or f"{path.name} in Sources"
        body = "\t\t\tisa = PBXBuildFile;\n"
        if attributes:
            attrs = ", ".join(attributes)
            body += f"\t\t\tsettings = {{ ATTRIBUTES = ({attrs},); }};\n"
        body += f"\t\t	fileRef = {ref} /* {path.name} */;\n"
        return self.add(f"build-file:{target}:{path.as_posix()}", label, body), label

    def group(self, key: str, name: str, children: list[tuple[str, str]], path: str | None = None) -> str:
        body = "\t\t\tisa = PBXGroup;\n" + self.list_field("children", children)
        if path is not None:
            body += f"\t\t\tpath = {pbx_quote(path)};\n"
        body += "\t\t\tsourceTree = \"<group>\";\n"
        return self.add(f"group:{key}", name, body)

    def phase(self, key: str, name: str, isa: str, files: list[tuple[str, str]]) -> str:
        body = (
            f"\t\t\tisa = {isa};\n"
            "\t\t\tbuildActionMask = 2147483647;\n"
            + self.list_field("files", files)
            + "\t\t\trunOnlyForDeploymentPostprocessing = 0;\n"
        )
        return self.add(f"phase:{key}", name, body)


def make_target_settings(platform: str, configuration: str, team: str | None) -> dict[str, object]:
    settings: dict[str, object] = {
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": "1",
        "DEVELOPMENT_TEAM": team or "",
        "ENABLE_PREVIEWS": "YES",
        "GENERATE_INFOPLIST_FILE": "NO",
        "MARKETING_VERSION": "1.0",
        "PRODUCT_NAME": "$(TARGET_NAME)",
        "SWIFT_EMIT_LOC_STRINGS": "YES",
        "SWIFT_STRICT_CONCURRENCY": "minimal",
        "SWIFT_VERSION": "5.0",
    }
    if platform == "iOS":
        settings.update({
            "INFOPLIST_FILE": "Config/Info-iOS.plist",
            "IPHONEOS_DEPLOYMENT_TARGET": "27.0",
            "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"],
            "PRODUCT_BUNDLE_IDENTIFIER": IOS_BUNDLE_ID,
            "SDKROOT": "iphoneos",
            "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
            "SUPPORTS_MACCATALYST": "NO",
            "TARGETED_DEVICE_FAMILY": "1",
        })
        if configuration == "Release":
            settings["VALIDATE_PRODUCT"] = "YES"
    else:
        settings.update({
            "INFOPLIST_FILE": "Config/Info-watchOS.plist",
            "INFOPLIST_KEY_WKApplication": "YES",
            "INFOPLIST_KEY_WKCompanionAppBundleIdentifier": IOS_BUNDLE_ID,
            "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"],
            "PRODUCT_BUNDLE_IDENTIFIER": WATCH_BUNDLE_ID,
            "SDKROOT": "watchos",
            "SKIP_INSTALL": "YES",
            "SUPPORTED_PLATFORMS": "watchos watchsimulator",
            "TARGETED_DEVICE_FAMILY": "4",
            "WATCHOS_DEPLOYMENT_TARGET": "27.0",
        })
        if configuration == "Release":
            settings["VALIDATE_PRODUCT"] = "YES"
    return settings


def write_scheme(name: str, target_id: str, product: str) -> None:
    def runnable() -> str:
        return (
            f'      <BuildableProductRunnable runnableDebuggingMode="0">\n'
            f'         <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target_id}" BuildableName="{product}" BlueprintName="{name}" ReferencedContainer="container:Suiji.xcodeproj"/>\n'
            "      </BuildableProductRunnable>\n"
        )

    text = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.7">
   <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
            <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target_id}" BuildableName="{product}" BlueprintName="{name}" ReferencedContainer="container:Suiji.xcodeproj"/>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES">
      <Testables/>
   </TestAction>
   <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES">
{runnable()}   </LaunchAction>
   <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES">
{runnable()}   </ProfileAction>
   <AnalyzeAction buildConfiguration="Debug"/>
   <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
'''
    (SCHEME_DIR / f"{name}.xcscheme").write_text(text, encoding="utf-8")


def generate(team: str | None = None) -> None:
    PROJECT_DIR.mkdir(parents=True, exist_ok=True)
    SCHEME_DIR.mkdir(parents=True, exist_ok=True)
    write_info_plists()
    project = ProjectFile()

    directory_specs = [
        ("Sources/SuijiCore", "Sources/SuijiCore", "SuijiCore"),
        ("Shared", "Shared", "Shared"),
        ("iOS", "iOS", "iOS"),
        ("Watch", "Watch", "Watch"),
    ]
    source_refs: dict[str, list[tuple[str, str, Path]]] = {}
    source_groups: list[tuple[str, str]] = []
    for key, folder, label in directory_specs:
        base = ROOT / folder
        files: list[tuple[str, str, Path]] = []
        if base.exists():
            for source in sorted(base.glob("*.swift")):
                relative = source.relative_to(ROOT)
                ref, comment = project.source_reference(relative)
                files.append((ref, comment, relative))
        source_refs[key] = files
        group_children = [(ref, comment) for ref, comment, _ in files]
        group = project.group(key, label, group_children, Path(folder).name)
        source_groups.append((group, label))

    core_group = project.group("Sources", "Sources", [source_groups[0]], "Sources")
    shared_group, ios_group, watch_group = (entry[0] for entry in source_groups[1:])

    config_children: list[tuple[str, str]] = []
    for filename in ("Info-iOS.plist", "Info-watchOS.plist"):
        ref = project.add(
            f"file:Config/{filename}",
            filename,
            "\t\t\tisa = PBXFileReference;\n"
            "\t\t	lastKnownFileType = text.plist.xml;\n"
            f"\t\t\tpath = {pbx_quote(filename)};\n"
            "\t\t\tsourceTree = \"<group>\";\n",
        )
        config_children.append((ref, filename))
    config_group = project.group("Config", "Config", config_children, "Config")

    asset_catalog = project.add(
        "file:Assets.xcassets",
        "Assets.xcassets",
        "\t\t\tisa = PBXFileReference;\n"
        "\t\t\tlastKnownFileType = folder.assetcatalog;\n"
        "\t\t\tpath = Assets.xcassets;\n"
        "\t\t\tsourceTree = \"<group>\";\n",
    )

    products: list[tuple[str, str]] = []
    ios_product = project.add(
        "product:Suiji",
        "Suiji.app",
        "\t\t\tisa = PBXFileReference;\n"
        "\t\t	explicitFileType = wrapper.application;\n"
        "\t\t	includeInIndex = 0;\n"
        "\t\t	path = Suiji.app;\n"
        "\t\t	sourceTree = BUILT_PRODUCTS_DIR;\n",
    )
    products.append((ios_product, "Suiji.app"))
    watch_product = project.add(
        "product:SuijiWatch",
        "SuijiWatch.app",
        "\t\t\tisa = PBXFileReference;\n"
        "\t\t	explicitFileType = wrapper.application;\n"
        "\t\t	includeInIndex = 0;\n"
        "\t\t	path = SuijiWatch.app;\n"
        "\t\t	sourceTree = BUILT_PRODUCTS_DIR;\n",
    )
    products.append((watch_product, "SuijiWatch.app"))
    products_group = project.group("Products", "Products", products)

    ios_source_files: list[tuple[str, str]] = []
    watch_source_files: list[tuple[str, str]] = []
    for folder_key in ("Sources/SuijiCore", "Shared"):
        for _, _, path in source_refs[folder_key]:
            ref = project.id(f"file:{path.as_posix()}")
            ios_source_files.append(project.build_file("Suiji", path, ref))
            watch_source_files.append(project.build_file("SuijiWatch", path, ref))
    for folder_key, target, output in (("iOS", "Suiji", ios_source_files), ("Watch", "SuijiWatch", watch_source_files)):
        for _, _, path in source_refs[folder_key]:
            ref = project.id(f"file:{path.as_posix()}")
            output.append(project.build_file(target, path, ref))

    ios_asset_build_file, ios_asset_comment = project.build_file(
        "Suiji",
        Path("Assets.xcassets"),
        asset_catalog,
        "Assets.xcassets in Resources",
    )
    watch_asset_build_file, watch_asset_comment = project.build_file(
        "SuijiWatch",
        Path("Assets.xcassets"),
        asset_catalog,
        "Assets.xcassets in Resources",
    )

    ios_sources_phase = project.phase("Suiji:Sources", "Sources", "PBXSourcesBuildPhase", ios_source_files)
    watch_sources_phase = project.phase("SuijiWatch:Sources", "Sources", "PBXSourcesBuildPhase", watch_source_files)
    ios_frameworks_phase = project.phase("Suiji:Frameworks", "Frameworks", "PBXFrameworksBuildPhase", [])
    watch_frameworks_phase = project.phase("SuijiWatch:Frameworks", "Frameworks", "PBXFrameworksBuildPhase", [])
    ios_resources_phase = project.phase(
        "Suiji:Resources",
        "Resources",
        "PBXResourcesBuildPhase",
        [(ios_asset_build_file, ios_asset_comment)],
    )
    watch_resources_phase = project.phase(
        "SuijiWatch:Resources",
        "Resources",
        "PBXResourcesBuildPhase",
        [(watch_asset_build_file, watch_asset_comment)],
    )

    embed_build_file, embed_comment = project.build_file(
        "Suiji",
        Path("SuijiWatch.app"),
        watch_product,
        "SuijiWatch.app in Embed Watch Content",
        ["CodeSignOnCopy", "RemoveHeadersOnCopy"],
    )
    embed_watch_phase = project.add(
        "phase:Suiji:EmbedWatchContent",
        "Embed Watch Content",
        "\t\t\tisa = PBXCopyFilesBuildPhase;\n"
        "\t\t\tbuildActionMask = 2147483647;\n"
        "\t\t	dstPath = \"$(CONTENTS_FOLDER_PATH)/Watch\";\n"
        "\t\t	dstSubfolderSpec = 16;\n"
        + project.list_field("files", [(embed_build_file, embed_comment)])
        + "\t\t\tname = \"Embed Watch Content\";\n"
        "\t\t\trunOnlyForDeploymentPostprocessing = 0;\n",
    )

    project_id = project.id("project")
    watch_target_id = project.id("target:SuijiWatch")
    dependency_proxy = project.add(
        "proxy:SuijiWatch",
        "PBXContainerItemProxy",
        "\t\t\tisa = PBXContainerItemProxy;\n"
        f"\t\t	containerPortal = {project_id} /* Project object */;\n"
        "\t\t	proxyType = 1;\n"
        f"\t\t	remoteGlobalIDString = {watch_target_id};\n"
        "\t\t	remoteInfo = SuijiWatch;\n",
    )
    watch_dependency = project.add(
        "dependency:Suiji:SuijiWatch",
        "SuijiWatch",
        "\t\t\tisa = PBXTargetDependency;\n"
        f"\t\t	target = {watch_target_id} /* SuijiWatch */;\n"
        f"\t\t	targetProxy = {dependency_proxy} /* PBXContainerItemProxy */;\n",
    )

    project_config_ids = [
        project.configuration("Project", name, {
            "CLANG_ENABLE_MODULES": "YES",
            "IPHONEOS_DEPLOYMENT_TARGET": "27.0",
            "SWIFT_VERSION": "5.0",
            "WATCHOS_DEPLOYMENT_TARGET": "27.0",
        })
        for name in ("Debug", "Release")
    ]
    project_config_list = project.configuration_list("Project", project_config_ids)

    ios_config_ids = [project.configuration("Suiji", name, make_target_settings("iOS", name, team)) for name in ("Debug", "Release")]
    ios_config_list = project.configuration_list("Suiji", ios_config_ids)
    watch_config_ids = [project.configuration("SuijiWatch", name, make_target_settings("watchOS", name, team)) for name in ("Debug", "Release")]
    watch_config_list = project.configuration_list("SuijiWatch", watch_config_ids)

    ios_target = project.add(
        "target:Suiji",
        "Suiji",
        "\t\t\tisa = PBXNativeTarget;\n"
        f"\t\t	buildConfigurationList = {ios_config_list} /* Build configuration list for Suiji */;\n"
        + project.list_field("buildPhases", [
            (ios_sources_phase, "Sources"),
            (ios_frameworks_phase, "Frameworks"),
            (ios_resources_phase, "Resources"),
            (embed_watch_phase, "Embed Watch Content"),
        ])
        + "\t\t\tbuildRules = (\n\t\t\t);\n"
        + project.list_field("dependencies", [(watch_dependency, "SuijiWatch")])
        + "\t\t	name = Suiji;\n"
        "\t\t	productName = Suiji;\n"
        f"\t\t	productReference = {ios_product} /* Suiji.app */;\n"
        "\t\t	productType = \"com.apple.product-type.application\";\n",
    )
    watch_target = project.add(
        "target:SuijiWatch",
        "SuijiWatch",
        "\t\t\tisa = PBXNativeTarget;\n"
        f"\t\t	buildConfigurationList = {watch_config_list} /* Build configuration list for SuijiWatch */;\n"
        + project.list_field("buildPhases", [
            (watch_sources_phase, "Sources"),
            (watch_frameworks_phase, "Frameworks"),
            (watch_resources_phase, "Resources"),
        ])
        + "\t\t\tbuildRules = (\n\t\t\t);\n"
        "\t\t	dependencies = (\n\t\t\t);\n"
        "\t\t	name = SuijiWatch;\n"
        "\t\t	productName = SuijiWatch;\n"
        f"\t\t	productReference = {watch_product} /* SuijiWatch.app */;\n"
        "\t\t	productType = \"com.apple.product-type.application\";\n",
    )

    root_group = project.group(
        "Main",
        "",
        [
            (core_group, "Sources"),
            (shared_group, "Shared"),
            (ios_group, "iOS"),
            (watch_group, "Watch"),
            (config_group, "Config"),
            (asset_catalog, "Assets.xcassets"),
            (products_group, "Products"),
        ],
    )
    project.add(
        "project",
        "Project object",
        "\t\t\tisa = PBXProject;\n"
        "\t\t	attributes = {\n"
        "\t\t\t	BuildIndependentTargetsInParallel = YES;\n"
        "\t\t\t	LastSwiftUpdateCheck = 2700;\n"
        "\t\t\t	LastUpgradeCheck = 2700;\n"
        "\t\t\t	TargetAttributes = {\n"
        f"\t\t\t\t\t{ios_target} = {{ CreatedOnToolsVersion = 27.0; ProvisioningStyle = Automatic; }};\n"
        f"\t\t\t\t\t{watch_target} = {{ CreatedOnToolsVersion = 27.0; ProvisioningStyle = Automatic; }};\n"
        "\t\t\t	};\n"
        "\t\t\t};\n"
        f"\t\t\tbuildConfigurationList = {project_config_list} /* Build configuration list for Project object */;\n"
        "\t\t	compatibilityVersion = \"Xcode 16.0\";\n"
        "\t\t	developmentRegion = en;\n"
        "\t\t	hasScannedForEncodings = 0;\n"
        "\t\t	knownRegions = (\n\t\t\t\ten,\n\t\t\t\tBase,\n\t\t\t);\n"
        f"\t\t	mainGroup = {root_group} /* Main group */;\n"
        f"\t\t	productRefGroup = {products_group} /* Products */;\n"
        "\t\t	projectDirPath = \"\";\n"
        "\t\t	projectRoot = \"\";\n"
        + project.list_field("targets", [(ios_target, "Suiji"), (watch_target, "SuijiWatch")]),
    )

    PROJECT_FILE.write_text(
        "// !$*UTF8*$!\n"
        "{\n"
        "\tarchiveVersion = 1;\n"
        "\tclasses = {};\n"
        "\tobjectVersion = 60;\n"
        "\tobjects = {\n"
        + "\n".join(project.objects)
        + "\n\t};\n"
        f"\trootObject = {project_id} /* Project object */;\n"
        "}\n",
        encoding="utf-8",
    )
    write_scheme("Suiji", ios_target, "Suiji.app")
    write_scheme("SuijiWatch", watch_target, "SuijiWatch.app")
    print(f"Generated {PROJECT_FILE}")
    print(f"iOS sources: {len(ios_source_files)}; watchOS sources: {len(watch_source_files)}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Generate the Suiji iOS and watchOS Xcode project.")
    parser.add_argument("--team", help="Apple Developer Team ID for automatic signing")
    generate(parser.parse_args().team)
