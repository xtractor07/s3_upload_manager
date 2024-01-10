//
//  ViewController.swift
//  S3UploadManager
//
//  Created by Kumar Aman on 13/12/23.
//

import UIKit
import PhotosUI
import UserNotifications

class ViewController: UIViewController, UploadManagerDelegate {
    func uploadStatus(_ manager: UploadManager, uploadComplete status: Bool) {
        DispatchQueue.main.async { [self] in
            if status {
                activityIndicator.color = UIColor.systemYellow
                activityIndicator.startAnimating()
            } else {
                activityIndicator.color = UIColor.systemGreen
                activityIndicator.stopAnimating()
            }
        }
    }
    
    func uploadSpeed(_ manager: UploadManager, uploadSpeed speed: Double) {
        DispatchQueue.main.async { [self] in
            speedLabel.text = "\(speed) MB/s"
        }
    }
    
    
//    var uploadManager: UploadManager!
    @IBOutlet weak var selectMediaBtn: UIButton!
//    @IBOutlet weak var uploadStatusBtn: UIButton!
    var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    @IBOutlet weak var totalMediaProgress: UIProgressView!
    @IBOutlet weak var currentMediaProgress: UIProgressView!
    @IBOutlet weak var speedLabel: UILabel!
    @IBOutlet weak var activityIndicator: UIActivityIndicatorView!
    
    var previousBytesSent: Int64 = 0
    var previousUpdateTime: TimeInterval = Date().timeIntervalSince1970

    override func viewDidLoad() {
        super.viewDidLoad()
        UploadManager.shared.delegate = self
//        uploadManager = UploadManager()
        NotificationCenter.default.addObserver(self, selector: #selector(appMovedToBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        // Do any additional setup after loading the view.
    }
    
    @IBAction func selectMediaDidPressed(_ sender: UIButton) {
        self.totalMediaProgress.progress = 0.0
        self.currentMediaProgress.progress = 0.0
        activityIndicator.color = UIColor.systemRed
        presentImageAndVideoPicker()
    }
    
    func uploadManager(_ manager: UploadManager, didUpdateProgress progress: Float) {
        DispatchQueue.main.async {
            print("Progress: \(progress)")
            self.totalMediaProgress.progress = progress
        }
    }
    
    func activeMediaProgress(_ manager: UploadManager, didUpdateProgress progress: Float) {
        DispatchQueue.main.async {
            print("ActiveMediaProgress: \(progress)")
            self.currentMediaProgress.progress = progress
        }
    }
    
    func uploadStatus(_ manager: UploadManager, uploadComplete color: UIColor) {
        DispatchQueue.main.async {
//            self.uploadStatusBtn.backgroundColor = color
//            self.uploadStatusBtn.tintColor = color
        }
    }
    
    func presentImageAndVideoPicker() {
        var config = PHPickerConfiguration()
        config.selectionLimit = 0  // 0 for unlimited selection
        config.filter = .any(of: [.images, .videos])
        
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }
    
    private func handleImage(_ image: UIImage) {
        guard let imageData = image.jpegData(compressionQuality: 1.0) else {
            print("Could not convert image to JPEG data")
            return
        }
        handleMediaData(imageData, originalFileName: "image.jpg", isVideo: false)
    }
    
    private func handleMediaData(_ data: Data, originalFileName: String, isVideo: Bool) {
        let fileExtension = isVideo ? "mp4" : "jpg"
        let uniqueFileName = "\(UUID().uuidString).\(fileExtension)"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(uniqueFileName)
        
        do {
            try data.write(to: tempURL)
            let mimeType = getMimeType(for: tempURL)
            
            UploadManager.shared.createMultipartUpload(name: uniqueFileName, mimeType: mimeType, mediaUrl: tempURL) {result in
                switch result {
                case .success(_):
                    print("Success")

                case .failure(_):
                    print("Failure")
                }
            }
        } catch {
            print("Error saving media data: \(error)")
        }
    }
    
    
    func getMimeType(for url: URL) -> String {
        guard let utType = UTType(filenameExtension: url.pathExtension) else {
            return "application/octet-stream" // default or unknown MIME type
        }
        return utType.preferredMIMEType ?? "application/octet-stream"
    }
    
    func copyVideoToAppTemporaryDirectory(originalURL: URL, completion: @escaping (URL?) -> Void) {
        DispatchQueue.global(qos: .background).async {
            let fileManager = FileManager.default
            let tempDirectory = fileManager.temporaryDirectory
            let localURL = tempDirectory.appendingPathComponent(originalURL.lastPathComponent)
            
            do {
                if fileManager.fileExists(atPath: localURL.path) {
                    try fileManager.removeItem(at: localURL)
                }
                try fileManager.copyItem(at: originalURL, to: localURL)
                DispatchQueue.main.async {
                    completion(localURL)
                }
            } catch {
                print("Error copying file: \(error)")
                DispatchQueue.main.async {
                    completion(nil)
                }
            }
        }
    }
    
    func scheduleSimpleNotification(identifier: String) {
        let content = UNMutableNotificationContent()
        content.title = "Success"
        content.body = "Create Multipart Success!"
        content.sound = UNNotificationSound.default

        // Set the trigger of the notification -- here we set it to 5 seconds after the current time.
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.5, repeats: false)

        // Create the request with the identifier, content, and trigger
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

        // Add the request to the notification center
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Error scheduling notification: \(error)")
            }
        }
    }
    
    @objc func appMovedToBackground() {
        backgroundTask = UIApplication.shared.beginBackgroundTask {
            // This is the expiration handler. It's called when the background time is about to expire.
            print("BackgroundSession about expire")
            self.endBackgroundTask()
        }

        // Add code here to perform your long-running task.

        // Make sure to call endBackgroundTask() when this task is done.
    }

    func endBackgroundTask() {
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
}

extension ViewController: PHPickerViewControllerDelegate {
    
    // Delegate method
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        UploadManager.shared.totalMediaCount = results.count
        for result in results {
            if result.itemProvider.canLoadObject(ofClass: UIImage.self) {
                // Handle image
                result.itemProvider.loadObject(ofClass: UIImage.self) { [weak self] object, error in
                    guard let self = self, let image = object as? UIImage, error == nil else {
                        print("Error loading image: \(error?.localizedDescription ?? "Unknown error")")
                        return
                    }
                    self.handleImage(image)
                }
            } else if result.itemProvider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                // Handle video
                result.itemProvider.loadDataRepresentation(forTypeIdentifier: UTType.movie.identifier) { [weak self] data, error in
                    guard let self = self, let data = data, error == nil else {
                        print("Error loading video data: \(error?.localizedDescription ?? "Unknown error")")
                        return
                    }
                    self.handleMediaData(data, originalFileName: "video.mp4", isVideo: true)
                }
            }
        }
    }
}



