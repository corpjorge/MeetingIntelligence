import AVFoundation
import CoreMedia
import ScreenCaptureKit

@MainActor
@available(macOS 15.0, *)
func configureVideoAPIs(window: SCWindow, destination: URL, sampleTime: CMTime) throws {
    let picker = SCContentSharingPicker.shared
    var pickerConfiguration = SCContentSharingPickerConfiguration()
    pickerConfiguration.allowedPickerModes = [.singleWindow]
    picker.defaultConfiguration = pickerConfiguration
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let configuration = SCStreamConfiguration()
    configuration.width = 1920
    configuration.height = 1080
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
    configuration.capturesAudio = false
    configuration.captureMicrophone = false
    configuration.queueDepth = 3
    configuration.captureDynamicRange = .SDR
    let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
    if let clock = stream.synchronizationClock {
        _ = CMSyncConvertTime(sampleTime, from: clock, to: CMClockGetHostTimeClock())
    }
    let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
    writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: 1920,
        AVVideoHeightKey: 1080
    ])
    input.expectsMediaDataInRealTime = true
    if writer.canAdd(input) { writer.add(input) }
    let recording = SCRecordingOutputConfiguration()
    recording.outputURL = destination
    recording.videoCodecType = .h264
    recording.outputFileType = .mp4
}
