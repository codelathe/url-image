//
//  ImageLoaderService.swift
//  URLImage
//
//
//  Created by Dmytro Anokhin on 28/08/2019.
//  Copyright © 2019 Dmytro Anokhin. All rights reserved.
//

import Foundation
import CoreGraphics


protocol ImageLoaderService: AnyObject {

    func subscribe(forURL url: URL, incremental: Bool, processor: ImageProcessing?, _ observer: ImageLoaderObserver)

    func unsubscribe(_ observer: ImageLoaderObserver, fromURL url: URL)

    func load(url: URL, delay: TimeInterval, expiryDate: Date?)
}


final class ImageLoaderServiceImpl: ImageLoaderService {

    init(remoteFileCache: RemoteFileCacheService, imageProcessingService: ImageProcessingService) {
        let urlSessionConfiguration = URLSessionConfiguration.default.copy() as! URLSessionConfiguration
        urlSessionConfiguration.httpMaximumConnectionsPerHost = 1
        urlSessionConfiguration.httpAdditionalHeaders = URLImageService.httpAdditionalHeaders

        urlSessionDelegate = URLSessionDelegateWrapper()
        urlSession = URLSession(configuration: urlSessionConfiguration, delegate: urlSessionDelegate, delegateQueue: queue)

        self.remoteFileCache = remoteFileCache
        self.imageProcessingService = imageProcessingService

        urlSessionDelegate.finishDownloadingCallback = { task, tmpURL in
            guard let url = task.originalRequest?.url, let downloader = self.urlToDownloaderMap[url] as? FileDownloader else {
                return
            }

            downloader.finishDownloading(with: tmpURL)
        }

        urlSessionDelegate.writeDataCallback = { task, bytesWritten, totalBytesWritten, totalBytesExpectedToWrite in
            guard let url = task.originalRequest?.url, let downloader = self.urlToDownloaderMap[url] as? FileDownloader else {
                return
            }

            if totalBytesExpectedToWrite > 0 {
                let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
                downloader.progress(Float(progress))
            }
            else {
                downloader.progress(nil)
            }
        }

        urlSessionDelegate.receiveDataCallback = { task, data in
            guard let url = task.originalRequest?.url, let downloader = self.urlToDownloaderMap[url] as? DataDownloader else {
                return
            }

            downloader.append(data: data)
        }

        urlSessionDelegate.completeCallback = { task, error in
            guard let url = task.originalRequest?.url, let downloader = self.urlToDownloaderMap[url] else {
                return
            }

            (downloader as? DataDownloader)?.finishDownloading()
            downloader.complete(with: error)
        }
    }

    func subscribe(forURL url: URL, incremental: Bool, processor: ImageProcessing?, _ observer: ImageLoaderObserver) {
        queue.addOperation {
            self.createDownloaderIfNeeded(forURL: url, incremental: incremental)
            let handler = ImageLoadHandler(processor: processor, observer: observer)
            self.urlToDownloaderMap[url]?.addHandler(handler)
        }
    }

    func unsubscribe(_ observer: ImageLoaderObserver, fromURL url: URL) {
        queue.addOperation {
            guard let task = self.urlToDownloaderMap[url] else {
                return
            }

            let handlersToRemove = task.handlers.filter { $0.observer === observer }

            for handler in handlersToRemove {
                task.removeHandler(handler)
            }

            if task.handlers.isEmpty {
                self.urlToDownloaderMap[url]?.cancel()
            }
        }
    }

    func load(url: URL, delay: TimeInterval, expiryDate: Date?) {
        queue.addOperation {
            guard let downloader = self.urlToDownloaderMap[url] else {
                assertionFailure("Downloader must be created before calling load")
                return
            }

            if let expiryDate = expiryDate {
                if let currentExpiryDate = downloader.expiryDate {
                    // If there is expiry date make sure to use the latest of two
                    downloader.expiryDate = currentExpiryDate < expiryDate ? expiryDate : currentExpiryDate
                }
                else {
                    downloader.expiryDate = expiryDate
                }
            }

            downloader.resume(after: delay)
        }
    }

    // MARK: Private

    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "URLImage.ImageLoaderServiceImpl.queue"
        queue.maxConcurrentOperationCount = 1

        return queue
    }()

    private let urlSession: URLSession
    private let urlSessionDelegate: URLSessionDelegateWrapper

    private unowned let remoteFileCache: RemoteFileCacheService
    private unowned let imageProcessingService: ImageProcessingService

    private var _urlToDownloaderMap: [URL: Downloader] = [:]

    private var urlToDownloaderMap: [URL: Downloader] {
        get {
            assert(OperationQueue.current === queue, "Must only be accessed on the designated queue: '\(queue.name!)'")
            return _urlToDownloaderMap
        }

        set {
            assert(OperationQueue.current === queue, "Must only be accessed on the designated queue: '\(queue.name!)'")
            _urlToDownloaderMap = newValue
        }
    }

    private func createDownloaderIfNeeded(forURL url: URL, incremental: Bool) {
        guard urlToDownloaderMap[url] == nil else {
            return
        }

        let downloader: Downloader

        if incremental {
            let task = urlSession.dataTask(with: url)
            downloader = DataDownloader(url: url, task: task, remoteFileCache: remoteFileCache, imageProcessingService: imageProcessingService)
        }
        else {
            let task = urlSession.downloadTask(with: url)
            downloader = FileDownloader(url: url, task: task, remoteFileCache: remoteFileCache, imageProcessingService: imageProcessingService)
        }

        downloader.completionCallback = {
            self.queue.addOperation {
                self.urlToDownloaderMap.removeValue(forKey: url)
            }
        }

        urlToDownloaderMap[url] = downloader
    }
}
