// The Swift Programming Language
// https://docs.swift.org/swift-book

import Foundation
import CoreFoundation
import Combine
import CommonAbstraction
import USBDiskMonitorAbstraction

#if os(macOS)
import IOKit
import IOKit.usb
import IOKit.storage

import DiskArbitration

public final class USBDiskMonitor: USBDiskMonitorProtocol {
    public var mountedDisk: PassthroughSubject<[USBDisk], DiskMountError> = .init()
    public var status: CurrentValueSubject<ObservableServiceStatus, ObservableServiceError> = .init(.notStarted)

    private let queue: DispatchQueue
    private var session: DASession?
    
    private var dictionaryKeyCallBacks = kCFTypeDictionaryKeyCallBacks
    private var dictionaryValueCallBacks = kCFTypeDictionaryValueCallBacks
    lazy var usbDiskDescriptionMatch: CFMutableDictionary? = {
        var dictionary = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &dictionaryKeyCallBacks, &dictionaryValueCallBacks)
        
        CFDictionaryAddValue(
            dictionary,
            Unmanaged.passUnretained(kDADiskDescriptionDeviceProtocolKey).toOpaque(),
            Unmanaged.passUnretained(kIOPropertyPhysicalInterconnectTypeUSB as CFString).toOpaque()
        )
        return dictionary
    }()
    
    private var disks: Set<USBDisk> = [] {
        didSet {
            updateDisksPublisher(disks)
        }
    }
    
    @inlinable func updateDisksPublisher(_ disks: Set<USBDisk>) {
        mountedDisk.send(Array(disks))
    }
    
    public init() {
        print("\(Self.self)." + #function)
        queue = DispatchQueue(label: "com.dmitrykhotyanovich.uniquephoto.massstoragemonitor", qos: .background)
    }
    
    deinit {
        print("\(Self.self)." + #function)
        stopObserving()
    }
    
    public func stopObserving() {
        print("\(Self.self)." + #function)
        guard let session else { return }
        DASessionSetDispatchQueue(session, nil)
        self.session = nil
        status.send(.stopped)
    }
    
    public func startObserving() {
        print("\(Self.self)." + #function)
        guard let session = DASessionCreate(kCFAllocatorDefault)
        else {
            status.send(.notStarted)
            return
        }
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        DASessionSetDispatchQueue(session, queue)

        // Register for notifications when a disk is mounted
        DARegisterDiskAppearedCallback(session, usbDiskDescriptionMatch, diskAppearedCallback, context)

        // Register for notifications when a disk is unmounted (disappears)
        DARegisterDiskDisappearedCallback(session, usbDiskDescriptionMatch, diskDisappearedCallback, context)

        // Register for notification when a disk is mountable and has changes in descriptions info
        DARegisterDiskDescriptionChangedCallback(
            session,
            usbDiskDescriptionMatch,//kDADiskDescriptionMatchVolumeMountable.takeUnretainedValue(),
            nil,
            diskDescriptionChangedCallback,
            context
        )

        DASessionSetDispatchQueue(session, queue)
        
        status.send(.running)
    }
    
    func handleDiskDescriptionChanged(description: [String: Any]) {
//        guard let protocolType = description[kDADiskDescriptionDeviceProtocolKey as String] as? String,
//              protocolType == "USB" else {
//            print("\(Self.self)." + #function + ": Ignoring non-USB disk description change.")
//            return
//        }
        print("\n\(Self.self)." + #function)
        processDiskDescription(description)
        
    }
    
    func handleDiskAppeared(description: [String: Any]) {
        
//        guard let protocolType = description[kDADiskDescriptionDeviceProtocolKey as String] as? String,
//              protocolType == "USB" else {
//            print("\(Self.self)." + #function + ": Ignoring non-USB disk description change.")
//            return
//        }
        
        print("\(Self.self)." + #function)
        processDiskDescription(description)
    }
    
    func handleDiskDisappeared(description: [String: Any]) {
        print("\(Self.self)." + #function)
        print("USB Mass Storage Device Disconnected:")
        // Get the volume name for the disconnected USB device
        guard let volumeID = extractVolumeID(from: description)
        else {
            print("Could not extract volume ID from description: \(description)")
            return
        }
        print("Volume ID: \(volumeID)")
        if let disk = disks.first(where: { $0.id == volumeID }) {
            disks.remove(disk)
//        if let mediaName = description[kDADiskDescriptionMediaNameKey as String] as? String {
//            print("Media Name: \(mediaName)")
//            if var disk = disks.first(where: { $0.mediaName == mediaName }) {
//                disk.isMounted = false
//                disks.update(with: disk)
////                mountedDisk.send(disk)
//            }
        }
    }
    
    private func processDiskDescription(_ description: [String: Any]) {
        if let volumeName = description[kDADiskDescriptionVolumeNameKey as String] as? String,
           let mediaSize = description[kDADiskDescriptionMediaSizeKey as String] as? Int64,
           let mediaName = description[kDADiskDescriptionMediaNameKey as String] as? String,
           let volumeID = extractVolumeID(from: description) {
            print("\nUSB Mass Storage Device Description Changed:")
            print("Volume Name: \(volumeName)")
            print("Capacity: \(mediaSize / (1024 * 1024 * 1024)) GB")
            print("Volume ID: \(volumeID)")
            
            let volumePath = description[kDADiskDescriptionVolumePathKey as String] as? URL
            print("Volume Path: \(volumePath?.path ?? "N/A") ")

            let updatedDisk = USBDisk(id: volumeID, name: volumeName, volume: volumePath?.path(), isMounted: volumePath != nil, size: mediaSize, mediaName: mediaName)
            guard disks.update(with: updatedDisk) != nil
            else {
                disks.insert(updatedDisk)
//                mountedDisk.send(updatedDisk)
                print("USB Mass Storage Device Mounted: \(updatedDisk)")
                return
            }
            updateDisksPublisher(disks)
        }
    }
    
    private func extractVolumeID(from description: [String: Any]) -> UUID? {
        guard let cfType = description[kDADiskDescriptionVolumeUUIDKey as String] as? CFTypeRef,
              CFGetTypeID(cfType) == CFUUIDGetTypeID()
        else {
            return nil
        }
        
        let cfUUID = unsafeBitCast(cfType, to: CFUUID.self)
        // Convert CFUUID to UUID using the UUID string
        guard let uuidString = CFUUIDCreateString(nil, cfUUID) as String?
        else {
            print("Could not convert CFUUID to UUID")
            return nil
        }
        return UUID(uuidString: uuidString)
    }
}

//MARK: - Disk Arbitrary Callbacks:

func diskAppearedCallback(_ disk: DADisk, _ context: UnsafeMutableRawPointer?) -> Void {
    if let description = DADiskCopyDescription(disk as DADisk) as? [String: Any], let context = context {
        let `self` = Unmanaged<USBDiskMonitor>.fromOpaque(context).takeUnretainedValue()
        self.handleDiskAppeared(description: description)
    }
}

func diskDisappearedCallback(_ disk: DADisk, _ context: UnsafeMutableRawPointer?) -> Void {
    if let description = DADiskCopyDescription(disk as DADisk) as? [String: Any], let context = context {
        let `self` = Unmanaged<USBDiskMonitor>.fromOpaque(context).takeUnretainedValue()
        self.handleDiskDisappeared(description: description)
    }
}

func diskDescriptionChangedCallback(_ disk: DADisk, _ array: CFArray, _ context: UnsafeMutableRawPointer?) -> Void {
    if let description = DADiskCopyDescription(disk as DADisk) as? [String: Any], let context = context {
        let `self` = Unmanaged<USBDiskMonitor>.fromOpaque(context).takeUnretainedValue()
        self.handleDiskDescriptionChanged(description: description)
    }
}
#endif
