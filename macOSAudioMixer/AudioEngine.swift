//
//  AudioEngine.swift
//  macOSAudioMixer
//
//  Created by Mauricio Alcala on 05/12/25.
//

import AVFoundation
import CoreAudio
import AudioToolbox
import Foundation
import Combine

/**
 * Component 3: Audio Engine (Multi-Input Dual-Engine Architecture + Monitoring)
 * Supports mixing N inputs into a single Master Output AND a Monitor Output.
 */
class AudioEngine: ObservableObject {
    
    // Published status for UI feedback
    @Published var isRunning: Bool = false
    
    // --- Master Output Engine (e.g., Virtual Cable) ---
    private let outputEngine = AVAudioEngine()
    private let mainMixer = AVAudioMixerNode()
    
    // --- Monitor Output Engine (e.g., Headphones) ---
    private let monitorEngine = AVAudioEngine()
    private let monitorMixer = AVAudioMixerNode()
    private var isMonitorEnabled = false // Only active if a device is selected
    
    // --- Input Channels ---
    // Key: AudioObjectID (Device ID)
    // Note: private access, but we expose 'isInputActive'
    private var inputChannels: [AudioObjectID: InputChannel] = [:]
    
    // --- Gain Settings ---
    // We use a lazy setup or just standard properties.
    // didSet is not called during init, only on subsequent updates.
    var masterBoost: Float = 1.0 {
        didSet {
            // Explicit self to be safe, though not strictly required
            self.updateVolumes()
        }
    }
    
    var monitorBoost: Float = 15.0 {
        didSet {
            self.updateVolumes()
        }
    }
    
    // Internal tracking of raw slider volumes (0.0 - 1.0)
    private var currentMasterRawVolume: Float = 0.25
    private var currentMonitorRawVolume: Float = 0.25
    
    init() {
        setupOutputGraphs()
    }
    
    private func setupOutputGraphs() {
        // 1. Setup Master
        outputEngine.attach(mainMixer)
        let masterFormat = outputEngine.outputNode.inputFormat(forBus: 0)
        outputEngine.connect(mainMixer, to: outputEngine.outputNode, format: masterFormat)
        mainMixer.outputVolume = currentMasterRawVolume * masterBoost
        
        // 2. Setup Monitor
        monitorEngine.attach(monitorMixer)
        let monitorFormat = monitorEngine.outputNode.inputFormat(forBus: 0)
        monitorEngine.connect(monitorMixer, to: monitorEngine.outputNode, format: monitorFormat)
        monitorMixer.outputVolume = currentMonitorRawVolume * monitorBoost
    }
    
    // MARK: - Master Control
    
    func start() throws {
        // Start Master
        if !outputEngine.isRunning {
            try outputEngine.start()
        }
        
        // Start Monitor (if enabled/configured)
        if isMonitorEnabled && !monitorEngine.isRunning {
            try monitorEngine.start()
        }
        
        // Start Channels (or ensure they resume playing if engine restarted)
        for channel in inputChannels.values {
            try channel.start()
        }
        
        self.isRunning = true
        print("✅ Master Audio Engine started.")
    }
    
    func stop() {
        outputEngine.stop()
        monitorEngine.stop()
        
        for channel in inputChannels.values {
            channel.stop()
        }
        
        self.isRunning = false
        print("Master Audio Engine stopped.")
    }

    // MARK: - Device Configuration
    
    func setMasterOutputDevice(device: AudioDevice) throws {
        // Stop everything cleanly so players reset
        self.stop()
        
        try setDevice(device.id, on: outputEngine.outputNode)
        print("Master Output configured: \(device.name)")
    }
    
    func setMonitorOutputDevice(device: AudioDevice?) throws {
        // Stop everything cleanly
        self.stop()
        
        guard let device = device else {
            isMonitorEnabled = false
            return
        }
        
        try setDevice(device.id, on: monitorEngine.outputNode)
        isMonitorEnabled = true
        print("Monitor Output configured: \(device.name)")
    }
    
    private func setDevice(_ deviceID: AudioObjectID, on node: AVAudioNode) throws {
        // Cast to AVAudioIONode to ensure we are dealing with a hardware interface
        guard let ioNode = node as? AVAudioIONode else {
            throw NSError(domain: "AudioEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Node is not an IO Node."])
        }
        
        let audioUnit = ioNode.audioUnit!
        var id = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioObjectID>.size)
        )
        guard status == kAudioHardwareNoError else {
            throw NSError(domain: "AudioEngine", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Failed to set device ID."])
        }
    }
    
    func addInputDevice(device: AudioDevice) throws {
        guard inputChannels[device.id] == nil else { return }
        
        print("Adding Input Device: \(device.name)...")
        
        // Create new Input Channel with references to BOTH engines
        let newChannel = InputChannel(
            device: device,
            masterEngine: outputEngine,
            masterMixer: mainMixer,
            monitorEngine: monitorEngine,
            monitorMixer: monitorMixer
        )
        
        try newChannel.configure()
        inputChannels[device.id] = newChannel
        
        if isRunning {
            try newChannel.start()
        }
    }
    
    func removeInputDevice(device: AudioDevice) {
        guard let channel = inputChannels[device.id] else { return }
        print("Removing Input Device: \(device.name)...")
        channel.stop()
        channel.teardown()
        inputChannels.removeValue(forKey: device.id)
    }
    
    func isInputActive(deviceID: AudioObjectID) -> Bool {
        return inputChannels[deviceID] != nil
    }
    
    // MARK: - Volume Control
    
    private func updateVolumes() {
        mainMixer.outputVolume = currentMasterRawVolume * masterBoost
        monitorMixer.outputVolume = currentMonitorRawVolume * monitorBoost
    }
    
    func setVolume(for device: AudioDevice, volume: Float) {
        if let channel = inputChannels[device.id] {
            channel.setVolume(volume)
        }
    }
    
    func setMasterVolume(volume: Float) {
        currentMasterRawVolume = volume
        mainMixer.outputVolume = volume * masterBoost
    }
    
    func setMonitorVolume(volume: Float) {
        currentMonitorRawVolume = volume
        monitorMixer.outputVolume = volume * monitorBoost
    }
}

// MARK: - Internal Input Channel Class

private class InputChannel {
    let device: AudioDevice
    
    // Capture Engine
    private let inputEngine = AVAudioEngine()
    
    // Playback Nodes (One for each output path)
    private let masterPlayer = AVAudioPlayerNode()
    private let monitorPlayer = AVAudioPlayerNode()
    
    private var converter: AVAudioConverter?

    
    // References
    private unowned let masterEngine: AVAudioEngine
    private unowned let masterMixer: AVAudioMixerNode
    private unowned let monitorEngine: AVAudioEngine
    private unowned let monitorMixer: AVAudioMixerNode
    
    init(device: AudioDevice,
         masterEngine: AVAudioEngine, masterMixer: AVAudioMixerNode,
         monitorEngine: AVAudioEngine, monitorMixer: AVAudioMixerNode) {
        self.device = device
        self.masterEngine = masterEngine
        self.masterMixer = masterMixer
        self.monitorEngine = monitorEngine
        self.monitorMixer = monitorMixer
    }
    
    func configure() throws {
        // 1. Setup Master Path
        masterEngine.attach(masterPlayer)
        let masterFormat = masterMixer.outputFormat(forBus: 0)
        masterEngine.connect(masterPlayer, to: masterMixer, format: masterFormat)
        
        // 2. Setup Monitor Path
        monitorEngine.attach(monitorPlayer)
        let monitorFormat = monitorMixer.outputFormat(forBus: 0)
        monitorEngine.connect(monitorPlayer, to: monitorMixer, format: monitorFormat)
        
        // 3. Setup Input Hardware
        let inputNode = inputEngine.inputNode
        inputEngine.disconnectNodeOutput(inputNode) // Disconnect direct loopback output of the capture engine to prevent echo
        let inputAudioUnit = inputNode.audioUnit!
        var inputDeviceID = device.id
        let status = AudioUnitSetProperty(
            inputAudioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &inputDeviceID,
            UInt32(MemoryLayout<AudioObjectID>.size)
        )
        guard status == kAudioHardwareNoError else {
            throw NSError(domain: "InputChannel", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Failed to set input device ID."])
        }
        
        // 4. Converter logic (assuming Master format is the target standard)
        // We'll convert to the Master format, and assume Monitor can handle it (or let Core Audio handle minor mismatches)
        let inputFormat = inputNode.inputFormat(forBus: 0)
        if inputFormat != masterFormat {
            self.converter = AVAudioConverter(from: inputFormat, to: masterFormat)
        }
        
        // 5. Tap
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] (buffer, time) in
            guard let self = self else { return }
            self.processBuffer(buffer, inputFormat: inputFormat, outputFormat: masterFormat)
        }
    }
    
    private func processBuffer(_ buffer: AVAudioPCMBuffer, inputFormat: AVAudioFormat, outputFormat: AVAudioFormat) {
        // Helper to schedule on both
        let schedule = { (buf: AVAudioPCMBuffer) in
            // Schedule on Master
            self.masterPlayer.scheduleBuffer(buf)
            // Schedule on Monitor (if engine is running, otherwise it just queues or is ignored)
            self.monitorPlayer.scheduleBuffer(buf)
        }
        
        if let converter = self.converter {
            let ratio = outputFormat.sampleRate / inputFormat.sampleRate
            let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
            
            if let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCapacity) {
                var error: NSError? = nil
                let inputCallback: AVAudioConverterInputBlock = { _, outStatus in
                    outStatus.pointee = .haveData
                    return buffer
                }
                
                let status = converter.convert(to: outputBuffer, error: &error, withInputFrom: inputCallback)
                if status != .error, error == nil {
                    schedule(outputBuffer)
                }
            }
        } else {
            schedule(buffer)
        }
    }
    
    func start() throws {
        if !inputEngine.isRunning { try inputEngine.start() }
        if !masterPlayer.isPlaying { masterPlayer.play() }
        ensureMonitorPlaying()
    }
    
    func ensureMonitorPlaying() {
        if !monitorPlayer.isPlaying && monitorEngine.isRunning {
            monitorPlayer.play()
        }
    }
    
    func stop() {
        inputEngine.stop()
        masterPlayer.stop()
        monitorPlayer.stop()
    }
    
    func teardown() {
        masterEngine.detach(masterPlayer)
        monitorEngine.detach(monitorPlayer)
    }
    
    func setVolume(_ volume: Float) {
        masterPlayer.volume = volume
        monitorPlayer.volume = volume
    }
}