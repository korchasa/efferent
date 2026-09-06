import ProjectDescription

/// Tuist manifest for Efferent. The Xcode project is generated, never committed.
///
/// One app target holds both the collecting/sending core and the thin UI on top
/// of it. A separate framework would buy isolation the app does not need and
/// cost a second module boundary in every file.
public let project = Project(
    name: "Efferent",
    organizationName: "dev.korchasa",
    packages: [
        .remote(url: "https://github.com/groue/GRDB.swift.git", requirement: .upToNextMajor(from: "7.11.1"))
    ],
    settings: .settings(
        base: [
            // No DEVELOPMENT_TEAM here on purpose. It identifies the account
            // rather than the app, this repository is public, and nothing built
            // from it needs one: the archive is unsigned and signing happens
            // elsewhere. Running on a device from Xcode does need it, so it
            // lives in the ignored `Configs/Local.xcconfig` — see the example
            // beside it.
            "SWIFT_VERSION": "5.9",
            "CODE_SIGN_STYLE": "Automatic",
            "SWIFT_TREAT_WARNINGS_AS_ERRORS": "YES",
            "MARKETING_VERSION": "1.0.0",
            "CURRENT_PROJECT_VERSION": "16",
        ],
        configurations: [
            .debug(name: "Debug", xcconfig: "Configs/Debug.xcconfig"),
            .release(name: "Release", xcconfig: "Configs/Release.xcconfig"),
        ]
    ),
    targets: [
        .target(
            name: "Efferent",
            destinations: [.iPhone],
            product: .app,
            bundleId: "dev.korchasa.efferent",
            deploymentTargets: .iOS("17.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": .string("Efferent"),
                "CFBundleIconName": .string("AppIcon"),
                "CFBundleShortVersionString": .string("$(MARKETING_VERSION)"),
                "CFBundleVersion": .string("$(CURRENT_PROJECT_VERSION)"),
                "UILaunchScreen": .dictionary([:]),
                "UISupportedInterfaceOrientations": .array([
                    .string("UIInterfaceOrientationPortrait")
                ]),
                // Shown verbatim in the system permission sheet. Say what leaves
                // the phone and where it goes; a vague string fails review.
                "NSHealthShareUsageDescription": .string(
                    "Efferent reads your health data so it can send it to the server you configure. Nothing is shared with anyone else."
                ),
                // Required even though the app never writes. Upload validation
                // refuses any binary that links HealthKit without both purpose
                // strings (error 90683), and it refuses it after the whole
                // build has been uploaded. Nobody ever reads this one: write
                // access is never requested, so the sheet never shows it.
                "NSHealthUpdateUsageDescription": .string(
                    "Efferent never writes to your health data. It only reads what is already there."
                ),
                // Public deployment configuration. These are addresses, not
                // credentials; the reading key never enters the plist.
                "EfferentServiceURL": .string("https://efferent.korchasa.dev"),
                "EfferentMCPBaseURL": .string(
                    "https://efferent.korchasa.dev/mcp/b"
                ),
                // A reader on your own network is a normal way to run this, and
                // it will not have a certificate. The batch is sealed either
                // way, so plain http on a local address changes who can see the
                // metadata, not the readings.
                "NSAppTransportSecurity": .dictionary([
                    "NSAllowsLocalNetworking": .boolean(true)
                ]),
                // Background delivery wakes the app; the deferred send finishes
                // through a background URLSession, which needs no mode of its own.
                "UIBackgroundModes": .array([.string("processing")]),
                "BGTaskSchedulerPermittedIdentifiers": .array([
                    .string("dev.korchasa.efferent.refresh")
                ]),
            ]),
            sources: [
                "src/App/Sources/**",
                "src/Core/Sources/**",
            ],
            resources: ["Resources/Assets.xcassets"],
            entitlements: "Resources/Efferent.entitlements",
            dependencies: [
                .package(product: "GRDB")
            ]
        ),
        .target(
            name: "EfferentTests",
            destinations: [.iPhone],
            product: .unitTests,
            bundleId: "dev.korchasa.efferent.tests",
            deploymentTargets: .iOS("17.0"),
            infoPlist: .default,
            sources: ["src/Tests/Sources/**"],
            dependencies: [.target(name: "Efferent")]
        ),
    ],
    schemes: [
        .scheme(
            name: "Efferent",
            shared: true,
            buildAction: .buildAction(targets: ["Efferent"]),
            testAction: .targets(["EfferentTests"]),
            runAction: .runAction(executable: "Efferent")
        )
    ]
)
