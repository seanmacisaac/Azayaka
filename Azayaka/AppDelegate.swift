//
//  AppDelegate.swift
//  Azayaka
//
//  Created by Martin Persson on 2022-12-25.
//

import AVFoundation
import AVFAudio
import Cocoa
import KeyboardShortcuts
import ScreenCaptureKit
import UserNotifications
import SwiftUI

@main
struct Azayaka: App {
    @StateObject private var appState = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            Preferences()
                .fixedSize()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, SCStreamDelegate, SCStreamOutput {
    var vW: AVAssetWriter!
    var vwInput, awInput, micInput: AVAssetWriterInput!
    let audioEngine = AVAudioEngine()
    var startTime: Date?
    var stream: SCStream!
    var filePath: String!
    var audioFile: AVAudioFile?
    var audioSettings: [String : Any]!
    var availableContent: SCShareableContent?
    var filter: SCContentFilter?
    var updateTimer: Timer?
    var recordMic = false

    var screen: SCDisplay?
    var window: SCWindow?
    var streamType: StreamType?

    var audioUnit: AudioUnit?
    var sampleRate: Double = 44100.0
    var theta: Double = 0.0
    var beepDuration: Double = 0.2 // 200 milliseconds
    var beepFrequency: Double = 261.63 // Middle C
    var isBeeping: Bool = false

    let excludedWindows = ["", "com.apple.dock", "com.apple.controlcenter", "com.apple.notificationcenterui", "com.apple.systemuiserver", "com.apple.WindowManager", "dev.mnpn.Azayaka", "com.gaosun.eul", "com.pointum.hazeover", "net.matthewpalmer.Vanilla", "com.dwarvesv.minimalbar", "com.bjango.istatmenus.status"]

    var statusItem: NSStatusItem!
    var menu = NSMenu()
    let info = NSMenuItem(title: "One moment, waiting on update".local, action: nil, keyEquivalent: "")
    let noneAvailable = NSMenuItem(title: "None available".local, action: nil, keyEquivalent: "")
    let preferences = NSWindow()
    let ud = UserDefaults.standard
    let UpdateHandler = Updates()

    func setupAudioUnit() {
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                             componentSubType: kAudioUnitSubType_DefaultOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0,
                                             componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &desc) else {
            fatalError("Can't find default output audio component")
        }

        var audioUnit: AudioUnit?
        AudioComponentInstanceNew(component, &audioUnit)
        self.audioUnit = audioUnit

        var input = AURenderCallbackStruct(inputProc: renderCallback,
                                           inputProcRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
        AudioUnitSetProperty(audioUnit!,
                             kAudioUnitProperty_SetRenderCallback,
                             kAudioUnitScope_Input,
                             0,
                             &input,
                             UInt32(MemoryLayout<AURenderCallbackStruct>.size))

        var streamFormat = AudioStreamBasicDescription(mSampleRate: sampleRate,
                                                       mFormatID: kAudioFormatLinearPCM,
                                                       mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                                       mBytesPerPacket: 4,
                                                       mFramesPerPacket: 1,
                                                       mBytesPerFrame: 4,
                                                       mChannelsPerFrame: 1,
                                                       mBitsPerChannel: 32,
                                                       mReserved: 0)
        AudioUnitSetProperty(audioUnit!,
                             kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Input,
                             0,
                             &streamFormat,
                             UInt32(MemoryLayout<AudioStreamBasicDescription>.size))

        AudioUnitInitialize(audioUnit!)
        AudioOutputUnitStart(audioUnit!)
    }

    let renderCallback: AURenderCallback = { inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData in
        let appDelegate = Unmanaged<AppDelegate>.fromOpaque(inRefCon).takeUnretainedValue()
        let thetaIncrement = 2.0 * Double.pi * appDelegate.beepFrequency / appDelegate.sampleRate

        guard let bufferPointer = ioData?.pointee.mBuffers.mData?.assumingMemoryBound(to: Float.self) else {
            return noErr
        }

        for frame in 0..<Int(inNumberFrames) {
            if appDelegate.isBeeping {
                bufferPointer[frame] = Float(sin(appDelegate.theta))
                appDelegate.theta += thetaIncrement
            } else {
                bufferPointer[frame] = 0.0
            }

            if appDelegate.theta > 2.0 * Double.pi {
                appDelegate.theta -= 2.0 * Double.pi
            }
        }

        return noErr
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        lazy var userDesktop = (NSSearchPathForDirectoriesInDomains(.desktopDirectory, .userDomainMask, true) as [String]).first!
        
        // the `com.apple.screencapture` domain has the user set path for where they want to store screenshots or videos
        let saveDirectory = (UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") ?? userDesktop) as NSString
        
        ud.register( // default defaults (used if not set)
            defaults: [
                "audioFormat": AudioFormat.aac.rawValue,
                "audioQuality": AudioQuality.high.rawValue,
                "frameRate": 60,
                "videoQuality": 1.0,
                "videoFormat": VideoFormat.mp4.rawValue,
                "encoder": Encoder.h264.rawValue,
                "saveDirectory": saveDirectory,
                "hideSelf": false,
                Preferences.frontAppKey: false,
                "showMouse": true,
                "recordMic": false,
                "highRes": true,
                Preferences.updateCheck: true,
                Preferences.fileName: "Recording at %t".local,
                "countDown": 0
            ]
        )
        // create a menu bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon()
        statusItem.menu = menu
        menu.minimumWidth = 250
        Task { await updateAvailableContent(buildMenu: true) }
        
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error { print("Notification authorisation denied: \(error.localizedDescription)") }
        }

        NotificationCenter.default.addObserver( // update the content & menu when a display device has changed
            forName: NSApplication.didChangeScreenParametersNotification,
            object: NSApplication.shared,
            queue: OperationQueue.main
        ) { [self] notification -> Void in
            Task { await updateAvailableContent(buildMenu: true) }
        }

        #if !DEBUG // no point in checking for updates if we're not on a release
        if ud.bool(forKey: Preferences.updateCheck) {
            UpdateHandler.checkForUpdates()
        }
        #endif

        setupAudioUnit()

        // Create and start the timer to toggle the beep state every second
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            self.isBeeping = true
            DispatchQueue.main.asyncAfter(deadline: .now() + self.beepDuration) {
                self.isBeeping = false
            }
        }
    }

    func updateAvailableContent(buildMenu: Bool) async -> Bool { // returns status of getting content from SCK
        do {
            availableContent = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            let infoMenu = NSMenu()
            let infoItem = NSMenuItem()
            switch error {
                case SCStreamError.userDeclined:
                    infoItem.title = "Azayaka requires screen recording permissions.".local
                    requestPermissions()
                default:
                    print("Failed to fetch available content: ".local, error.localizedDescription)
                infoItem.attributedTitle = NSAttributedString(string: "Failed to fetch available content: ".local + "\n\(error.localizedDescription)")
            }
            infoMenu.addItem(infoItem)
            infoMenu.addItem(NSMenuItem.separator())
            infoMenu.addItem(NSMenuItem(title: "Preferences…".local, action: #selector(openPreferences), keyEquivalent: ","))
            infoMenu.addItem(NSMenuItem(title: "Quit Azayaka".local, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
            statusItem.menu = infoMenu
            return false
        }
        assert(self.availableContent?.displays.isEmpty != nil, "There needs to be at least one display connected".local)
        let frontOnly = UserDefaults.standard.bool(forKey: Preferences.frontAppKey)
        DispatchQueue.main.async {
            if buildMenu {
                self.createMenu()
            }
            self.refreshWindows(frontOnly: frontOnly)
            // ask to just refresh the windows list instead of rebuilding it all
        }
        return true
    }

    func requestPermissions() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Azayaka needs permissions!".local
            alert.informativeText = "Azayaka needs screen recording permissions, even if you only intend on recording audio.".local
            alert.addButton(withTitle: "Open Settings".local)
            alert.addButton(withTitle: "Okay".local)
            alert.addButton(withTitle: "No thanks, quit".local)
            alert.alertStyle = .informational
            switch(alert.runModal()) {
                case .alertFirstButtonReturn:
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                case .alertThirdButtonReturn: NSApp.terminate(self)
                default: return
            }
        }
    }

    // a ScreenCaptureKit implementation does not work correctly, is it the order of the returned windows perhaps?
    // optionOnScreenOnly mentions "Windows are returned in order from front to back", which might be the magic here.
    func getFocusedWindowID() async -> CGWindowID? {
        guard let frontAppPID = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        guard frontAppPID != ProcessInfo.processInfo.processIdentifier else { return nil }
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: AnyObject]] else { return nil }

        guard await updateAvailableContent(buildMenu: false) else { return nil } // to make sure we've got the latest content for getValidWindows

        for windowInfo in windowList {
            if let windowPID = windowInfo["kCGWindowOwnerPID"] as? pid_t,
               let windowID = windowInfo["kCGWindowNumber"] as? CGWindowID,
               windowPID == frontAppPID,
               getValidWindows(frontOnly: false).contains(where: { $0.windowID == windowID }) { // make sure this window is available
                return windowID
            }
        }

        return nil
    }

    func getValidWindows(frontOnly: Bool) -> [SCWindow] {
        let frontAppId = frontOnly ? NSWorkspace.shared.frontmostApplication?.processIdentifier : nil
        // in sonoma, there is a new new purple thing overlaying the traffic lights, I don't really want this to show up.
        // its title is simply "Window", but its bundle id is the same as the parent, so this seems like a strange bodge..
        return availableContent!.windows.filter {
            guard let app = $0.owningApplication,
                let title = $0.title, !title.isEmpty else {
                return false
            }
            return !excludedWindows.contains(app.bundleIdentifier)
                && !title.contains("Item-0")
                && title != "Window"
                && (!frontOnly
                    || frontAppId == nil // include all if none is frontmost
                    || (frontAppId == app.processID))
        }
    }

    func allowShortcuts(_ allow: Bool) {
        if allow {
            KeyboardShortcuts.enable(.recordCurrentDisplay, .recordCurrentWindow, .recordSystemAudio)
        } else {
            KeyboardShortcuts.disable(.recordCurrentDisplay, .recordCurrentWindow, .recordSystemAudio)
        }
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        if stream != nil {
            stopRecording()
        }

        // Stop the audio unit when the application terminates
        if let audioUnit = audioUnit {
            AudioOutputUnitStop(audioUnit)
            AudioComponentInstanceDispose(audioUnit)
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
}

@MainActor
final class AppState: ObservableObject {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        KeyboardShortcuts.onKeyDown(for: .recordSystemAudio) { [self] in
            Task { await toggleRecording(type: "audio") }
        }
        KeyboardShortcuts.onKeyDown(for: .recordCurrentDisplay) { [self] in
            Task { await toggleRecording(type: "display") }
        }
        KeyboardShortcuts.onKeyDown(for: .recordCurrentWindow) { [self] in
            Task { await toggleRecording(type: "window") }
        }
    }

    func toggleRecording(type: String) async {
        appDelegate.allowShortcuts(false)
        if appDelegate.stream == nil {
            let menuItem = NSMenuItem() // this will be our sender, which includes details about which content it is we want to record
            menuItem.identifier = NSUserInterfaceItemIdentifier(type)
            if type == "display" {
                if let currentDisplayID = appDelegate.getScreenWithMouse()?.displayID { // use display with mouse on it
                    menuItem.title = currentDisplayID.description
                } else { // fall back to first available display
                    menuItem.title = (appDelegate.availableContent!.displays.first?.displayID.description)!
                }
            } else if type == "window" {
                if let windowID = await appDelegate.getFocusedWindowID() {
                    menuItem.title = windowID.description
                } else {
                    // todo: relay lack of windows to user
                    appDelegate.allowShortcuts(true)
                    return
                }
            }
            appDelegate.prepRecord(menuItem)
        } else {
            appDelegate.stopRecording()
        }
    }
}

extension String {
    var local: String { return NSLocalizedString(self, comment: "") }
}
