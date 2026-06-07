//
//  ContentView.swift
//  macOSAudioMixer
//
//  Created by Mauricio Alcala on 05/12/25.
//

import SwiftUI

struct ContentView: View {
    
    @StateObject var viewModel = MixerViewModel()
    @State private var showPermissionAlert = false
    @State private var micPermissionStatus: PermissionsManager.MicPermissionStatus = .notDetermined
    @State private var showSettings = false
    @State private var rotateRefresh = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            headerView
            
            // Loading Bar
            loadingIndicatorView
            
            // Main content
            if micPermissionStatus != .granted {
                permissionRequestView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                mainControlView
            }
        }
        .background(
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()
        )
        .frame(minWidth: 750, minHeight: 600)
        .onAppear {
            checkPermissions()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }
    
    // Header View
    var headerView: some View {
        HStack(spacing: 15) {
            Image(systemName: "music.note.house.fill")
                .font(.title2)
                .foregroundStyle(
                    LinearGradient(
                        colors: [.purple, .blue],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("macOS Audio Mixer")
                        .font(.system(.title3, design: .rounded).bold())
                    
                    // Pulsating status dot
                    HStack(spacing: 4) {
                        Circle()
                            .fill(viewModel.audioEngine.isRunning ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text(viewModel.audioEngine.isRunning ? "LIVE" : "STANDBY")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(viewModel.audioEngine.isRunning ? .green : .orange)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        (viewModel.audioEngine.isRunning ? Color.green : Color.orange)
                            .opacity(0.1)
                    )
                    .cornerRadius(4)
                }
                
                Text("Studio-grade multi-device router & level controller")
                    .font(.caption2)
                    .foregroundColor(.gray)
            }
            
            Spacer()
            
            // Refresh Button
            Button(action: {
                withAnimation(.linear(duration: 1.0)) {
                    rotateRefresh = true
                }
                viewModel.deviceManager.loadDevices()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    rotateRefresh = false
                }
            }) {
                Image(systemName: "arrow.clockwise")
                    .font(.title3)
                    .foregroundColor(.primary)
                    .rotationEffect(Angle(degrees: viewModel.deviceManager.isLoading || rotateRefresh ? 360 : 0))
                    .animation(viewModel.deviceManager.isLoading || rotateRefresh ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: viewModel.deviceManager.isLoading || rotateRefresh)
            }
            .buttonStyle(GrowingIconButton())
            .help("Scan Audio Devices")
            
            // Settings Button
            Button(action: { showSettings = true }) {
                Image(systemName: "slider.horizontal.3")
                    .font(.title3)
                    .foregroundColor(.primary)
            }
            .buttonStyle(GrowingIconButton())
            .help("Mixer Settings")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 15)
        .background(Color.primary.opacity(0.03))
    }
    
    // Loading Indicator View (thin line)
    var loadingIndicatorView: some View {
        VStack {
            if viewModel.deviceManager.isLoading {
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(height: 2)
                    .transition(.opacity)
            } else {
                Spacer()
                    .frame(height: 2)
            }
        }
    }
    
    // Permission request view
    var permissionRequestView: some View {
        VStack(spacing: 20) {
            Image(systemName: "mic.fill.badge.plus")
                .font(.system(size: 60))
                .foregroundStyle(.purple.gradient)
            
            Text("Microphone Permission Required")
                .font(.title2).bold()
            
            Text("This utility routes physical and virtual audio devices.\nTo configure input routes, macOS requires audio capture authorization.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundColor(.gray)
                .padding(.horizontal, 40)
            
            Button("Grant Microphone Access") {
                PermissionsManager.requestPermission { granted in
                    self.micPermissionStatus = granted ? .granted : .denied
                    if !granted { self.showPermissionAlert = true }
                }
            }
            .buttonStyle(ModernProminentButtonStyle())
            .alert("Permission Required", isPresented: $showPermissionAlert) {
                Button(role: .cancel) { } label: { Text("OK") }
            } message: {
                Text("Microphone access is essential for this app. Please grant permission in System Settings > Privacy & Security > Microphone.")
            }
        }
    }
    
    // Main Control View
    var mainControlView: some View {
        HStack(alignment: .top, spacing: 20) {
            
            // Left Column: Input Channels
            VStack(alignment: .leading, spacing: 15) {
                HStack {
                    Text("INPUT CHANNELS")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    Text("\(viewModel.selectedInputDevices.count) Active")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.purple)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.purple.opacity(0.15))
                        .cornerRadius(4)
                }
                
                ScrollView {
                    VStack(spacing: 12) {
                        if viewModel.deviceManager.inputDevices.isEmpty {
                            VStack(spacing: 15) {
                                Image(systemName: "bolt.horizontal.circle.fill")
                                    .font(.system(size: 30))
                                    .foregroundColor(.gray)
                                Text("No hardware inputs detected.")
                                    .font(.body)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 250)
                        } else {
                            ForEach(viewModel.deviceManager.inputDevices) { device in
                                DeviceRow(device: device, viewModel: viewModel)
                            }
                        }
                    }
                    .padding(.trailing, 5) // Space for scrollbar
                }
            }
            .frame(maxWidth: .infinity)
            
            // Right Column: Output Busses & Info
            VStack(spacing: 20) {
                
                // Master Bus Card
                OutputBusCard(
                    title: "MASTER OUTPUT",
                    icon: "arrow.up.forward.circle.fill",
                    color: .purple,
                    device: $viewModel.selectedOutputDevice,
                    devices: viewModel.deviceManager.outputDevices,
                    volume: Binding(
                        get: { viewModel.masterVolume },
                        set: { viewModel.setMasterVolume($0) }
                    ),
                    isMuted: viewModel.isMasterMuted,
                    toggleMute: { viewModel.toggleMasterMute() }
                )
                
                // Monitor Bus Card
                OutputBusCard(
                    title: "MONITOR OUTPUT",
                    icon: "headphones.circle.fill",
                    color: .blue,
                    device: $viewModel.selectedMonitorDevice,
                    devices: viewModel.deviceManager.outputDevices,
                    volume: Binding(
                        get: { viewModel.monitorVolume },
                        set: { viewModel.setMonitorVolume($0) }
                    ),
                    isMuted: viewModel.isMonitorMuted,
                    toggleMute: { viewModel.toggleMonitorMute() },
                    nullText: "No Monitor (Muted)"
                )
                
                // Tips / Instructions Card
                instructionsCard
            }
            .frame(width: 300)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 15)
    }
    
    // Instruction Box
    var instructionsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("SYSTEM CABLING TIP", systemImage: "info.circle.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary)
            
            VStack(alignment: .leading, spacing: 4) {
                Text("1. Route Mac Sound Output -> BlackHole 2ch.")
                Text("2. Check 'BlackHole 2ch' in Input Channels.")
                Text("3. Set Master Output to Zoom/OBS Virtual input.")
                Text("4. Set Monitor Output to your Headphones.")
            }
            .font(.system(size: 10))
            .foregroundColor(.secondary)
            .lineSpacing(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.02))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.04), lineWidth: 1)
        )
    }
    
    // Check permission logic
    func checkPermissions() {
        self.micPermissionStatus = PermissionsManager.getStatus()
        if self.micPermissionStatus == .notDetermined {
            PermissionsManager.requestPermission { granted in
                self.micPermissionStatus = granted ? .granted : .denied
            }
        }
    }
}

// MARK: - Modern UI Subviews

struct DeviceRow: View {
    let device: AudioDevice
    @ObservedObject var viewModel: MixerViewModel
    @State private var isHovering = false
    
    var body: some View {
        let isSelected = viewModel.isSelected(device)
        let isMuted = viewModel.isInputMuted(for: device)
        
        HStack(spacing: 12) {
            // Checkbox/Toggle Button
            Button(action: { viewModel.toggleInput(device) }) {
                HStack(spacing: 8) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundColor(isSelected ? .purple : .gray)
                    
                    Image(systemName: "mic.fill")
                        .font(.system(size: 12))
                        .foregroundColor(isSelected ? .purple : .gray)
                    
                    Text(device.name)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        .foregroundColor(isSelected ? .primary : .secondary)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            
            Spacer()
            
            // Slider and Mute Controls (visible only if enabled)
            if isSelected {
                HStack(spacing: 10) {
                    // Volume Slider
                    Slider(
                        value: Binding(
                            get: { viewModel.getInputVolume(for: device) },
                            set: { viewModel.setInputVolume(for: device, volume: $0) }
                        ),
                        in: 0...1
                    )
                    .frame(width: 140)
                    .accentColor(.purple)
                    .disabled(isMuted)
                    
                    // Decibels/Percent display
                    Text("\(Int(viewModel.getInputVolume(for: device) * 100))%")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(isMuted ? .secondary.opacity(0.5) : .primary)
                        .frame(width: 32, alignment: .trailing)
                    
                    // Mute Button
                    Button(action: { viewModel.toggleInputMute(for: device) }) {
                        Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 11))
                            .foregroundColor(isMuted ? .red : .gray)
                            .frame(width: 28, height: 22)
                            .background(isMuted ? Color.red.opacity(0.15) : Color.primary.opacity(0.04))
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.purple.opacity(0.04) : Color.primary.opacity(0.01))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.purple.opacity(0.2) : Color.primary.opacity(0.04), lineWidth: 1)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .scaleEffect(isHovering ? 1.01 : 1.0)
    }
}

struct OutputBusCard: View {
    let title: String
    let icon: String
    let color: Color
    @Binding var device: AudioDevice?
    let devices: [AudioDevice]
    @Binding var volume: Float
    let isMuted: Bool
    let toggleMute: () -> Void
    var nullText: String = "Select Output Destination..."
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Title Header
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundColor(color)
                    .font(.title3)
                
                Text(title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)
                
                Spacer()
                
                if device != nil && !isMuted {
                    Text("ACTIVE")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(color)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(color.opacity(0.1))
                        .cornerRadius(3)
                }
            }
            
            // Picker
            Picker("", selection: $device) {
                Text(nullText).tag(nil as AudioDevice?)
                ForEach(devices) { dev in
                    Text(dev.name).tag(dev as AudioDevice?)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            
            if device != nil {
                // Controls
                VStack(spacing: 8) {
                    HStack(spacing: 10) {
                        // Mute button
                        Button(action: toggleMute) {
                            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .font(.system(size: 11))
                                .foregroundColor(isMuted ? .red : .gray)
                                .frame(width: 28, height: 24)
                                .background(isMuted ? Color.red.opacity(0.15) : Color.primary.opacity(0.04))
                                .cornerRadius(5)
                        }
                        .buttonStyle(.plain)
                        
                        // Volume Slider
                        Slider(value: $volume, in: 0...1)
                            .accentColor(color)
                            .disabled(isMuted)
                        
                        // Digit display
                        Text("\(Int(volume * 100))%")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(isMuted ? .secondary.opacity(0.5) : .primary)
                            .frame(width: 32, alignment: .trailing)
                    }
                }
            } else {
                Text("Select a hardware or virtual driver output above to route this mix.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.02))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(device != nil ? color.opacity(0.15) : Color.primary.opacity(0.04), lineWidth: 1)
        )
    }
}

// MARK: - Custom Style Modifiers

struct GrowingIconButton: ButtonStyle {
    @State private var isHovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 28, height: 28)
            .background(isHovered ? Color.primary.opacity(0.06) : Color.clear)
            .cornerRadius(6)
            .onHover { hover in
                isHovered = hover
            }
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
    }
}

struct ModernProminentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                LinearGradient(
                    colors: [.purple, .indigo],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .foregroundColor(.white)
            .font(.body.bold())
            .cornerRadius(8)
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
    }
}

// NSViewRepresentable for frosted glass background in SwiftUI macOS
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}