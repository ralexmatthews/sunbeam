//
//  SunBeamApp.swift
//  SunBeam
//
//  Created by Alex Matthews on 7/23/26.
//

import SwiftUI
import AppKit

@main
struct SunBeamApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var controller = RazerController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(controller)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}

/// There's a single window and no menu-bar item, so closing that window should
/// quit the app rather than leave it running headless in the Dock.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
