// Vita3K project
// Copyright (C) 2026 Vita3K team
//
// This program is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 2 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License along
// with this program; if not, write to the Free Software Foundation, Inc.,
// 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

// Built-in JIT, helper side: StikJIT (StikDebug's JIT engine as a library, MPL-2.0, by the StikDebug
// team; it bundles jkcoxson's idevice) attaches a debugger to Hinoki from this separate process. An app
// can't debug itself: the debugger stops every thread of the process it debugs, its own included.
// Compiled into the helper extension together with StikJIT's sources (see ios_bundle.cmake).

import Foundation

/// Progress lines go back to Hinoki (extension.mm sends them over the helper's connection)
public typealias V3KJITProgress = @convention(c) (UnsafePointer<CChar>?) -> Void

/// Runs StikJIT for Hinoki's process `pid` with the pairing file's bytes. Blocks until JIT is enabled
/// (the debugger has attached, run the script if one is needed, and detached) or it failed. Returns nil
/// on success, else a malloc'd message (free it).
@_cdecl("v3k_helper_enable_jit")
public func v3kHelperEnableJIT(_ pid: Int32, _ pairing: UnsafePointer<UInt8>?, _ pairingLength: Int,
                               _ scriptBase64: UnsafePointer<CChar>?, _ forceScript: Bool, _ port: Int32,
                               _ progress: V3KJITProgress?) -> UnsafeMutablePointer<CChar>? {
    func report(_ text: String) {
        text.withCString { progress?($0) }
    }
    func fail(_ text: String) -> UnsafeMutablePointer<CChar>? {
        strdup(text)
    }

    guard #available(iOS 17.4, *) else { return fail("Built-in JIT needs iOS 17.4 or newer") }
    guard let pairing, pairingLength > 0 else { return fail("No pairing file") }

    // The pairing file only lives here for the length of the attach, in the helper's own container
    let fileManager = FileManager.default
    let pairingURL = fileManager.temporaryDirectory.appendingPathComponent("pairing-\(UUID().uuidString).plist")
    do {
        try Data(bytes: pairing, count: pairingLength).write(to: pairingURL, options: .completeFileProtectionUntilFirstUserAuthentication)
    } catch {
        return fail("Could not write the pairing file: \(error.localizedDescription)")
    }
    defer { try? fileManager.removeItem(at: pairingURL) }

    // The Developer Disk Image is downloaded once and kept here; iOS keeps it mounted until a reboot
    let library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
    let ddiFolder = library.appendingPathComponent("StikJIT", isDirectory: true)
    try? fileManager.createDirectory(at: ddiFolder, withIntermediateDirectories: true)
    let paths = DDIPaths.default(in: ddiFolder)

    let script: StikJIT.Script
    if let scriptBase64, scriptBase64.pointee != 0 {
        script = .customBase64(String(cString: scriptBase64))
    } else {
        script = .universal
    }

    // The device's Remote Pairing port: newer iOS versions don't keep it at 49152, and StikJIT finds it
    // over Bonjour. Hinoki looks for it from the app (where iOS can ask for Local Network access) and
    // passes it here; without one, StikJIT looks itself. A longer timeout than StikJIT's 5 s: the
    // LocalDevVPN tunnel can take a few seconds to answer right after it connects
    let configuration: StikJIT.Configuration
    if port > 0, port <= Int32(UInt16.max) {
        report("Device port \(port)")
        configuration = StikJIT.Configuration(rsdPort: UInt16(port), automaticallyDiscoverRSDPort: false, connectionTimeout: 12)
    } else {
        configuration = StikJIT.Configuration(automaticallyDiscoverRSDPort: true, connectionTimeout: 12)
    }

    do {
        try StikJIT.enableJIT(targetPID: pid,
                              pairingFile: pairingURL,
                              ddiPaths: paths,
                              configuration: configuration,
                              script: script,
                              forceScript: forceScript,
                              preparationProgress: { stage in
                                  switch stage {
                                  case .checkingReachability: report("Connecting to the device (LocalDevVPN)")
                                  case .checkingDDI: report("Checking the Developer Disk Image")
                                  case .downloadingDDI(let fraction, let status): report("Downloading the Developer Disk Image \(Int(fraction * 100))% \(status)")
                                  case .mountingDDI(let fraction): report("Mounting the Developer Disk Image \(Int(fraction * 100))%")
                                  case .verifyingDDI: report("Verifying the Developer Disk Image")
                                  case .ready: report("Device ready, attaching the debugger")
                                  }
                              },
                              progress: { report($0) })
        return nil
    } catch {
        return fail(error.localizedDescription)
    }
}
