//
//  AppDelegate.swift
//  S3UploadManager
//
//  Created by Kumar Aman on 13/12/23.
//

import UIKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

//    var window: UIWindow?
//    var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Override point for customization after application launch.
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            if granted {
                print("Notification permission granted.")
            } else {
                print("Notification permission denied.")
            }
        }
        return true
    }

    // MARK: UISceneSession Lifecycle

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        // Called when a new scene session is being created.
        // Use this method to select a configuration to create the new scene with.
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
        // Called when the user discards a scene session.
        // If any sessions were discarded while the application was not running, this will be called shortly after application:didFinishLaunchingWithOptions.
        // Use this method to release any resources that were specific to the discarded scenes, as they will not return.
    }
    
//    func applicationDidEnterBackground(_ application: UIApplication) {
//        backgroundTask = application.beginBackgroundTask(withName: "MyBackgroundTask") {
//            // This block is executed when the background time is about to expire.
//            // End the task if it's still running.
////            application.endBackgroundTask(self.backgroundTask)
////            self.backgroundTask = .invalid
//            
//        }
//    }
    
//    func applicationWillEnterForeground(_ application: UIApplication) {
//        application.endBackgroundTask(self.backgroundTask)
//        self.backgroundTask = .invalid
//    }


}

