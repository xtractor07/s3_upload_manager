//
//  UploadManager.swift
//  S3UploadManager
//
//  Created by Kumar Aman on 13/12/23.
//

import Foundation

enum UploadTaskType {
    case createMultipartUpload
    case getMultipartPreSignedUrls
    // Add more task types as needed
}


class UploadManager: NSObject {
    static let shared = UploadManager()
    private var completionHandlers: [UploadTaskType: [Int: (Result<Data, Error>) -> Void]] = [:]
    private var taskInfoMap = [Int: Data]()

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


