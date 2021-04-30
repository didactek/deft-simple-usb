//
//  HostFWUSBBus.swift
//  deft-simple-usb
//
//  Created by Kit Transue on 2021-04-28.
//  Copyright © 2021 Kit Transue
//  SPDX-License-Identifier: Apache-2.0
//

import Foundation
import SimpleUSB
import IOUSBHost


/// On macOS, the bus services are always available, so an "object" of this type is just a pass-through
/// to IOUSBHost services.
public class FWUSBBus: USBBus {
    enum UsbError: Error {
        case noDeviceMatched
        case deviceCriteriaNotUnique
    }

    public init() {
        // FIXME: how to do this better, and where?
        logger.logLevel = .trace
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
        #if false  // documentation suggests there is a helper here, but I can't find it:
        let searchRequest = IOUSBHostDevice.createMatchingDictionary(
            vendorID: idVendor,
            productID: idProduct,
            bcdDevice: nil,
            deviceClass: nil,
            deviceSubclass: nil,
            deviceProtocol: nil,
            speed: nil,
            productIDArray: nil)
        #else
        let deviceSearchPattern: [IOUSBHostMatchingPropertyKey : Int] = [
            .vendorID : idVendor!,
            .productID : idProduct!,
        ]
        let deviceDomain = [ "IOProviderClass": "IOUSBHostDevice" ]
        let searchRequest = (deviceSearchPattern as NSDictionary).mutableCopy() as! NSMutableDictionary
        searchRequest.addEntries(from: deviceDomain)
        #endif

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
