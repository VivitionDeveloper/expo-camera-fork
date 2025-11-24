import UIKit
@preconcurrency import AVFoundation
import ExpoModulesCore

protocol CameraSessionManagerDelegate: AnyObject {
  var sessionQueue: DispatchQueue { get }
  var videoQuality: VideoQuality { get }
  var mode: CameraMode { get }
  var pictureSize: PictureSize { get }
  var isMuted: Bool { get }
  var active: Bool { get }
  var presetCamera: AVCaptureDevice.Position { get }
  var selectedLens: String? { get }
  var torchEnabled: Bool { get }
  var autoFocus: AVCaptureDevice.FocusMode { get }
  var zoom: CGFloat { get }
  var whiteBalanceTemperature: Int { get }
  var onMountError: EventDispatcher { get }
  var onCameraReady: EventDispatcher { get }
  var permissionsManager: EXPermissionsInterface? { get }
  var appContext: AppContext? { get }
  var barcodeScanner: BarcodeScanner? { get }

  func emitAvailableLenses()
  func changePreviewOrientation()
  func logPhotoOutput(_ message: String, _ output: AVCapturePhotoOutput?)
}

class CameraSessionManager: NSObject {
  weak var delegate: CameraSessionManagerDelegate?

  let session = AVCaptureSession()
  private let deviceDiscovery = DeviceDiscovery()

  private var captureDeviceInput: AVCaptureDeviceInput?
  private var photoOutput: AVCapturePhotoOutput?
  private var videoFileOutput: AVCaptureMovieFileOutput?
  private var maxPhotoDimsObservation: NSKeyValueObservation?

  init(delegate: CameraSessionManagerDelegate) {
    self.delegate = delegate
    super.init()
  }

  func initializeCaptureSessionInput() {
    guard let delegate else {
      return
    }
    delegate.sessionQueue.async {
      self.updateDevice()
      self.startSession()
    }
  }

  func updateSessionPreset(preset: AVCaptureSession.Preset) {
#if !targetEnvironment(simulator)
    if session.canSetSessionPreset(preset) {
      if session.sessionPreset != preset {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = preset
        NSLog("[Camera] Session preset updated to \(preset.rawValue)")
      }
    } else {
      // The selected preset cannot be used on the current device so we fall back to the highest available.
      if session.sessionPreset != .high {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .high
        NSLog("[Camera] Session preset updated to \(session.sessionPreset.rawValue)")
      }
    }
#endif
  }

  func updateDevice() {
    guard let delegate else {
      return
    }

    let lenses = delegate.presetCamera == .back
    ? deviceDiscovery.backCameraLenses
    : deviceDiscovery.frontCameraLenses

    let selectedDevice = lenses.first {
      $0.localizedName == delegate.selectedLens
    }

    if let selectedDevice {
      addDevice(selectedDevice)
    } else {
      let device = delegate.presetCamera == .back
      ? deviceDiscovery.defaultBackCamera
      : deviceDiscovery.defaultFrontCamera

      if let device {
        addDevice(device)
      }
    }
  }

  func updateCameraIsActive() {
    guard let delegate else {
      return
    }
    delegate.sessionQueue.async {
      if delegate.active {
        if !self.session.isRunning {
          self.session.startRunning()
        }
      } else {
        self.session.stopRunning()
      }
    }
  }

  func setCameraMode() {
    guard let delegate else {
      return
    }

    if delegate.mode == .video {
      if videoFileOutput == nil {
        setupMovieFileCapture()
      }
      updateSessionAudioIsMuted()
    } else {
      cleanupMovieFileCapture()
    }
  }

  func updateSessionAudioIsMuted() {
    guard let delegate else {
      return
    }

    NSLog("[Camera] updateSessionAudioIsMuted: isMuted = \(delegate.isMuted)")
    session.beginConfiguration()
    defer { session.commitConfiguration() }

    if delegate.isMuted {
      for input in session.inputs {
        if let deviceInput = input as? AVCaptureDeviceInput {
          if deviceInput.device.hasMediaType(.audio) {
            session.removeInput(input)
            return
          }
        }
      }
    }

    if !delegate.isMuted && delegate.mode == .video {
      if let audioCapturedevice = AVCaptureDevice.default(for: .audio) {
        do {
          let audioDeviceInput = try AVCaptureDeviceInput(device: audioCapturedevice)
          if session.canAddInput(audioDeviceInput) {
            session.addInput(audioDeviceInput)
          }
        } catch {
          log.info("\(#function): \(error.localizedDescription)")
        }
      }
    }
  }

  func enableTorch() {
    guard let delegate, let device = captureDeviceInput?.device, device.hasTorch else {
      return
    }

    do {
      try device.lockForConfiguration()
      if device.hasTorch && device.isTorchModeSupported(.on) {
        device.torchMode = delegate.torchEnabled ? .on : .off
      }
    } catch {
      log.info("\(#function): \(error.localizedDescription)")
    }
    device.unlockForConfiguration()
  }

  func setFocusMode() {
    guard let device = captureDeviceInput?.device, let delegate else {
      return
    }

    do {
      try device.lockForConfiguration()
      if device.isFocusModeSupported(delegate.autoFocus), device.focusMode != delegate.autoFocus {
        device.focusMode = delegate.autoFocus
      }
    } catch {
      log.info("\(#function): \(error.localizedDescription)")
      return
    }
    device.unlockForConfiguration()
  }

  func updateZoom() {
    guard let device = captureDeviceInput?.device, let delegate else {
      return
    }

    do {
      try device.lockForConfiguration()
      device.videoZoomFactor = max(1.0, min(delegate.zoom, device.activeFormat.videoMaxZoomFactor))
    } catch {
      log.info("\(#function): \(error.localizedDescription)")
    }

    device.unlockForConfiguration()
  }

  func updateWhiteBalance() {
    guard let device = captureDeviceInput?.device, let delegate else {
      return
    }

    do {
      try device.lockForConfiguration()
      if device.isWhiteBalanceModeSupported(.locked) && device.isLockingWhiteBalanceWithCustomDeviceGainsSupported() {
        if delegate.whiteBalanceTemperature > 0 {
          let temperatureAndTint = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
            temperature: Float(delegate.whiteBalanceTemperature),
            tint: 0.0)
          var whiteBalanceGains = device.deviceWhiteBalanceGains(for: temperatureAndTint)
          whiteBalanceGains = self.normalizedGains(whiteBalanceGains, for: device)        
          device.setWhiteBalanceModeLocked(with: whiteBalanceGains, completionHandler: nil)
          NSLog("[Camera] Set white balance to \(delegate.whiteBalanceTemperature)K, gains: \(whiteBalanceGains)")
        }
        else {
          device.whiteBalanceMode = .continuousAutoWhiteBalance
          NSLog("[Camera] Set white balance to continuous mode")
        }
      }
      else {
        NSLog("[Camera] White balance locked mode or custom device gains are not supported on this device.")
      }
    } catch {
      NSLog("[Camera] Locking for config failed \(#function): \(error.localizedDescription)")
    }
    device.unlockForConfiguration()
  }

  func getAvailableLenses() -> [String] {
    guard let delegate else {
      return []
    }

    let availableLenses = delegate.presetCamera == AVCaptureDevice.Position.back
    ? deviceDiscovery.backCameraLenses
    : deviceDiscovery.frontCameraLenses

    // Lens ordering can be varied which causes problems if you keep the result in react state.
    // We sort them to provide a stable ordering
    return availableLenses.map { $0.localizedName }.sorted {
      $0 < $1
    }
  }

  func setupMovieFileCapture() {
    let output = AVCaptureMovieFileOutput()
    if session.canAddOutput(output) {
      session.addOutput(output)
      videoFileOutput = output
    }
  }

  func cleanupMovieFileCapture() {
    if let videoFileOutput {
      if session.outputs.contains(videoFileOutput) {
        session.removeOutput(videoFileOutput)
        self.videoFileOutput = nil
      }
    }
  }

  func stopSession() {
#if targetEnvironment(simulator)
    return
#else
    NSLog("[Camera] Stopping session and removing all inputs and outputs.")
    session.beginConfiguration()
    for input in self.session.inputs {
      session.removeInput(input)
    }

    for output in session.outputs {
      session.removeOutput(output)
    }
    session.commitConfiguration()

    if session.isRunning {
      session.stopRunning()
    }
#endif
  }

  func addErrorNotification() {
    guard let delegate else {
      return
    }

    Task {
      let errors = NotificationCenter.default.notifications(named: .AVCaptureSessionRuntimeError, object: self.session)
        .compactMap({ $0.userInfo?[AVCaptureSessionErrorKey] as? AVError })
      for await error in errors where error.code == .mediaServicesWereReset {
        if !session.isRunning {
          session.startRunning()
        }
        delegate.sessionQueue.async {
          self.updateSessionAudioIsMuted()
        }
        delegate.onMountError(["message": "Camera session was reset"])
      }
    }
  }

  var currentPhotoOutput: AVCapturePhotoOutput? {
    return photoOutput
  }

  var currentVideoFileOutput: AVCaptureMovieFileOutput? {
    return videoFileOutput
  }

  var currentDevice: AVCaptureDevice? {
    return captureDeviceInput?.device
  }

  // Called from CameraView::handleTapToExpose
  func setExposureAndFocus(at devicePoint: CGPoint) {
    guard let device = captureDeviceInput?.device else {
      return
    }

    do {
      try device.lockForConfiguration()

      // Auto Exposure on tapped point
      if device.isExposurePointOfInterestSupported,
         device.isExposureModeSupported(.continuousAutoExposure) {
        device.exposurePointOfInterest = devicePoint
        device.exposureMode = .continuousAutoExposure
      }

      // Auto Focus on tapped point
      if device.isFocusPointOfInterestSupported,
         device.isFocusModeSupported(.continuousAutoFocus) {
        device.focusPointOfInterest = devicePoint
        device.focusMode = .continuousAutoFocus
      }

      // Not for now:
      // device.isSubjectAreaChangeMonitoringEnabled = true
    } catch {
      NSLog("[Camera] \(#function): \(error.localizedDescription)")
    }

    device.unlockForConfiguration()
  }

  private func normalizedGains(_ gains: AVCaptureDevice.WhiteBalanceGains,
                                for device: AVCaptureDevice) -> AVCaptureDevice.WhiteBalanceGains {
    var g = gains
    let maxGain = device.maxWhiteBalanceGain
    g.redGain   = min(max(g.redGain,   1.0), maxGain)
    g.greenGain = min(max(g.greenGain, 1.0), maxGain)
    g.blueGain  = min(max(g.blueGain,  1.0), maxGain)
    return g
  }

  private func addDevice(_ device: AVCaptureDevice) {
    guard let delegate else {
      return
    }

    // check if device is already present
    if let currentDevice = captureDeviceInput?.device, currentDevice.uniqueID == device.uniqueID {
      NSLog("[Camera] Device already added: \(device.localizedName)")
      return
    }

    session.beginConfiguration()
    defer {
      session.commitConfiguration()
      delegate.emitAvailableLenses()
    }
    if let captureDeviceInput {
      session.removeInput(captureDeviceInput)
    }

    do {
      let deviceInput = try AVCaptureDeviceInput(device: device)
      if session.canAddInput(deviceInput) {
        session.addInput(deviceInput)
        captureDeviceInput = deviceInput
        NSLog("[Camera] Added device input: \(device.localizedName)")
        updateZoom()
        updateWhiteBalance()
      }
    } catch {
      delegate.onMountError(["message": "Camera could not be started - \(error.localizedDescription)"])
    }
  }

  private func startSession() {
#if targetEnvironment(simulator)
    return
#else
    guard let delegate else {
      return
    }
    guard let manager = delegate.permissionsManager else {
      log.info("Permissions module not found.")
      return
    }
    if !manager.hasGrantedPermission(usingRequesterClass: CameraOnlyPermissionRequester.self) {
      delegate.onMountError(["message": "Camera permissions not granted - component could not be rendered."])
      return
    }

    let photoOutput = AVCapturePhotoOutput()
    photoOutput.isLivePhotoCaptureEnabled = false
    photoOutput.isHighResolutionCaptureEnabled = true
    photoOutput.maxPhotoQualityPrioritization = .quality
    
    session.beginConfiguration()
    if session.canAddOutput(photoOutput) {
      session.addOutput(photoOutput)
      self.photoOutput = photoOutput
    }

    session.sessionPreset = delegate.mode == .video
    ? delegate.videoQuality.toPreset()
    : delegate.pictureSize.toCapturePreset()
    
    if #available(iOS 17.0, *),
      let device = currentDevice {
      let supported = device.activeFormat.supportedMaxPhotoDimensions

      if let maxDim = supported.max(by: { $0.width * $0.height < $1.width * $1.height }) {
        self.photoOutput?.isHighResolutionCaptureEnabled = true
        self.photoOutput?.maxPhotoQualityPrioritization = .quality
        self.photoOutput?.maxPhotoDimensions = maxDim
        NSLog("[Camera] Configured output.maxPhotoDimensions to \(self.photoOutput?.maxPhotoDimensions.width)x\(self.photoOutput?.maxPhotoDimensions.height)")


        maxPhotoDimsObservation = self.photoOutput?.observe(\.maxPhotoDimensions, options: [.old, .new]) {
          output, change in
          NSLog("[Camera] maxPhotoDimensions changed: \(self.photoOutput?.maxPhotoDimensions.width)x\(self.photoOutput?.maxPhotoDimensions.height)")
        }
      }
    }

    // for now: remove existing metadata outputs to be sure it doesn't interfere with high resolution photo capture
    for output in session.outputs {
      if output is AVCaptureMetadataOutput {
        session.removeOutput(output)
        NSLog("[Camera] Removed AVCaptureMetadataOutput")
      }
    }
    
    session.commitConfiguration()

    delegate.logPhotoOutput("After commit", self.photoOutput)

    addErrorNotification()
    delegate.changePreviewOrientation()
    delegate.barcodeScanner?.maybeStartBarcodeScanning()
    updateCameraIsActive() // starts the session
    DispatchQueue.main.async { [weak delegate] in
      delegate?.onCameraReady()
    }
    enableTorch()
    delegate.logPhotoOutput("End of startSession", self.photoOutput)
#endif
  }
}
