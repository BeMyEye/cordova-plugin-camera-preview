import AVFoundation
import CoreImage

protocol OnFocusDelegate: class {
    func onFocus()
}

class CameraSessionManager: NSObject {

    var ciFilter: CIFilter?
    var filterLock: NSLock?
    var session: AVCaptureSession?
    var sessionQueue: DispatchQueue?
    var defaultCamera: AVCaptureDevice.Position?
    var defaultFlashMode: AVCaptureDevice.FlashMode = .off
    var videoZoomFactor: CGFloat = 0.0
    var device: AVCaptureDevice?
    var videoDeviceInput: AVCaptureDeviceInput?
    var stillImageOutput: AVCaptureStillImageOutput?
    var delegate: CameraRenderController?
    var currentWhiteBalanceMode = ""
    var colorTemperatures = [String: TemperatureAndTint]()
    var onTapToFocusDoneCompletion: (() -> Void)?
    
    override init() {
        super.init()

        // Create the AVCaptureSession
        session = AVCaptureSession()
        sessionQueue = DispatchQueue(label: "session queue")
        if (session?.canSetSessionPreset(AVCaptureSession.Preset.photo))! {
            session?.sessionPreset = AVCaptureSession.Preset.photo
        }
        filterLock = NSLock()
        let wbIncandescent = TemperatureAndTint()
        wbIncandescent.mode = "incandescent"
        wbIncandescent.minTemperature = 2200
        wbIncandescent.maxTemperature = 3200
        wbIncandescent.tint = 0
        let wbCloudyDaylight = TemperatureAndTint()
        wbCloudyDaylight.mode = "cloudy-daylight"
        wbCloudyDaylight.minTemperature = 6000
        wbCloudyDaylight.maxTemperature = 7000
        wbCloudyDaylight.tint = 0
        let wbDaylight = TemperatureAndTint()
        wbDaylight.mode = "daylight"
        wbDaylight.minTemperature = 5500
        wbDaylight.maxTemperature = 5800
        wbDaylight.tint = 0
        let wbFluorescent = TemperatureAndTint()
        wbFluorescent.mode = "fluorescent"
        wbFluorescent.minTemperature = 3300
        wbFluorescent.maxTemperature = 3800
        wbFluorescent.tint = 0
        let wbShade = TemperatureAndTint()
        wbShade.mode = "shade"
        wbShade.minTemperature = 7000
        wbShade.maxTemperature = 8000
        wbShade.tint = 0
        let wbWarmFluorescent = TemperatureAndTint()
        wbWarmFluorescent.mode = "warm-fluorescent"
        wbWarmFluorescent.minTemperature = 3000
        wbWarmFluorescent.maxTemperature = 3000
        wbWarmFluorescent.tint = 0
        let wbTwilight = TemperatureAndTint()
        wbTwilight.mode = "twilight"
        wbTwilight.minTemperature = 4000
        wbTwilight.maxTemperature = 4400
        wbTwilight.tint = 0
        
        colorTemperatures["incandescent"] = wbIncandescent
        colorTemperatures["cloudy-daylight"] = wbCloudyDaylight
        colorTemperatures["daylight"] = wbDaylight
        colorTemperatures["fluorescent"] = wbFluorescent
        colorTemperatures["shade"] = wbShade
        colorTemperatures["warm-fluorescent"] = wbWarmFluorescent
        colorTemperatures["twilight"] = wbTwilight
    }

    func getDeviceFormats() -> [AVCaptureDevice.Format] {
        let videoDevice: AVCaptureDevice? = cameraWithPosition(position: defaultCamera!)
        return videoDevice?.formats as! [AVCaptureDevice.Format]
    }
    
    func setupSession(_ defaultCamera: String?, completion: @escaping (_ started: Bool, _ error: String?) -> Void) {
        self.sessionQueue?.async(execute: {() -> Void in
            var success = true
            var setupError : Error? = nil
            
            print("defaultCamera: \(defaultCamera ?? "")")
            if defaultCamera == "front" {
                self.defaultCamera = .front
            } else {
                self.defaultCamera = .back
            }
            
            let videoDevice: AVCaptureDevice? = self.cameraWithPosition(position: self.defaultCamera!)
            
            if videoDevice?.hasFlash ?? false && videoDevice?.isFlashModeSupported(.auto) ?? false {
                do {
                    try videoDevice?.lockForConfiguration()
                    videoDevice?.flashMode = .auto
                    videoDevice?.unlockForConfiguration()
                } catch {
                    setupError = error
                }
            }
            
            if setupError != nil {
                print("\(setupError)")
                success = false
            }
            
            var videoDeviceInput: AVCaptureDeviceInput? = nil
            
            if let aDevice = videoDevice {
                videoDeviceInput = try? AVCaptureDeviceInput(device: aDevice)
            }
            
            if let videoDeviceInput = videoDeviceInput {
                if (self.session?.canAddInput(videoDeviceInput))! {
                    self.session?.addInput(videoDeviceInput)
                    self.videoDeviceInput = videoDeviceInput
                }
            }
            
            let stillImageOutput = AVCaptureStillImageOutput()
            if (self.session?.canAddOutput(stillImageOutput))! {
                self.session?.addOutput(stillImageOutput)
                stillImageOutput.outputSettings = [AVVideoCodecKey: AVVideoCodecJPEG]
                stillImageOutput.isHighResolutionStillImageOutputEnabled = true
                self.stillImageOutput = stillImageOutput
            }
            
            self.device = videoDevice
            completion(success, setupError?.localizedDescription)
        })

    }

    func updateOrientation(_ orientation: AVCaptureVideoOrientation) {
        var captureConnection: AVCaptureConnection?
        if stillImageOutput != nil {
            captureConnection = stillImageOutput?.connection(with: AVMediaType.video)
            if captureConnection?.isVideoOrientationSupported != nil {
                captureConnection?.videoOrientation = orientation
            }
        }
    }

    func switchCamera(_ completion: @escaping (_ switched: Bool) -> Void) {
        if defaultCamera == .front {
            defaultCamera = .back
        } else {
            defaultCamera = .front
        }
    
        let error: Error? = nil
        var success = true
        self.session?.beginConfiguration()
        if let videoDeviceInput = self.videoDeviceInput {
            self.session?.removeInput(videoDeviceInput)
            self.videoDeviceInput = nil
        }
        var videoDevice: AVCaptureDevice? = nil
        videoDevice = self.cameraWithPosition(position: self.defaultCamera!)
        if videoDevice?.hasFlash ?? false && videoDevice?.isFlashModeSupported(AVCaptureDevice.FlashMode(rawValue: self.defaultFlashMode.rawValue)!) ?? false {
            if try! videoDevice?.lockForConfiguration() != nil {
                videoDevice?.flashMode = AVCaptureDevice.FlashMode(rawValue: self.defaultFlashMode.rawValue)!
                videoDevice?.unlockForConfiguration()
            } else {
                if let anError = error {
                    print("\(anError)")
                }
                success = false
            }
        }
        var videoDeviceInput: AVCaptureDeviceInput? = nil
        if let aDevice = videoDevice {
            videoDeviceInput = try? AVCaptureDeviceInput(device: aDevice)
        }
        if error != nil {
            if let anError = error {
                print("\(anError)")
            }
            success = false
        }
        
        
        if let videoDeviceInput = videoDeviceInput {
            if (self.session?.canAddInput(videoDeviceInput))! {
                self.session?.addInput(videoDeviceInput)
                self.videoDeviceInput = videoDeviceInput
            }
        }

        self.session?.commitConfiguration()
        self.device = videoDevice
        completion(success)
    }

    func getFocusModes() -> [Any]? {
        var focusModes = [AnyHashable]()
        if (device?.isFocusModeSupported(AVCaptureDevice.FocusMode(rawValue: 0)!))! {
            focusModes.append("fixed")
        }
        if (device?.isFocusModeSupported(AVCaptureDevice.FocusMode(rawValue: 1)!))! {
            focusModes.append("auto")
        }
        if (device?.isFocusModeSupported(AVCaptureDevice.FocusMode(rawValue: 2)!))! {
            focusModes.append("continuous")
        }
        return focusModes as [Any]
    }

    func getFocusMode() -> String? {
        var focusMode: String
        let videoDevice: AVCaptureDevice? = cameraWithPosition(position: defaultCamera!)
        switch videoDevice!.focusMode {
            case .locked:
                focusMode = "fixed"
            case .autoFocus:
                focusMode = "auto"
            case .continuousAutoFocus:
                focusMode = "continuous"
        }
        return focusMode
    }

    func setFocusmode(_ focusMode: String?) -> String? {
        var errMsg = ""
        let videoDevice: AVCaptureDevice? = cameraWithPosition(position: defaultCamera!)
        try? device?.lockForConfiguration()
        if focusMode == "fixed" {
            if videoDevice?.isFocusModeSupported(.locked) ?? false {
                videoDevice?.focusMode = .locked
            } else {
                errMsg = "Focus mode not supported"
            }
        } else if focusMode == "auto" {
            if videoDevice?.isFocusModeSupported(.autoFocus) ?? false {
                videoDevice?.focusMode = .autoFocus
            } else {
                errMsg = "Focus mode not supported"
            }
        } else if focusMode == "continuous" {
            if videoDevice?.isFocusModeSupported(.continuousAutoFocus) ?? false {
                videoDevice?.focusMode = .continuousAutoFocus
            } else {
                errMsg = "Focus mode not supported"
            }
        } else {
            errMsg = "Exposure mode not supported"
        }
        device?.unlockForConfiguration()
        if errMsg != "" {
            print("\(errMsg)")
            return "ERR01"
        }
        return focusMode
    }


    func getFlashModes() -> [Any]? {
        var flashModes = [AnyHashable]()
        if (device?.hasFlash)! {
            if (device?.isFlashModeSupported(.off))! {
                flashModes.append("off")
            }
            if (device?.isFlashModeSupported(.on))! {
                flashModes.append("on")
            }
            if (device?.isFlashModeSupported(.off))! {
                flashModes.append("auto")
            }
            if (device?.hasTorch)! {
                flashModes.append("torch")
            }
        }
        return flashModes as [Any]
    }

    func getFlashMode() -> Int {
        if device!.hasFlash && device!.isFlashModeSupported(AVCaptureDevice.FlashMode(rawValue: defaultFlashMode.rawValue)!) {
            return device!.flashMode.rawValue
        }
        return -1
    }

    func setFlashMode(_ flashMode: AVCaptureDevice.FlashMode) {
        // Let's save the setting even if we can't set it up on this camera.
        self.defaultFlashMode = flashMode
        
        if device!.hasFlash && device!.isFlashModeSupported(self.defaultFlashMode) {
            do {
                try device?.lockForConfiguration()
                
                if device!.hasTorch && device!.isTorchAvailable {
                    device?.torchMode = .off
                }
                device?.flashMode = self.defaultFlashMode
                device?.unlockForConfiguration()
            } catch let error {
                if error != nil {
                    print("\(error)")
                }
            }
        } else {
            print("Camera has no flash or flash mode not supported")
        }
    }

    func setTorchMode() {
        let error: Error? = nil
        
        if device!.hasTorch && device!.isTorchAvailable {
            if try! device?.lockForConfiguration() != nil {
                if (device?.isTorchModeSupported(.on))! {
                    device?.torchMode = .on
                } else if (device?.isTorchModeSupported(.auto))! {
                    device?.torchMode = .auto
                } else {
                    device?.torchMode = .off
                }
                device?.unlockForConfiguration()
            } else {
                if let anError = error {
                    print("\(anError)")
                }
            }
        } else {
            print("Camera has no flash or flash mode not supported")
        }
    }

    func setZoom(_ desiredZoomFactor: CGFloat) {
        try? device?.lockForConfiguration()
        videoZoomFactor = max(1.0, min(desiredZoomFactor, (device?.activeFormat.videoMaxZoomFactor)!))
        device?.videoZoomFactor = videoZoomFactor
        device?.unlockForConfiguration()
        print("\(videoZoomFactor) zoom factor set")
    }

    func getZoom() -> CGFloat {
        let videoDevice: AVCaptureDevice? = cameraWithPosition(position: defaultCamera!)
        return videoDevice?.videoZoomFactor ?? 0.0
    }

    func getHorizontalFOV() -> Float {
        let videoDevice: AVCaptureDevice? = cameraWithPosition(position: defaultCamera!)
        return videoDevice?.activeFormat.videoFieldOfView ?? 0.0
    }

    func getMaxZoom() -> CGFloat {
        let videoDevice: AVCaptureDevice? = cameraWithPosition(position: defaultCamera!)
        return videoDevice?.activeFormat.videoMaxZoomFactor ?? 0.0
    }

    func getExposureModes() -> [Any]? {
        let videoDevice: AVCaptureDevice? = cameraWithPosition(position: defaultCamera!)
        var exposureModes = [AnyHashable]()
        if videoDevice?.isExposureModeSupported(AVCaptureDevice.ExposureMode(rawValue: 0)!) ?? false {
            exposureModes.append("lock")
        }
        if videoDevice?.isExposureModeSupported(AVCaptureDevice.ExposureMode(rawValue: 1)!) ?? false {
            exposureModes.append("auto")
        }
        if videoDevice?.isExposureModeSupported(AVCaptureDevice.ExposureMode(rawValue: 2)!) ?? false {
            exposureModes.append("cotinuous")
        }
        if videoDevice?.isExposureModeSupported(AVCaptureDevice.ExposureMode(rawValue: 3)!) ?? false {
            exposureModes.append("custom")
        }
        print("\(exposureModes)")
        return exposureModes as [Any]
    }

    func getExposureMode() -> String? {
        var exposureMode: String
        let videoDevice: AVCaptureDevice? = cameraWithPosition(position: defaultCamera!)
        switch videoDevice?.exposureMode {
            case AVCaptureDevice.ExposureMode(rawValue: 0):
                exposureMode = "lock"
            case AVCaptureDevice.ExposureMode(rawValue: 1):
                exposureMode = "auto"
            case AVCaptureDevice.ExposureMode(rawValue: 2):
                exposureMode = "continuous"
            case AVCaptureDevice.ExposureMode(rawValue: 3):
                exposureMode = "custom"
            default:
                exposureMode = "unsupported"
                print("Mode not supported")
        }
        return exposureMode
    }

    func setExposureMode(_ exposureMode: String?) -> String? {
        var errMsg = ""
        let videoDevice: AVCaptureDevice? = cameraWithPosition(position: defaultCamera!)
        try? device?.lockForConfiguration()
        if exposureMode == "lock" {
            if videoDevice?.isExposureModeSupported(AVCaptureDevice.ExposureMode(rawValue: 0)!) ?? false {
                videoDevice?.exposureMode = AVCaptureDevice.ExposureMode(rawValue: 0)!
            } else {
                errMsg = "Exposure mode not supported"
            }
        } else if exposureMode == "auto" {
            if videoDevice?.isExposureModeSupported(AVCaptureDevice.ExposureMode(rawValue: 1)!) ?? false {
                videoDevice?.exposureMode = AVCaptureDevice.ExposureMode(rawValue: 1)!
            } else {
                errMsg = "Exposure mode not supported"
            }
        } else if exposureMode == "continuous" {
            if videoDevice?.isExposureModeSupported(AVCaptureDevice.ExposureMode(rawValue: 2)!) ?? false {
                videoDevice?.exposureMode = AVCaptureDevice.ExposureMode(rawValue: 2)!
            } else {
                errMsg = "Exposure mode not supported"
            }
        } else if exposureMode == "custom" {
            if videoDevice?.isExposureModeSupported(AVCaptureDevice.ExposureMode(rawValue: 3)!) ?? false {
                videoDevice?.exposureMode = AVCaptureDevice.ExposureMode(rawValue: 3)!
            } else {
                errMsg = "Exposure mode not supported"
            }
        } else {
            errMsg = "Exposure mode not supported"
        }
        device?.unlockForConfiguration()
        if errMsg != "" {
            print("\(errMsg)")
            return "ERR01"
        }
        return exposureMode
    }

    func getExposureCompensationRange() -> [Any]? {
        let videoDevice: AVCaptureDevice? = cameraWithPosition(position: defaultCamera!)
        let maxExposureCompensation = CGFloat(videoDevice?.maxExposureTargetBias ?? 0.0)
        let minExposureCompensation = CGFloat(videoDevice?.minExposureTargetBias ?? 0.0)
        let exposureCompensationRange = [minExposureCompensation, maxExposureCompensation]
        return exposureCompensationRange
    }

    func getExposureCompensation() -> CGFloat {
        let videoDevice: AVCaptureDevice? = cameraWithPosition(position: defaultCamera!)
        print("getExposureCompensation: \(videoDevice?.exposureTargetBias ?? 0.0)")
        return CGFloat(videoDevice?.exposureTargetBias ?? 0.0)
    }

    func setExposureCompensation(_ exposureCompensation: Float) {
        let error: Error? = nil
        if try! device?.lockForConfiguration() != nil {
            let exposureTargetBias: Float = max(device!.minExposureTargetBias, min(exposureCompensation, (device?.maxExposureTargetBias)!))
            device?.setExposureTargetBias(Float(exposureTargetBias), completionHandler: nil)
            device?.unlockForConfiguration()
        } else {
            if let anError = error {
                print("\(anError)")
            }
        }
    }

    func getSupportedWhiteBalanceModes() -> [Any]? {
        let videoDevice: AVCaptureDevice? = cameraWithPosition(position: defaultCamera!)
        print("maxWhiteBalanceGain: \(videoDevice?.maxWhiteBalanceGain ?? 0.0)")
        var whiteBalanceModes = [AnyHashable]()
        if videoDevice?.isWhiteBalanceModeSupported(AVCaptureDevice.WhiteBalanceMode(rawValue: 0)!) ?? false {
            whiteBalanceModes.append("lock")
        }
        if videoDevice?.isWhiteBalanceModeSupported(AVCaptureDevice.WhiteBalanceMode(rawValue: 1)!) ?? false {
            whiteBalanceModes.append("auto")
        }
        if videoDevice?.isWhiteBalanceModeSupported(AVCaptureDevice.WhiteBalanceMode(rawValue: 2)!) ?? false {
            whiteBalanceModes.append("continuous")
        }
        
        var enumerator = colorTemperatures.values.makeIterator()
        let wbTemperature: TemperatureAndTint! = TemperatureAndTint()
        
        while wbTemperature == enumerator.next() {
            var temperatureAndTintValues: AVCaptureDevice.WhiteBalanceTemperatureAndTintValues! = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues()
            temperatureAndTintValues.temperature = ((wbTemperature?.minTemperature)! + (wbTemperature?.maxTemperature)!) / 2
            temperatureAndTintValues.tint = wbTemperature?.tint ?? 0.0
            
            let rgbGains: AVCaptureDevice.WhiteBalanceGains? = videoDevice?.deviceWhiteBalanceGains(for: temperatureAndTintValues)
            if let aMode = wbTemperature?.mode {
                print("mode: \(aMode)")
            }
            if let aTemperature = wbTemperature?.minTemperature {
                print("minTemperature: \(aTemperature)")
            }
            if let aTemperature = wbTemperature?.maxTemperature {
                print("maxTemperature: \(aTemperature)")
            }
            print("blueGain: \(rgbGains?.blueGain ?? 0.0)")
            print("redGain: \(rgbGains?.redGain ?? 0.0)")
            print("greenGain: \(rgbGains?.greenGain ?? 0.0)")
            if ((rgbGains?.blueGain ?? 0.0) >= 1) && ((rgbGains?.blueGain ?? 0.0) <= (videoDevice?.maxWhiteBalanceGain ?? 0.0)) && ((rgbGains?.redGain ?? 0.0) >= 1) && ((rgbGains?.redGain ?? 0.0) <= (videoDevice?.maxWhiteBalanceGain ?? 0.0)) && ((rgbGains?.greenGain ?? 0.0) >= 1) && ((rgbGains?.greenGain ?? 0.0) <= (videoDevice?.maxWhiteBalanceGain ?? 0.0)) {
                if let aMode = wbTemperature?.mode {
                    whiteBalanceModes.append(aMode)
                }
            }
        }
        print("\(whiteBalanceModes)")
        return whiteBalanceModes
    }

    func getWhiteBalanceMode() -> String? {
        var whiteBalanceMode: String
        let videoDevice: AVCaptureDevice? = cameraWithPosition(position: defaultCamera!)
        switch videoDevice?.whiteBalanceMode {
            case AVCaptureDevice.WhiteBalanceMode (rawValue: 0):
                whiteBalanceMode = "lock"
                whiteBalanceMode = currentWhiteBalanceMode
            case AVCaptureDevice.WhiteBalanceMode (rawValue: 1):
                whiteBalanceMode = "auto"
            case AVCaptureDevice.WhiteBalanceMode (rawValue: 2):
                whiteBalanceMode = "continuous"
            default:
                whiteBalanceMode = "unsupported"
                print("White balance mode not supported")
        }
        return whiteBalanceMode
    }
    
    func setWhiteBalanceMode(_ whiteBalanceMode: String?) -> String? {
        var errMsg = "";
        print("plugin White balance mode: \(whiteBalanceMode ?? "")")
        let videoDevice: AVCaptureDevice? = cameraWithPosition(position: defaultCamera!)
        try? device?.lockForConfiguration()
        if whiteBalanceMode == "lock" {
            if videoDevice?.isWhiteBalanceModeSupported(AVCaptureDevice.WhiteBalanceMode(rawValue: 0)!) ?? false {
                videoDevice?.whiteBalanceMode = AVCaptureDevice.WhiteBalanceMode(rawValue: 0)!
            } else {
                errMsg = "White balance mode not supported"
            }
        } else if whiteBalanceMode == "auto" {
            if videoDevice?.isWhiteBalanceModeSupported(AVCaptureDevice.WhiteBalanceMode(rawValue: 1)!) ?? false {
                videoDevice?.whiteBalanceMode = AVCaptureDevice.WhiteBalanceMode(rawValue: 1)!
            } else {
                errMsg = "White balance mode not supported"
            }
        } else if whiteBalanceMode == "continuous" {
            if videoDevice?.isWhiteBalanceModeSupported(AVCaptureDevice.WhiteBalanceMode(rawValue: 2)!) ?? false {
                videoDevice?.whiteBalanceMode = AVCaptureDevice.WhiteBalanceMode(rawValue: 2)!
            } else {
                errMsg = "White balance mode not supported"
            }
        } else {
            print("Additional modes for \(whiteBalanceMode ?? "")")
            let temperatureForWhiteBalanceSetting = colorTemperatures[whiteBalanceMode!]
            if temperatureForWhiteBalanceSetting != nil {
                var temperatureAndTintValues: AVCaptureDevice.WhiteBalanceTemperatureAndTintValues! = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues()
                temperatureAndTintValues.temperature = ((temperatureForWhiteBalanceSetting?.minTemperature)! + (temperatureForWhiteBalanceSetting?.maxTemperature)!) / 2
                temperatureAndTintValues.tint = temperatureForWhiteBalanceSetting?.tint ?? 0.0
                let rgbGains: AVCaptureDevice.WhiteBalanceGains? = videoDevice?.deviceWhiteBalanceGains(for: temperatureAndTintValues)
                if ((rgbGains?.blueGain ?? 0.0) >= 1) && ((rgbGains?.blueGain ?? 0.0) <= (videoDevice?.maxWhiteBalanceGain ?? 0.0)) && ((rgbGains?.redGain ?? 0.0) >= 1) && ((rgbGains?.redGain ?? 0.0) <= (videoDevice?.maxWhiteBalanceGain ?? 0.0)) && ((rgbGains?.greenGain ?? 0.0) >= 1) && ((rgbGains?.greenGain ?? 0.0) <= (videoDevice?.maxWhiteBalanceGain ?? 0.0)) {
                    if let aGains = rgbGains {
                        videoDevice?.setWhiteBalanceModeLocked(with: aGains, completionHandler: nil)
                    }
                    currentWhiteBalanceMode = whiteBalanceMode!
                } else {
                    errMsg = "White balance mode not supported"
                }
            } else {
                errMsg = "White balance mode not supported"
            }
        }
        device?.unlockForConfiguration()
        
        if errMsg != "" {
            print("\(errMsg)")
            return "ERR01"
        }
        
        return whiteBalanceMode
    }
    
    func setPictureSize(_ format: AVCaptureDevice.Format?) {
        let error: Error? = nil
        
        if try! device?.lockForConfiguration() != nil {
            if let format = format {
                device?.activeFormat = format
            }
            device?.unlockForConfiguration()
            session?.commitConfiguration()
        } else {
            if let anError = error {
                print("\(anError)")
            }
        }
    }
    
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "adjustingFocus" {
            let adjustingFocus: Bool = change?[.newKey] as? Int == 1
            print(adjustingFocus)
            if !adjustingFocus {
                self.onTapToFocusDone()
                // Remove the observer when the camera is done focusing
                device?.removeObserver(self, forKeyPath: "adjustingFocus")
            }
        }
    }

    func takePictureOnFocus() {
        // add an observer, when takePictureOnFocus is requested
        let flag: NSKeyValueObservingOptions = .new
        device?.addObserver(self, forKeyPath: "adjustingFocus", options: flag, context: nil)
    }

    func tapToFocus(toFocus xPoint: CGFloat, yPoint: CGFloat,  completion: inout () -> Void) {
        try! device?.lockForConfiguration()
        
        let screenRect: CGRect = UIScreen.main.bounds
        let screenWidth: CGFloat = screenRect.size.width
        let screenHeight: CGFloat = screenRect.size.height
        
        // This coordinates are always relative to a landscape device orientation with the home button on the right, regardless of the actual device orientation.
        let focus_x: CGFloat = yPoint / screenHeight
        let focus_y: CGFloat = (screenWidth - xPoint) / screenWidth
        
        if (device?.isFocusModeSupported(.autoFocus))! {
            device?.focusPointOfInterest = CGPoint(x: focus_x, y: focus_y)
            device?.focusMode = .autoFocus
            
            self.onTapToFocusDoneCompletion = completion
            device?.addObserver(self, forKeyPath: "adjustingFocus", options: [.new], context: nil)
        }
        if (device?.isExposureModeSupported(.autoExpose))! {
            device?.exposurePointOfInterest = CGPoint(x: focus_x, y: focus_y)
            device?.exposureMode = .autoExpose
        }
        device?.unlockForConfiguration()
    }
    
    func onTapToFocusDone() {
        self.onTapToFocusDoneCompletion?()
    }

    // Find a camera with the specified AVCaptureDevicePosition, returning nil if one is not found
    func cameraWithPosition(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let devices = AVCaptureDevice.devices(for: AVMediaType.video) as! [AVCaptureDevice]
        
        for device: AVCaptureDevice in devices {
            if device.position == position {
                return device
            }
        }
        return nil
    }
}
