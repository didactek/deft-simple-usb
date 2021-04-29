//
//  USBDevice.swift
//  deft-simple-usb
//
//  Created by Kit Transue on 2020-08-02.
//  Copyright © 2020 Kit Transue
//  SPDX-License-Identifier: Apache-2.0
//

import Foundation
import Logging
import CLibUSB
import SimpleUSB

var logger = Logger(label: "com.didactek.deft-simple-usb.libusb")
// FIXME: how to default configuration to debug?


public class LUUSBDevice: USBDevice, DeviceCommon {
    typealias EndpointAddress = PlatformEndpointAddress<UInt8>

    var libusbTimeout = UInt32(5000)
    public var timeout: TimeInterval {
        get { TimeInterval(Double(libusbTimeout) / 1000)  }
        set { libusbTimeout = UInt32(newValue * 1000) }
    }

    let subsystem: LUUSBBus // keep the subsytem alive
    let device: OpaquePointer
    var handle: OpaquePointer? = nil
    let interfaceNumber: Int32 = 0

    let writeEndpoint: EndpointAddress
    let readEndpoint: EndpointAddress

    init(subsystem: LUUSBBus, device: OpaquePointer) throws {
        self.subsystem = subsystem
        self.device = device

        LUUSBBus.checkCall(libusb_open(device, &handle)) { msg in  // deinit: libusb_close
            throw USBError.bindingDeviceHandle(msg)
        }

        var configurationPtr: UnsafeMutablePointer<libusb_config_descriptor>? = nil
        defer {
            libusb_free_config_descriptor(configurationPtr)
        }
        LUUSBBus.checkCall(libusb_get_active_config_descriptor(device, &configurationPtr)) { msg in
            throw USBError.getConfiguration(msg)
        }
        guard let configuration = configurationPtr else {
            throw USBError.getConfiguration("null configuration")
        }
        let configurationIndex = 0
        let interfacesCount = configuration[configurationIndex].bNumInterfaces
        logger.debug("there are \(interfacesCount) interfaces on this device")

        // The operating system may have loaded a default driver for this device
        // (e.g. on linux, the 'ftdi_sio' driver will likely be loaded for the FTDI device
        // to act as a UART serial adapter). Since we are rolling our own driver here,
        // ask libusb to unload the system-loaded driver while we are using the device.
        // It is OK to ask for detach on macOS.
        libusb_set_auto_detach_kernel_driver(handle, 1 /* non-zero is 'yes: enable' */)

        LUUSBBus.checkCall(libusb_claim_interface(handle, interfaceNumber)) { msg in  // deinit: libusb_release_interface
            throw USBError.claimInterface(msg)
        }
        let interface = configuration[configurationIndex].interface[Int(interfaceNumber)]

        let endpointCount = interface.altsetting[0].bNumEndpoints
        logger.debug("Device/Interface has \(endpointCount) endpoints")
        let endpoints = (0 ..< endpointCount).map { interface.altsetting[0].endpoint[Int($0)] }
        let addresses = endpoints.map { EndpointAddress(rawValue: $0.bEndpointAddress) }
        writeEndpoint = addresses.first { $0.isWritable }!
        readEndpoint = addresses.first { !$0.isWritable }!

        libusb_ref_device(device)  // now we won't throw
    }

    deinit {
        libusb_release_interface(handle, interfaceNumber)
        libusb_close(handle)
        libusb_unref_device(device)
    }

    /// Synchronously send USB control transfer.
    /// - returns: number of bytes transferred (if success)
    public func controlTransfer(requestType: BMRequestType, bRequest: UInt8, wValue: UInt16, wIndex: UInt16, data: Data?, wLength: UInt16) -> Int32 {
        // USB 2.0 9.3.4: wIndex
        // some interpretations (high bits 0):
        //   as endpoint (direction:1/0:3/endpoint:4)
        //   as interface (interface number)
        // semantics for ControlRequestType.standard requests are defined in
        // Table 9.4 Standard Device Requests
        // ControlRequestType.vendor semantics may vary.
        // FIXME: could we make .standard calls more typesafe?
        var dataCopy = Array(data ?? Data())
        return libusb_control_transfer(handle, requestType, bRequest, wValue, wIndex, &dataCopy, wLength, libusbTimeout)
    }

    public func bulkTransferOut(msg: Data) {
        let outgoingCount = Int32(msg.count)

        var bytesTransferred = Int32(0)
        var msgScratchCopy = msg

        let result = msgScratchCopy.withUnsafeMutableBytes { unsafe in
            libusb_bulk_transfer(handle, writeEndpoint.rawValue, unsafe.bindMemory(to: UInt8.self).baseAddress, outgoingCount, &bytesTransferred, libusbTimeout)
        }
        guard result == 0 else {
            fatalError("bulkTransfer returned \(result)")
        }
        guard outgoingCount == bytesTransferred else {
            fatalError("not all bytes sent")
        }
    }

    public func bulkTransferIn() -> Data {
        let bufSize = 1024 // FIXME: tell the device about this!
        var readBuffer = Array(repeating: UInt8(0), count: bufSize)
        var readCount = Int32(0)
        let result = libusb_bulk_transfer(handle, readEndpoint.rawValue, &readBuffer, Int32(bufSize), &readCount, libusbTimeout)
        guard result == 0 else {
            let errorMessage = String(cString: libusb_error_name(result)) // must not free message
            fatalError("bulkTransfer read returned \(result): \(errorMessage)")
        }
        return Data(readBuffer.prefix(Int(readCount))) // FIXME: Xcode 11.6 / Swift 5.2.4: explicit constructor is needed to avoid crash in Data subrange if we just return the prefix!! This seems like a bug????
    }
}
