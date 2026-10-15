// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "True",
    platforms: [.macOS("14.0")],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
    ],
    targets: [
        .executableTarget(
            name: "True",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
            path: "Sources/True",
            swiftSettings: [
                // macOS 26 + Swift 6: the runtime's DYNAMIC main-actor isolation check hard-traps
                // (dispatch_assert_queue_fail / EXC_BREAKPOINT) when a @MainActor closure is invoked
                // off the main thread by a system framework (AppKit event dispatch, SwiftUI) even
                // when it genuinely runs on main (a runtime false positive; swift#88993/#89214).
                // This drops that runtime check while keeping ALL Swift-6 COMPILE-TIME isolation
                // safety. Lifted from Axon's Package.swift; safe to drop when the OS bug is fixed.
                .unsafeFlags(["-Xfrontend", "-disable-dynamic-actor-isolation"]),
            ]
        ),
        .testTarget(
            name: "TrueTests",
            dependencies: ["True"],
            path: "Tests/TrueTests",
            swiftSettings: [
                .unsafeFlags(["-Xfrontend", "-disable-dynamic-actor-isolation"]),
            ]
        ),
    ]
)
