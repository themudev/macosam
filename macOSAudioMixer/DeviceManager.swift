//
//  DeviceManager.swift
//  macOSAudioMixer
//
//  Created by Mauricio Alcala on 05/12/25.
//

import Foundation
import Combine
import CoreAudio
import AudioToolbox
import AVFoundation

// Workaround for kAudioObjectScopeGlobal not being visible from CoreAudio/AudioToolbox modules
let kAudioObjectScopeGlobal: AudioObjectPropertyScope = 0x676c6f62 // 'glob'

/**
 * Component 2: Device Manager
 * Queries Core Audio for devices and monitors for hot-plugging.
 */
class DeviceManager: ObservableObject {
    
    // Published properties that SwiftUI views will bind to
    @Published var inputDevices: [AudioDevice] = []
    @Published var outputDevices: [AudioDevice] = []
    @Published var isLoading: Bool = false
    
    init() {
        // 2. Start listening for device changes (hot-plugging)
        setupDeviceListener()
        
        // Load devices immediately, loadDevices() will schedule it asynchronously
        self.loadDevices()
    }
    
    // MARK: - Device Query
    
    // Public function to refresh the lists
    func loadDevices() {
        // Ensure we set loading state on the main thread
        DispatchQueue.main.async {
            self.isLoading = true
        }
        
        // Query Core Audio on a background thread
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let inputs = self.getDevices(isInput: true)
            let outputs = self.getDevices(isInput: false)
            
            // Publish the new devices and clear loading on the main thread
            DispatchQueue.main.async {
                self.inputDevices = inputs
                self.outputDevices = outputs
                self.isLoading = false
                print("DeviceManager: Loaded \(inputs.count) inputs and \(outputs.count) outputs asynchronously.")
            }
        }
    }
    
    /**
     * Finds all available audio devices of a specific type (input or output).
     * FIX: Updated array allocation and data size handling for robust Core Audio query.
     */
    private func getDevices(isInput: Bool) -> [AudioDevice] {
        var devices: [AudioDevice] = []
        
        // 1. Get the required size of the device list
        var dataSize: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        // Get the size of the data first
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        )
        
        // Retry logic for size query failure
        if status != kAudioHardwareNoError {
            print("Core Audio Warning: Device list size query failed first attempt (\(status)). Retrying...")
            usleep(1000) // Sleep for 1ms
            status = AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &dataSize
            )
        }
        
        guard status == kAudioHardwareNoError else {
            print("Core Audio Error: Failed to get device list size after retry: \(status)")
            return devices
        }
        
        // 2. Allocate the array and fetch the data directly (Robust Swift style)
        let deviceCount = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = [AudioObjectID](repeating: 0, count: deviceCount)
        
        // IMPORTANT: We must update dataSize to the actual buffer size before the call
        dataSize = UInt32(deviceCount * MemoryLayout<AudioObjectID>.size)

        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceIDs // Swift safely passes a pointer to the array's buffer
        )
        
        guard status == kAudioHardwareNoError else {
            print("Core Audio Error: Failed to get device list: \(status)")
            return devices
        }
        
        // 3. Iterate through all device IDs to check if they support input/output and get their names
        for deviceID in deviceIDs {
            // Check if the device has streams for the requested scope (input or output)
            let scope = isInput ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput
            if deviceSupportsStreams(deviceID: deviceID, scope: scope) {
                // Get the device name
                let name = getDeviceName(deviceID: deviceID)
                devices.append(AudioDevice(id: deviceID, name: name, isInput: isInput))
            }
        }
        
        return devices.sorted { $0.name < $1.name } // Sort alphabetically
    }
    
    // Helper function to check if a device has input/output streams
    private func deviceSupportsStreams(deviceID: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        
        guard status == kAudioHardwareNoError, dataSize > 0 else { return false }
        
        // Allocate buffer to hold the AudioBufferList
        let bufferListPointer = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(dataSize))
        defer { bufferListPointer.deallocate() }
        
        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, bufferListPointer)
        
        guard status == kAudioHardwareNoError else { return false }
        
        // Cast to AudioBufferList and check mNumberBuffers
        let bufferList = bufferListPointer.withMemoryRebound(to: AudioBufferList.self, capacity: 1) { $0.pointee }
        
        return bufferList.mNumberBuffers > 0
    }
    
    // Helper function to get the device's human-readable name
    private func getDeviceName(deviceID: AudioObjectID) -> String {
        // Change: Declare as non-optional CFString, initialize to nil (C-style)
        var name: CFString? = nil   
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var propertySize = UInt32(MemoryLayout<CFString?>.size)
        
        // Use Swift's 'withUnsafeMutablePointer' to safely pass the address
        let status = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(
                deviceID,
                &propertyAddress,
                0,
                nil,
                &propertySize,
                pointer
            )
        }
        
        // Now, we safely unwrap 'name' as an optional in the conditional check
        if status == kAudioHardwareNoError, let cfName = name {
            // ARC will manage the release of cfName when it's bridged to String
            return cfName as String
        } else {
            return "Unknown Device (\(deviceID))"
        }
    }
    
    // MARK: - Device Listener (Hot-Plugging)
    
    /**
     * Registers a property listener for the global kAudioHardwarePropertyDevices property.
     */
    private func setupDeviceListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        // The listener function must be a C function or a closure marked with @convention(c)
        let status = AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            deviceListenerCallback,
            unsafeBitCast(self, to: UnsafeMutableRawPointer.self)
        )
        
        if status != kAudioHardwareNoError {
            print("Core Audio Error: Failed to add device listener: \(status)")
        }
    }
    
    /**
     * Static C callback function that Core Audio calls when the device list changes.
     */
    private let deviceListenerCallback: AudioObjectPropertyListenerProc = { (
        objectID,
        numberAddresses,
        addresses,
        clientData
    ) -> OSStatus in
        
        // Re-cast the clientData pointer back to a DeviceManager instance
        let manager = unsafeBitCast(clientData, to: DeviceManager.self)
        
        // IMPORTANT: Core Audio callbacks are NOT on the main thread.
        DispatchQueue.main.async {
            print("Device list changed. Updating...")
            manager.loadDevices()
        }
        
        return kAudioHardwareNoError
    }
    
    // Clean up the listener when the object is deinitialized
    deinit {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        AudioObjectRemovePropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            deviceListenerCallback,
            unsafeBitCast(self, to: UnsafeMutableRawPointer.self)
        )
    }
}
