//
//  MixerViewModel.swift
//  macOSAudioMixer
//
//  Created by Mauricio Alcala on 05/12/25.
//

import Foundation
import Combine
import CoreAudio

// MARK: - Keys Namespace
private enum Keys {
    static let masterOutputKey = "selectedMasterOutputDeviceID"
    static let monitorOutputKey = "selectedMonitorOutputDeviceID"
    static let inputDevicesKey = "selectedInputDeviceIDs"
    static let inputVolumesKey = "inputVolumes"
    static let inputMutesKey = "inputMutes"
    static let masterVolumeKey = "masterVolume"
    static let isMasterMutedKey = "isMasterMuted"
    static let monitorVolumeKey = "monitorVolume"
    static let isMonitorMutedKey = "isMonitorMuted"
}

class MixerViewModel: ObservableObject {
    
    @Published var deviceManager = DeviceManager()
    @Published var audioEngine = AudioEngine()
    
    // Track selected devices
    @Published var selectedInputDevices: Set<AudioDevice> = [] { didSet { saveStateDebounced() } }
    
    // Track Volume Levels (Key: AudioObjectID, Value: 0.0 to 1.0)
    @Published var inputVolumes: [AudioObjectID: Float] = [:] { didSet { saveStateDebounced() } }
    // Track Mute State (Key: AudioObjectID, Value: Bool)
    @Published var inputMuted: [AudioObjectID: Bool] = [:] { didSet { saveStateDebounced() } }
    
    // Output Volumes & Mute
    @Published var masterVolume: Float = 0.25 { didSet { saveStateDebounced() } }
    @Published var isMasterMuted: Bool = false { didSet { saveStateDebounced() } }
    
    @Published var monitorVolume: Float = 0.25 { didSet { saveStateDebounced() } }
    @Published var isMonitorMuted: Bool = false { didSet { saveStateDebounced() } }
    
    // Output Devices
    @Published var selectedOutputDevice: AudioDevice? { didSet { saveStateDebounced() } }
    @Published var selectedMonitorDevice: AudioDevice? { didSet { saveStateDebounced() } }
    
    // Settings Reference
    let settings = AppSettings.shared
    
    private var cancellables = Set<AnyCancellable>()
    private var saveWorkItem: DispatchWorkItem?

    init() {
        // Initialize AudioEngine with current settings
        audioEngine.masterBoost = Float(settings.masterGain)
        audioEngine.monitorBoost = Float(settings.monitorGain)
        
        // Subscribe to Settings Changes
        settings.$masterGain
            .sink { [weak self] gain in
                self?.audioEngine.masterBoost = Float(gain)
            }
            .store(in: &cancellables)
            
        settings.$monitorGain
            .sink { [weak self] gain in
                self?.audioEngine.monitorBoost = Float(gain)
            }
            .store(in: &cancellables)
            
        // Subscribe to device manager changes to restore state
        deviceManager.$inputDevices
            .combineLatest(deviceManager.$outputDevices)
            .first() // Only restore once after devices are initially loaded
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                self?.restoreState()
            }
            .store(in: &cancellables)

        // 2. Master Output Logic
        $selectedOutputDevice
            .removeDuplicates()
            .sink { [weak self] device in
                guard let self = self else { return }
                
                // --- Validation: Prevent Master == Monitor ---
                if let newMaster = device, let currentMonitor = self.selectedMonitorDevice, newMaster.id == currentMonitor.id {
                    print("Validation: Master and Monitor cannot be the same. Clearing Monitor selection.")
                    DispatchQueue.main.async {
                        self.selectedMonitorDevice = nil
                    }
                }
                
                guard let device = device else {
                    print("Master Output cleared.")
                    self.audioEngine.stop()
                    return
                }
                
                print("Setting Master Output to: \(device.name)")
                do {
                    try self.audioEngine.setMasterOutputDevice(device: device)
                    if !self.selectedInputDevices.isEmpty {
                        try self.audioEngine.start()
                    }
                    // Apply volume immediately after setting device
                    self.setMasterVolume(self.masterVolume)
                    self.toggleMasterMute() // Retrigger mute to apply state
                    self.toggleMasterMute()
                } catch {
                    print("Error setting master output: \(error)")
                }
            }
            .store(in: &cancellables)
            
        // 3. Monitor Output Logic
        $selectedMonitorDevice
            .removeDuplicates()
            .sink { [weak self] device in
                guard let self = self else { return }
                
                // --- Validation: Prevent Monitor == Master ---
                if let newMonitor = device, let currentMaster = self.selectedOutputDevice, newMonitor.id == currentMaster.id {
                    print("Validation: Monitor and Master cannot be the same. Clearing Monitor selection.")
                    DispatchQueue.main.async {
                        self.selectedMonitorDevice = nil
                    }
                    return
                }
                
                if let device = device {
                    print("Setting Monitor Output to: \(device.name)")
                } else {
                    print("Disabling Monitor Output")
                }
                
                do {
                    try self.audioEngine.setMonitorOutputDevice(device: device)
                    // RESTART if we have active inputs
                    if !self.selectedInputDevices.isEmpty {
                        try self.audioEngine.start()
                    }
                    // Apply volume immediately after setting device
                    self.setMonitorVolume(self.monitorVolume)
                    self.toggleMonitorMute() // Retrigger mute
                    self.toggleMonitorMute()
                } catch {
                    print("Error setting monitor output: \(error)")
                }
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Input Management
    
    func toggleInput(_ device: AudioDevice) {
        if selectedInputDevices.contains(device) {
            // Remove
            selectedInputDevices.remove(device)
            audioEngine.removeInputDevice(device: device)
        } else {
            // Add
            selectedInputDevices.insert(device)
            
            // Initialize volume if not set
            if inputVolumes[device.id] == nil {
                inputVolumes[device.id] = Float(settings.defaultVolume)
            }
            // Initialize mute state if not set
            if inputMuted[device.id] == nil {
                inputMuted[device.id] = false
            }
            
            do {
                try audioEngine.addInputDevice(device: device)
                // Apply the stored volume immediately
                updateInputVolume(for: device)
                
                // Ensure engine is running
                if !audioEngine.isRunning {
                    try audioEngine.start()
                }
            } catch {
                print("Error adding input device: \(error)")
                selectedInputDevices.remove(device)
            }
        }
    }
    
    func isSelected(_ device: AudioDevice) -> Bool {
        return selectedInputDevices.contains(device)
    }
    
    // MARK: - Volume & Mute Control
    
    // Helper to calculate effective volume
    private func updateInputVolume(for device: AudioDevice) {
        let rawVol = inputVolumes[device.id] ?? Float(settings.defaultVolume)
        let isMuted = inputMuted[device.id] ?? false
        let effectiveVol = isMuted ? 0.0 : rawVol
        audioEngine.setVolume(for: device, volume: effectiveVol)
    }
    
    func setInputVolume(for device: AudioDevice, volume: Float) {
        inputVolumes[device.id] = volume
        // If muted, we update the stored value but don't apply it yet
        if !(inputMuted[device.id] ?? false) {
             audioEngine.setVolume(for: device, volume: volume)
        }
    }
    
    func toggleInputMute(for device: AudioDevice) {
        let current = inputMuted[device.id] ?? false
        inputMuted[device.id] = !current
        updateInputVolume(for: device)
    }
    
    func isInputMuted(for device: AudioDevice) -> Bool {
        if (inputMuted[device.id] ?? false) { return true }
        // Also consider it muted if volume is 0 (for UI purposes)
        return (inputVolumes[device.id] ?? 1.0) == 0.0
    }
    
    func getInputVolume(for device: AudioDevice) -> Float {
        return inputVolumes[device.id] ?? Float(settings.defaultVolume)
    }
    
    // --- Output Volume ---
    
    func setMasterVolume(_ volume: Float) {
        masterVolume = volume
        if !isMasterMuted {
            audioEngine.setMasterVolume(volume: volume)
        }
    }
    
    func toggleMasterMute() {
        isMasterMuted.toggle()
        audioEngine.setMasterVolume(volume: isMasterMuted ? 0.0 : masterVolume)
    }
    
    func setMonitorVolume(_ volume: Float) {
        monitorVolume = volume
        if !isMonitorMuted {
            audioEngine.setMonitorVolume(volume: volume)
        }
    }
    
    func toggleMonitorMute() {
        isMonitorMuted.toggle()
        audioEngine.setMonitorVolume(volume: isMonitorMuted ? 0.0 : monitorVolume)
    }
    
    // MARK: - Persistence
    
    private func saveState() {
        let defaults = UserDefaults.standard
        defaults.set(selectedOutputDevice?.id, forKey: Keys.masterOutputKey)
        defaults.set(selectedMonitorDevice?.id, forKey: Keys.monitorOutputKey)
        
        // Convert AudioObjectID to String for Dictionary keys, and [UInt32] for Array
        let selectedInputIDs = selectedInputDevices.map { $0.id }
        defaults.set(selectedInputIDs, forKey: Keys.inputDevicesKey)
        
        let inputVolStrings = inputVolumes.mapKeys { $0.description }
        defaults.set(inputVolStrings, forKey: Keys.inputVolumesKey)
        
        let inputMuteStrings = inputMuted.mapKeys { $0.description }
        defaults.set(inputMuteStrings, forKey: Keys.inputMutesKey)
        
        defaults.set(masterVolume, forKey: Keys.masterVolumeKey)
        defaults.set(isMasterMuted, forKey: Keys.isMasterMutedKey)
        defaults.set(monitorVolume, forKey: Keys.monitorVolumeKey)
        defaults.set(isMonitorMuted, forKey: Keys.isMonitorMutedKey)
    }
    
    private func saveStateDebounced() {
        saveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.saveState()
        }
        saveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
    }
    
    private func restoreState() {
        let defaults = UserDefaults.standard
        
        // Restore Master Output
        if let savedID = defaults.object(forKey: Keys.masterOutputKey) as? AudioObjectID {
            selectedOutputDevice = deviceManager.outputDevices.first { $0.id == savedID }
            // Apply volume/mute if device found
            if let _ = selectedOutputDevice {
                self.masterVolume = defaults.float(forKey: Keys.masterVolumeKey)
                self.isMasterMuted = defaults.bool(forKey: Keys.isMasterMutedKey)
                // Force engine to apply (sink will trigger this)
                self.setMasterVolume(self.masterVolume)
                self.audioEngine.setMasterVolume(volume: self.isMasterMuted ? 0.0 : self.masterVolume)
            }
        }
        
        // Restore Monitor Output
        if let savedID = defaults.object(forKey: Keys.monitorOutputKey) as? AudioObjectID {
            selectedMonitorDevice = deviceManager.outputDevices.first { $0.id == savedID }
            // Apply volume/mute if device found
            if let _ = selectedMonitorDevice {
                self.monitorVolume = defaults.float(forKey: Keys.monitorVolumeKey)
                self.isMonitorMuted = defaults.bool(forKey: Keys.isMonitorMutedKey)
                self.setMonitorVolume(self.monitorVolume)
                self.audioEngine.setMonitorVolume(volume: self.isMonitorMuted ? 0.0 : self.monitorVolume)
            }
        }
        
        // Restore Input Devices
        if let savedIDs = defaults.object(forKey: Keys.inputDevicesKey) as? [AudioObjectID] {
            let savedVolumes = defaults.object(forKey: Keys.inputVolumesKey) as? [String: Float] ?? [:]
            let savedMutes = defaults.object(forKey: Keys.inputMutesKey) as? [String: Bool] ?? [:]
            
            for savedID in savedIDs {
                if let device = deviceManager.inputDevices.first(where: { $0.id == savedID }) {
                    // This will trigger toggleInput and eventually addInputDevice
                    // but we need to ensure the correct volume/mute is applied after add
                    self.selectedInputDevices.insert(device)
                    self.inputVolumes[device.id] = savedVolumes[device.id.description] ?? Float(settings.defaultVolume)
                    self.inputMuted[device.id] = savedMutes[device.id.description] ?? false
                    
                    // Add to engine directly if not already there
                    // Use new PUBLIC method to check existence
                    if !audioEngine.isInputActive(deviceID: device.id) {
                         do {
                            try audioEngine.addInputDevice(device: device)
                            self.updateInputVolume(for: device) // Apply stored vol/mute
                        } catch {
                            print("Error restoring input device \(device.name): \(error)")
                        }
                    }
                }
            }
        }
    }
}

// Helper extension for dictionary key mapping
private extension Dictionary where Key == AudioObjectID {
    func mapKeys<NewKey: Hashable>(_ transform: (Key) throws -> NewKey) rethrows -> [NewKey: Value] {
        var newDict = [NewKey: Value]()
        for (key, value) in self {
            newDict[try transform(key)] = value
        }
        return newDict
    }
}
// Note: We don't need mapKeysBack unless we are parsing manually, but restoreState handles the loop.