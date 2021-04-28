//
//  USBBus.swift
//
//
//  Created by Kit Transue on 2020-08-11.
//  Copyright © 2020 Kit Transue
//  SPDX-License-Identifier: Apache-2.0
//

import Foundation
import CLibUSB
import IOUSBHost


/// Bridge to the C library [libusb](https://libusb.info) functions imported by CLibUSB.
/// Configure the subsystem and find devices attached to the bus.
public class LUUSBBus {
    // FIXME: common: factor
    enum UsbError: Error {
        case noDeviceMatched
        case deviceCriteriaNotUnique
    }

    static func checkCall(_ rawResult: Int32, onError: (String) throws -> Never) {
        let result = libusb_error(rawValue: rawResult)
        guard result == LIBUSB_SUCCESS else {
            let msg = String(cString: libusb_strerror(result))
            try! onError(msg)
        }
    }

    /// Shared libusb context, for use in libusb_init, etc.
    var ctx: OpaquePointer? = nil

    public init() {
        // FIXME: how to do this better, and where?
        logger.logLevel = .trace

        Self.checkCall(libusb_init(&ctx)) { msg in // deinit: libusb_exit
            fatalError("libusb_init failed: \(msg)")
        }
    }

    deinit {
        libusb_exit(ctx)
    }


    /// - parameter idVendor: filter found devices by vendor, if not-nil.
    /// - parameter idProduct: filter found devices by product, if not-nil. Requires idVendor.
    /// - returns: the one device that matches the search criteria
    /// - throws: if device is not found or criteria are not unique
    public func findDevice(idVendor: Int?, idProduct: Int?) throws -> LUUSBDevice {
        // scan for devices:
         var devicesBuffer: UnsafeMutablePointer<OpaquePointer?>? = nil
        let deviceCount = libusb_get_device_list(ctx, &devicesBuffer)
        defer {
            libusb_free_device_list(devicesBuffer, 1)
        }
        guard deviceCount > 0 else {
            throw UsbError.noDeviceMatched
        }
        logger.debug("found \(deviceCount) devices")

        var details = (0 ..< deviceCount).map { deviceDetail(device: devicesBuffer![$0]!) }

        // try to select one device from spec
        if let idVendor = idVendor {
            details.removeAll { $0.idVendor != idVendor }
        }
        if let idProduct = idProduct {
            guard idVendor != nil else {
                fatalError("idVendor required if specifying idProduct")
            }
            details.removeAll { $0.idProduct != idProduct }
        }
        if details.isEmpty {
            throw UsbError.noDeviceMatched
        }
        if details.count > 1 {
            throw UsbError.deviceCriteriaNotUnique
        }
        return try LUUSBDevice(subsystem: self, device: details.first!.device)
    }


    /// Information obtainable from the device descriptor without opening a connection to the device.
    ///
    /// See [USB 2.0](https://www.usb.org/document-library/usb-20-specification) 9.6.1, Device
    struct DeviceDescription {
        /// libusb handle to the device
        let device: OpaquePointer
        /// USB idVendor of the device
        let idVendor: Int
        /// USB idProduct of the device
        let idProduct: Int
        /// number of configurations
        let bNumConfigurations: Int

    }

    /// Read the device descriptor.
    ///
    /// - Parameter device: Handle from libusb_get_device_list.
    /// - Note: Wraps libusb_get_device_descriptor.
    func deviceDetail(device: OpaquePointer) -> DeviceDescription {
        var descriptor = libusb_device_descriptor()
        let _ = libusb_get_device_descriptor(device, &descriptor)
        logger.debug("vendor: \(String(descriptor.idVendor, radix: 16))")
        logger.debug("product: \(String(descriptor.idProduct, radix: 16))")
        logger.debug("device has \(descriptor.bNumConfigurations) configurations")

        return DeviceDescription(
            device: device,
            idVendor: Int(descriptor.idVendor),
            idProduct: Int(descriptor.idProduct),
            bNumConfigurations: Int(descriptor.bNumConfigurations))
    }
}


/// On macOS, the bus services are always available, so an "object" of this type is just a pass-through
/// to IOUSBHost services.
public class USBBus {
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

        return try USBDevice(device: device)
    }
}
