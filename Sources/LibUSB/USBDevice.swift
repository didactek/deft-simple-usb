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
import IOUSBHost


var logger = Logger(label: "com.didactek.deft-simple-usb.libusb")
// FIXME: how to default configuration to debug?



enum USBError: Error {
    case bindingDeviceHandle(String)
    case getConfiguration(String)
    case claimInterface(String)
}

public protocol USBDevice {
    func controlTransferOut(bRequest: UInt8, value: UInt16, wIndex: UInt16, data: Data?)

    func bulkTransferOut(msg: Data)
    func bulkTransferIn() -> Data

    var timeout: TimeInterval {get set}

    // basically IOUSBHostPipe.IOUSBHostDeviceRequestType
    func controlRequest(type: ControlRequestType, direction: ControlDirection, recipient: ControlRequestRecipient) -> BMRequestType
}

extension USBDevice {
    public func controlRequest(type: ControlRequestType, direction: ControlDirection, recipient: ControlRequestRecipient) -> BMRequestType {
        return type.rawValue | direction.rawValue | recipient.rawValue
    }
}

protocol DeviceCommon: USBDevice {
    /// Synchronously send USB control transfer.
    /// - returns: number of bytes transferred (if success)
    func controlTransfer(requestType: BMRequestType, bRequest: UInt8, wValue: UInt16, wIndex: UInt16, data: Data?, wLength: UInt16) -> Int32
}

extension DeviceCommon {
    public func controlTransferOut(bRequest: UInt8, value: UInt16, wIndex: UInt16, data: Data?) {
        let requestType = controlRequest(type: .vendor, direction: .hostToDevice, recipient: .device)
        let requestSize = data?.count ?? 0

        let result = controlTransfer(requestType: requestType,
                                     bRequest: bRequest,
                                     wValue: value, wIndex: wIndex,
                                     data: data,
                                     wLength: UInt16(requestSize))

        guard result == requestSize else {
            // FIXME: should probably throw rather than abort, and maybe not all calls need to be this strict
            fatalError("controlTransferOut failed: transferred \(result) bytes of \(requestSize)")
        }
    }
}

struct PlatformEndpointAddress<RawValue: FixedWidthInteger> {
    enum EndpointDirection: RawValue {
        // Table 9-13. Standard Endpoint Descriptor
        case input = 0b1000_0000
        case output = 0
    }

    let rawValue: RawValue

    init(rawValue: RawValue) {
        self.rawValue = rawValue
    }

    // USB 2.0: 9.6.6 Endpoint:
    // Bit 7 is direction IN/OUT
    let directionMask = RawValue(EndpointDirection.input.rawValue | EndpointDirection.output.rawValue)

    var isWritable: Bool {
        get {
            return rawValue & directionMask == EndpointDirection.output.rawValue
        }
    }
}


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

        // On linux, the 'ftdi_sio' driver will likely be loaded for the FTDI device.
        // Since we aren't using the FTDI in UART mode, ask libusb to unload this driver
        // while we are using the device.
        // This seems to be OK to do on macOS
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
    func controlTransfer(requestType: BMRequestType, bRequest: UInt8, wValue: UInt16, wIndex: UInt16, data: Data?, wLength: UInt16) -> Int32 {
        // USB 2.0 9.3.4: wIndex
        // some interpretations (high bits 0):
        //   as endpoint (direction:1/0:3/endpoint:4)
        //   as interface (interface number)
        // semantics for ControlRequestType.standard requests are defined in
        // Table 9.4 Standard Device Requests
        // ControlRequestType.vendor semantics may vary.
        // FIXME: could we make .standard calls more typesafe?
        var dataCopy = Array(data ?? Data())
        return dataCopy.withUnsafeMutableBufferPointer {
            libusb_control_transfer(handle, requestType, bRequest, wValue, wIndex, $0.baseAddress, wLength, libusbTimeout)
        }
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

public class FWUSBDevice: USBDevice, DeviceCommon {
    public var timeout = TimeInterval(5)

    typealias EndpointAddress = PlatformEndpointAddress<Int>

    let device: IOUSBHostDevice
    let writeEndpoint: IOUSBHostPipe
    let readEndpoint: IOUSBHostPipe

    init(device: IOUSBHostDevice) throws {
        logger.trace("Configuring USBDevice with descriptor \(device.deviceDescriptor!.pointee)")

        self.device = device

        let configuration = try! device.configurationDescriptor(with: 0).pointee
        logger.trace("Configuration with:0 is \(configuration)")

        // check bNumInterfaces
        let interfacesCount = configuration.bNumInterfaces
        logger.debug("Device supports \(interfacesCount) interfaces")

        let interfaceDescriptionPtr = IOUSBGetNextInterfaceDescriptor(device.configurationDescriptor, nil /*zeroeth previous; first is next*/)
        // claim interface
        guard let interfaceDescription = interfaceDescriptionPtr else {
            throw USBError.claimInterface("IOUSBGetNextInterfaceDescriptor")
        }
        logger.trace("Interface description: \(interfaceDescription.pointee)")

        // Create lookup for the service
        // FIXME: I'm sure the framework provides a better helper for constructing this;
        // I just can't seem to find it....
        let interfaceSearchInts: [IOUSBHostMatchingPropertyKey : Int] = [
            .vendorID: Int(device.deviceDescriptor!.pointee.idVendor),
            .productID: Int(device.deviceDescriptor!.pointee.idProduct),
            .interfaceNumber: 0,
            .configurationValue: Int(configuration.bConfigurationValue),
            .interfaceClass: Int(interfaceDescription.pointee.bInterfaceClass),
            .interfaceSubClass: Int(interfaceDescription.pointee.bInterfaceSubClass),
            .interfaceProtocol: Int(interfaceDescription.pointee.bInterfaceProtocol),
        ]
        let searchRequest = (interfaceSearchInts as NSDictionary).mutableCopy() as! NSMutableDictionary
        searchRequest.addEntries(from: ["IOProviderClass" : "IOUSBHostInterface"])


        logger.trace("interface search request is \(searchRequest)")
        let service = IOServiceGetMatchingService(kIOMasterPortDefault, searchRequest)

        let interface = try! IOUSBHostInterface.init(__ioService: service, options: [], queue: nil, interestHandler: nil)

        var endpointPipes = [IOUSBHostPipe]()
        var endpointIterator = IOUSBGetNextEndpointDescriptor(interface.configurationDescriptor, interface.interfaceDescriptor, nil)
        logger.trace("Interface configurationDescriptor is \(interface.configurationDescriptor.pointee)")

        logger.trace("Interface interfaceDescriptor is \(interface.interfaceDescriptor.pointee)")
        while let endpointFound = endpointIterator {
            logger.trace("Making pipe for endpoint: \(endpointFound.pointee)")
            endpointPipes.append(try interface.copyPipe(withAddress: Int(endpointFound.pointee.bEndpointAddress)))
            endpointFound.withMemoryRebound(to: IOUSBDescriptorHeader.self, capacity: 1) {
                endpointIterator = IOUSBGetNextEndpointDescriptor(interface.configurationDescriptor, interface.interfaceDescriptor, $0)
            }
        }
        logger.debug("created \(endpointPipes.count) pipes")

        guard endpointPipes.count == 2 else {
            throw USBError.claimInterface("expected to find bulk for read and write")
        }

        writeEndpoint = endpointPipes.first(where: { EndpointAddress(rawValue: $0.endpointAddress).isWritable })!
        readEndpoint = endpointPipes.first(where: { !EndpointAddress(rawValue: $0.endpointAddress).isWritable })!
    }


    /// Synchronously send USB control transfer.
    func controlTransfer(requestType: BMRequestType, bRequest: UInt8, wValue: UInt16, wIndex: UInt16, data: Data?, wLength: UInt16) -> Int32 {
        // USB 2.0 9.3.4: wIndex
        // some interpretations (high bits 0):
        //   as endpoint (direction:1/0:3/endpoint:4)
        //   as interface (interface number)
        // semantics for ControlRequestType.standard requests are defined in
        // Table 9.4 Standard Device Requests
        // ControlRequestType.vendor semantics may vary.
        // FIXME: could we make .standard calls more typesafe?
        // FIXME: Using an API that is not documented in the 11.1 SDK, but instead
        // is discovered by looking at the Objective-C headers and either making guesses
        // about the NS_REFINED_FOR_SWIFT extensions or using those methods directly.
        // Hopefully the next SDK will be more clear about how bridging should work.

        let payload: NSMutableData?
        if let data = data {
            payload = NSMutableData(data: data)
        } else {
            payload = nil
        }

        let request = IOUSBDeviceRequest(bmRequestType: requestType, bRequest: bRequest, wValue: wValue, wIndex: wIndex, wLength: wLength)
        var transferred: Int = 0

        // FIXME: There is control request code described in the IOSUSBHostPipe headers,
        // but they are marked NS_REFINED_FOR_SWIFT, suggesting there is an extension
        // somewhere that provides a prettier API. However, I can't seem to find that
        // extension, so am using the hidden-but-available function (hidden with
        // a pair of leading underscores.
        try! device.__send(request, //IOUSBDeviceRequest)request
                           data: payload, //data:(nullable NSMutableData*)data
                           bytesTransferred: &transferred, //bytesTransferred:(nullable NSUInteger*)bytesTransferred
                           completionTimeout: timeout) //completionTimeout:(NSTimeInterval)completionTimeout
        return Int32(transferred)
    }


    public func bulkTransferOut(msg: Data) {
        let payload = NSMutableData(data: msg)

        var bytesSent = 0
        let resultsAvailable = DispatchSemaphore(value: 0)
        try! writeEndpoint.enqueueIORequest(with: payload, completionTimeout: timeout) {
            status, bytesTransferred in
            logger.trace("bulkTransferOut completed with status \(status); \(bytesTransferred) of \(msg.count) bytes transferred")
            guard status == 0 else {
                fatalError("bulkTransferOut IORequest failure: code \(status)")
            }
            bytesSent = bytesTransferred
            resultsAvailable.signal()
        }
        resultsAvailable.wait()

        guard msg.count == bytesSent else {
            fatalError("not all msg bytes sent")
        }
    }

    public func bulkTransferIn() -> Data {
        // provide space in a local buffer to hold read results
        // Note that 'capacity' and 'length' are different concepts, and it is
        // the latter that matters when passing the buffer. Length initializes
        // bytes to zero.
        let localBuffer = NSMutableData(length: Int(readEndpoint.descriptors.pointee.descriptor.wMaxPacketSize))
        var bytesReceived = 0

        let resultsAvailable = DispatchSemaphore(value: 0)
        try! readEndpoint.enqueueIORequest(with: localBuffer, completionTimeout: timeout) {
            status, bytesTransferred in
            guard status == 0 else {
                fatalError("bulkTransfer read status: \(status)")
            }
            bytesReceived = bytesTransferred
            resultsAvailable.signal()
        }
        resultsAvailable.wait()

        return Data(localBuffer!.prefix(bytesReceived))
    }
}
