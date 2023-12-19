//
//  UploadManager.swift
//  S3UploadManager
//
//  Created by Kumar Aman on 13/12/23.
//

import Foundation
import UserNotifications

enum UploadTaskType {
    case createMultipartUpload
    case getMultipartPreSignedUrls
    case uploadMedia
    case completeMultipartUpload
    // Add more task types as needed
}

struct CompleteUploadRequest: Encodable {
    let fileKey: String
    let UploadId: String
    let parts: [Part]
}

struct Part: Encodable {
    let PartNumber: Int
    let ETag: String
}

class UploadManager: NSObject {
    static let shared = UploadManager()
    private var completionHandlers: [UploadTaskType: [Int: (Result<Data, Error>) -> Void]] = [:]
    private var taskInfoMap = [Int: Data]()
    
    private var uploadQueue: [() -> Void] = []
    private var isUploading = false
    
    private lazy var backgroundSession: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.xtractor.S3UploadManager")
        config.isDiscretionary = true
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

    func createMultipartUpload(name: String, mimeType: String, completion: @escaping (Result<CreateMultipartUploadResponse, Error>) -> Void) {
        // Add task to the queue
        uploadQueue.append { [weak self] in
            self?.performCreateMultipartUpload(name: name, mimeType: mimeType, completion: completion)
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
    
    func uploadMedia(to preSignedUrl: URL, fileURL: URL, mimeType: String, completion: @escaping (Result<String?, Error>) -> Void) {
        do {
            let fileData = try Data(contentsOf: fileURL)
            guard let tempFileURL = writeDataToTempFile(data: fileData) else {
                completion(.failure(URLError(.cannotCreateFile)))
                return
            }

            var request = URLRequest(url: preSignedUrl)
            request.httpMethod = "PUT"
            request.setValue(mimeType, forHTTPHeaderField: "Content-Type")

            let task = backgroundSession.uploadTask(with: request, fromFile: tempFileURL)
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
            taskInfoMap[task.taskIdentifier] = fileData
            task.resume()
        } catch {
            completion(.failure(error))
        }
    }
    
    private func performCreateMultipartUpload(name: String, mimeType: String, completion: @escaping (Result<CreateMultipartUploadResponse, Error>) -> Void) {
        // Existing createMultipartUpload logic here
        guard let url = URL(string: "http://13.57.38.104:8080/uploads/createMultipartUpload") else {
            completion(.failure(URLError(.badURL)))
            return
        }

        let uploadData = ["name": name, "mimeType": mimeType]
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
            completionHandlers[.createMultipartUpload, default: [:]][task.taskIdentifier] = { result in
                switch result {
                case .success(let data):
                    do {
                        let response = try JSONDecoder().decode(CreateMultipartUploadResponse.self, from: data)
                        self.getMultipartPreSignedUrls(fileKey: name, uploadId: response.uploadId, parts: 1){presignedResult in
                            switch presignedResult {
                            case .success(let presignedResponse):
                                guard let preSignedUrlString = presignedResponse.parts.first?.signedUrl,
                                      let preSignedUrl = URL(string: preSignedUrlString) else {
                                    return
                                }
                                self.uploadMedia(to: preSignedUrl, fileURL: fileURL, mimeType: mimeType){ uploadResult in
                                    switch uploadResult {
                                    case .success(let etag):
                                        if let unwrappedEtag = etag {
                                            print("Etag: \(unwrappedEtag)")
                                            let parts = [Part(PartNumber: 1, ETag: unwrappedEtag.trimmingCharacters(in: CharacterSet(charactersIn: "\"")))]
                                            print("Part: \(parts)")
                                            self.completeMultipartUpload(fileKey: name, uploadId: response.uploadId, parts: parts) { result in
                                                switch result {
                                                case .success(_):
                                                    print("Multipart Complete!")
                                                    self.scheduleSimpleNotification(identifier: name)
                                                case .failure(_):
                                                    print("Multipart Failed!")
                                                }
                                            }
                                            print("Upload Success!")
                                        }
                                    case .failure(_):
                                        print("UploadError!")
                                    }
                                }
                            case .failure(_):
                                print("Error")
                            }
                        }
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
                    // Handle successful task completion
                    switch taskType {
                    case .createMultipartUpload:
                        print("CreateMultipart Success!")
                    case .getMultipartPreSignedUrls:
                        print("GetMultipartPresigned Success!")
                    case .uploadMedia:
                        print("UploadComplete!")
                    case .completeMultipartUpload:
                        // After handling completion
                        DispatchQueue.main.async { [weak self] in
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

}


extension UploadManager: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if taskInfoMap[dataTask.taskIdentifier] == nil {
            taskInfoMap[dataTask.taskIdentifier] = Data()
        }
        taskInfoMap[dataTask.taskIdentifier]?.append(data)
    }
}





