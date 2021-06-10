//
//  HostFWUSBBus.swift
//  deft-simple-usb
//
//  Created by Kit Transue on 2021-04-28.
//  Copyright © 2021 Kit Transue
//  SPDX-License-Identifier: Apache-2.0
//

#if SKIPMODULE  // See Package.swift discussion
#else
import Foundation
import IOUSBHost
import DeftLog
import SimpleUSB

let logger = DeftLog.logger(label: "com.didactek.deft-simple-usb.host-fw-usb")
// FIXME: how to default configuration to debug?


/// Bridge to the macOS IOUSBHost usermode USB framework.
/// Provide services to find devices attached to the bus.
public class FWUSBBus: USBBus {
    enum UsbError: Error {
        case noDeviceMatched
        case deviceCriteriaNotUnique
    }

    public init() {
    }

    deinit {
    }

    /// - parameter idVendor: filter found devices by vendor, if not-nil.
    /// - parameter idProduct: filter found devices by product, if not-nil. Requires idVendor.
    /// - returns: the one device that matches the search criteria
    /// - throws: if device is not found or criteria are not unique
    public func findDevice(idVendor: Int?, idProduct: Int?) throws -> USBDevice {
        // scan for devices:
        // create a matching dictionary:

        // FIXME: the documentation suggests there is a IOUSBHostDevice.createMatchingDictionary
        // helper, but I can't find the refined-for-Swift version.
        let deviceSearchPattern: [IOUSBHostMatchingPropertyKey : Int] = [
            .vendorID : idVendor!,
            .productID : idProduct!,
        ]
        let deviceDomain = [ "IOProviderClass": "IOUSBHostDevice" ]
        let searchRequest = (deviceSearchPattern as NSDictionary).mutableCopy() as! NSMutableDictionary
        searchRequest.addEntries(from: deviceDomain)

        #if true  // FIXME: use iterator approach; throw if not unique
        let service = IOServiceGetMatchingService(kIOMasterPortDefault, searchRequest)
        guard service != 0 else {
            throw UsbError.noDeviceMatched
        }
        #else  // iterator approach
        var existing: io_iterator_t = 0
        let _ = IOServiceGetMatchingServices(kIOMasterPortDefault, cfDeviceSearchPattern, &existing)
        let service = existing
        #endif

        let device = try IOUSBHostDevice.init(__ioService: service, options: [/*.deviceCapture*/], queue: nil, interestHandler: nil)

        return try FWUSBDevice(device: device)
    }
}
#endif
