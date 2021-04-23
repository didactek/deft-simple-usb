//
//  USBDevice.swift
//  ftdi-synchronous-serial
//
//  Created by Kit Transue on 2020-08-02.
//  Copyright © 2020 Kit Transue
//  SPDX-License-Identifier: Apache-2.0
//

import Foundation
import Logging
#if false  // libusb implementation
import CLibUSB
#else  // IOUSBHost implementation
import IOUSBHost
#endif


var logger = Logger(label: "com.didactek.ftdi-synchronous-serial.main")
// FIXME: how to default configuration to debug?

struct EndpointAddress {
    #if false  // libusb implementation
    typealias RawValue = UInt8
    #else  // IOUSBHost implementation
    typealias RawValue = Int
    enum EndpointDirection: RawValue {
        // Table 9-13. Standard Endpoint Descriptor
        case input = 0b1000_0000
        case output = 0
    }
    #endif
    let rawValue: RawValue

    init(rawValue: RawValue) {
        self.rawValue = rawValue
    }

    // USB 2.0: 9.6.6 Endpoint:
    // Bit 7 is direction IN/OUT
    #if false   // libusb implementation
    let directionMask = Self.RawValue(LIBUSB_ENDPOINT_IN.rawValue | LIBUSB_ENDPOINT_OUT.rawValue)
    #else  // IOUSBHub implementation
    let directionMask = Self.RawValue(EndpointDirection.input.rawValue | EndpointDirection.output.rawValue)
    #endif

    var isWritable: Bool {
        get {
            #if false   // libusb implementation
            return rawValue & directionMask == LIBUSB_ENDPOINT_OUT.rawValue
            #else  // IOUSBHub implementation
            return rawValue & directionMask == EndpointDirection.output.rawValue
            #endif
        }
    }
}

public class USBDevice {

    enum USBError: Error {
        case bindingDeviceHandle(String)
        case getConfiguration(String)
        case claimInterface(String)
    }

    #if false  // libusb implementation
    let subsystem: USBBus // keep the subsytem alive
    let device: OpaquePointer
    var handle: OpaquePointer? = nil
    let interfaceNumber: Int32 = 0

    let writeEndpoint: EndpointAddress
    let readEndpoint: EndpointAddress
    #else  // IOUSBHost implementation
    let buffer: NSMutableData
    let controlEndpoint: IOUSBHostPipe
    let bulkEndpoint: IOUSBHostPipe
    #endif
    var usbWriteTimeout: UInt32 = 5000  // FIXME

    #if true  // IOUSBHost implementation
    init(device: IOUSBHostDevice) throws {
        // like the libusb version:
        logger.trace("Configuring USBDevice with descriptor \(device.deviceDescriptor!.pointee)")

        // get configuration
        // assume configuration zero
        let configuration = try! device.configurationDescriptor(with: 0).pointee

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
        let interfaceSearchStrings: [IOUSBHostMatchingPropertyKey : Int] = [
            :
        ]
        let searchRequest = (interfaceSearchInts as NSDictionary).mutableCopy() as! NSMutableDictionary
        searchRequest.addEntries(from: interfaceSearchStrings)
        searchRequest.addEntries(from: ["IOProviderClass" : "IOUSBHostInterface"])

        let service = IOServiceGetMatchingService(kIOMasterPortDefault, searchRequest)

        let interface = try! IOUSBHostInterface.init(__ioService: service, options: [], queue: nil, interestHandler: nil)

        // FIXME: 1024 pulled from air
        buffer = try! interface.ioData(withCapacity: 1024)

        // get write and read endpoints
        // FIXME: who knows if these are the right way around!
        var endpointPipes = [IOUSBHostPipe]()
        var endpointIterator = IOUSBGetNextEndpointDescriptor(interface.configurationDescriptor, interface.interfaceDescriptor, nil)
        while let endpointFound = endpointIterator {
            logger.trace("Making pipe for endpoint: \(endpointFound.pointee)")
            endpointPipes.append(try interface.copyPipe(withAddress: Int(endpointFound.pointee.bEndpointAddress)))
            endpointFound.withMemoryRebound(to: IOUSBDescriptorHeader.self, capacity: 1) {
                endpointIterator = IOUSBGetNextEndpointDescriptor(interface.configurationDescriptor, interface.interfaceDescriptor, $0)
            }
        }
        logger.debug("created \(endpointPipes.count) pipes")

        // FIXME: only getting two pipes.
        guard endpointPipes.count == 2 else {
            throw USBError.claimInterface("expected pipes for control and bulk")
        }

        // FIXME: maybe 1 write, 1 read assumes wrong semantics.
        // Maybe we get Control (with read and write streams) +
        // Bulk (with read and write streams)?
        bulkEndpoint = endpointPipes[1]
        controlEndpoint = endpointPipes[0]

        // FIXME: remove nextInterface checking. This is just to clarify that we can only obtain
        // one interface using IOUSBGetNextInterfaceDescriptor.
        let nextInterface = interfaceDescription.withMemoryRebound(to: IOUSBDescriptorHeader.self, capacity: 1) {
            IOUSBGetNextInterfaceDescriptor(device.configurationDescriptor, $0)
        }
        guard nextInterface == nil || interfacesCount > 1 else {
            logger.trace("Next interface is: \(nextInterface!)")
            fatalError("More interfaces available than promised")
        }
    }
    #else  // libusb implementation
    init(subsystem: USBBus, device: OpaquePointer) throws {
        self.subsystem = subsystem
        self.device = device

        USBBus.checkCall(libusb_open(device, &handle)) { msg in  // deinit: libusb_close
            throw USBError.bindingDeviceHandle(msg)
        }

        var configurationPtr: UnsafeMutablePointer<libusb_config_descriptor>? = nil
        defer {
            libusb_free_config_descriptor(configurationPtr)
        }
        USBBus.checkCall(libusb_get_active_config_descriptor(device, &configurationPtr)) { msg in
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
        // This seesm to be OK to do on macOS
        libusb_set_auto_detach_kernel_driver(handle, 1 /* non-zero is 'yes: enable' */)

        USBBus.checkCall(libusb_claim_interface(handle, interfaceNumber)) { msg in  // deinit: libusb_release_interface
            // FIXME: "Resource Busy" on Linux may be the ftdi_sio driver being associated with the device.
            // Proper setup should fix this. Proper setup being...????
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
    #endif

    deinit {
        #if false // libusb implementation
        libusb_release_interface(handle, interfaceNumber)
        libusb_close(handle)
        libusb_unref_device(device)
        #endif
    }


    // USB spec 2.0, sec 9.3: USB Device Requests
    // USB spec 2.0, sec 9.3.1: bmRequestType
    typealias BMRequestType = UInt8
    enum ControlDirection: BMRequestType {
        case hostToDevice = 0b0000_0000
        case deviceToHost = 0b1000_0000
    }
    enum ControlRequestType: BMRequestType {
        case standard = 0b00_00000
        case `class`  = 0b01_00000
        case vendor   = 0b10_00000
        case reserved = 0b11_00000
    }
    enum ControlRequestRecipient: BMRequestType {
        case device = 0
        case interface = 1
        case endpoint = 2
        case other = 3
    }

    // basically IOUSBHostPipe.IOUSBHostDeviceRequestType
    func controlRequest(type: ControlRequestType, direction: ControlDirection, recipient: ControlRequestRecipient) -> BMRequestType {
        return type.rawValue | direction.rawValue | recipient.rawValue
    }

    public func controlTransferOut(bRequest: UInt8, value: UInt16, wIndex: UInt16, data: Data? = nil) {
        let requestType = controlRequest(type: .vendor, direction: .hostToDevice, recipient: .device)

        let result = controlTransfer(requestType: requestType,
                                     bRequest: bRequest,
                                     wValue: value, wIndex: wIndex,
                                     data: data,
                                     wLength: UInt16(data?.count ?? 0), timeout: usbWriteTimeout)
        guard result == 0 else {
            // FIXME: should probably throw rather than abort, and maybe not all calls need to be this strict
            fatalError("controlTransferOut failed")
        }
    }

    /// Synchronously send USB control transfer.
    /// - returns: number of bytes transferred (if success)
    func controlTransfer(requestType: BMRequestType, bRequest: UInt8, wValue: UInt16, wIndex: UInt16, data: Data?, wLength: UInt16, timeout: UInt32) -> Int32 {
        // USB 2.0 9.3.4: wIndex
        // some interpretations (high bits 0):
        //   as endpoint (direction:1/0:3/endpoint:4)
        //   as interface (interface number)
        // semantics for ControlRequestType.standard requests are defined in
        // Table 9.4 Standard Device Requests
        // ControlRequestType.vendor semantics may vary.
        // FIXME: could we make .standard calls more typesafe?
        #if false  // libusb implementation
        var dataCopy = Array(data ?? Data())
        return dataCopy.withUnsafeMutableBufferPointer {
            libusb_control_transfer(handle, requestType, bRequest, wValue, wIndex, $0.baseAddress, wLength, timeout)
        }
        #else  // IOUSBHost implementation
        // The Objective-C API provides a "sendControlRequest" which is not avaliable
        // in the Swift API. The following is my attempt to discover an alternative
        // pattern.

        // IOUSBHostDeviceRequestType is the only method documented in the "Send Control Requests"
        // section, but it is a helper that constructs the request type (BMRequestType in the linux
        // implementation here).

        // Since in USB, the control endpoint is endpoint 0, maybe I do all the
        // work of formatting and writing on that endpoint?

        // Format described in [USB 2.0](https://www.usb.org/document-library/usb-20-specification) 9.3 USB Device Requests
        // Protocol is little-endian [USB 2.0](https://www.usb.org/document-library/usb-20-specification) 8.1 Byte/Bit Ordering
        let wordsSegment = [wValue, wIndex, wLength].map { word in
            withUnsafeBytes(of: word.littleEndian) { Data($0) }
        }.joined()
        let request = NSMutableData(data: Data([
            requestType,
            bRequest]) + wordsSegment)

        if let data = data {
            data.copyBytes(to: buffer.mutableBytes.assumingMemoryBound(to: UInt8.self), from: 0..<data.count)
        }

        var bytesSent = 0
        let resultsAvailable = DispatchSemaphore(value: 0)
        try! controlEndpoint.enqueueIORequest(with: request, completionTimeout: TimeInterval(usbWriteTimeout)) {
            status, bytesTransferred in
            bytesSent = bytesTransferred  // FIXME: getting 2 instead of 0? Something awry with request?
            resultsAvailable.signal()
        }
        resultsAvailable.wait()

        return Int32(bytesSent)
        #endif
    }


    public func bulkTransferOut(msg: Data) {
        #if true  // IOUSBHost implementation
        let payload = NSMutableData(data: msg)
        // Making stabs at the semantics surrounding buffer and with: parameter.
        // Since I don't see a way of communicating the length of the message
        // if using the buffer, will assume that for outgoing we want to send
        // the msg as the with: parameter of the IO Request.

        var bytesSent = 0
        let resultsAvailable = DispatchSemaphore(value: 0)
        try! bulkEndpoint.enqueueIORequest(with: payload, completionTimeout: TimeInterval(usbWriteTimeout)) {
            status, bytesTransferred in
            logger.trace("bulkTransferOut completed with status \(status); \(bytesTransferred) of \(msg.count) bytes transferred")
            bytesSent = bytesTransferred
            resultsAvailable.signal()
        }
        resultsAvailable.wait()

//        guard result == 0 else {
//            fatalError("bulkTransfer returned \(result)")
//        }
        guard msg.count == bytesSent else {
            fatalError("not all bytes sent")
        }

        // defeat control flow analysis to preserve syntax checking of code after this
        if Date.init().timeIntervalSince1970 > 5 {
            fatalError("bulkTransferOut implementation is untested")
        }
        // end control flow defeat/runtime warning
        #else  // libusb implementation
        let outgoingCount = Int32(msg.count)

        var bytesTransferred = Int32(0)
        var msgScratchCopy = msg

        let result = msgScratchCopy.withUnsafeMutableBytes { unsafe in
            libusb_bulk_transfer(handle, writeEndpoint.rawValue, unsafe.bindMemory(to: UInt8.self).baseAddress, outgoingCount, &bytesTransferred, usbWriteTimeout)
        }
        guard result == 0 else {
            fatalError("bulkTransfer returned \(result)")
        }
        guard outgoingCount == bytesTransferred else {
            fatalError("not all bytes sent")
        }
        #endif
    }

    public func bulkTransferIn() -> Data {
        #if true  // IOUSBHost implementation
        var bytesReceived = 0
        let resultsAvailable = DispatchSemaphore(value: 0)
        try! bulkEndpoint.enqueueIORequest(with: nil, completionTimeout: TimeInterval(usbWriteTimeout)) {
            status, bytesTransferred in
            guard status == 0 else {
                fatalError("bulkTransfer read returned \(status)")
            }
            bytesReceived = bytesTransferred
            resultsAvailable.signal()
        }
        resultsAvailable.wait()


        // defeat control flow analysis to preserve syntax checking of code after this
        if Date.init().timeIntervalSince1970 > 5 {
            fatalError("bulkTransferIn implementation is untested")
        }
        // end control flow defeat/runtime warning

        return Data(buffer.prefix(bytesReceived))
        #else  // libusb implementation
        let bufSize = 1024 // FIXME: tell the device about this!
        var readBuffer = Array(repeating: UInt8(0), count: bufSize)
        var readCount = Int32(0)
        let result = libusb_bulk_transfer(handle, readEndpoint.rawValue, &readBuffer, Int32(bufSize), &readCount, usbWriteTimeout)
        guard result == 0 else {
            let errorMessage = String(cString: libusb_error_name(result)) // must not free message
            fatalError("bulkTransfer read returned \(result): \(errorMessage)")
        }
        return Data(readBuffer.prefix(Int(readCount))) // FIXME: Xcode 11.6 / Swift 5.2.4: explicit constructor is needed to avoid crash in Data subrange if we just return the prefix!! This seems like a bug????
        #endif
    }
}
