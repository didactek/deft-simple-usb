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
    let device: IOUSBHostDevice
    let writeEndpoint: IOUSBHostPipe
    let readEndpoint: IOUSBHostPipe
    #endif
    var usbWriteTimeout: UInt32 = 5000  // FIXME

    #if true  // IOUSBHost implementation
    init(device: IOUSBHostDevice) throws {
        // like the libusb version:
        logger.trace("Configuring USBDevice with descriptor \(device.deviceDescriptor!.pointee)")

        self.device = device

        // get configuration
        // assume configuration zero (and throws with configuration 1 or -1)
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
        // FIXME: hardcoded kIOUSBFindInterfaceDontCare is 65535; doesn't help
        // when used for class/subclass/protocol.
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
        buffer = try! interface.ioData(withCapacity: Int(writeEndpoint.descriptors.pointee.descriptor.wMaxPacketSize))

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
        let requestSize = data?.count ?? 0

        let result = controlTransfer(requestType: requestType,
                                     bRequest: bRequest,
                                     wValue: value, wIndex: wIndex,
                                     data: data,
                                     wLength: UInt16(requestSize), timeout: usbWriteTimeout)

        guard result == requestSize else {
            // FIXME: should probably throw rather than abort, and maybe not all calls need to be this strict
            fatalError("controlTransferOut failed: transferred \(result) bytes of \(requestSize)")
        }
    }

    /// Synchronously send USB control transfer.
    /// - parameter timeout: timeout in milliseconds
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
        // FIXME: Using an API that is not documented in the 11.1 SDK, but instead
        // is discovered by looking at the Objective-C headers and either making guesses
        // about the NS_REFINED_FOR_SWIFT extensions or using those methods directly.
        // Hopefully the next SDK will be more clear about how bridging should work.

        let payload: NSMutableData? = data == nil ? nil : NSMutableData(data: data!)

        let request = IOUSBDeviceRequest(bmRequestType: requestType, bRequest: bRequest, wValue: wValue, wIndex: wIndex, wLength: wLength)
        let timeout = TimeInterval(Double(timeout)/1_000.0)
        var transferred: Int = 0

        // FIXME: There is control request code described in the IOSUSBHostPipe headers,
        // but they are marked NS_REFINED_FOR_SWIFT, suggesting there is an extension
        // somewhere that provides a prettier API. However, I can't seem to find that
        // extension, so am going to try the hidden-but-available function (hidden with
        // a pair of leading underscores.
        //
        // Hoping that send on the *device* uses the proper endpoint zero.
        try! device.__send(request, //IOUSBDeviceRequest)request
                           data: payload, //data:(nullable NSMutableData*)data
                           bytesTransferred: &transferred, //bytesTransferred:(nullable NSUInteger*)bytesTransferred
                           completionTimeout: timeout) //completionTimeout:(NSTimeInterval)completionTimeout
        return Int32(transferred)
        #endif  // IOUSBHost implementation
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
        try! writeEndpoint.enqueueIORequest(with: payload, completionTimeout: TimeInterval(usbWriteTimeout)) {
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

        // provide space in a local buffer to hold read results
        // Note that 'capacity' and 'length' are different concepts, and it is
        // the latter that matters when passing the buffer. Length initializes
        // bytes to zero.
        let localBuffer = NSMutableData(length: Int(readEndpoint.descriptors.pointee.descriptor.wMaxPacketSize))
        try! readEndpoint.enqueueIORequest(with: localBuffer, completionTimeout: TimeInterval(usbWriteTimeout)) {
            status, bytesTransferred in
            guard status == 0 else {
                fatalError("bulkTransfer read status: \(status)")
            }
            bytesReceived = bytesTransferred
            resultsAvailable.signal()
        }
        resultsAvailable.wait()
        return Data(localBuffer!.prefix(bytesReceived))

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
