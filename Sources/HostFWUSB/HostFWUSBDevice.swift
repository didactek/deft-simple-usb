//
//  HostFWUSBDevice.swift
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
import SimpleUSB


/// Bridge to the macOS IOUSBHostDevice class in the IOUSBHost usermode USB framework.
/// Obtain a FWUSBDevice from the findDevice vendor in the USBBus provider. FWUSBDevice
/// configures default configuration endpoints for bulk read and write, and provides control transfer
/// support.
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
        logger.trace("Device supports \(interfacesCount) interfaces")

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
        logger.trace("created \(endpointPipes.count) pipes")

        guard endpointPipes.count == 2 else {
            throw USBError.claimInterface("expected to find bulk for read and write")
        }

        writeEndpoint = endpointPipes.first(where: { EndpointAddress(rawValue: $0.endpointAddress).isWritable })!
        readEndpoint = endpointPipes.first(where: { !EndpointAddress(rawValue: $0.endpointAddress).isWritable })!

        logger.debug("Connected to device with idVendor \(device.deviceDescriptor!.pointee.idVendor); idProduct: \(device.deviceDescriptor!.pointee.idProduct)")
    }

    // Documented in protocol
    public func controlTransfer(requestType: BMRequestType, bRequest: UInt8, wValue: UInt16, wIndex: UInt16, data: Data?, wLength: UInt16) -> Int32 {
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

        // FIXME: There are control request methods described in the IOSUSBHostPipe
        // Objective-C headers, but they are marked NS_REFINED_FOR_SWIFT, suggesting
        // there is an extension somewhere that provides a prettier API. However,
        // I can't seem to find that extension, so am using the hidden-but-available
        // method. (NS_REFINED_FOR_SWIFT mangles the method name with
        // a pair of leading underscores.)
        try! device.__send(request, //IOUSBDeviceRequest)request
                           data: payload, //data:(nullable NSMutableData*)data
                           bytesTransferred: &transferred, //bytesTransferred:(nullable NSUInteger*)bytesTransferred
                           completionTimeout: timeout) //completionTimeout:(NSTimeInterval)completionTimeout
        return Int32(transferred)
    }

    // Documented in protocol
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

    // Documented in protocol
    public func bulkTransferIn() -> Data {
        // Provide space in a local buffer to hold read results.
        // Note that 'capacity' and 'length' are different concepts, and it is
        // the length (number of intialized bytes) that is used by the IO request
        // machinery to infer the buffer size.
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
#endif
