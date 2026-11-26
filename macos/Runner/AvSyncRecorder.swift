import AVFoundation
import Cocoa
import FlutterMacOS

/// Hardware-clock-synchronized webcam Video + Audio recorder for EEG experiments.
///
/// Captures H.264 + AAC into an `.mp4` container using `AVCaptureSession` and
/// `AVAssetWriter`, reporting the exact host wall-clock and monotonic uptime of
/// the very first encoded video frame and periodic drift telemetry over a
/// `FlutterMethodChannel`.
final class AvSyncRecorder: NSObject,
  AVCaptureVideoDataOutputSampleBufferDelegate,
  AVCaptureAudioDataOutputSampleBufferDelegate
{
  static let channelName = "ccs_mobile_studio/av_sync"

  private let channel: FlutterMethodChannel
  private let sessionQueue = DispatchQueue(label: "com.ccs.avsync.session")

  private var captureSession: AVCaptureSession?
  private var assetWriter: AVAssetWriter?
  private var videoInput: AVAssetWriterInput?
  private var audioInput: AVAssetWriterInput?

  private var isRecording = false
  private var sessionStartedWriting = false
  private var firstFrameReported = false
  private var firstPts: CMTime = .invalid
  private var firstWallDate: Date?
  private var lastPts: CMTime = .invalid
  private var lastPulseWallTime: TimeInterval = 0
  private var frameCount: Int = 0
  private var outputPath: String?

  init(messenger: FlutterBinaryMessenger) {
    self.channel = FlutterMethodChannel(
      name: AvSyncRecorder.channelName,
      binaryMessenger: messenger
    )
    super.init()
    self.channel.setMethodCallHandler { [weak self] call, result in
      self?.handleMethodCall(call, result: result)
    }
  }

  private func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isAvailable":
      let hasVideo = AVCaptureDevice.default(for: .video) != nil
      let hasAudio = AVCaptureDevice.default(for: .audio) != nil
      result(["available": hasVideo || hasAudio, "hasVideo": hasVideo, "hasAudio": hasAudio])

    case "startRecording":
      guard let args = call.arguments as? [String: Any],
        let path = args["path"] as? String
      else {
        result(FlutterError(code: "INVALID_ARGS", message: "Missing output path", details: nil))
        return
      }
      ensurePermissionsAndStart(path: path, result: result)

    case "stopRecording":
      stopRecording(result: result)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func ensurePermissionsAndStart(path: String, result: @escaping FlutterResult) {
    let videoStatus = AVCaptureDevice.authorizationStatus(for: .video)
    let startWithAudioCheck = {
      let audioStatus = AVCaptureDevice.authorizationStatus(for: .audio)
      if audioStatus == .notDetermined {
        AVCaptureDevice.requestAccess(for: .audio) { _ in
          self.sessionQueue.async {
            self.beginCapture(path: path, result: result)
          }
        }
      } else {
        self.sessionQueue.async {
          self.beginCapture(path: path, result: result)
        }
      }
    }

    if videoStatus == .notDetermined {
      AVCaptureDevice.requestAccess(for: .video) { granted in
        if !granted {
          DispatchQueue.main.async {
            result(
              FlutterError(
                code: "PERMISSION_DENIED",
                message: "Camera permission was denied in System Settings.",
                details: nil
              )
            )
          }
          return
        }
        startWithAudioCheck()
      }
    } else if videoStatus == .denied || videoStatus == .restricted {
      result(
        FlutterError(
          code: "PERMISSION_DENIED",
          message: "Camera permission denied. Enable it in System Settings -> Privacy & Security -> Camera.",
          details: nil
        )
      )
    } else {
      startWithAudioCheck()
    }
  }

  private func beginCapture(path: String, result: @escaping FlutterResult) {
    if isRecording {
      DispatchQueue.main.async {
        result(FlutterError(code: "ALREADY_RECORDING", message: "AV recording already running", details: nil))
      }
      return
    }

    let url = URL(fileURLWithPath: path)
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: path) {
      try? fileManager.removeItem(at: url)
    }
    try? fileManager.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    let session = AVCaptureSession()
    session.beginConfiguration()
    if session.canSetSessionPreset(.hd1280x720) {
      session.sessionPreset = .hd1280x720
    } else if session.canSetSessionPreset(.medium) {
      session.sessionPreset = .medium
    }

    guard let videoDevice = AVCaptureDevice.default(for: .video) else {
      session.commitConfiguration()
      DispatchQueue.main.async {
        result(FlutterError(code: "NO_CAMERA", message: "No webcam device found.", details: nil))
      }
      return
    }

    do {
      let videoDeviceInput = try AVCaptureDeviceInput(device: videoDevice)
      if session.canAddInput(videoDeviceInput) {
        session.addInput(videoDeviceInput)
      }
    } catch {
      session.commitConfiguration()
      DispatchQueue.main.async {
        result(FlutterError(code: "CAMERA_INIT_FAILED", message: error.localizedDescription, details: nil))
      }
      return
    }

    var hasAudioTrack = false
    if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
      let audioDevice = AVCaptureDevice.default(for: .audio),
      let audioDeviceInput = try? AVCaptureDeviceInput(device: audioDevice),
      session.canAddInput(audioDeviceInput)
    {
      session.addInput(audioDeviceInput)
      hasAudioTrack = true
    }

    let vOut = AVCaptureVideoDataOutput()
    vOut.alwaysDiscardsLateVideoFrames = false
    vOut.videoSettings = [
      kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
    ]
    vOut.setSampleBufferDelegate(self, queue: sessionQueue)
    guard session.canAddOutput(vOut) else {
      session.commitConfiguration()
      DispatchQueue.main.async {
        result(FlutterError(code: "OUTPUT_FAILED", message: "Cannot attach video output.", details: nil))
      }
      return
    }
    session.addOutput(vOut)

    if hasAudioTrack {
      let aOut = AVCaptureAudioDataOutput()
      aOut.setSampleBufferDelegate(self, queue: sessionQueue)
      if session.canAddOutput(aOut) {
        session.addOutput(aOut)
      } else {
        hasAudioTrack = false
      }
    }
    session.commitConfiguration()

    let writer: AVAssetWriter
    do {
      writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    } catch {
      DispatchQueue.main.async {
        result(FlutterError(code: "WRITER_INIT_FAILED", message: error.localizedDescription, details: nil))
      }
      return
    }

    let dims = CMVideoFormatDescriptionGetDimensions(videoDevice.activeFormat.formatDescription)
    let width = dims.width > 0 ? Int(dims.width) : 1280
    let height = dims.height > 0 ? Int(dims.height) : 720
    let vSettings: [String: Any] = [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: width,
      AVVideoHeightKey: height,
      AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: 2_500_000,
        AVVideoMaxKeyFrameIntervalKey: 30,
      ],
    ]
    let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: vSettings)
    vIn.expectsMediaDataInRealTime = true
    if writer.canAdd(vIn) {
      writer.add(vIn)
    }

    var aIn: AVAssetWriterInput?
    if hasAudioTrack {
      let aSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 44100,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 96000,
      ]
      let audioWriterInput = AVAssetWriterInput(mediaType: .audio, outputSettings: aSettings)
      audioWriterInput.expectsMediaDataInRealTime = true
      if writer.canAdd(audioWriterInput) {
        writer.add(audioWriterInput)
        aIn = audioWriterInput
      }
    }

    self.captureSession = session
    self.assetWriter = writer
    self.videoInput = vIn
    self.audioInput = aIn
    self.outputPath = path
    self.sessionStartedWriting = false
    self.firstFrameReported = false
    self.firstPts = .invalid
    self.lastPts = .invalid
    self.firstWallDate = nil
    self.lastPulseWallTime = 0
    self.frameCount = 0
    self.isRecording = true

    session.startRunning()
    DispatchQueue.main.async {
      result([
        "started": true,
        "path": path,
        "hasAudio": aIn != nil,
        "width": width,
        "height": height,
      ])
    }
  }

  private func stopRecording(result: @escaping FlutterResult) {
    sessionQueue.async {
      guard self.isRecording else {
        DispatchQueue.main.async {
          result(["stopped": false])
        }
        return
      }
      self.isRecording = false
      self.captureSession?.stopRunning()
      self.captureSession = nil

      let capturedFrames = self.frameCount
      let savedPath = self.outputPath
      let startWall = self.firstWallDate
      let durationSec =
        (self.firstPts.isValid && self.lastPts.isValid)
        ? max(0.0, CMTimeGetSeconds(CMTimeSubtract(self.lastPts, self.firstPts)))
        : 0.0

      guard let writer = self.assetWriter, self.sessionStartedWriting else {
        self.assetWriter = nil
        self.videoInput = nil
        self.audioInput = nil
        DispatchQueue.main.async {
          result([
            "stopped": true,
            "path": savedPath ?? "",
            "frameCount": capturedFrames,
            "durationSec": durationSec,
          ])
        }
        return
      }

      self.videoInput?.markAsFinished()
      self.audioInput?.markAsFinished()
      writer.finishWriting {
        let stopWallMs = Date().timeIntervalSince1970 * 1000.0
        let firstWallMs = (startWall?.timeIntervalSince1970 ?? 0) * 1000.0
        self.assetWriter = nil
        self.videoInput = nil
        self.audioInput = nil
        DispatchQueue.main.async {
          result([
            "stopped": true,
            "path": savedPath ?? "",
            "frameCount": capturedFrames,
            "durationSec": durationSec,
            "firstFrameUtcMs": firstWallMs,
            "stopUtcMs": stopWallMs,
          ])
        }
      }
    }
  }

  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard isRecording, CMSampleBufferDataIsReady(sampleBuffer) else { return }
    guard let writer = assetWriter else { return }

    let isVideo = output is AVCaptureVideoDataOutput
    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

    if !sessionStartedWriting {
      guard isVideo else { return }  // Start session cleanly on exact first video frame PTS
      if writer.startWriting() {
        writer.startSession(atSourceTime: pts)
        sessionStartedWriting = true
        firstPts = pts
        firstWallDate = Date()
        lastPulseWallTime = ProcessInfo.processInfo.systemUptime
      } else {
        return
      }
    }

    if isVideo {
      if let vIn = videoInput, vIn.isReadyForMoreMediaData {
        vIn.append(sampleBuffer)
        frameCount += 1
        lastPts = pts
        if !firstFrameReported {
          firstFrameReported = true
          let utcMs = (firstWallDate ?? Date()).timeIntervalSince1970 * 1000.0
          let uptimeSec = ProcessInfo.processInfo.systemUptime
          let ptsSec = CMTimeGetSeconds(pts)
          DispatchQueue.main.async {
            self.channel.invokeMethod(
              "onFirstFrame",
              arguments: [
                "first_frame_utc_ms": utcMs,
                "monotonic_uptime_sec": uptimeSec,
                "pts_sec": ptsSec,
              ]
            )
          }
        } else {
          let nowUptime = ProcessInfo.processInfo.systemUptime
          if nowUptime - lastPulseWallTime >= 10.0, let wallStart = firstWallDate {
            lastPulseWallTime = nowUptime
            let wallElapsed = Date().timeIntervalSince(wallStart)
            let ptsElapsed = CMTimeGetSeconds(CMTimeSubtract(pts, firstPts))
            let frames = frameCount
            DispatchQueue.main.async {
              self.channel.invokeMethod(
                "onSyncPulse",
                arguments: [
                  "elapsed_wall_sec": wallElapsed,
                  "elapsed_pts_sec": ptsElapsed,
                  "frame_count": frames,
                ]
              )
            }
          }
        }
      }
    } else if let aIn = audioInput, aIn.isReadyForMoreMediaData {
      aIn.append(sampleBuffer)
    }
  }
}
