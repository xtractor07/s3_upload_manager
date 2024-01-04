//
//  UploadManager.swift
//  S3UploadManager
//
//  Created by Kumar Aman on 13/12/23.
//
import Foundation
import UserNotifications
import UIKit

protocol UploadManagerDelegate: AnyObject {
    func uploadManager(_ manager: UploadManager, didUpdateProgress progress: Float)
}

class UploadManager: NSObject {
    static let shared = UploadManager()
    var uploadData = UploadData(fileKey: nil, uploadId: nil, mediaUrl: nil, mimeType: nil, eTag: nil)
    private var completionHandlers: [UploadTaskType: [Int: (Result<Data, Error>) -> Void]] = [:]
    private var taskInfoMap = [Int: Data]()
    
    private var uploadQueue: [() -> Void] = []
    private var isUploading = false
    private var currentUploadTask: URLSessionUploadTask?
    private var currentUploadRequest: URLRequest?
    private var currentUploadFileURL: URL?
    private var currentDataChunk: Data?
    private var currentPart: Int = 0
    private var activePart: Int = 0
    private var currentUploadCompletionHandler: ((Result<String?, Error>) -> Void)?
    private var uploadedMediaCount: Int = 0
    private var parts: [Part] = []
    var totalMediaCount: Int?
    weak var delegate: UploadManagerDelegate?
    
    override init() {
        super.init()
        setupNotificationObservers()
    }
    
    private lazy var backgroundSession: URLSession = {
        let config = URLSessionConfiguration.default
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private func writeDataToTempFile(data: Data) -> URL? {
        let tempDirectory = FileManager.default.temporaryDirectory
        let tempFileURL = tempDirectory.appendingPathComponent(UUID().uuidString)

        do {
            try data.write(to: tempFileURL)
            return tempFileURL
        } catch {
            print("Error writing data to temp file: \(error)")
            return nil
        }
    }

    func createMultipartUpload(name: String, mimeType: String, mediaUrl: URL, completion: @escaping (Result<CreateMultipartUploadResponse, Error>) -> Void) {
        // Add task to the queue
        uploadQueue.append { [weak self] in
            self?.performCreateMultipartUpload(name: name, mimeType: mimeType, mediaUrl: mediaUrl)
        }
        
        // Try to start the next task
        startNextUploadTask()
        
    }
    
    func getMultipartPreSignedUrls(fileKey: String, uploadId: String, parts: Int, completion: @escaping (Result<PreSignedURLResponse, Error>) -> Void) {
        guard let url = URL(string: "http://13.57.38.104:8080/uploads/getMultipartPreSignedUrls") else {
            completion(.failure(URLError(.badURL)))
            return
        }

        let uploadData: [String: Any] = [
            "fileKey": fileKey,
            "UploadId": uploadId,
            "parts": parts
        ]

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: uploadData, options: [])
            guard let fileURL = writeDataToTempFile(data: jsonData) else {
                completion(.failure(URLError(.cannotCreateFile)))
                return
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let task = backgroundSession.uploadTask(with: request, fromFile: fileURL)
            completionHandlers[.getMultipartPreSignedUrls, default: [:]][task.taskIdentifier] = { result in
                switch result {
                case .success(let data):
                    do {
                        let response = try JSONDecoder().decode(PreSignedURLResponse.self, from: data)
                        completion(.success(response))
                    } catch {
                        completion(.failure(error))
                    }
                case .failure(let error):
                    completion(.failure(error))
                }
            }
            task.resume()
        } catch {
            completion(.failure(error))
        }
    }
    
    func uploadChunk(to preSignedUrl: URL, data: Data, mimeType: String, completion: @escaping (Result<String?, Error>) -> Void) {
            var request = URLRequest(url: preSignedUrl)
            request.httpMethod = "PUT"
            request.setValue(mimeType, forHTTPHeaderField: "Content-Type")

            let task = backgroundSession.uploadTask(with: request, from: data)
            completionHandlers[.uploadMedia, default: [:]][task.taskIdentifier] = { [weak self] result in
                switch result {
                case .success(_):
//                    if (self!.currentPart == 2){
                        // Assuming the response data contains the ETag or similar information
                        guard let httpResponse = task.response as? HTTPURLResponse, 200...299 ~= httpResponse.statusCode else {
                            completion(.failure(URLError(.badServerResponse)))
                            return
                        }
                        // Extracting ETag from the response headers
                        let etag = httpResponse.allHeaderFields["Etag"] as? String
                        // Passing ETag in the success completion
                        completion(.success(etag))
//                    }

                case .failure(let error):
                    completion(.failure(error))
                }

                // Cleanup
                self?.taskInfoMap.removeValue(forKey: task.taskIdentifier)
            }
            
            currentUploadTask = task
            currentUploadRequest = request
            currentDataChunk = data
            currentUploadCompletionHandler = completion
            task.resume()
    }
    
    func uploadMedia(to preSignedUrl: URL, fileURL: URL, mimeType: String, completion: @escaping (Result<String?, Error>) -> Void) {
            var request = URLRequest(url: preSignedUrl)
            request.httpMethod = "PUT"
            request.setValue(mimeType, forHTTPHeaderField: "Content-Type")

            let task = backgroundSession.uploadTask(with: request, fromFile: fileURL)
            completionHandlers[.uploadMedia, default: [:]][task.taskIdentifier] = { [weak self] result in
                switch result {
                case .success(_):
                    // Assuming the response data contains the ETag or similar information
                    guard let httpResponse = task.response as? HTTPURLResponse, 200...299 ~= httpResponse.statusCode else {
                        completion(.failure(URLError(.badServerResponse)))
                        return
                    }
                    // Extracting ETag from the response headers
                    let etag = httpResponse.allHeaderFields["Etag"] as? String
                    // Passing ETag in the success completion
                    completion(.success(etag))

                case .failure(let error):
                    completion(.failure(error))
                }

                // Cleanup
                self?.taskInfoMap.removeValue(forKey: task.taskIdentifier)
            }

            currentUploadTask = task
            currentUploadRequest = request
            currentUploadFileURL = fileURL
            currentUploadCompletionHandler = completion
            task.resume()
    }
    
    private func performCreateMultipartUpload(name: String, mimeType: String, mediaUrl: URL) {
        // Existing createMultipartUpload logic here
        guard let url = URL(string: "http://13.57.38.104:8080/uploads/createMultipartUpload") else {
            return
        }
        
        self.uploadData.fileKey = name
        self.uploadData.mediaUrl = mediaUrl
        self.uploadData.mimeType = mimeType
    
        let uploadData = ["name": name, "mimeType": mimeType]
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: uploadData, options: [])
            guard let fileURL = writeDataToTempFile(data: jsonData) else {
                return
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let task = backgroundSession.uploadTask(with: request, fromFile: fileURL)
            completionHandlers[.createMultipartUpload, default: [:]][task.taskIdentifier] = { result in
                switch result {
                case .success(_):
                    print("CreateMultipartSuccess!")
                case .failure(let error):
                    print("CreateMultiPartFailure: \(error.localizedDescription)")
                }
            }
            task.resume()
        } catch {
        }
    }
    
    func completeMultipartUpload(fileKey: String, uploadId: String, parts: [Part], completion: @escaping (Result<Void, Error>) -> Void) {
        guard let url = URL(string: "http://13.57.38.104:8080/uploads/completeMultipartUpload") else {
            completion(.failure(URLError(.badURL)))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let uploadData = CompleteUploadRequest(fileKey: fileKey, UploadId: uploadId, parts: parts)

        do {
            let jsonData = try JSONEncoder().encode(uploadData)
            guard let tempFileURL = writeDataToTempFile(data: jsonData) else {
                completion(.failure(URLError(.cannotCreateFile)))
                return
            }

            let task = backgroundSession.uploadTask(with: request, fromFile: tempFileURL)
            completionHandlers[.completeMultipartUpload, default: [:]][task.taskIdentifier] = { result in
                switch result {
                case .success(_):
                    completion(.success(()))
                case .failure(let error):
                    completion(.failure(error))
                }
            }
            task.resume()
        } catch {
            completion(.failure(error))
        }
    }


    private func startNextUploadTask() {
        guard !isUploading, !uploadQueue.isEmpty else { return }
        
        isUploading = true
        let nextTask = uploadQueue.removeFirst()
        nextTask()
    }

    
    func scheduleSimpleNotification(identifier: String) {
        let content = UNMutableNotificationContent()
        content.title = "Success"
        content.body = "Upload Success!"
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
}

// URLSession Delegate Methods
extension UploadManager: URLSessionTaskDelegate {
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let taskType: UploadTaskType = getTaskType(from: task)! // derive from task metadata or other logic

            // Retrieve the completion handler based on the task type
            if let completion = completionHandlers[taskType]?[task.taskIdentifier] {
                if let error = error {
                    // Handle task completion with error
                    completion(.failure(error))
                } else if let httpResponse = task.response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                    let responseData = taskInfoMap[task.taskIdentifier] ?? Data()
                    // Convert responseData to a String to print it

                    // Handle successful task completion
                    switch taskType {
                        
                    case .createMultipartUpload:
                        handleCreateMultipartUploadResponse(httpResponse, data: responseData)
        
                    case .getMultipartPreSignedUrls:
                        handleGetMultipartPreSignedUrlsResponse(httpResponse, data: responseData)
                        
                    case .uploadMedia:
                        currentPart += activePart
                        if currentPart == 2 {
                        handleUploadMediaResponse(httpResponse, data: responseData)
                        }
                    case .completeMultipartUpload:
                        // After handling completion
                        DispatchQueue.main.async { [weak self] in
                            self?.removeTemporaryFile(fileURL: (self?.uploadData.mediaUrl!)!)
                            self?.isUploading = false
                            self?.startNextUploadTask()
                        }
                    }
                    completion(.success(responseData))
                } else {
                    // Handle other HTTP responses
                    completion(.failure(URLError(.badServerResponse)))
                }
                
                // Clean up after handling completion
                completionHandlers[taskType]?.removeValue(forKey: task.taskIdentifier)
                taskInfoMap.removeValue(forKey: task.taskIdentifier)
            }
        }
    
    private func handleCreateMultipartUploadResponse(_ response: HTTPURLResponse, data: Data) {
        // Process the data and httpResponse as needed for createMultipartUpload
        do {
            let response = try JSONDecoder().decode(CreateMultipartUploadResponse.self, from: data)
            self.uploadData.uploadId = response.uploadId
            self.getMultipartPreSignedUrls(fileKey: response.fileKey, uploadId: response.uploadId, parts: 2) { response in
                switch response {
                case .success(_):
                    print("PresignedSuccess")
                case .failure(let error):
                    print(error.localizedDescription)
                }
            }
        } catch {
            print("error")
        }
    }

    private func handleGetMultipartPreSignedUrlsResponse(_ response: HTTPURLResponse, data: Data) {
        // Process the data and httpResponse as needed for getMultipartPreSignedUrls
        do {
            let response = try JSONDecoder().decode(PreSignedURLResponse.self, from: data)
//            guard let preSignedUrlString = response.parts.first?.signedUrl,
//                  let preSignedUrl = URL(string: preSignedUrlString) else {
//                return
//            }
            var currentChunk = 0
            
            if let fileData = loadDataFromFileURL(fileURL: uploadData.mediaUrl!) {
                let chunks = splitFileDataIntoChunks(fileData: fileData, numberOfChunks: 2)
//                = [Part(PartNumber: currentPart, ETag: self.uploadData.eTag!)]
                response.parts.forEach { part in
                    self.uploadChunk(to: URL(string: part.signedUrl)!, data: chunks[currentChunk], mimeType: self.uploadData.mimeType!) { response in
                        self.activePart = part.partNumber
                        switch response {
                        case .success(let etag):
                            self.uploadData.eTag = etag!.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                            self.parts.append(Part(PartNumber: self.activePart, ETag: self.uploadData.eTag!))
                            self.currentPart = part.partNumber
                            print("UploadSuccess")
                        case .failure(let error):
                            print(error.localizedDescription)
                        }
                    }
                    currentChunk += 1
                }
            }
        } catch {
            
        }
    }

    private func handleUploadMediaResponse(_ response: HTTPURLResponse, data: Data) {
        // Process the data and httpResponse as needed for uploadMedia
            self.uploadData.eTag = (response.allHeaderFields["Etag"] as? String)!.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            
        self.completeMultipartUpload(fileKey: self.uploadData.fileKey!, uploadId: self.uploadData.uploadId!, parts: parts){ [self] response in
                switch response {
                case .success(_):
                    print("MultiPart Success: \(parts)")
                    self.uploadedMediaCount += 1
                    let progress = Float(self.uploadedMediaCount) / Float(self.totalMediaCount!)
                    self.delegate?.uploadManager(self, didUpdateProgress: progress)
                    if(progress == 1.0) {
                        self.uploadedMediaCount = 0
                    }
                    
                case .failure(let error):
                    print("Error: \(error.localizedDescription)")
                }
            }
    }

    private func handleCompleteMultipartUploadResponse(_ response: HTTPURLResponse, data: Data, completion: (Result<Data, Error>) -> Void) {
        // Process the data and httpResponse as needed for completeMultipartUpload
    }
    
    func getTaskType(from task: URLSessionTask) -> UploadTaskType? {
        guard let url = task.originalRequest?.url else { return nil }
        
        if url.absoluteString.contains("createMultipartUpload") {
            return .createMultipartUpload
        } else if url.absoluteString.contains("getMultipartPreSignedUrls") {
            return .getMultipartPreSignedUrls
        } else if url.absoluteString.contains("amazonaws.com") {
            return .uploadMedia
        } else if url.absoluteString.contains("completeMultipartUpload") {
            return .completeMultipartUpload
        }
        // Add more conditions as needed
        return nil
    }
    
    private func removeTemporaryFile(fileURL: URL) {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: fileURL.path) {
            do {
                try fileManager.removeItem(at: fileURL)
                print("Temporary file removed: \(fileURL)")
            } catch {
                print("Failed to remove temporary file: \(error)")
            }
        } else {
            print("File does not exist, no need to delete: \(fileURL)")
        }
    }
}


extension UploadManager: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if taskInfoMap[dataTask.taskIdentifier] == nil {
            taskInfoMap[dataTask.taskIdentifier] = Data()
        }
        taskInfoMap[dataTask.taskIdentifier]?.append(data)
    }
}

extension UploadManager {
    private func setupNotificationObservers() {
        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
    }
    
    
    @objc private func appDidEnterBackground() {
        // Handle transition to background
        switchToBackgroundSession()
        restartCurrentUpload()
    }

    @objc private func appDidEnterForeground() {
        // Handle transition to foreground
        switchToForegroundSession()
        restartCurrentUpload()
    }
}

extension UploadManager {
    private func switchToBackgroundSession() {
        // Switch to a URLSession configured for background tasks
        cancelCurrentUploadTask()
        initializeSession(forBackground: true)
        print("App moved to background")
        restartCurrentUpload()
    }

    private func switchToForegroundSession() {
        // Switch to a URLSession configured for foreground tasks
        cancelCurrentUploadTask()
        initializeSession(forBackground: false)
        print("App moved to foreground")
        restartCurrentUpload()
    }
}

extension UploadManager {
    
    func initializeSession(forBackground background: Bool) {
        let config = background ? createBackgroundSessionConfiguration() : createForegroundSessionConfiguration()
        backgroundSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        // Optionally, restart or resume pending uploads here
    }
    
    private func createForegroundSessionConfiguration() -> URLSessionConfiguration {
        // Use default configuration for foreground
        return URLSessionConfiguration.default
    }

    private func createBackgroundSessionConfiguration() -> URLSessionConfiguration {
        // Use background configuration for background tasks
        let config = URLSessionConfiguration.background(withIdentifier: "com.xtractor.S3UploadManager")
        // Set additional properties if needed
        return config
    }
    
    private func cancelCurrentUploadTask() {
        currentUploadTask?.cancel()
        currentUploadTask = nil
    }
    
    func splitFileDataIntoChunks(fileData: Data, numberOfChunks: Int) -> [Data] {
        let totalSize = fileData.count
        let chunkSize = totalSize / numberOfChunks
        var chunks: [Data] = []

        for i in 0..<numberOfChunks {
            let start = i * chunkSize
            let end = (i == numberOfChunks - 1) ? totalSize : start + chunkSize
            let chunk = fileData.subdata(in: start..<end)
            chunks.append(chunk)
        }

        return chunks
    }
    
    func loadDataFromFileURL(fileURL: URL) -> Data? {
        do {
            let data = try Data(contentsOf: fileURL)
            return data
        } catch {
            print("Error loading file data: \(error)")
            return nil
        }
    }
    
    func restartCurrentUpload() {
            guard let request = currentUploadRequest, let fileURL = currentUploadFileURL else {
                print("No current upload to restart.")
                return
            }

            // Create a new task with the same request and file URL
            let newTask = backgroundSession.uploadTask(with: request, fromFile: fileURL)
            completionHandlers[.uploadMedia, default: [:]][newTask.taskIdentifier] = { [weak self] result in
                switch result {
                case .success(_):
                    // Assuming the response data contains the ETag or similar information
                    if let httpResponse = newTask.response as? HTTPURLResponse, 200...299 ~= httpResponse.statusCode {
                        let etag = httpResponse.allHeaderFields["Etag"] as? String
                        self?.currentUploadCompletionHandler?(.success(etag))
                    } else {
                        self?.currentUploadCompletionHandler?(.failure(URLError(.badServerResponse)))
                    }
                case .failure(let error):
                    self?.currentUploadCompletionHandler?(.failure(error))
                }
            }
            
//             Update the current upload task reference and resume
            currentUploadTask = newTask
            newTask.resume()
    }
}



