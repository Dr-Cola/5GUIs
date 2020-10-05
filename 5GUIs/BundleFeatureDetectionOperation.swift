//
//  BundleFeatureDetectionOperation.swift
//  5 GUIs
//
//  Created by Helge Heß on 28.09.20.
//

import SwiftUI

protocol BundleFeatureDetectionOperationDelegate: AnyObject {
  func detectionStateDidChange(_ state: BundleFeatureDetectionOperation)
}

/**
 * This is the main "operation" object which runs from a background queue and
 * collects all the info we want.
 */
final class BundleFeatureDetectionOperation: ObservableObject {
  // FIXME: this is more like a 'load operation'. But we can't use plain
  //        Operation, because we are async (would need to do that boilerplate).
  
  weak var delegate : BundleFeatureDetectionOperationDelegate?
    
  enum State: Equatable {
    case processing
    case failedToOpen(Swift.Error?)
    case notAnApplication
    case finished
    static func == (lhs: State, rhs: State) -> Bool {
      switch ( lhs, rhs ) {
        case ( .processing       , .processing       ): return true
        case ( .failedToOpen     , .failedToOpen     ): return true
        case ( .notAnApplication , .notAnApplication ): return true
        case ( .finished         , .finished         ): return true
        default: return false
      }
    }
  }
  
  let fm  = FileManager.default

  @Published var state = State.processing {
    didSet {
      delegate?.detectionStateDidChange(self)
    }
  }
  @Published var info : ExecutableFileTechnologyInfo {
    didSet {
      delegate?.detectionStateDidChange(self)
    }
  }
  @Published var otoolAvailable = true

  var url : URL { info.fileURL }
  
  init(_ url: URL) {
    self.info = ExecutableFileTechnologyInfo(fileURL: url)
  }
  func resume() {
    DispatchQueue.global().async {
      self.startWork()
    }
  }
  
  
  // MARK: - Just some threadsafe helpers ...
  
  private func apply(_ block: @escaping () -> Void) {
    RunLoop.main.perform(block)
  }
  private func apply<V>(_ keyPath:
                            ReferenceWritableKeyPath<BundleFeatureDetectionOperation, V>,
                        _ value: V)
  {
    apply {
      self[keyPath: keyPath] = value
    }
  }
  private func applyState(_ state: State) { // Q: Any
    apply(\.state, state)
  }
  
  
  // MARK: - Main Entry
  
  private func startWork() { // Q: background
    
    var isDir : ObjCBool = false
    guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
      return applyState(.failedToOpen(nil))
    }
   
    if isDir.boolValue {
      processWrapper(url)
    }
    else {
      processFile(url)
    }
  }
  
  
  // MARK: - Workers
  
  private func processFile(_ url: URL) {
    guard fm.isExecutableFile(atPath: url.path) else {
      return applyState(.notAnApplication)
    }
    
    // TODO: grab Info.plist embedded in Mach-O
    
    apply(\.info.executableURL, url)
    
    processExecutable(url)
    
    applyState(.finished)
  }
  
  /**
   * Processes an app bundle (on a background queue).
   *
   * Steps
   * 1. load and parse info dictionary
   * 2. load image
   * 3. run otool on the main executable and its dependencies
   * 4. look for files in the bundle hierarchy
   */
  private func processWrapper(_ url: URL) { // Q: Any
    guard let bundle = Bundle(url: url) else {
      print("could not open bundle:", url)
      return applyState(.failedToOpen(nil))
    }
    
    let info = InfoDict(bundle.infoDictionary ?? [:])
    
    guard let executableURL = bundle.executableURL else {
      print("no executable in bundle:", bundle)
      return applyState(.notAnApplication)
    }
    let receiptURL = bundle.appStoreReceiptURL
    
    apply {
      self.info.executableURL  = executableURL
      self.info.receiptURL     = receiptURL
      self.info.infoDictionary = info
    }
    
    let image = loadImage(in: info, bundle: bundle)
    apply(\.info.appImage, image)
    
    processExecutable(executableURL)
    
    processDirectoryContents(url)
    
    
    // TODO: look for nested binaries (additional apps).
    

    // DONE
    self.applyState(.finished)
  }
  
  
  // MARK: - Individual Workers
  
  /// This runs objdump on the executable (w/ traversal of dependencies)
  private func processExecutable(_ executableURL: URL) { // Q: Any
    do {
      let dependencies = try otool(executableURL)
      
      // scan in this bg thread
      var detectedFeatures = DetectedTechnologies()
      detectedFeatures.scanDependencies(dependencies)
      
      apply {
        self.otoolAvailable = true
        self.info.dependencies = dependencies
        self.info.detectedTechnologies.formUnion(detectedFeatures)
      }
    }
    catch {
      print("Could not invoke OTool:", error)
      apply(\.otoolAvailable, false)
    }
  }
  
  /// Looks at the directory hierarchy of the bundle
  private func processDirectoryContents(_ url: URL) { // Q: Any
    var detectedFeatures = DetectedTechnologies()
    let contents = url.appendingPathComponent("Contents")
    
    // Charles & Eclipse
    for pc in [ "Java", "Eclipse" ] {
      let suburl = contents.appendingPathComponent(pc)
      if fm.fileExists(atPath: suburl.path) {
        detectedFeatures.insert(.java)
        break
      }
    }
    
    // JD-GUI
    if info.infoDictionary?.JavaX ?? false {
      detectedFeatures.insert(.java)
    }
    
    do { // Electron apps seem to have this ...
      let suburl = contents.appendingPathComponent("Resources/app.asar")
      if fm.fileExists(atPath: suburl.path) {
        detectedFeatures.insert(.electron)
      }
    }
    
    // Check for AppleScript applications
    do {
      let suburl = contents.appendingPathComponent("Resources/Scripts")
      let hasScript =
        try fm.contentsOfDirectory(at: suburl,
                                   includingPropertiesForKeys: nil,
                                   options: .skipsSubdirectoryDescendants)
          .contains { $0.pathExtension == "scpt" }
      if hasScript {
        detectedFeatures.insert(.applescript)
      }
    }
    catch {} // not ehre
    
    // scan the Frameworks directory
    do {
      let suburl = contents.appendingPathComponent("Frameworks")
      let files  =
        try fm.contentsOfDirectory(at: suburl, includingPropertiesForKeys: nil,
                                   options: .skipsSubdirectoryDescendants)
          .map { $0.lastPathComponent }
          .sorted()

      for filename in files {
        if filename.hasPrefix("libwx_") {
          detectedFeatures.insert(.wxWidgets)
        }
        else if filename == "python-extensions" {
          detectedFeatures.insert(.python)
        }
      }
    }
    catch {} // doesn't have to exist
    
    if !detectedFeatures.isEmpty {
      apply {
        self.info.detectedTechnologies.formUnion(detectedFeatures)
      }
    }
  }
}

extension DetectedTechnologies {
  
  mutating func scanDependencies(_ dependencies: [ String ]) {
    for dep in dependencies {
      func check(_ option: DetectedTechnologies, _ needle: String) -> Bool
      {
        guard !contains(option)    else { return false } // scanned already
        guard dep.contains(needle) else { return false }
        self.insert(option)
        return true
      }
      
      if check(.electron,  "Electron")          { continue }
      if check(.catalyst,  "UIKitMacHelper")    { continue }
      if check(.appkit,    "AppKit.framework")  { continue }
      if check(.swiftui,   "SwiftUI.framework") { continue }
      if check(.uikit,     "UIKit.framework")   { continue }
      if check(.qt,        "QtCore.framework")  { continue }
      
      if check(.cplusplus, "libc++")            { continue }
      if check(.objc,      "libobjc")           { continue }
      if check(.swift,     "libswiftCore")      { continue }
    }
  }
}
